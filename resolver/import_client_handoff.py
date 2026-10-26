"""
Turn a filled client VPC handoff (client-vpc-handoff-template.yaml) into a
workspace request (CLAUDE.md §10 item #15).

Checks the handoff against live AWS first, read-only (describe-* calls
only), then writes workspace-requests/aws/<env>/<name>.yaml. The network
section maps to existing request fields: compute subnets and their route
tables are adopted, backend subnets hold any endpoints the factory still
creates, and the client's S3 gateway endpoint is reused. Edge subnets,
NATs and the TGW are checked here but never consumed by Terraform.

Usage:
    python resolver/import_client_handoff.py \
        --handoff client-handoffs/aws/dev/<name>.yaml \
        --request-id REQ-00200 --submitted-by <you> \
        --cost-center <cc> [--classification internal] \
        [--technical-owner ...] [--business-owner ...] \
        [--skip-aws-checks] [--force]
"""

import argparse
import ipaddress
import json
import subprocess
import sys
from pathlib import Path

import yaml

from loader import load_yaml

ROOT = Path(__file__).resolve().parents[1]

# Databricks' allowed netmask range for workspace subnets.
DATABRICKS_MIN_PREFIX = 17
DATABRICKS_MAX_PREFIX = 26


class HandoffError(ValueError):
    pass


def find_placeholders(node, path="") -> list[str]:
    found = []

    if isinstance(node, dict):
        for key, value in node.items():
            found += find_placeholders(value, f"{path}.{key}" if path else key)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            found += find_placeholders(value, f"{path}[{i}]")
    elif isinstance(node, str) and "REPLACE-ME" in node:
        found.append(path)

    return found


def validate_shape(handoff: dict) -> None:
    placeholders = find_placeholders(handoff)

    if placeholders:
        raise HandoffError(
            "Handoff still has REPLACE-ME values: " + ", ".join(placeholders)
        )

    azs = handoff.get("availability_zones") or []

    if len(azs) != 2:
        raise HandoffError("Handoff must list exactly two availability_zones.")

    for az in azs:
        prefix = ipaddress.ip_network(az["compute_subnet"]["cidr"]).prefixlen

        if not DATABRICKS_MIN_PREFIX <= prefix <= DATABRICKS_MAX_PREFIX:
            raise HandoffError(
                f"Compute subnet {az['compute_subnet']['id']} is a /{prefix}; "
                f"Databricks needs /{DATABRICKS_MIN_PREFIX} to /{DATABRICKS_MAX_PREFIX}."
            )


# ---------------------------------------------------------------------------
# Live AWS checks
# ---------------------------------------------------------------------------


def aws(region: str, *args: str) -> dict:
    result = subprocess.run(
        ["aws", *args, "--region", region, "--output", "json"],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        raise HandoffError(f"aws {' '.join(args[:2])} failed: {result.stderr.strip()}")

    return json.loads(result.stdout or "{}")


def check_live(handoff: dict) -> list[str]:
    """Returns a list of problems; empty means the handoff matches AWS."""

    region = handoff["aws"]["region"]
    vpc = handoff["vpc"]
    azs = handoff["availability_zones"]
    problems = []

    identity = aws(region, "sts", "get-caller-identity")

    if identity["Account"] != str(handoff["aws"]["account_id"]):
        raise HandoffError(
            f"Current AWS credentials are for account {identity['Account']}, "
            f"but the handoff is for {handoff['aws']['account_id']}."
        )

    # VPC, both CIDRs, DNS
    found = aws(region, "ec2", "describe-vpcs", "--vpc-ids", vpc["id"])["Vpcs"][0]
    cidrs = {
        a["CidrBlock"]
        for a in found["CidrBlockAssociationSet"]
        if a["CidrBlockState"]["State"] == "associated"
    }

    for key in ("primary_cidr", "secondary_cidr"):
        if vpc[key] not in cidrs:
            problems.append(f"VPC {vpc['id']} has no associated {key} {vpc[key]} (has {sorted(cidrs)})")

    for attribute in ("enableDnsSupport", "enableDnsHostnames"):
        value = aws(
            region, "ec2", "describe-vpc-attribute",
            "--vpc-id", vpc["id"], "--attribute", attribute,
        )[attribute[0].upper() + attribute[1:]]["Value"]

        if not value:
            problems.append(f"VPC {vpc['id']} has {attribute} disabled")

    # Subnets: in the VPC, with the stated CIDR and AZ
    expected = {}

    for az in azs:
        for tier in ("edge_subnet", "compute_subnet", "backend_subnet"):
            expected[az[tier]["id"]] = (az[tier]["cidr"], az["name"], tier)

    subnets = aws(region, "ec2", "describe-subnets", "--subnet-ids", *expected)["Subnets"]

    for subnet in subnets:
        cidr, az_name, tier = expected[subnet["SubnetId"]]

        if subnet["VpcId"] != vpc["id"]:
            problems.append(f"{tier} {subnet['SubnetId']} is in {subnet['VpcId']}, not {vpc['id']}")
        if subnet["CidrBlock"] != cidr:
            problems.append(f"{tier} {subnet['SubnetId']} is {subnet['CidrBlock']}, not {cidr}")
        if subnet["AvailabilityZone"] != az_name:
            problems.append(f"{tier} {subnet['SubnetId']} is in {subnet['AvailabilityZone']}, not {az_name}")

    # NATs: private, available, in their AZ's edge subnet
    nat_ids = [az["private_nat_gateway_id"] for az in azs]
    nats = {
        n["NatGatewayId"]: n
        for n in aws(region, "ec2", "describe-nat-gateways", "--nat-gateway-ids", *nat_ids)["NatGateways"]
    }

    for az in azs:
        nat = nats.get(az["private_nat_gateway_id"])

        if nat is None:
            problems.append(f"NAT gateway {az['private_nat_gateway_id']} not found")
            continue
        if nat["SubnetId"] != az["edge_subnet"]["id"]:
            problems.append(f"NAT {nat['NatGatewayId']} is in {nat['SubnetId']}, not edge subnet {az['edge_subnet']['id']}")
        if nat.get("ConnectivityType") != "private":
            problems.append(f"NAT {nat['NatGatewayId']} is not a private NAT gateway")
        if nat["State"] != "available":
            problems.append(f"NAT {nat['NatGatewayId']} is {nat['State']}")

    # Compute route tables: associated with their subnet, default route to
    # the same-AZ NAT
    compute_rt_ids = [az["compute_subnet"]["route_table_id"] for az in azs]
    route_tables = {
        rt["RouteTableId"]: rt
        for rt in aws(region, "ec2", "describe-route-tables", "--route-table-ids", *compute_rt_ids)["RouteTables"]
    }

    for az in azs:
        rt = route_tables[az["compute_subnet"]["route_table_id"]]
        associated = {a.get("SubnetId") for a in rt["Associations"]}

        if az["compute_subnet"]["id"] not in associated:
            problems.append(f"Compute subnet {az['compute_subnet']['id']} is not associated with {rt['RouteTableId']}")

        default = [r for r in rt["Routes"] if r.get("DestinationCidrBlock") == "0.0.0.0/0"]

        if not default or default[0].get("NatGatewayId") != az["private_nat_gateway_id"]:
            problems.append(f"Route table {rt['RouteTableId']} has no 0.0.0.0/0 route to NAT {az['private_nat_gateway_id']}")

    # S3 gateway endpoint on both compute route tables
    s3_id = handoff["vpc_endpoints"]["s3_gateway_endpoint_id"]
    endpoint = aws(region, "ec2", "describe-vpc-endpoints", "--vpc-endpoint-ids", s3_id)["VpcEndpoints"][0]

    missing = set(compute_rt_ids) - set(endpoint["RouteTableIds"])

    if endpoint["VpcId"] != vpc["id"] or missing:
        problems.append(f"S3 endpoint {s3_id} must be in {vpc['id']} and on route tables {sorted(missing)}")

    return problems


# ---------------------------------------------------------------------------
# Request
# ---------------------------------------------------------------------------


def build_request(handoff: dict, args) -> dict:
    azs = handoff["availability_zones"]
    endpoints = handoff["vpc_endpoints"]

    network = {
        "strategy": "custom",
        "existing_vpc_id": handoff["vpc"]["id"],
        "existing_vpc_cidr": handoff["vpc"]["primary_cidr"],
        "existing_subnet_ids": [az["compute_subnet"]["id"] for az in azs],
        "existing_route_table_ids": [az["compute_subnet"]["route_table_id"] for az in azs],
        "existing_endpoint_subnet_ids": [az["backend_subnet"]["id"] for az in azs],
        "existing_s3_gateway_endpoint_id": endpoints["s3_gateway_endpoint_id"],
    }

    for source, target in (
        ("sts_interface_endpoint_id", "existing_sts_endpoint_id"),
        ("kms_interface_endpoint_id", "existing_kms_endpoint_id"),
    ):
        if endpoints.get(source):
            network[target] = endpoints[source]

    if str(handoff["databricks"].get("enterprise_tier")).lower() == "true":
        network["connectivity"] = "privatelink"

    cloud = {"provider": "aws", "region": handoff["aws"]["region"]}

    if handoff["databricks"].get("account_id"):
        cloud["databricks_account_id"] = handoff["databricks"]["account_id"]

    workspace = handoff["workspace"]

    return {
        "api_version": "v1",
        "request": {
            "id": args.request_id,
            "submitted_by": args.submitted_by,
            "source": "workspace-request",
        },
        "workspace": {"name": workspace["name"], "environment": workspace["environment"]},
        "cloud": cloud,
        "application": {
            "name": workspace.get("application") or workspace["name"],
            "identifier": workspace["name"],
        },
        "ownership": {
            "technical_owner": args.technical_owner,
            "business_owner": args.business_owner,
        },
        "data": {"classification": args.classification},
        "network": network,
        "tags": {"cost_center": args.cost_center},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--handoff", required=True)
    parser.add_argument("--request-id", required=True, help="REQ-#### for the new request")
    parser.add_argument("--submitted-by", required=True)
    parser.add_argument("--cost-center", required=True)
    parser.add_argument("--classification", default="internal")
    parser.add_argument("--technical-owner", default="platform-team")
    parser.add_argument("--business-owner", default="technology")
    parser.add_argument("--skip-aws-checks", action="store_true", help="Only check the file itself")
    parser.add_argument("--force", action="store_true", help="Overwrite an existing request")
    args = parser.parse_args()

    try:
        handoff = load_yaml(Path(args.handoff))
        validate_shape(handoff)

        if args.skip_aws_checks:
            print("[import] skipping live AWS checks")
        else:
            problems = check_live(handoff)

            if problems:
                raise HandoffError(
                    "Handoff doesn't match AWS:\n  - " + "\n  - ".join(problems)
                )

            print("[import] handoff matches live AWS")

        request = build_request(handoff, args)
        workspace = handoff["workspace"]
        out = ROOT / "workspace-requests" / "aws" / workspace["environment"] / f"{workspace['name']}.yaml"

        if out.exists() and not args.force:
            raise HandoffError(f"{out.relative_to(ROOT)} already exists (use --force to overwrite).")

        header = (
            f"# Generated from {Path(args.handoff).as_posix()} by "
            "resolver/import_client_handoff.py.\n"
            "# The network section is the client's VPC; edit the rest freely.\n"
        )

        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(header + yaml.safe_dump(request, sort_keys=False), encoding="utf-8")
        print(f"[import] wrote {out.relative_to(ROOT).as_posix()}")

    except (HandoffError, FileNotFoundError, KeyError) as error:
        print(f"[import] FAILED: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
