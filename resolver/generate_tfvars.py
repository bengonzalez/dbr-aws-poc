from pathlib import Path
import argparse
import json

from loader import load_yaml

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


def build_tfvars(normalized: dict, deployment: dict) -> dict:
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

    private_subnets = (
        deployment.get("network", {}).get("subnets", {}).get("private")
    )

    require(
        isinstance(private_subnets, list) and len(private_subnets) >= 2,
        "Deployment file must define at least two entries under "
        "'network.subnets.private' (each with 'cidr' and "
        "'availability_zone').",
    )

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
        tfvars["platform"] = platform

    overrides = deployment.get("overrides", {})

    for key in OVERRIDE_OWNERSHIP_KEYS:
        if key in overrides:
            tfvars[f"{key}_override"] = overrides[key]

    for key in ("vpc_cidr", "existing_security_group_id"):
        if key in overrides:
            tfvars[key] = overrides[key]

    kms = deployment.get("kms", {})

    for key in KMS_PASSTHROUGH_KEYS:
        if key in kms:
            tfvars[key] = kms[key]

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
            "infrastructure/workspace/<workspace>.deployment.yaml."
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

    deployment_path = (
        Path(args.deployment) if args.deployment
        else ROOT / "infrastructure" / "workspace" / f"{args.workspace}.deployment.yaml"
    )

    output_path = (
        Path(args.output) if args.output
        else ROOT / "infrastructure" / "workspace" / f"{args.workspace}.tfvars.json"
    )

    normalized = load_yaml(normalized_path)
    deployment = load_yaml(deployment_path)

    tfvars = build_tfvars(normalized, deployment)

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
