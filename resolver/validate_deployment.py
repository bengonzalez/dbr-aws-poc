"""
Checks a deployed workspace's live AWS/Databricks state against what the
resolver resolved for it (normalized/<workspace>.yaml) - the consumer of
policies.yaml's validation_policy (CLAUDE.md Sec5.8 / Sec8).

Unlike every other resolver/*.py script, this runs AFTER a real
`terraform apply`, against live state, not before one against local YAML.
Prerequisite: the shared root (infrastructure/workspace/) must already be
`terraform init`'d with this workspace's backend-config - same standing
convention as plan/apply.

Each check reports one of:
  PASS            - verified against live state
  FAIL            - checked, and the live state doesn't match
  N/A             - not applicable to this workspace (e.g. encryption
                    check when the profile is platform_managed, not
                    customer_managed)
  NOT_IMPLEMENTED - no Terraform resource exists anywhere in this
                    pipeline to produce the thing being checked yet
                    (identity/SCIM provisioning, centralized audit log
                    delivery) - reported honestly rather than silently
                    skipped or faked as a pass.

Exit code is 0 unless validation.blocking is true AND at least one check
is FAIL (NOT_IMPLEMENTED/N/A never trigger a non-zero exit) - this is
what a future CI pipeline would gate on.
"""

from pathlib import Path
from datetime import datetime, timezone
import argparse
import json
import subprocess

from loader import load_yaml
from generate_tfvars import resolve_metastore_id

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE_ROOT = ROOT / "infrastructure" / "workspace"

PASS = "PASS"
FAIL = "FAIL"
NOT_APPLICABLE = "N/A"
NOT_IMPLEMENTED = "NOT_IMPLEMENTED"


class CheckResult:
    def __init__(self, name: str, status: str, detail: str = ""):
        self.name = name
        self.status = status
        self.detail = detail

    def to_dict(self) -> dict:
        return {"name": self.name, "status": self.status, "detail": self.detail}


def run_databricks(args: list[str], profile: str) -> tuple[dict | None, str | None]:
    """Run a databricks CLI command. Returns (parsed_json, None) on success,
    or (None, error_message) on failure - never raises, so callers can
    turn a CLI failure into a FAIL check result instead of crashing."""

    command = ["databricks"] + args + ["--profile", profile, "-o", "json"]

    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return None, "'databricks' CLI not found on PATH."

    if result.returncode != 0:
        return None, result.stderr.strip() or result.stdout.strip()

    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, f"Could not parse databricks CLI output: {result.stdout!r}"


def get_terraform_outputs() -> dict:
    """Read `terraform output -json` from the shared root. Raises
    RuntimeError with an actionable message if the backend isn't
    initialized for any workspace, or isn't the one the caller expects -
    the caller is responsible for confirming it's the right one."""

    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=WORKSPACE_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        raise RuntimeError("'terraform' CLI not found on PATH.")

    if result.returncode != 0:
        raise RuntimeError(
            "'terraform output' failed in infrastructure/workspace/ - has "
            "this workspace's backend been initialized? Run: terraform "
            "init -backend-config=backend.tfbackend "
            "-backend-config=../deployments/<env>/<name>/backend.tfbackend "
            f"-reconfigure first. ({result.stderr.strip()})"
        )

    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"Could not parse terraform output: {result.stdout!r}")

    return {key: entry.get("value") for key, entry in raw.items()}


def run_checks(
    normalized: dict,
    deployment: dict,
    inventory: dict,
    profile: str,
) -> list[CheckResult]:
    outputs = get_terraform_outputs()
    workspace_id = outputs.get("databricks_workspace_id")

    results = []

    if not workspace_id:
        results.append(
            CheckResult(
                "workspace.exists",
                FAIL,
                "No databricks_workspace_id in terraform output - this "
                "workspace has not been applied (or the backend isn't "
                "pointed at it).",
            )
        )

        # Nothing else can be meaningfully checked without a live workspace.
        results.append(
            CheckResult("network.required", FAIL, "workspace not deployed")
        )

        if normalized["encryption"]["workspace"] == "customer_managed":
            results.append(
                CheckResult(
                    "encryption.required", FAIL, "workspace not deployed"
                )
            )
        else:
            results.append(
                CheckResult(
                    "encryption.required",
                    NOT_APPLICABLE,
                    "encryption.workspace is platform_managed",
                )
            )

        if normalized["governance"]["unity_catalog"]:
            results.append(
                CheckResult(
                    "governance.unity_catalog", FAIL, "workspace not deployed"
                )
            )

        results.extend(_not_implemented_checks())

        return results

    workspace, error = run_databricks(
        ["account", "workspaces", "get", str(workspace_id)], profile
    )

    if workspace is None:
        results.append(
            CheckResult(
                "workspace.exists", FAIL, f"Could not fetch workspace: {error}"
            )
        )
        results.append(
            CheckResult("network.required", FAIL, "could not fetch workspace")
        )
    else:
        status = workspace.get("workspace_status")

        results.append(
            CheckResult(
                "workspace.exists",
                PASS if status == "RUNNING" else FAIL,
                f"workspace_status={status!r}",
            )
        )

        network_id = workspace.get("network_id")

        results.append(
            CheckResult(
                "network.required",
                PASS if network_id else FAIL,
                f"network_id={network_id!r}",
            )
        )

    # ---------------------------------------------------------
    # encryption.required
    # ---------------------------------------------------------

    if normalized["encryption"]["workspace"] == "customer_managed":
        if workspace is None:
            results.append(
                CheckResult(
                    "encryption.required", FAIL, "could not fetch workspace"
                )
            )
        else:
            storage_key = workspace.get("storage_customer_managed_key_id")
            managed_key = workspace.get("managed_services_customer_managed_key_id")

            results.append(
                CheckResult(
                    "encryption.required",
                    PASS if (storage_key and managed_key) else FAIL,
                    f"storage_customer_managed_key_id={storage_key!r}, "
                    f"managed_services_customer_managed_key_id={managed_key!r}",
                )
            )
    else:
        results.append(
            CheckResult(
                "encryption.required",
                NOT_APPLICABLE,
                "encryption.workspace is platform_managed - SSE-S3 already "
                "guaranteed by Terraform's own successful apply",
            )
        )

    # ---------------------------------------------------------
    # governance.unity_catalog
    # ---------------------------------------------------------

    if normalized["governance"]["unity_catalog"]:
        databricks_account_id = deployment["databricks"]["account_id"]
        region = normalized["cloud"]["region"]

        expected_metastore_id = resolve_metastore_id(
            databricks_account_id, region, deployment, inventory
        )

        assignment, error = run_databricks(
            ["account", "metastore-assignments", "get", str(workspace_id)],
            profile,
        )

        if assignment is None:
            results.append(
                CheckResult(
                    "governance.unity_catalog",
                    FAIL,
                    f"Could not fetch metastore assignment: {error}",
                )
            )
        else:
            actual_metastore_id = assignment.get("metastore_assignment", {}).get(
                "metastore_id"
            )

            results.append(
                CheckResult(
                    "governance.unity_catalog",
                    PASS if actual_metastore_id == expected_metastore_id else FAIL,
                    f"expected={expected_metastore_id!r}, "
                    f"actual={actual_metastore_id!r}. Note: this only "
                    "confirms metastore assignment, not live catalog "
                    "contents/isolation - that needs a workspace-scoped "
                    "Databricks profile, a scoped-out follow-up.",
                )
            )

    results.extend(_not_implemented_checks())

    return results


def _not_implemented_checks() -> list[CheckResult]:
    return [
        CheckResult(
            "identity.required",
            NOT_IMPLEMENTED,
            "no SCIM/user/group provisioning exists anywhere in this "
            "pipeline yet",
        ),
        CheckResult(
            "logging.centralized",
            NOT_IMPLEMENTED,
            "no audit-log-delivery Terraform resource exists anywhere in "
            "this pipeline yet",
        ),
    ]


def print_report(results: list[CheckResult]) -> None:
    print()
    print("Workspace Validation Report")
    print("----------------------------")
    print()

    for result in results:
        print(f"[{result.status}] {result.name}")
        if result.detail:
            print(f"    {result.detail}")

    print()

    counts = {}
    for result in results:
        counts[result.status] = counts.get(result.status, 0) + 1

    summary = ", ".join(f"{count} {status}" for status, count in counts.items())
    print(f"Summary: {summary}")
    print()


def write_evidence(workspace_name: str, results: list[CheckResult]) -> Path:
    evidence_dir = ROOT / "validation-evidence" / workspace_name
    evidence_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    evidence_path = evidence_dir / f"{timestamp}.json"

    with evidence_path.open("w", encoding="utf-8") as file:
        json.dump(
            {
                "workspace": workspace_name,
                "timestamp": timestamp,
                "checks": [result.to_dict() for result in results],
            },
            file,
            indent=2,
        )
        file.write("\n")

    return evidence_path


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate a deployed workspace's live AWS/Databricks state "
            "against what the resolver resolved for it. Run this after "
            "terraform apply, with infrastructure/workspace/ already "
            "terraform init'd against this workspace's backend-config."
        )
    )

    parser.add_argument("--workspace", required=True, help="Workspace name.")

    parser.add_argument(
        "--profile",
        required=True,
        help="Databricks CLI account-console profile (same one used for "
        "terraform apply).",
    )

    parser.add_argument(
        "--normalized",
        help="Override path to the normalized YAML.",
    )

    parser.add_argument(
        "--deployment",
        help="Override path to the deployment YAML.",
    )

    args = parser.parse_args()

    normalized_path = (
        Path(args.normalized)
        if args.normalized
        else ROOT / "normalized" / f"{args.workspace}.yaml"
    )

    normalized = load_yaml(normalized_path)
    environment = normalized["workspace"]["environment"]

    deployment_path = (
        Path(args.deployment)
        if args.deployment
        else ROOT
        / "infrastructure"
        / "deployments"
        / environment
        / args.workspace
        / "deployment.yaml"
    )

    deployment = load_yaml(deployment_path)
    inventory = load_yaml(ROOT / "platform" / "inventory" / "aws.yaml")

    results = run_checks(normalized, deployment, inventory, args.profile)

    print_report(results)

    if normalized["validation"]["evidence"] == "required":
        evidence_path = write_evidence(args.workspace, results)
        print(f"Evidence written to: {evidence_path}")
        print()

    blocking = normalized["validation"]["blocking"]
    has_failure = any(result.status == FAIL for result in results)

    if blocking and has_failure:
        print("STATUS: FAILED (blocking)")
        return 1

    if has_failure:
        print("STATUS: FAILED (non-blocking - not failing the run)")
    else:
        print("STATUS: PASSED")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print()
        print("validation failed")
        print("------------------")
        print()
        print(error)
        print()

        raise SystemExit(1)
