from pathlib import Path
import argparse
import json

from loader import load_yaml
from check_cidr_allocations import check_all as check_cidr_allocations

ROOT = Path(__file__).resolve().parent.parent

OVERRIDE_OWNERSHIP_KEYS = (
    "vpc_ownership",
    "routing_ownership",
    "security_group_ownership",
    "endpoints_ownership",
)

KMS_PASSTHROUGH_KEYS = (
    "existing_workspace_storage_key_arn",
    "existing_workspace_storage_key_alias",
    "existing_managed_services_key_arn",
    "existing_managed_services_key_alias",
)


def require(condition: bool, message: str) -> None:
    """Raise ValueError with `message` when `condition` is false."""

    if not condition:
        raise ValueError(message)


def build_tfvars(normalized: dict, deployment: dict, inventory: dict) -> dict:
    """
    Combine a resolver normalized config with the small set of
    deployment-only values Terraform needs but the resolver does not
    produce (existing resource ids, concrete subnet CIDRs).
    """

    databricks_account_id = deployment.get("databricks", {}).get("account_id")

    require(
        bool(databricks_account_id),
        "Deployment file is missing 'databricks.account_id'.",
    )

    deployment_network = deployment.get("network", {})

    private_subnets = deployment_network.get("subnets", {}).get("private")

    require(
        isinstance(private_subnets, list) and len(private_subnets) >= 2,
        "Deployment file must define at least two entries under "
        "'network.subnets.private' (each with 'cidr' and "
        "'availability_zone').",
    )

    # Required whenever VPC ownership resolves to 'terraform' - whether by
    # the 'isolated' strategy's own default or by an explicit override. Not
    # nested under 'overrides': it isn't an override, it's always needed
    # once Terraform is the one creating the VPC.
    vpc_cidr = deployment_network.get("vpc_cidr")

    network = dict(normalized["network"])
    requirements = dict(network["requirements"])
    subnets = dict(requirements["subnets"])

    # 'allocation' describes a strategy (count/AZs/cidr_source), not a
    # Terraform input - only 'ownership' and the concrete 'private' list are.
    subnets.pop("allocation", None)
    subnets["private"] = private_subnets

    requirements["subnets"] = subnets
    network["requirements"] = requirements

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
        "encryption": normalized["encryption"],
        "governance": normalized["governance"],
        "compute": normalized["compute"],
        "logging": normalized["logging"],
        "validation": normalized["validation"],
        "tags": normalized.get("tags", {}),
    }

    platform = deployment.get("platform")

    if platform:
        # vpc_cidr (when present) is informational only, for
        # check_cidr_allocations.py's containment check against an existing
        # VPC - var.platform's object type doesn't declare it and Terraform
        # doesn't need it (the VPC already exists), so it's excluded here.
        tfvars["platform"] = {
            key: value for key, value in platform.items() if key != "vpc_cidr"
        }

    if vpc_cidr is not None:
        tfvars["vpc_cidr"] = vpc_cidr

    overrides = deployment.get("overrides", {})

    for key in OVERRIDE_OWNERSHIP_KEYS:
        if key in overrides:
            tfvars[f"{key}_override"] = overrides[key]

    if "existing_security_group_id" in overrides:
        tfvars["existing_security_group_id"] = overrides["existing_security_group_id"]

    if "privatelink_enabled" in overrides:
        tfvars["privatelink_enabled_override"] = overrides["privatelink_enabled"]

    kms = deployment.get("kms", {})

    for key in KMS_PASSTHROUGH_KEYS:
        if key in kms:
            tfvars[key] = kms[key]

    if normalized["governance"]["unity_catalog"]:
        region = normalized["cloud"]["region"]

        # Known existing metastores (one per Databricks account/region) live
        # in platform/inventory/aws.yaml's 'databricks' section, keyed by
        # Databricks account id - looked up automatically so a workspace's
        # deployment.yaml only needs to name its Databricks account, not
        # repeat the metastore id every time. 'unity_catalog.
        # existing_metastore_id' in deployment.yaml is an optional override
        # for the rare workspace that needs a different metastore.
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

        tfvars["existing_metastore_id"] = existing_metastore_id

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
            "infrastructure/deployments/<environment>/<workspace>/"
            "deployment.yaml (environment read from the normalized file), "
            "writing infrastructure/deployments/<environment>/<workspace>/"
            "terraform.tfvars.json. All workspaces share the one Terraform "
            "root in infrastructure/workspace/ - see "
            "resolver/generate_backend_config.py for selecting which "
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

    deployment_dir = (
        ROOT / "infrastructure" / "deployments" / environment / args.workspace
    )

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

    # Check this (and every other committed workspace's) CIDR allocations
    # for collisions before generating anything Terraform would act on.
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
