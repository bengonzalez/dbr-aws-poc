from pathlib import Path
import argparse
import json

from loader import load_yaml
from check_cidr_allocations import (
    check_all as check_cidr_allocations,
    used_subnets_for_scope,
    vpc_scope,
)
from inventory import (
    allocate_subnets,
    require,
    resolve_connectivity,
    resolve_databricks_account_id,
    resolve_existing_vpc_cidr,
    resolve_metastore_id,
    resolve_platform_network,
    resolve_route_table_ids,
    subnet_defaults_for,
)
from generate_tfvars_azure import main_azure as _main_azure

ROOT = Path(__file__).resolve().parent.parent

KMS_PASSTHROUGH_KEYS = (
    "existing_workspace_storage_key_arn",
    "existing_workspace_storage_key_alias",
    "existing_managed_services_key_arn",
    "existing_managed_services_key_alias",
)


def resolve_network_ownership(
    normalized: dict, deployment: dict, inventory: dict
) -> tuple[str, str, str]:
    """
    Resolve vpc/routing/endpoints ownership (CLAUDE.md §8 milestones
    9, 30). Shared by ensure_subnet_allocation() and build_tfvars() so
    the two can't drift apart.

    vpc_ownership stays strategy-driven (override > strategy default) -
    there's no cleaner signal than network.strategy itself; 'custom'
    legitimately defaults to "existing" even with no explicit
    existing_vpc_id, via the inventory fallback.

    routing_ownership is now INFERRED rather than defaulted blindly:
    when Terraform owns the VPC itself, routing is necessarily also
    "terraform" (nothing existing to reuse - not a choice). Otherwise,
    it's "existing" only when route table ids are actually known for
    THIS VPC (inventory.resolve_route_table_ids()) - not "existing"
    with nothing to actually reuse. overrides.routing_ownership remains
    a rare escape hatch on top of this.

    endpoints_ownership defaults to whatever routing_ownership just
    resolved to: a VPC with no known route tables has, in every real
    case seen so far, no existing S3/STS/KMS endpoints either
    (client-vpc-proof's bare VPC) - both signal "this is a genuinely
    bare VPC," not two independent facts. overrides.endpoints_ownership
    remains available for the rare case they actually diverge (CLAUDE.md
    §4 flags document-ai-dev's VPC - existing route tables, but no
    endpoints today - as a possible future example).

    Returns (vpc_ownership, routing_ownership, endpoints_ownership).
    """

    overrides = deployment.get("overrides", {})
    network_strategy = normalized["network"]["strategy"]

    vpc_ownership = overrides.get("vpc_ownership") or (
        "terraform" if network_strategy == "isolated" else "existing"
    )

    if vpc_ownership == "terraform":
        routing_ownership = overrides.get("routing_ownership") or "terraform"
    else:
        aws_account_id = normalized["cloud"]["account"]
        region = normalized["cloud"]["region"]
        requested_vpc_id = normalized["network"].get("existing_vpc_id")
        requested_route_table_ids = normalized["network"].get(
            "existing_route_table_ids"
        )

        routing_ownership = overrides.get("routing_ownership") or (
            "existing"
            if resolve_route_table_ids(
                aws_account_id,
                region,
                deployment,
                inventory,
                requested_vpc_id,
                requested_route_table_ids,
            )
            else "terraform"
        )

    endpoints_ownership = overrides.get("endpoints_ownership") or routing_ownership

    return vpc_ownership, routing_ownership, endpoints_ownership


def ensure_subnet_allocation(
    workspace_name: str,
    normalized: dict,
    deployment: dict,
    inventory: dict,
    deployment_dir: Path,
) -> dict:
    """
    Guarantee `deployment["network"]["subnets"]["private"]` is populated
    before build_tfvars() needs it, auto-allocating it when the operator
    hasn't hand-typed one (CLAUDE.md §8 milestone 28).

    Four cases, checked in order:
    0. network.existing_subnet_ids is set (deployment.yaml override, or
       the request's own network.existing_subnet_ids - CLAUDE.md §8
       milestone 33) - the requester is adopting pre-existing subnets
       rather than having Terraform create any. No CIDR to allocate or
       pin at all - return deployment unchanged; build_tfvars() surfaces
       the ids directly as their own top-level Terraform variable.
    1. deployment.yaml already defines network.subnets.private (today's
       hand-maintained case) - return deployment unchanged. This is the
       entire backward-compatibility guarantee: every workspace that
       predates this feature never enters the new code path below.
    2. infrastructure/deployments/<env>/<name>/allocated-subnets.yaml
       already exists (pinned by a prior run of this function) - load
       and merge it in, unchanged from whatever was first computed.
       Never recomputed - see the module docstring on
       inventory.allocate_subnets() for why recomputing on every run
       would be unsafe once a workspace is actually applied.
    3. Neither exists yet - this is the first time this workspace has
       been generated. Resolve the VPC CIDR to carve from (request's
       vpc_cidr/existing_vpc_id/existing_vpc_cidr, or deployment.yaml's
       own override - same three-tier precedence as
       resolve_platform_network()), look up this account/region's
       subnet_defaults convention, gather every other committed
       workspace's already-used ranges in the same VPC scope, allocate,
       write the result to allocated-subnets.yaml, and merge it in.
    """

    existing_subnet_ids = deployment.get("network", {}).get(
        "existing_subnet_ids"
    ) or normalized.get("network", {}).get("existing_subnet_ids")

    if existing_subnet_ids:
        return deployment

    network = deployment.get("network", {})

    if network.get("subnets", {}).get("private"):
        return deployment

    allocated_path = deployment_dir / "allocated-subnets.yaml"

    if allocated_path.exists():
        allocated_network = load_yaml(allocated_path).get("network", {})
    else:
        vpc_ownership, routing_ownership, endpoints_ownership = (
            resolve_network_ownership(normalized, deployment, inventory)
        )

        aws_account_id = normalized["cloud"]["account"]
        region = normalized["cloud"]["region"]
        normalized_network = normalized.get("network", {})

        if vpc_ownership == "terraform":
            vpc_cidr = network.get("vpc_cidr") or normalized_network.get("vpc_cidr")

            require(
                bool(vpc_cidr),
                "VPC ownership resolves to 'terraform', but no VPC CIDR is "
                "known - supply 'network.vpc_cidr' in the workspace "
                "request (the client's own address-space choice), or set "
                "it explicitly in this workspace's deployment file to "
                "override.",
            )
        else:
            requested_vpc_id = normalized_network.get("existing_vpc_id")
            requested_vpc_cidr = normalized_network.get("existing_vpc_cidr")

            vpc_cidr = resolve_existing_vpc_cidr(
                aws_account_id,
                region,
                deployment,
                inventory,
                requested_vpc_id,
                requested_vpc_cidr,
            )

            require(
                bool(vpc_cidr),
                "Could not determine the existing VPC's CIDR block needed "
                "to auto-allocate subnets - supply "
                "'network.existing_vpc_cidr' in the workspace request (or "
                "'platform.vpc_cidr' in this workspace's deployment file) "
                "if the VPC named by existing_vpc_id isn't already known "
                "in platform/inventory/aws.yaml.",
            )

        subnet_defaults = subnet_defaults_for(aws_account_id, region, inventory)

        require(
            bool(subnet_defaults.get("availability_zones"))
            and subnet_defaults.get("prefix_length") is not None,
            f"No 'subnet_defaults' (prefix_length + availability_zones) "
            f"is declared for AWS account '{aws_account_id}' region "
            f"'{region}' in platform/inventory/aws.yaml - needed to "
            f"auto-allocate subnets.",
        )

        if vpc_ownership == "terraform" or endpoints_ownership == "terraform":
            databricks_account_id = deployment.get("databricks", {}).get(
                "account_id"
            )

            _, nat_needed = resolve_connectivity(
                databricks_account_id,
                inventory,
                normalized_network.get("connectivity", "auto"),
            )

            nat_needed = nat_needed and vpc_ownership == "terraform"
        else:
            nat_needed = False

        scope_key, _ = vpc_scope(workspace_name, deployment, normalized, inventory)
        used_ranges = used_subnets_for_scope(scope_key, exclude_workspace=workspace_name)

        private_subnets, nat_subnet_cidr = allocate_subnets(
            vpc_cidr,
            subnet_defaults["prefix_length"],
            subnet_defaults["availability_zones"],
            used_ranges,
            nat_needed,
        )

        allocated_network = {"subnets": {"private": private_subnets}}

        if nat_subnet_cidr is not None:
            allocated_network["nat_subnet_cidr"] = nat_subnet_cidr

        allocated_path.parent.mkdir(parents=True, exist_ok=True)

        with allocated_path.open("w", encoding="utf-8") as file:
            file.write(
                "# AUTO-GENERATED by resolver/generate_tfvars.py's "
                "ensure_subnet_allocation() on first run for this "
                "workspace - do not hand-edit (same convention as "
                "terraform.tfvars.json/backend.tfbackend). Pinned "
                "permanently once written: regenerating tfvars for THIS "
                "workspace will not recompute these values, so adding a "
                "sibling workspace later can never shift a subnet CIDR "
                "already in use by a real, applied deployment. To force "
                "reallocation (e.g. before first apply), delete this "
                "file and re-run generate_tfvars.py.\n"
            )
            json.dump({"network": allocated_network}, file, indent=2)
            file.write("\n")

    merged_network = dict(network)
    merged_network["subnets"] = dict(network.get("subnets", {}))
    merged_network["subnets"]["private"] = allocated_network.get("subnets", {}).get(
        "private"
    )

    if "nat_subnet_cidr" in allocated_network:
        merged_network.setdefault("nat_subnet_cidr", allocated_network["nat_subnet_cidr"])

    merged_deployment = dict(deployment)
    merged_deployment["network"] = merged_network

    return merged_deployment


def build_tfvars(normalized: dict, deployment: dict, inventory: dict) -> dict:
    """
    Combine a resolver normalized config with the small set of
    deployment-only values Terraform needs but the resolver does not
    produce (existing resource ids, concrete subnet CIDRs).
    """

    # Normally already resolved by main() (deployment override > request's
    # cloud.databricks_account_id > inventory default) and merged into
    # `deployment` before this function runs - this check only fires if
    # build_tfvars() is called directly without that resolution step.
    databricks_account_id = deployment.get("databricks", {}).get("account_id")

    require(
        bool(databricks_account_id),
        "No Databricks account id resolved - see "
        "inventory.resolve_databricks_account_id() for where this should "
        "come from (deployment.yaml override, request's "
        "cloud.databricks_account_id, or platform/inventory/aws.yaml's "
        "default).",
    )

    deployment_network = deployment.get("network", {})

    # Adopting pre-existing subnets (deployment.yaml override > request's
    # network.existing_subnet_ids, CLAUDE.md §8 milestone 33) skips subnet
    # CIDR allocation entirely - no 'network.subnets.private' is needed or
    # expected in that case.
    existing_subnet_ids = deployment_network.get(
        "existing_subnet_ids"
    ) or normalized["network"].get("existing_subnet_ids")

    private_subnets = None

    if existing_subnet_ids is None:
        private_subnets = deployment_network.get("subnets", {}).get("private")

        require(
            isinstance(private_subnets, list) and len(private_subnets) >= 2,
            "Deployment file must define at least two entries under "
            "'network.subnets.private' (each with 'cidr' and "
            "'availability_zone') - or, for a new workspace, supply "
            "'network.vpc_cidr'/'existing_vpc_id' in the workspace request "
            "so resolver/generate_tfvars.py's ensure_subnet_allocation() can "
            "auto-allocate them, or 'network.existing_subnet_ids' to adopt "
            "pre-existing subnets instead.",
        )

    # Required whenever VPC ownership resolves to 'terraform' - whether by
    # the 'isolated' strategy's own default or by an explicit override. Not
    # nested under 'overrides': it isn't an override, it's always needed
    # once Terraform is the one creating the VPC.
    vpc_cidr = deployment_network.get("vpc_cidr") or normalized["network"].get(
        "vpc_cidr"
    )

    network = dict(normalized["network"])
    requirements = dict(network["requirements"])
    subnets = dict(requirements["subnets"])

    if existing_subnet_ids is not None:
        subnets["ownership"] = "existing"
        subnets.pop("private", None)
    else:
        subnets["ownership"] = "terraform"
        subnets["private"] = private_subnets

    requirements["subnets"] = subnets
    network["requirements"] = requirements

    # connectivity/vpc_cidr/existing_vpc_id/existing_vpc_cidr/
    # existing_security_group_id/existing_route_table_ids/
    # existing_subnet_ids are all resolved separately (into
    # privatelink_enabled_override/nat_enabled_override/vpc_cidr/platform/
    # existing_security_group_id/existing_subnet_ids below) - var.network's
    # object type doesn't declare any of them, since each is consumed as
    # its own standalone variable, not threaded through the network object
    # itself. (existing_security_group_id/existing_route_table_ids weren't
    # being stripped here before this fix - a real bug introduced in
    # milestone 29, latent because no real or throwaway test for that
    # field had been run through terraform validate/plan, only inspected
    # as raw JSON.)
    for key in (
        "connectivity",
        "vpc_cidr",
        "existing_vpc_id",
        "existing_vpc_cidr",
        "existing_security_group_id",
        "existing_route_table_ids",
        "existing_subnet_ids",
    ):
        network.pop(key, None)

    tfvars = {
        "databricks_account_id": databricks_account_id,
        "workspace": normalized["workspace"],
        "cloud": {
            "provider": normalized["cloud"]["provider"],
            "region": normalized["cloud"]["region"],
        },
        "application": normalized["application"],
        "ownership": normalized["ownership"],
        "network": network,
        "data": normalized["data"],
        # KMS bring-your-own-key ARNs (when present) are surfaced
        # separately as their own top-level vars below - var.encryption's
        # object type only declares workspace/application_data.
        "encryption": {
            key: value
            for key, value in normalized["encryption"].items()
            if key not in KMS_PASSTHROUGH_KEYS
        },
        # catalog_admin_principal/existing_metastore_id (when present) are
        # surfaced separately as their own top-level vars below -
        # var.governance's object type doesn't declare either, since
        # they're consumed directly by modules/unity-catalog-workspace /
        # inventory.resolve_metastore_id(), not by the governance-shaped
        # resolver output itself.
        "governance": {
            key: value
            for key, value in normalized["governance"].items()
            if key not in ("catalog_admin_principal", "existing_metastore_id")
        },
        "compute": normalized["compute"],
        "logging": normalized["logging"],
        "validation": normalized["validation"],
        "tags": normalized.get("tags", {}),
    }

    overrides = deployment.get("overrides", {})

    vpc_ownership, routing_ownership, endpoints_ownership = (
        resolve_network_ownership(normalized, deployment, inventory)
    )

    platform = resolve_platform_network(
        normalized["cloud"]["account"],
        normalized["cloud"]["region"],
        deployment,
        inventory,
        need_vpc=vpc_ownership == "existing",
        need_routing=routing_ownership == "existing",
        requested_vpc_id=normalized["network"].get("existing_vpc_id"),
        requested_route_table_ids=normalized["network"].get(
            "existing_route_table_ids"
        ),
    )

    if platform:
        tfvars["platform"] = platform

    if vpc_cidr is not None:
        tfvars["vpc_cidr"] = vpc_cidr

    # vpc/routing/endpoints ownership are now always set explicitly from
    # resolve_network_ownership()'s result (CLAUDE.md §8 milestone 30) -
    # routing/endpoints are INFERRED, not just passed through from
    # deployment.yaml's overrides, so silently forwarding only an
    # explicit override (the old behavior) would let
    # modules/workspace-deployment/locals.tf's own strategy-only
    # coalesce() independently (and wrongly) recompute a different
    # default, diverging from this inference.
    tfvars["vpc_ownership_override"] = vpc_ownership
    tfvars["routing_ownership_override"] = routing_ownership
    tfvars["endpoints_ownership_override"] = endpoints_ownership

    # security_group_ownership has no strategy-based default (always
    # "terraform" unless overridden), so there's no divergence risk in
    # only forwarding it when deployment.yaml explicitly sets it - its
    # own inference (existing_security_group_id's presence) is handled
    # separately below.
    if "security_group_ownership" in overrides:
        tfvars["security_group_ownership_override"] = overrides[
            "security_group_ownership"
        ]

    # Existing security group id: deployment.yaml override > request's
    # network.existing_security_group_id (CLAUDE.md §8 milestone 29).
    # Security group ownership has no strategy-based default (always
    # "terraform" unless overridden, modules/workspace-deployment/locals.tf)
    # - the only reason an id is ever supplied is to use it, so its
    # presence alone implies ownership "existing", without also requiring
    # a separate overrides.security_group_ownership key. setdefault()
    # leaves an explicit overrides.security_group_ownership (set just
    # above) untouched if present.
    existing_security_group_id = overrides.get(
        "existing_security_group_id"
    ) or normalized["network"].get("existing_security_group_id")

    if existing_security_group_id is not None:
        tfvars["existing_security_group_id"] = existing_security_group_id
        tfvars.setdefault("security_group_ownership_override", "existing")

    if existing_subnet_ids is not None:
        tfvars["existing_subnet_ids"] = existing_subnet_ids

    # Connectivity (PrivateLink vs NAT) only matters when Terraform owns
    # enough of the networking stack to act on it - and PrivateLink and
    # NAT have different requirements, so they're gated independently:
    #   - PrivateLink's AWS-side resources are purely additive (interface
    #     endpoints + a security group) - safe whenever Terraform owns the
    #     *endpoints*, same as modules/workspace-privatelink already gates
    #     on today, regardless of who owns the VPC itself (e.g.
    #     client-vpc-proof builds its own endpoints inside a
    #     client-provided VPC).
    #   - NAT attaches an Internet Gateway to the *whole VPC* and modifies
    #     the *existing* private route tables - not something to do to a
    #     VPC this factory doesn't own. Gated on vpc_ownership, not
    #     endpoints_ownership (deliberately different from PrivateLink
    #     above - client-vpc-proof has endpoints_ownership "terraform" but
    #     vpc_ownership "existing", and must NOT get NAT).
    # network.connectivity (request-level) is the only control surface for
    # this - no deployment.yaml override exists (CLAUDE.md §8 milestone
    # 29 removed it: nothing was found that connectivity couldn't already
    # express via "privatelink"/"nat"/"auto").
    if endpoints_ownership == "terraform" or vpc_ownership == "terraform":
        privatelink_enabled, nat_enabled = resolve_connectivity(
            databricks_account_id,
            inventory,
            normalized["network"].get("connectivity", "auto"),
        )

        if endpoints_ownership == "terraform":
            tfvars["privatelink_enabled_override"] = privatelink_enabled

        if vpc_ownership == "terraform":
            tfvars["nat_enabled_override"] = nat_enabled

            if nat_enabled:
                nat_subnet_cidr = deployment_network.get("nat_subnet_cidr")

                require(
                    bool(nat_subnet_cidr),
                    "network.connectivity resolves to NAT, but the "
                    "deployment file is missing 'network.nat_subnet_cidr' "
                    "- a concrete CIDR for the NAT Gateway's public "
                    "subnet, same shape as the private subnet CIDRs "
                    "above.",
                )

                tfvars["nat_subnet_cidr"] = nat_subnet_cidr

    # KMS bring-your-own-key ARNs: deployment.yaml override > request's
    # encryption.existing_* (CLAUDE.md §8 milestone 29).
    kms = deployment.get("kms", {})

    for key in KMS_PASSTHROUGH_KEYS:
        value = kms.get(key) or normalized["encryption"].get(key)

        if value is not None:
            tfvars[key] = value

    if normalized["governance"]["unity_catalog"]:
        region = normalized["cloud"]["region"]

        tfvars["existing_metastore_id"] = resolve_metastore_id(
            databricks_account_id,
            region,
            deployment,
            inventory,
            normalized["governance"].get("existing_metastore_id"),
        )

        # Optional: who should be granted ALL_PRIVILEGES on the catalog.
        # Requester-specified (workspace-requests/<env>/<name>.yaml's
        # governance.catalog_admin_principal), not deployment-only - unlike
        # vpc_id/metastore_id this is a plain passthrough string, not an
        # infra id needing operator lookup, so the resolver already carried
        # it into normalized.governance. Omitted entirely by default -
        # catalog ownership then defaults to whoever runs terraform apply.
        catalog_admin_principal = normalized["governance"].get(
            "catalog_admin_principal"
        )

        if catalog_admin_principal is not None:
            tfvars["catalog_admin_principal"] = catalog_admin_principal

    return tfvars


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Generate an infrastructure/workspace/<name>.tfvars.json file "
            "from a resolver normalized config plus the small set of "
            "deployment-only values (existing resource ids, concrete "
            "subnet CIDRs) the resolver does not produce."
        )
    )

    parser.add_argument(
        "--workspace",
        required=True,
        help=(
            "Workspace name. By default, looks for "
            "normalized/<workspace>.yaml and "
            "infrastructure/deployments/<provider>/<environment>/<workspace>/"
            "deployment.yaml (provider and environment both read from the "
            "normalized file), writing "
            "infrastructure/deployments/<provider>/<environment>/<workspace>/"
            "terraform.tfvars.json. All workspaces for a given provider "
            "share that provider's one Terraform root "
            "(infrastructure/aws/workspace/ or infrastructure/azure/workspace/) "
            "- see resolver/generate_backend_config.py for selecting which "
            "workspace's state that root points at."
        ),
    )

    parser.add_argument(
        "--normalized",
        help="Override path to the normalized YAML.",
    )

    parser.add_argument(
        "--deployment",
        help="Override path to the deployment YAML.",
    )

    parser.add_argument(
        "--output",
        help="Override output path.",
    )

    args = parser.parse_args()

    normalized_path = (
        Path(args.normalized) if args.normalized
        else ROOT / "normalized" / f"{args.workspace}.yaml"
    )

    normalized = load_yaml(normalized_path)
    environment = normalized["workspace"]["environment"]
    provider = normalized["cloud"]["provider"]

    deployment_dir = (
        ROOT / "infrastructure" / "deployments" / provider / environment / args.workspace
    )

    if provider == "azure":
        _main_azure(args, normalized, deployment_dir)
        return

    _main_aws(args, normalized, deployment_dir)


def _main_aws(args, normalized: dict, deployment_dir: Path) -> None:
    deployment_path = (
        Path(args.deployment) if args.deployment
        else deployment_dir / "deployment.yaml"
    )

    output_path = (
        Path(args.output) if args.output
        else deployment_dir / "terraform.tfvars.json"
    )

    deployment = load_yaml(deployment_path)
    inventory = load_yaml(ROOT / "platform" / "inventory" / "aws.yaml")

    # Resolve once, up front: deployment.yaml's 'databricks.account_id'
    # override > the request's cloud.databricks_account_id > the AWS
    # account's inventory default (CLAUDE.md §8 milestone 29). Merged
    # back into `deployment` so every downstream read (ensure_subnet_
    # allocation, build_tfvars) keeps working unchanged - same pattern
    # ensure_subnet_allocation itself already uses for its own result.
    databricks_account_id = resolve_databricks_account_id(
        normalized["cloud"]["account"],
        inventory,
        normalized["cloud"].get("databricks_account_id"),
        deployment.get("databricks", {}).get("account_id"),
    )

    deployment = {
        **deployment,
        "databricks": {
            **deployment.get("databricks", {}),
            "account_id": databricks_account_id,
        },
    }

    # Check this (and every other committed workspace's) CIDR allocations
    # for collisions before generating anything Terraform would act on.
    check_cidr_allocations()

    deployment = ensure_subnet_allocation(
        args.workspace, normalized, deployment, inventory, deployment_dir
    )

    # Re-check after a first-time allocation writes a new
    # allocated-subnets.yaml - defensive re-validation, cheap, consistent
    # with how this check is already treated as the authority.
    check_cidr_allocations()

    tfvars = build_tfvars(normalized, deployment, inventory)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as file:
        json.dump(tfvars, file, indent=2, sort_keys=False)
        file.write("\n")

    print(f"tfvars written to: {output_path}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, FileNotFoundError) as error:
        print()
        print("tfvars generation failed")
        print("-------------------------")
        print()
        print(error)
        print()

        raise SystemExit(1)
