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

Scope is deliberately bounded to what a real Azure spike validated:
always a brand-new, Terraform-owned VNet (no existing-VNet reuse yet),
no customer-managed encryption, no KMS-equivalent bring-your-own-key.
"""

from pathlib import Path
import ipaddress
import json

from loader import load_yaml

ROOT = Path(__file__).resolve().parent.parent


def derive_subnet_cidrs(vpc_cidr: str) -> tuple[str, str]:
    """
    Carve the first two /24s out of vpc_cidr for Azure's fixed two-subnet
    VNet-injection model (Databricks' own "public"/"private" naming - not
    AZ-scoped the way AWS subnets are, so there's no per-region
    subnet_defaults/availability_zones inventory lookup needed here).
    """

    network = ipaddress.ip_network(vpc_cidr, strict=True)
    subnets = list(network.subnets(new_prefix=24))

    if len(subnets) < 2:
        raise ValueError(
            f"network.vpc_cidr '{vpc_cidr}' is too small to carve two "
            f"/24 subnets from - use at least a /23."
        )

    public_subnet_cidr, private_subnet_cidr = str(subnets[0]), str(subnets[1])

    return public_subnet_cidr, private_subnet_cidr


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

    if network_strategy != "isolated":
        raise ValueError(
            f"network.strategy '{network_strategy}' is not yet supported "
            f"for Azure - only 'isolated' (a brand-new, Terraform-owned "
            f"VNet) is implemented today. Existing-VNet reuse is an "
            f"explicitly deferred future enhancement."
        )

    vpc_cidr = normalized["network"].get("vpc_cidr")

    if not vpc_cidr:
        raise ValueError(
            "network.vpc_cidr is required for an Azure 'isolated' "
            "workspace - this is the client's own address-space choice, "
            "same as the AWS path."
        )

    public_subnet_cidr, private_subnet_cidr = derive_subnet_cidrs(vpc_cidr)

    encryption = normalized["encryption"]

    if encryption["workspace"] == "customer_managed":
        raise ValueError(
            "encryption.workspace == 'customer_managed' is not yet "
            "supported for Azure - customer-managed Key Vault encryption "
            "is an explicitly deferred future enhancement. This workspace's "
            "profile/classification currently resolves to customer_managed, "
            "which only the AWS path can satisfy today."
        )

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
        "network": {
            "vpc_cidr": vpc_cidr,
            "public_subnet_cidr": public_subnet_cidr,
            "private_subnet_cidr": private_subnet_cidr,
        },
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

    tfvars = build_tfvars_azure(normalized, deployment, inventory)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as file:
        json.dump(tfvars, file, indent=2, sort_keys=False)
        file.write("\n")

    print(f"tfvars written to: {output_path}")
