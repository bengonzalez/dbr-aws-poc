from pathlib import Path
import argparse

from loader import load_yaml

ROOT = Path(__file__).resolve().parent.parent

# Kept constant across every workspace per the platform's own convention
# (CLAUDE.md) - override with --bucket if this ever needs to vary.
DEFAULT_BUCKET = "beng-tfstatefiles"
DEFAULT_REGION = "us-east-1"


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Generate the partial S3 backend configuration for a workspace, "
            "passed to 'terraform init -backend-config=...' (twice - see "
            "below) to select which workspace's state the single shared "
            "Terraform root points at. Bucket/region/use_lockfile are the "
            "same for every workspace, so they live in one committed, "
            "idempotently-rewritten file (infrastructure/workspace/"
            "backend.tfbackend); only the per-workspace 'key' "
            "(<environment>/<workspace>/terraform.tfstate, environment "
            "read from normalized/<workspace>.yaml) goes into "
            "infrastructure/deployments/<environment>/<workspace>/"
            "backend.tfbackend. Pass both at init time: terraform init "
            "-backend-config=backend.tfbackend "
            "-backend-config=../deployments/<environment>/<workspace>/"
            "backend.tfbackend -reconfigure."
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

    output_path = (
        Path(args.output) if args.output
        else ROOT / "infrastructure" / "deployments" / environment / args.workspace / "backend.tfbackend"
    )

    key = f"{environment}/{args.workspace}/terraform.tfstate"

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as file:
        file.write(f'key = "{key}"\n')

    # Constants shared by every workspace - rewritten identically each run
    # so this file can never drift from the --bucket/--region actually used.
    shared_path = ROOT / "infrastructure" / "workspace" / "backend.tfbackend"

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
