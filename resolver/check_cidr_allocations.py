"""
Checks every committed workspace's VPC/subnet CIDRs for collisions and, for
'isolated' workspaces, containment within the reserved pool declared in
platform/inventory/aws.yaml.

This is a checker, not an allocator - picking the actual CIDR value for a
new workspace is still a manual step in its deployment.yaml. What this
closes is the silent-collision gap: previously the only way to know whether
a newly-chosen CIDR was already taken was to manually read every other
workspace's deployment.yaml. See CLAUDE.md Sec5.12 / Sec8 milestone 14.

Can be run standalone (`python resolver/check_cidr_allocations.py`) to
audit everything committed, or imported and called by
generate_tfvars.py so a new/changed deployment.yaml is checked before its
tfvars are written.
"""

from pathlib import Path
import ipaddress

from loader import load_yaml
from inventory import find_primary_network

ROOT = Path(__file__).resolve().parent.parent


def _load_pool(inventory: dict) -> ipaddress.IPv4Network:
    pool = inventory.get("cidr_pools", {}).get("isolated_vpc_pool")

    if pool is None:
        raise ValueError(
            "platform/inventory/aws.yaml is missing "
            "'cidr_pools.isolated_vpc_pool'."
        )

    return ipaddress.ip_network(pool)


def _iter_deployments() -> list[tuple[str, dict, dict]]:
    """Return (workspace_name, deployment_dict, normalized_dict) for every
    committed deployment.yaml under infrastructure/deployments/ (paired
    with its same-named normalized/<workspace>.yaml - the same pairing
    generate_tfvars.py itself relies on)."""

    deployments_root = ROOT / "infrastructure" / "deployments"

    results = []

    for deployment_path in sorted(deployments_root.glob("*/*/deployment.yaml")):
        workspace_name = deployment_path.parent.name
        normalized_path = ROOT / "normalized" / f"{workspace_name}.yaml"
        results.append(
            (
                workspace_name,
                load_yaml(deployment_path),
                load_yaml(normalized_path),
            )
        )

    return results


def _vpc_scope(
    workspace_name: str,
    deployment: dict,
    normalized: dict,
    inventory: dict,
) -> tuple[str, ipaddress.IPv4Network | None]:
    """
    Return (scope_key, vpc_network_or_None) for a workspace.

    scope_key groups workspaces that share the same VPC (so their subnets
    must not collide): every 'isolated' workspace gets its own unique VPC,
    so its scope key is itself; an 'existing' VPC reused by more than one
    workspace shares a scope key (the vpc_id).
    """

    network = deployment.get("network", {})
    platform = deployment.get("platform", {})

    vpc_cidr = network.get("vpc_cidr")
    vpc_id = platform.get("vpc_id")
    existing_vpc_cidr = platform.get("vpc_cidr")

    if vpc_cidr is not None:
        return (f"isolated:{workspace_name}", ipaddress.ip_network(vpc_cidr))

    if vpc_id is None:
        # Not in deployment.yaml - fall back to the account/region's known
        # primary network, the same auto-lookup generate_tfvars.py uses for
        # the actual Terraform var (CLAUDE.md Sec5.3/Sec8).
        primary = find_primary_network(
            normalized["cloud"]["account"], normalized["cloud"]["region"], inventory
        )

        vpc_id = primary.get("vpc", {}).get("id")
        existing_vpc_cidr = existing_vpc_cidr or primary.get("vpc", {}).get("cidr")

    if vpc_id is not None:
        vpc_network = (
            ipaddress.ip_network(existing_vpc_cidr)
            if existing_vpc_cidr is not None
            else None
        )

        return (f"existing:{vpc_id}", vpc_network)

    raise ValueError(
        f"Workspace '{workspace_name}' deployment.yaml defines neither "
        f"network.vpc_cidr (isolated) nor platform.vpc_id (existing), and "
        f"no primary network is known in platform/inventory/aws.yaml for "
        f"its AWS account/region - cannot determine its VPC."
    )


def check_all() -> None:
    """Check every committed deployment.yaml. Raises ValueError on the
    first collision or containment violation found."""

    inventory_path = ROOT / "platform" / "inventory" / "aws.yaml"
    inventory = load_yaml(inventory_path)

    pool = _load_pool(inventory)

    deployments = _iter_deployments()

    # scope_key -> (vpc_network_or_None, [(workspace_name, subnet_cidr), ...])
    scopes: dict[str, tuple[ipaddress.IPv4Network | None, list[tuple[str, ipaddress.IPv4Network]]]] = {}

    # Track each isolated workspace's own VPC network for pairwise overlap
    # checks against every OTHER isolated workspace (different VPCs, but
    # still required to be globally unique - see platform/inventory/aws.yaml).
    isolated_vpcs: list[tuple[str, ipaddress.IPv4Network]] = []

    for workspace_name, deployment, normalized in deployments:
        scope_key, vpc_network = _vpc_scope(
            workspace_name, deployment, normalized, inventory
        )

        if scope_key.startswith("isolated:") and vpc_network is not None:
            if not vpc_network.subnet_of(pool):
                raise ValueError(
                    f"Workspace '{workspace_name}' network.vpc_cidr "
                    f"({vpc_network}) falls outside the reserved isolated-VPC "
                    f"pool ({pool}) declared in "
                    f"platform/inventory/aws.yaml's cidr_pools.isolated_vpc_pool."
                )

            for other_name, other_network in isolated_vpcs:
                if vpc_network.overlaps(other_network):
                    raise ValueError(
                        f"Workspace '{workspace_name}' network.vpc_cidr "
                        f"({vpc_network}) overlaps workspace '{other_name}'s "
                        f"network.vpc_cidr ({other_network})."
                    )

            isolated_vpcs.append((workspace_name, vpc_network))

        deployment_network = deployment.get("network", {})

        # nat_subnet_cidr (when present) is just another subnet in the same
        # VPC - gets the same containment/collision checks as the private
        # subnets (CLAUDE.md §8 milestone 27).
        subnet_cidrs = [
            subnet["cidr"]
            for subnet in deployment_network.get("subnets", {}).get("private", [])
        ]

        nat_subnet_cidr = deployment_network.get("nat_subnet_cidr")

        if nat_subnet_cidr is not None:
            subnet_cidrs.append(nat_subnet_cidr)

        existing_vpc_network, existing_subnets = scopes.get(scope_key, (vpc_network, []))

        for subnet_cidr in subnet_cidrs:
            subnet_network = ipaddress.ip_network(subnet_cidr)

            if existing_vpc_network is not None and not subnet_network.subnet_of(existing_vpc_network):
                raise ValueError(
                    f"Workspace '{workspace_name}' subnet CIDR "
                    f"({subnet_network}) is not contained within its VPC's "
                    f"CIDR ({existing_vpc_network})."
                )

            for other_name, other_subnet_network in existing_subnets:
                if subnet_network.overlaps(other_subnet_network):
                    raise ValueError(
                        f"Workspace '{workspace_name}' subnet CIDR "
                        f"({subnet_network}) overlaps workspace "
                        f"'{other_name}'s subnet CIDR ({other_subnet_network}) "
                        f"within the same VPC."
                    )

            existing_subnets.append((workspace_name, subnet_network))

        scopes[scope_key] = (existing_vpc_network, existing_subnets)


if __name__ == "__main__":
    try:
        check_all()
    except (ValueError, FileNotFoundError, KeyError) as error:
        print()
        print("CIDR allocation check failed")
        print("-----------------------------")
        print()
        print(error)
        print()

        raise SystemExit(1)

    print("CIDR allocation check: PASS")
