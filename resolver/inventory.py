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


def find_primary_network(aws_account_id: str, region: str, inventory: dict) -> dict:
    """
    Find the 'primary' network entry for an AWS account/region in
    platform/inventory/aws.yaml. Accounts are keyed by a friendly name
    (e.g. 'dev'), not the account id itself, so this matches by value -
    the same way resolver.py's own inventory lookup already does.
    Returns {} if no matching account/region/network is found.
    """

    for account in inventory.get("aws", {}).get("accounts", {}).values():
        if account.get("account_id") == aws_account_id:
            return (
                account.get("regions", {})
                .get(region, {})
                .get("networks", {})
                .get("primary", {})
            )

    return {}


def resolve_platform_network(
    aws_account_id: str,
    region: str,
    deployment: dict,
    inventory: dict,
    need_vpc: bool,
    need_routing: bool,
) -> dict:
    """
    Resolve platform.vpc_id/route_table_ids for a workspace whose VPC/
    routing ownership resolves to 'existing' (mirroring the coalesce
    logic in modules/workspace-deployment/locals.tf - see
    generate_tfvars.py's build_tfvars for where that's replicated).
    Known existing networks (one 'primary' per AWS account/region) live
    in platform/inventory/aws.yaml, looked up automatically so a
    workspace's deployment.yaml doesn't need to repeat them. A
    workspace's own 'platform' block in deployment.yaml is an optional
    override - for reusing a DIFFERENT existing VPC than the account's
    primary one (e.g. a client-provided VPC), not just the common case.

    Returns a dict with only the keys actually needed (need_vpc/
    need_routing), suitable for use directly as the Terraform
    `platform` variable. Raises ValueError if something needed is
    missing from both the override and the inventory.
    """

    deployment_platform = deployment.get("platform") or {}

    platform: dict = {}

    if need_vpc:
        vpc_id = deployment_platform.get("vpc_id")

        if vpc_id is None:
            vpc_id = find_primary_network(aws_account_id, region, inventory).get(
                "vpc", {}
            ).get("id")

        require(
            bool(vpc_id),
            f"VPC ownership resolves to 'existing', but no VPC id is known "
            f"for AWS account '{aws_account_id}' region '{region}'. Add it "
            f"to platform/inventory/aws.yaml's 'aws.accounts' section, or "
            f"set 'platform.vpc_id' explicitly in this workspace's "
            f"deployment file to override.",
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
