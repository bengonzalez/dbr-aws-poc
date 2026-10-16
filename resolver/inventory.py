"""
Shared lookups against platform/inventory/aws.yaml (+ a workspace's own
deployment.yaml for optional overrides) - used by generate_tfvars.py,
check_cidr_allocations.py, and validate_deployment.py.

Centralized here (rather than living in generate_tfvars.py, where
resolve_metastore_id originally did) specifically to avoid a circular
import: generate_tfvars.py already imports check_cidr_allocations.py to
run it before writing tfvars, so check_cidr_allocations.py can't import
anything back from generate_tfvars.py.
"""

import ipaddress


def require(condition: bool, message: str) -> None:
    """Raise ValueError with `message` when `condition` is false."""

    if not condition:
        raise ValueError(message)


def resolve_metastore_id(
    databricks_account_id: str,
    region: str,
    deployment: dict,
    inventory: dict,
) -> str:
    """
    Resolve which Unity Catalog metastore a workspace should be assigned
    to: known existing metastores (one per Databricks account/region)
    live in platform/inventory/aws.yaml's 'databricks' section, looked up
    automatically so a workspace's deployment.yaml only needs to name its
    Databricks account, not repeat the metastore id every time.
    'unity_catalog.existing_metastore_id' in deployment.yaml is an
    optional override for the rare workspace that needs a different
    metastore. Raises ValueError if neither source has a value.
    """

    inventory_metastore_id = (
        inventory.get("databricks", {})
        .get("accounts", {})
        .get(databricks_account_id, {})
        .get("regions", {})
        .get(region, {})
        .get("metastore_id")
    )

    override_metastore_id = deployment.get("unity_catalog", {}).get(
        "existing_metastore_id"
    )

    existing_metastore_id = override_metastore_id or inventory_metastore_id

    require(
        bool(existing_metastore_id),
        f"governance.unity_catalog is true, but no metastore is known "
        f"for Databricks account '{databricks_account_id}' region "
        f"'{region}'. Add it to platform/inventory/aws.yaml's "
        f"'databricks.accounts' section, or set "
        f"'unity_catalog.existing_metastore_id' explicitly in this "
        f"workspace's deployment file to override.",
    )

    return existing_metastore_id


def _find_region_inventory(aws_account_id: str, region: str, inventory: dict) -> dict:
    """
    Find the region-level inventory entry for an AWS account/region in
    platform/inventory/aws.yaml (the parent of 'networks', 'approved',
    and 'subnet_defaults'). Accounts are keyed by a friendly name (e.g.
    'dev'), not the account id itself, so this matches by value - the
    same way resolver.py's own inventory lookup already does. Returns
    {} if no matching account/region is found.
    """

    for account in inventory.get("aws", {}).get("accounts", {}).values():
        if account.get("account_id") == aws_account_id:
            return account.get("regions", {}).get(region, {})

    return {}


def find_primary_network(aws_account_id: str, region: str, inventory: dict) -> dict:
    """
    Find the 'primary' network entry for an AWS account/region in
    platform/inventory/aws.yaml. Returns {} if no matching
    account/region/network is found.
    """

    return (
        _find_region_inventory(aws_account_id, region, inventory)
        .get("networks", {})
        .get("primary", {})
    )


def subnet_defaults_for(aws_account_id: str, region: str, inventory: dict) -> dict:
    """
    Find the region-level subnet-sizing/AZ convention
    ('subnet_defaults': prefix_length + availability_zones) used to
    auto-carve subnets out of whichever VPC a workspace ends up using.
    Region-level (not nested under any one VPC) since availability
    zones are a region property. Returns {} if none is declared.
    """

    return _find_region_inventory(aws_account_id, region, inventory).get(
        "subnet_defaults", {}
    )


def allocate_subnets(
    vpc_cidr: str,
    prefix_length: int,
    availability_zones: list[str],
    used_ranges: list[ipaddress.IPv4Network],
    nat_needed: bool,
) -> tuple[list[dict], str | None]:
    """
    Deterministically carve non-overlapping /prefix_length subnets out
    of vpc_cidr: one private subnet per entry in availability_zones (in
    list order), plus one more for a NAT Gateway's public subnet when
    nat_needed. Skips any candidate block that overlaps something in
    used_ranges (every other already-allocated subnet sharing this VPC
    scope - see check_cidr_allocations.used_subnets_for_scope()).

    Pure function: the caller is responsible for persisting the result
    (generate_tfvars.py pins it to a committed, generated
    allocated-subnets.yaml file) so repeated calls for the SAME
    workspace don't matter - this function has no memory of its own and
    always returns the first fit given its inputs.

    Returns (private_subnets, nat_subnet_cidr_or_None). Raises
    ValueError if the VPC doesn't have enough free space.
    """

    needed = len(availability_zones) + (1 if nat_needed else 0)

    network = ipaddress.ip_network(vpc_cidr)

    free_blocks = []

    for candidate in network.subnets(new_prefix=prefix_length):
        if not any(candidate.overlaps(used) for used in used_ranges):
            free_blocks.append(candidate)

        if len(free_blocks) >= needed:
            break

    require(
        len(free_blocks) >= needed,
        f"Could not auto-allocate {needed} /{prefix_length} subnet(s) "
        f"within VPC CIDR {vpc_cidr} - not enough free, non-overlapping "
        f"address space given what's already allocated to other "
        f"workspaces sharing this VPC.",
    )

    private_subnets = [
        {"cidr": str(free_blocks[index]), "availability_zone": az}
        for index, az in enumerate(availability_zones)
    ]

    nat_subnet_cidr = (
        str(free_blocks[len(availability_zones)]) if nat_needed else None
    )

    return private_subnets, nat_subnet_cidr


def resolve_platform_network(
    aws_account_id: str,
    region: str,
    deployment: dict,
    inventory: dict,
    need_vpc: bool,
    need_routing: bool,
    requested_vpc_id: str | None = None,
) -> dict:
    """
    Resolve platform.vpc_id/route_table_ids for a workspace whose VPC/
    routing ownership resolves to 'existing' (mirroring the coalesce
    logic in modules/workspace-deployment/locals.tf - see
    generate_tfvars.py's build_tfvars for where that's replicated).

    Precedence for the VPC id: deployment.yaml's 'platform.vpc_id'
    override > the request's network.existing_vpc_id (requested_vpc_id -
    the client's own existing VPC, CLAUDE.md §8 milestone 28) > the AWS
    account/region's known 'primary' network in
    platform/inventory/aws.yaml (today's default, unchanged). Route
    table ids only ever come from the override or the primary network -
    a client handing over a bare VPC has no route tables to hand over
    too.

    Returns a dict with only the keys actually needed (need_vpc/
    need_routing), suitable for use directly as the Terraform
    `platform` variable. Raises ValueError if something needed is
    missing from every source.
    """

    deployment_platform = deployment.get("platform") or {}

    platform: dict = {}

    if need_vpc:
        vpc_id = (
            deployment_platform.get("vpc_id")
            or requested_vpc_id
            or find_primary_network(aws_account_id, region, inventory).get(
                "vpc", {}
            ).get("id")
        )

        require(
            bool(vpc_id),
            f"VPC ownership resolves to 'existing', but no VPC id is known "
            f"for AWS account '{aws_account_id}' region '{region}'. Supply "
            f"'network.existing_vpc_id' in the workspace request, add a "
            f"primary network to platform/inventory/aws.yaml's "
            f"'aws.accounts' section, or set 'platform.vpc_id' explicitly "
            f"in this workspace's deployment file to override.",
        )

        platform["vpc_id"] = vpc_id

    if need_routing:
        route_table_ids = deployment_platform.get("route_table_ids")

        if route_table_ids is None:
            route_table_ids = find_primary_network(
                aws_account_id, region, inventory
            ).get("routing", {}).get("route_table_ids")

        require(
            bool(route_table_ids),
            f"Routing ownership resolves to 'existing', but no route "
            f"table ids are known for AWS account '{aws_account_id}' "
            f"region '{region}'. Add them to platform/inventory/aws.yaml's "
            f"'aws.accounts' section, or set 'platform.route_table_ids' "
            f"explicitly in this workspace's deployment file to override.",
        )

        platform["route_table_ids"] = route_table_ids

    return platform


def resolve_existing_vpc_cidr(
    aws_account_id: str,
    region: str,
    deployment: dict,
    inventory: dict,
    requested_vpc_id: str | None,
    requested_vpc_cidr: str | None,
) -> str | None:
    """
    Resolve the CIDR block of an existing VPC a workspace is reusing -
    informational only (never passed to Terraform, which doesn't need
    it; the VPC already exists). Used solely so subnet auto-allocation
    knows the address space to carve from.

    Same three-tier precedence as resolve_platform_network()'s VPC id:
    deployment.yaml's 'platform.vpc_cidr' override > the request's
    network.existing_vpc_cidr (requested_vpc_cidr) > the AWS
    account/region's known 'primary' network's CIDR in
    platform/inventory/aws.yaml - but only as the inventory fallback
    when the resolved VPC id actually IS that primary network (a
    different client-provided VPC has no inventory CIDR to fall back
    to; it must come from the override or the request).
    """

    deployment_platform = deployment.get("platform") or {}

    vpc_cidr = deployment_platform.get("vpc_cidr") or requested_vpc_cidr

    if vpc_cidr is not None:
        return vpc_cidr

    primary = find_primary_network(aws_account_id, region, inventory)
    primary_vpc = primary.get("vpc", {})

    resolved_vpc_id = (
        deployment_platform.get("vpc_id") or requested_vpc_id or primary_vpc.get("id")
    )

    if resolved_vpc_id == primary_vpc.get("id"):
        return primary_vpc.get("cidr")

    return None


def resolve_connectivity(
    databricks_account_id: str,
    inventory: dict,
    requested: str,
) -> tuple[bool, bool]:
    """
    Resolve how isolated-strategy classic compute reaches the Databricks
    control plane. `requested` is normalized.network.connectivity
    ("privatelink"/"nat"/"auto", a plain passthrough from the request -
    see resolver.py). Returns (privatelink_enabled, nat_enabled).

    `privatelink_available` (platform/inventory/aws.yaml, per Databricks
    account - an Enterprise-tier pricing fact, not a per-workspace
    choice) drives the "auto" default: PrivateLink when the account
    supports it, NAT otherwise - never a silent connectivity gap, which
    is what disabling PrivateLink used to leave behind (CLAUDE.md §5.11).
    Defaults to False (no PrivateLink) for an account not listed at all -
    conservative, since Enterprise tier is opt-in, not assumed.
    """

    privatelink_available = (
        inventory.get("databricks", {})
        .get("accounts", {})
        .get(databricks_account_id, {})
        .get("privatelink_available", False)
    )

    if requested == "privatelink":
        require(
            privatelink_available,
            f"network.connectivity is 'privatelink', but Databricks "
            f"account '{databricks_account_id}' does not have PrivateLink "
            f"available (platform/inventory/aws.yaml's "
            f"'databricks.accounts.<id>.privatelink_available' is false "
            f"or unset) - it requires Enterprise tier. Choose 'nat' or "
            f"'auto' in the workspace request instead.",
        )

        return True, False

    if requested == "nat":
        return False, True

    # "auto" (the default)
    return privatelink_available, not privatelink_available
