"""
Azure-specific tfvars generation, dispatched from generate_tfvars.py's
main() when normalized["cloud"]["provider"] == "azure".

Kept in its own module rather than branching inside generate_tfvars.py's
existing AWS-shaped functions (678 lines of VPC/routing/security-group/
endpoints ownership inference, subnet allocation, KMS bring-your-own-key,
metastore/account-id inventory lookups - none of which apply to Azure's
much smaller, bounded-scope shape). See the Azure milestone's plan for
why: parallel cloud-specific code, not interleaved branches, mirroring
the same "parallel trees" principle already recommended for the
Terraform module layer.

Scope: 'isolated' (a brand-new, Terraform-owned VNet, CLAUDE.md §8
milestone 35) and 'custom' (a client-provided VNet - Terraform creates two
delegated subnets inside it, auto-allocated and pinned the same way as
AWS's milestone-28 allocation, or adopts two existing ones, same as AWS's
milestone-33 existing_subnet_ids - CLAUDE.md §8 milestone 41).
Customer-managed Key Vault encryption, created or brought: CLAUDE.md §8
milestone 42.
"""

from pathlib import Path
import ipaddress
import json
import re

from loader import load_yaml

ROOT = Path(__file__).resolve().parent.parent

AZURE_VNET_ID_PATTERN = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
    r"Microsoft\.Network/virtualNetworks/[^/]+$",
    re.IGNORECASE,
)

# Same /24 convention as derive_subnet_cidrs() below for isolated VNets -
# comfortably above Azure Databricks' own /26 minimum per subnet.
CUSTOM_SUBNET_PREFIX_LENGTH = 24

# Private Link's private-endpoint subnet (CLAUDE.md §8 milestone 46): 3
# endpoints today; Microsoft recommends /27-/28 minimum, /26 leaves room.
PRIVATE_ENDPOINT_PREFIX_LENGTH = 26

# Environments where classic Private Link is required (user's call,
# milestone 46): on regardless of the request, and a request can't opt
# out. Elsewhere (dev) it's opt-in via network.connectivity: privatelink.
PRIVATE_LINK_REQUIRED_ENVIRONMENTS = ("stage", "live")

PRIVATE_DNS_ZONE_KEYS = {
    "privatelink.azuredatabricks.net": "databricks",
    "privatelink.dfs.core.windows.net": "dfs",
    "privatelink.blob.core.windows.net": "blob",
}

AZURE_DNS_ZONE_ID_PATTERN = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
    r"Microsoft\.Network/privateDnsZones/[^/]+$",
    re.IGNORECASE,
)


def derive_subnet_cidrs(vpc_cidr: str, private_endpoints: bool = False) -> tuple[str, str, str | None]:
    """
    Carve the first two /24s out of vpc_cidr for Azure's fixed two-subnet
    VNet-injection model (Databricks' own "public"/"private" naming - not
    AZ-scoped the way AWS subnets are, so there's no per-region
    subnet_defaults/availability_zones inventory lookup needed here) -
    plus, with Private Link, a /26 private-endpoint subnet from the third
    /24, which needs at least a /22.
    """

    network = ipaddress.ip_network(vpc_cidr, strict=True)
    subnets = list(network.subnets(new_prefix=24))
    needed = 3 if private_endpoints else 2

    if len(subnets) < needed:
        raise ValueError(
            f"network.vpc_cidr '{vpc_cidr}' is too small - use at least a "
            f"/{24 - (needed - 1).bit_length()}"
            + (" (Private Link needs a third subnet for its endpoints)." if private_endpoints else ".")
        )

    private_endpoint_subnet_cidr = (
        str(next(subnets[2].subnets(new_prefix=PRIVATE_ENDPOINT_PREFIX_LENGTH)))
        if private_endpoints else None
    )

    return str(subnets[0]), str(subnets[1]), private_endpoint_subnet_cidr


def resolve_private_link(normalized: dict) -> dict | None:
    """
    Resolve classic Private Link (CLAUDE.md §8 milestone 46) from the
    request's cloud-neutral network.connectivity plus the environment:

      privatelink        -> on
      auto / unset       -> on in stage/live, off in dev
      nat                -> rejected (an AWS concept; no NAT on Azure)

    Returns the Terraform private_link object, or None when off. Brought
    hub DNS zones (network.existing_private_dns_zone_ids) must cover all
    three privatelink zones and only make sense when it's on.
    """

    network = normalized["network"]
    connectivity = network.get("connectivity", "auto")
    environment = normalized["workspace"]["environment"]

    if connectivity == "nat":
        raise ValueError(
            "network.connectivity 'nat' doesn't apply to Azure (cluster "
            "egress uses Azure's default outbound access). Use "
            "'privatelink', or leave it unset."
        )

    enabled = connectivity == "privatelink" or environment in PRIVATE_LINK_REQUIRED_ENVIRONMENTS
    zone_ids = network.get("existing_private_dns_zone_ids")

    if not enabled:
        if zone_ids:
            raise ValueError(
                "network.existing_private_dns_zone_ids is set, but Private "
                f"Link is off for this {environment} workspace - set "
                "network.connectivity: privatelink, or remove the zones."
            )

        return None

    private_link = {"enabled": True}

    if zone_ids:
        by_key = {}

        for zone_id in zone_ids:
            if not AZURE_DNS_ZONE_ID_PATTERN.match(zone_id):
                raise ValueError(
                    f"network.existing_private_dns_zone_ids entry '{zone_id}' "
                    f"is not a full private DNS zone resource id."
                )

            key = PRIVATE_DNS_ZONE_KEYS.get(zone_id.rsplit("/", 1)[-1].lower())

            if key is None:
                raise ValueError(
                    f"network.existing_private_dns_zone_ids entry '{zone_id}' "
                    f"isn't one of {sorted(PRIVATE_DNS_ZONE_KEYS)}."
                )

            by_key[key] = zone_id

        missing = sorted(name for name, key in PRIVATE_DNS_ZONE_KEYS.items() if key not in by_key)

        if missing:
            raise ValueError(
                f"network.existing_private_dns_zone_ids must cover all three "
                f"privatelink zones - missing {missing}."
            )

        private_link["existing_private_dns_zone_ids"] = by_key

    return private_link


def _first_free(vnet_cidr: str, prefix_length: int, used: list[ipaddress.IPv4Network]) -> ipaddress.IPv4Network | None:
    return next(
        (
            candidate
            for candidate in ipaddress.ip_network(vnet_cidr, strict=True).subnets(new_prefix=prefix_length)
            if not any(candidate.overlaps(other) for other in used)
        ),
        None,
    )


def resolve_existing_vnet(normalized: dict, deployment: dict) -> tuple[str, str | None, list[str] | None]:
    """
    Return (existing_vnet_id, existing_vnet_cidr, existing_subnet_ids) for
    a 'custom' workspace - deployment.yaml's network block overrides the
    request's, same precedence as every AWS existing_* field. The request
    field names stay cloud-neutral (existing_vpc_id/existing_vpc_cidr) -
    on Azure they name a VNet.

    Unlike AWS, there's no inventory "primary network" fallback - the
    client VNet's id is always required here.
    """

    deployment_network = deployment.get("network", {})
    normalized_network = normalized.get("network", {})

    def pick(key):
        return deployment_network.get(key) or normalized_network.get(key)

    vnet_id = pick("existing_vpc_id")

    if not vnet_id:
        raise ValueError(
            "network.strategy 'custom' on Azure needs network.existing_vpc_id "
            "- the full resource id of the client's VNet "
            "(/subscriptions/<sub>/resourceGroups/<rg>/providers/"
            "Microsoft.Network/virtualNetworks/<name>). There's no inventory "
            "default VNet for Azure."
        )

    if not AZURE_VNET_ID_PATTERN.match(vnet_id):
        raise ValueError(
            f"network.existing_vpc_id '{vnet_id}' is not a full Azure VNet "
            f"resource id (/subscriptions/<sub>/resourceGroups/<rg>/"
            f"providers/Microsoft.Network/virtualNetworks/<name>)."
        )

    subnet_ids = pick("existing_subnet_ids")

    if subnet_ids is not None:
        if len(subnet_ids) != 2:
            raise ValueError(
                f"network.existing_subnet_ids must list exactly two subnet "
                f"ids on Azure - [public, private], in that order "
                f"(Databricks' VNet-injection model); got {len(subnet_ids)}."
            )

        prefix = vnet_id.lower() + "/subnets/"

        for subnet_id in subnet_ids:
            if not subnet_id.lower().startswith(prefix):
                raise ValueError(
                    f"network.existing_subnet_ids entry '{subnet_id}' is not "
                    f"a subnet of network.existing_vpc_id '{vnet_id}'."
                )

    return vnet_id, pick("existing_vpc_cidr"), subnet_ids


def _custom_subnets_in_vnet(vnet_id: str, exclude_workspace: str) -> list[ipaddress.IPv4Network]:
    """
    Every subnet CIDR already claimed by another committed Azure workspace
    in the same client VNet - read from each sibling's pinned
    allocated-subnets.yaml (which records its own VNet id, so no
    normalized/ lookup is needed) or a hand-typed deployment.yaml override
    that also names its VNet. Same blind spot as AWS's checker: subnets
    Terraform doesn't know about (client-created, or adopted via
    existing_subnet_ids) are invisible here.
    """

    used = []

    for workspace_dir in (ROOT / "infrastructure" / "deployments" / "azure").glob("*/*"):
        if workspace_dir.name == exclude_workspace or not workspace_dir.is_dir():
            continue

        documents = [
            load_yaml(path) or {}
            for path in (
                workspace_dir / "allocated-subnets.yaml",
                workspace_dir / "deployment.yaml",
            )
            if path.exists()
        ]

        for document in documents:
            network = document.get("network", {})

            if (network.get("existing_vpc_id") or "").lower() != vnet_id.lower():
                continue

            for key in ("public_subnet_cidr", "private_subnet_cidr", "private_endpoint_subnet_cidr"):
                if network.get(key):
                    used.append(ipaddress.ip_network(network[key]))

    return used


def ensure_custom_subnet_allocation(
    workspace_name: str,
    normalized: dict,
    deployment: dict,
    deployment_dir: Path,
) -> dict:
    """
    Azure analog of generate_tfvars.py's ensure_subnet_allocation() for
    'custom' workspaces: guarantee deployment["network"] carries
    public_subnet_cidr/private_subnet_cidr before build_tfvars_azure()
    needs them. No-op for 'isolated' (subnets are derived from vpc_cidr
    directly - nothing else shares that VNet) and when adopting existing
    subnets.

    Order: deployment.yaml's own hand-typed CIDRs > a previously pinned
    allocated-subnets.yaml > a fresh allocation, written once and never
    recomputed (same reasoning as AWS - a sibling added later must never
    shift an already-applied workspace's subnets).
    """

    if normalized["network"]["strategy"] != "custom":
        return deployment

    vnet_id, vnet_cidr, subnet_ids = resolve_existing_vnet(normalized, deployment)
    private_link = resolve_private_link(normalized) is not None

    if subnet_ids:
        if private_link:
            raise ValueError(
                "Private Link with adopted subnets (network.existing_subnet_ids) "
                "isn't supported yet - it would also need a brought "
                "private-endpoint subnet. Let the platform create the subnets "
                "(omit existing_subnet_ids), or turn Private Link off (dev only)."
            )

        return deployment

    network = dict(deployment.get("network", {}))

    if network.get("public_subnet_cidr") and network.get("private_subnet_cidr"):
        if private_link and not network.get("private_endpoint_subnet_cidr"):
            raise ValueError(
                "This workspace's deployment.yaml hand-types its subnet CIDRs, "
                "so it must also set network.private_endpoint_subnet_cidr for "
                "Private Link."
            )

        return deployment

    allocated_path = deployment_dir / "allocated-subnets.yaml"
    pinned = load_yaml(allocated_path)["network"] if allocated_path.exists() else None
    needs_pe = private_link and not (pinned or {}).get("private_endpoint_subnet_cidr")

    if pinned is None or needs_pe:
        if not vnet_cidr:
            raise ValueError(
                "network.existing_vpc_cidr is required to auto-allocate "
                "subnets inside the client's VNet (one of its address-space "
                "ranges) - or set network.public_subnet_cidr/"
                "private_subnet_cidr explicitly in this workspace's "
                "deployment.yaml, or adopt existing subnets via "
                "network.existing_subnet_ids."
            )

        used = _custom_subnets_in_vnet(vnet_id, exclude_workspace=workspace_name)
        allocated = dict(pinned) if pinned else {"existing_vpc_id": vnet_id}

        # Adding Private Link to an already-pinned workspace only adds the
        # endpoint subnet - its existing subnets never move.
        wanted = [] if pinned else [
            ("public_subnet_cidr", CUSTOM_SUBNET_PREFIX_LENGTH),
            ("private_subnet_cidr", CUSTOM_SUBNET_PREFIX_LENGTH),
        ]

        if needs_pe:
            wanted.append(("private_endpoint_subnet_cidr", PRIVATE_ENDPOINT_PREFIX_LENGTH))

        used.extend(
            ipaddress.ip_network(allocated[key])
            for key in ("public_subnet_cidr", "private_subnet_cidr")
            if key in allocated
        )

        for key, prefix_length in wanted:
            block = _first_free(vnet_cidr, prefix_length, used)

            if block is None:
                raise ValueError(
                    f"Could not auto-allocate a /{prefix_length} for {key} "
                    f"within {vnet_cidr} - not enough free address space "
                    f"given what other workspaces already use in VNet {vnet_id}."
                )

            allocated[key] = str(block)
            used.append(block)

        allocated_path.parent.mkdir(parents=True, exist_ok=True)

        with allocated_path.open("w", encoding="utf-8") as file:
            file.write(
                "# AUTO-GENERATED by resolver/generate_tfvars_azure.py's "
                "ensure_custom_subnet_allocation() on first run for this "
                "workspace - do not hand-edit. Pinned permanently once "
                "written (same convention as the AWS path's "
                "allocated-subnets.yaml): regenerating tfvars never "
                "recomputes it. Records its own VNet id so sibling "
                "workspaces sharing that VNet avoid these ranges. To force "
                "reallocation before first apply, delete this file and "
                "re-run generate_tfvars.py.\n"
            )
            json.dump({"network": allocated}, file, indent=2)
            file.write("\n")
    else:
        allocated = pinned

    for key in ("public_subnet_cidr", "private_subnet_cidr", "private_endpoint_subnet_cidr"):
        if key in allocated:
            network.setdefault(key, allocated[key])

    return {**deployment, "network": network}


AZURE_KEY_ID_PATTERN = re.compile(
    r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
    r"Microsoft\.KeyVault/vaults/[^/]+/keys/[^/]+$",
    re.IGNORECASE,
)

# Which encryption setting each brought key belongs to.
AZURE_KEY_FIELDS = {
    "existing_workspace_storage_key_id": "workspace",
    "existing_managed_services_key_id": "workspace",
    "existing_application_data_key_id": "application_data",
}

AWS_KEY_FIELDS = (
    "existing_workspace_storage_key_arn",
    "existing_workspace_storage_key_alias",
    "existing_managed_services_key_arn",
    "existing_managed_services_key_alias",
)


def resolve_encryption_azure(normalized: dict) -> dict:
    """
    Validate the resolved encryption block for Azure (CLAUDE.md §8
    milestone 42) and return it as the root's var.encryption expects:
    workspace/application_data plus any brought Key Vault key ids.

    Fails loudly rather than silently ignoring: AWS KMS fields on an Azure
    request, a malformed key id, a brought key whose encryption setting
    isn't customer_managed (it would never be used), and customer-managed
    workspace keys combined with a FedRAMP compliance standard (Databricks
    documents managed-disk CMK as unsupported for FedRAMP workspaces).
    """

    encryption = normalized["encryption"]

    aws_fields = [key for key in AWS_KEY_FIELDS if key in encryption]

    if aws_fields:
        raise ValueError(
            f"encryption.{', encryption.'.join(aws_fields)} are AWS KMS "
            f"fields - on Azure, use the existing_*_key_id fields (full "
            f"Key Vault key resource ids) instead."
        )

    for field, setting in AZURE_KEY_FIELDS.items():
        key_id = encryption.get(field)

        if key_id is None:
            continue

        if not AZURE_KEY_ID_PATTERN.match(key_id):
            raise ValueError(
                f"encryption.{field} '{key_id}' is not a full Key Vault key "
                f"resource id (/subscriptions/<sub>/resourceGroups/<rg>/"
                f"providers/Microsoft.KeyVault/vaults/<vault>/keys/<key>)."
            )

        if encryption[setting] != "customer_managed":
            raise ValueError(
                f"encryption.{field} is set, but encryption.{setting} "
                f"resolves to '{encryption[setting]}' for this workspace's "
                f"profile/classification - the key would never be used."
            )

    compliance_standards = normalized["governance"].get("compliance_standards") or []

    fedramp = [standard for standard in compliance_standards if "FEDRAMP" in standard.upper()]

    if encryption["workspace"] == "customer_managed" and fedramp:
        raise ValueError(
            f"Customer-managed workspace keys can't be combined with "
            f"{', '.join(fedramp)}: Databricks documents managed-disk CMK as "
            f"unsupported for FedRAMP-compliance workspaces."
        )

    return {
        key: value
        for key, value in encryption.items()
        if key in ("workspace", "application_data") or key in AZURE_KEY_FIELDS
    }


def resolve_azure_account_inventory(account_id: str, inventory: dict) -> dict:
    """
    Find the platform/inventory/azure.yaml 'accounts' entry matching a
    request's Azure subscription id - same generic account-matching
    loop resolver.py's resolve_configuration() already does at request
    time, duplicated here (not imported) since this runs later, in the
    tfvars-generation stage, with only `normalized` to go on.
    """

    for account in inventory.get("azure", {}).get("accounts", {}).values():
        if account.get("account_id") == account_id:
            return account

    return {}


def build_tfvars_azure(normalized: dict, deployment: dict, inventory: dict) -> dict:
    network_strategy = normalized["network"]["strategy"]
    private_link = resolve_private_link(normalized)

    if network_strategy == "isolated":
        vpc_cidr = normalized["network"].get("vpc_cidr")

        if not vpc_cidr:
            raise ValueError(
                "network.vpc_cidr is required for an Azure 'isolated' "
                "workspace - this is the client's own address-space choice, "
                "same as the AWS path."
            )

        public_subnet_cidr, private_subnet_cidr, private_endpoint_subnet_cidr = derive_subnet_cidrs(
            vpc_cidr, private_endpoints=private_link is not None
        )

        network = {
            "vpc_cidr": vpc_cidr,
            "public_subnet_cidr": public_subnet_cidr,
            "private_subnet_cidr": private_subnet_cidr,
        }

        if private_endpoint_subnet_cidr:
            network["private_endpoint_subnet_cidr"] = private_endpoint_subnet_cidr
    elif network_strategy == "custom":
        vnet_id, _, subnet_ids = resolve_existing_vnet(normalized, deployment)

        network = {"existing_vnet_id": vnet_id}

        if subnet_ids:
            network["existing_public_subnet_id"] = subnet_ids[0]
            network["existing_private_subnet_id"] = subnet_ids[1]
        else:
            # Populated by ensure_custom_subnet_allocation() before this runs.
            deployment_network = deployment.get("network", {})
            network["public_subnet_cidr"] = deployment_network["public_subnet_cidr"]
            network["private_subnet_cidr"] = deployment_network["private_subnet_cidr"]

            if private_link:
                network["private_endpoint_subnet_cidr"] = deployment_network["private_endpoint_subnet_cidr"]
    else:
        raise ValueError(
            f"network.strategy '{network_strategy}' is not supported for "
            f"Azure - only 'isolated' and 'custom'."
        )

    encryption = resolve_encryption_azure(normalized)

    governance = {**normalized["governance"]}
    catalog_admin_principal = governance.pop("catalog_admin_principal", None)
    compliance_standards = governance.pop("compliance_standards", None) or []

    # var.cloud (infrastructure/workspace-azure) only declares
    # provider/region - no account/subscription id, same posture as the
    # AWS root (the azurerm provider derives its subscription from
    # whatever Azure CLI session is active, same as AWS's provider
    # deriving its account from active credentials - see
    # data.azurerm_client_config.current in the root's locals.tf).
    cloud = {
        "provider": normalized["cloud"]["provider"],
        "region": normalized["cloud"]["region"],
    }

    tfvars = {
        "cloud": cloud,
        "workspace": normalized["workspace"],
        "application": normalized["application"],
        "ownership": normalized["ownership"],
        "network": network,
        "data": normalized["data"],
        "encryption": encryption,
        "governance": governance,
        "compute": normalized["compute"],
        "logging": normalized["logging"],
        "validation": normalized["validation"],
        "tags": normalized.get("tags", {}),
    }

    if catalog_admin_principal is not None:
        tfvars["catalog_admin_principal"] = catalog_admin_principal

    if compliance_standards:
        tfvars["compliance_standards"] = compliance_standards

    if private_link:
        tfvars["private_link"] = private_link

    # Optional: account-level network policy / shared audit-log
    # destination to attach (CLAUDE.md §10 backlog item #1a / §8
    # milestone 40) - same deployment-override > inventory-default >
    # None precedence as AWS's resolve_network_policy_id(), but keyed by
    # Azure subscription id here (azure.accounts.<name>), not by a
    # Databricks account id - this project's Azure pipeline has never
    # needed to track a separate Databricks account id anywhere else
    # (Unity Catalog auto-assigns, see platform/inventory/azure.yaml's
    # own header comment), so introducing one just for these two fields
    # would be its own, separate piece of scope. Neither field is ever
    # required - an unset network policy/diagnostic setting is today's
    # behavior for every workspace.
    azure_account_inventory = resolve_azure_account_inventory(
        normalized["cloud"]["account"], inventory
    )

    network_policy_id = deployment.get("network_policy_id") or (
        azure_account_inventory.get("network_policy_id")
    )

    if network_policy_id:
        tfvars["network_policy_id"] = network_policy_id

    log_analytics_workspace_id = deployment.get(
        "log_analytics_workspace_id"
    ) or azure_account_inventory.get("log_analytics_workspace_id")

    if log_analytics_workspace_id:
        tfvars["log_analytics_workspace_id"] = log_analytics_workspace_id

    return tfvars


def main_azure(args, normalized: dict, deployment_dir: Path) -> None:
    deployment_path = (
        Path(args.deployment) if args.deployment
        else deployment_dir / "deployment.yaml"
    )

    output_path = (
        Path(args.output) if args.output
        else deployment_dir / "terraform.tfvars.json"
    )

    deployment = load_yaml(deployment_path)
    inventory = load_yaml(ROOT / "platform" / "inventory" / "azure.yaml")

    deployment = ensure_custom_subnet_allocation(
        normalized["workspace"]["name"], normalized, deployment, deployment_dir
    )

    tfvars = build_tfvars_azure(normalized, deployment, inventory)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as file:
        json.dump(tfvars, file, indent=2, sort_keys=False)
        file.write("\n")

    print(f"tfvars written to: {output_path}")
