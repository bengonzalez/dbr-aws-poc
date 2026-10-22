"""
Tears down one workspace (CLAUDE.md §8 milestone 45), folding in every
manual teardown step this project has had to repeat by hand:

  1. Points the cloud's shared root at THIS workspace's backend itself
     (terraform init with both -backend-config files). There's no way to
     destroy the wrong workspace by forgetting to re-init first, the risk
     CLAUDE.md §9 warns about for plan/apply.
  2. `terraform state rm` of the one-way-locked legacy settings
     (databricks_disable_legacy_access_setting /
     databricks_disable_legacy_dbfs_setting - Databricks refuses to delete
     them once enabled, milestone 38). Found by resource type, so it works
     for the AWS module path and the Azure root alike.
  3. `terraform destroy`, retried on failures known to be transient:
     dropped connections (milestone 43) and AWS's "still attached to a
     workspace" lag right after the workspace itself is deleted
     (milestone 36).
  4. Azure only: deletes the Databricks-managed resource group, which
     never cascade-deletes with its workspace (milestones 35-44), but only
     after confirming the parent workspace is gone.
  5. Optional --purge-files (for throwaways): deletes the now-empty state
     object and the workspace's generated local files.

Two AWS hazards are detected and STOPPED on, not fixed: a non-empty S3
bucket (emptying it deletes real data - milestone 34 kept force_destroy
off on purpose) and the Unity Catalog storage-credential "dependent
storage location" lock (milestone 34's plan/apply-then-destroy sequence).
Both print the exact manual steps.

AWS still needs the usual Databricks CLI profile for the account root
(TF_VAR_databricks_profile or infrastructure/aws/workspace/
local.auto.tfvars). Azure uses the active az login.
"""

from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
import sys

from loader import load_yaml, resolve_normalized_path

ROOT = Path(__file__).resolve().parent.parent

LOCKED_SETTING_TYPES = (
    "databricks_disable_legacy_access_setting",
    "databricks_disable_legacy_dbfs_setting",
)

TRANSIENT_PATTERNS = (
    r"HTTP response was nil",
    r"connection (may have been )?reset",
    r"while it is attached to a workspace",
    r"TLS handshake timeout",
)

MAX_DESTROY_ATTEMPTS = 3


class TeardownError(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"[teardown] {message}", flush=True)


def run(command: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    executable = shutil.which(command[0])

    if executable is None:
        raise TeardownError(f"'{command[0]}' not found on PATH.")

    result = subprocess.run([executable] + command[1:], cwd=cwd, capture_output=True, text=True)

    if check and result.returncode != 0:
        raise TeardownError(
            f"`{' '.join(command[:3])} ...` failed:\n{(result.stderr or result.stdout).strip()}"
        )

    return result


def terraform_init(root: Path, provider: str, environment: str, workspace: str) -> None:
    per_workspace = f"../../deployments/{provider}/{environment}/{workspace}/backend.tfbackend"

    if not (root / per_workspace).exists():
        raise TeardownError(
            f"No backend config at {(root / per_workspace).resolve()} - run "
            f"resolver/generate_backend_config.py --workspace {workspace} first."
        )

    log(f"terraform init against {provider}/{environment}/{workspace}'s backend")
    run(
        [
            "terraform", "init",
            "-backend-config=backend.tfbackend",
            f"-backend-config={per_workspace}",
            "-reconfigure", "-input=false",
        ],
        cwd=root,
    )


def state_list(root: Path) -> list[str]:
    result = run(["terraform", "state", "list"], cwd=root, check=False)

    if result.returncode != 0:
        # An empty/never-written state errors on some backends - treat as empty.
        return []

    return [line for line in result.stdout.splitlines() if line.strip()]


def terraform_outputs(root: Path) -> dict:
    result = run(["terraform", "output", "-json"], cwd=root, check=False)

    if result.returncode != 0:
        return {}

    try:
        return {key: entry.get("value") for key, entry in json.loads(result.stdout).items()}
    except json.JSONDecodeError:
        return {}


def remove_locked_settings(root: Path, addresses: list[str]) -> None:
    locked = [
        address
        for address in addresses
        if address.split(".")[-2] in LOCKED_SETTING_TYPES
    ]

    if not locked:
        return

    log(f"state rm {len(locked)} one-way-locked setting(s): {', '.join(locked)}")
    run(["terraform", "state", "rm"] + locked, cwd=root)


def check_aws_hazards(output: str) -> None:
    """Raise with manual steps for the two AWS failures that must not be
    auto-fixed."""

    if "BucketNotEmpty" in output:
        details = "\n".join(line for line in output.splitlines() if "Bucket" in line or "bucket" in line)
        raise TeardownError(
            "An S3 bucket still holds data. Emptying it deletes that data "
            "for good, so this script won't do it. If that's intended: "
            "`aws s3 rm s3://<bucket> --recursive` (plus deleting object "
            "versions if the bucket is versioned), then re-run.\n" + details
        )

    credential = re.search(r"(module\.[\w.\[\]\"-]*databricks_storage_credential\.this)", output)

    if "dependent storage location" in output:
        address = credential.group(1) if credential else "<storage credential address>"
        raise TeardownError(
            "Unity Catalog won't delete the storage credential yet "
            "(\"dependent storage location\"). Known workaround (CLAUDE.md "
            "§8 milestone 34), from the AWS root: "
            f"`terraform plan -target='{address}' -out=p && terraform apply p` "
            f"(this update is expected to fail), then "
            f"`terraform destroy -target='{address}'`, then re-run this script."
        )


def destroy(root: Path, var_file: str, provider: str) -> None:
    for attempt in range(1, MAX_DESTROY_ATTEMPTS + 1):
        log(f"terraform destroy (attempt {attempt}/{MAX_DESTROY_ATTEMPTS})")

        result = run(
            ["terraform", "destroy", "-auto-approve", "-input=false", "-no-color", f"-var-file={var_file}"],
            cwd=root,
            check=False,
        )

        output = result.stdout + result.stderr

        if result.returncode == 0:
            summary = re.search(r"Destroy complete! Resources: \d+ destroyed\.", output)
            log(summary.group(0) if summary else "destroy complete")
            return

        if provider == "aws":
            check_aws_hazards(output)

        if attempt < MAX_DESTROY_ATTEMPTS and any(re.search(p, output, re.I) for p in TRANSIENT_PATTERNS):
            log("known transient failure - retrying")
            continue

        errors = "\n".join(line for line in output.splitlines() if "Error" in line) or output[-2000:]
        raise TeardownError(f"terraform destroy failed:\n{errors}")


def azure_group_exists(name: str) -> bool:
    result = run(["az", "group", "exists", "-n", name], check=False)
    return result.stdout.strip().lower() == "true"


def delete_azure_managed_group(workspace: str, workspace_resource_id: str | None) -> None:
    managed = f"rg-{workspace}-managed"  # managed_resource_group_name in modules/azure/workspace-deployment

    if workspace_resource_id:
        still_there = run(["az", "resource", "show", "--ids", workspace_resource_id], check=False)

        if still_there.returncode == 0:
            raise TeardownError(
                f"The workspace still exists after destroy ({workspace_resource_id}) - "
                f"not touching {managed}."
            )

    if not azure_group_exists(managed):
        log(f"managed resource group {managed} already gone")
        return

    log(f"deleting orphaned managed resource group {managed} (a few minutes)")
    run(["az", "group", "delete", "-n", managed, "--yes"])


def purge_state(provider: str, environment: str, workspace: str) -> None:
    key = f"{environment}/{workspace}/terraform.tfstate"

    if provider == "azure":
        backend = dict(
            re.findall(r'(\w+)\s*=\s*"?([^"\n]+)"?', (ROOT / "infrastructure/azure/workspace/backend.tfbackend").read_text())
        )
        result = run(
            [
                "az", "storage", "blob", "delete",
                "--account-name", backend["storage_account_name"],
                "-c", backend["container_name"],
                "-n", key,
            ],
            check=False,
        )
    else:
        backend = dict(
            re.findall(r'(\w+)\s*=\s*"?([^"\n]+)"?', (ROOT / "infrastructure/aws/workspace/backend.tfbackend").read_text())
        )
        result = run(["aws", "s3", "rm", f"s3://{backend['bucket']}/{key}"], check=False)

    log(f"state object {key}: {'deleted' if result.returncode == 0 else 'not deleted - ' + result.stderr.strip()[:200]}")


def purge_files(provider: str, environment: str, workspace: str, normalized_path: Path) -> None:
    deployment_dir = ROOT / "infrastructure" / "deployments" / provider / environment / workspace

    if deployment_dir.exists():
        shutil.rmtree(deployment_dir)
        log(f"removed {deployment_dir.relative_to(ROOT)}")

    if normalized_path.exists():
        normalized_path.unlink()
        log(f"removed {normalized_path.relative_to(ROOT)}")

    evidence = ROOT / "validation-evidence" / workspace

    if evidence.exists():
        shutil.rmtree(evidence)
        log(f"removed {evidence.relative_to(ROOT)}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Destroy one workspace, including the manual steps a plain terraform destroy misses."
    )
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--provider", choices=["aws", "azure"], help="Only needed for a name that exists on both clouds.")
    parser.add_argument("--yes", action="store_true", help="Skip the confirmation prompt.")
    parser.add_argument(
        "--purge-files",
        action="store_true",
        help="Also delete the empty state object and the workspace's generated local files "
        "(deployment dir, normalized config, validation evidence). For throwaways - "
        "without it, everything needed to redeploy is kept. The request file is never touched.",
    )
    args = parser.parse_args()

    normalized_path = resolve_normalized_path(ROOT, args.workspace, args.provider)
    normalized = load_yaml(normalized_path)
    provider = normalized["cloud"]["provider"]
    environment = normalized["workspace"]["environment"]

    root = ROOT / "infrastructure" / provider / "workspace"
    var_file = f"../../deployments/{provider}/{environment}/{args.workspace}/terraform.tfvars.json"

    if not (root / var_file).exists():
        raise TeardownError(f"No tfvars at {(root / var_file).resolve()} - nothing generated for this workspace.")

    terraform_init(root, provider, environment, args.workspace)

    addresses = state_list(root)
    outputs = terraform_outputs(root)

    log(f"{provider}/{environment}/{args.workspace}: {len(addresses)} resource(s) in state")

    if addresses and not args.yes:
        if not sys.stdin.isatty():
            raise TeardownError("Refusing to destroy without confirmation - pass --yes (no terminal to prompt on).")

        try:
            answer = input(f"Destroy {len(addresses)} resource(s) of '{args.workspace}'? Type the workspace name: ")
        except EOFError:
            # isatty() can report True for a redirected stdin under Git Bash.
            raise TeardownError("Refusing to destroy without confirmation - pass --yes (no input to read a confirmation from).")

        if answer.strip() != args.workspace:
            log("cancelled")
            return 1

    if addresses:
        remove_locked_settings(root, addresses)
        destroy(root, var_file, provider)

    if provider == "azure":
        delete_azure_managed_group(args.workspace, outputs.get("workspace_resource_id"))

    remaining = state_list(root)

    if remaining:
        raise TeardownError(f"{len(remaining)} resource(s) still in state: {', '.join(remaining[:5])}")

    if args.purge_files:
        purge_state(provider, environment, args.workspace)
        purge_files(provider, environment, args.workspace, normalized_path)

    log("done")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (TeardownError, ValueError, FileNotFoundError) as error:
        print(f"\n[teardown] FAILED: {error}\n", file=sys.stderr)
        raise SystemExit(1)
