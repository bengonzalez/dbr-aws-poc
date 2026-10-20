from pathlib import Path
import argparse

from loader import load_yaml

ROOT = Path(__file__).resolve().parent.parent

# Kept constant across every workspace per the platform's own convention
# (CLAUDE.md) - override with --bucket if this ever needs to vary.
DEFAULT_BUCKET = "beng-tfstatefiles"
DEFAULT_REGION = "us-east-1"

# Azure equivalents - the storage account/resource group don't need to
# exist yet for code-only work (no real apply in this pass); same
# bootstrap-ahead-of-use pattern the AWS bucket defaults above already
# have (beng-tfstatefiles also pre-existed as a manually-created resource
# outside this repo's Terraform).
DEFAULT_RESOURCE_GROUP = "rg-databricks-tfstate"
DEFAULT_STORAGE_ACCOUNT = "stdatabrickstfstate"
DEFAULT_CONTAINER = "tfstate"


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Generate the partial S3 backend configuration for a workspace, "
            "passed to 'terraform init -backend-config=...' (twice - see "
            "below) to select which workspace's state the single shared "
            "Terraform root points at. Bucket/region/use_lockfile are the "
            "same for every workspace of a given cloud provider, so they "
            "live in one committed, idempotently-rewritten file per "
            "provider (infrastructure/aws/workspace/backend.tfbackend or "
            "infrastructure/azure/workspace/backend.tfbackend); only the "
            "per-workspace 'key' (<environment>/<workspace>/"
            "terraform.tfstate, provider and environment both read from "
            "normalized/<workspace>.yaml) goes into "
            "infrastructure/deployments/<provider>/<environment>/<workspace>/"
            "backend.tfbackend. Pass both at init time: terraform init "
            "-backend-config=backend.tfbackend "
            "-backend-config=../../deployments/<provider>/<environment>/"
            "<workspace>/backend.tfbackend -reconfigure."
        )
    )

    parser.add_argument(
        "--workspace",
        required=True,
        help="Workspace name.",
    )

    parser.add_argument(
        "--normalized",
        help="Override path to the normalized YAML (for reading environment).",
    )

    parser.add_argument(
        "--bucket",
        default=DEFAULT_BUCKET,
        help=f"S3 bucket holding state (default: {DEFAULT_BUCKET}).",
    )

    parser.add_argument(
        "--region",
        default=DEFAULT_REGION,
        help=f"AWS region of the bucket (default: {DEFAULT_REGION}).",
    )

    parser.add_argument(
        "--resource-group",
        default=DEFAULT_RESOURCE_GROUP,
        help=f"Azure resource group holding the state storage account "
             f"(default: {DEFAULT_RESOURCE_GROUP}). Only used for "
             f"azure-provider workspaces.",
    )

    parser.add_argument(
        "--storage-account",
        default=DEFAULT_STORAGE_ACCOUNT,
        help=f"Azure storage account holding state (default: "
             f"{DEFAULT_STORAGE_ACCOUNT}). Only used for azure-provider "
             f"workspaces.",
    )

    parser.add_argument(
        "--container",
        default=DEFAULT_CONTAINER,
        help=f"Azure storage container holding state (default: "
             f"{DEFAULT_CONTAINER}). Only used for azure-provider "
             f"workspaces.",
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

    output_path = (
        Path(args.output) if args.output
        else ROOT / "infrastructure" / "deployments" / provider / environment / args.workspace / "backend.tfbackend"
    )

    key = f"{environment}/{args.workspace}/terraform.tfstate"

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as file:
        file.write(f'key = "{key}"\n')

    if provider == "azure":
        # Constants shared by every Azure workspace - rewritten identically
        # each run, same drift-proofing as the AWS shared file below.
        shared_path = ROOT / "infrastructure" / "azure" / "workspace" / "backend.tfbackend"

        shared_lines = [
            f'resource_group_name  = "{args.resource_group}"',
            f'storage_account_name = "{args.storage_account}"',
            f'container_name       = "{args.container}"',
        ]

        with shared_path.open("w", encoding="utf-8") as file:
            file.write("\n".join(shared_lines) + "\n")

        print(f"backend config written to: {output_path}")
        print(f"  key    = {key}")
        print(f"shared backend config written to: {shared_path}")
        print(f"  resource_group_name  = {args.resource_group}")
        print(f"  storage_account_name = {args.storage_account}")
        print(f"  container_name       = {args.container}")
        return

    # Constants shared by every workspace - rewritten identically each run
    # so this file can never drift from the --bucket/--region actually used.
    shared_path = ROOT / "infrastructure" / "aws" / "workspace" / "backend.tfbackend"

    shared_lines = [
        f'bucket       = "{args.bucket}"',
        f'region       = "{args.region}"',
        "use_lockfile = true",
    ]

    with shared_path.open("w", encoding="utf-8") as file:
        file.write("\n".join(shared_lines) + "\n")

    print(f"backend config written to: {output_path}")
    print(f"  key    = {key}")
    print(f"shared backend config written to: {shared_path}")
    print(f"  bucket = {args.bucket}")
    print(f"  region = {args.region}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, FileNotFoundError, KeyError) as error:
        print()
        print("backend config generation failed")
        print("---------------------------------")
        print()
        print(error)
        print()

        raise SystemExit(1)
