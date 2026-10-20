"""
Checks a deployed workspace's live AWS/Databricks state against what the
resolver resolved for it (normalized/<workspace>.yaml) - the consumer of
policies.yaml's validation_policy (CLAUDE.md Sec5.8 / Sec8).

AWS-only (CLAUDE.md Sec8 milestone 35's Azure support does not extend to
this script yet).

Unlike every other resolver/*.py script, this runs AFTER a real
`terraform apply`, against live state, not before one against local YAML.
Prerequisite: the shared root (infrastructure/aws/workspace/) must already
be `terraform init`'d with this workspace's backend-config - same standing
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
  SKIPPED         - the check exists and works, but wasn't given what it
                    needs this run (currently: governance.unity_catalog.
                    catalog, which needs a workspace-scoped --workspace-
                    profile, separate from the account-console --profile
                    used everywhere else, since `databricks catalogs get`
                    is a workspace-level API).

Exit code is 0 unless validation.blocking is true AND at least one check
is FAIL (NOT_IMPLEMENTED/N/A/SKIPPED never trigger a non-zero exit) -
this is what a future CI pipeline would gate on.
"""

from pathlib import Path
from datetime import datetime, timezone
import argparse
import json
import subprocess

from loader import load_yaml
from inventory import resolve_databricks_account_id, resolve_metastore_id

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE_ROOT = ROOT / "infrastructure" / "aws" / "workspace"

PASS = "PASS"
FAIL = "FAIL"
NOT_APPLICABLE = "N/A"
NOT_IMPLEMENTED = "NOT_IMPLEMENTED"
SKIPPED = "SKIPPED"


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
            "'terraform output' failed in infrastructure/aws/workspace/ - "
            "has this workspace's backend been initialized? Run: terraform "
            "init -backend-config=backend.tfbackend "
            "-backend-config=../../deployments/aws/<env>/<name>/backend.tfbackend "
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
    databricks_account_id: str,
    profile: str,
    workspace_profile: str | None = None,
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
            results.append(
                check_catalog_contents(
                    catalog_name=normalized["workspace"]["name"],
                    expected_bucket_name=expected_bucket_name(normalized),
                    workspace_profile=workspace_profile,
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
        region = normalized["cloud"]["region"]

        expected_metastore_id = resolve_metastore_id(
            databricks_account_id,
            region,
            deployment,
            inventory,
            normalized["governance"].get("existing_metastore_id"),
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
                    f"actual={actual_metastore_id!r}",
                )
            )

        results.append(
            check_catalog_contents(
                catalog_name=normalized["workspace"]["name"],
                expected_bucket_name=expected_bucket_name(normalized),
                workspace_profile=workspace_profile,
            )
        )

    results.extend(_not_implemented_checks())

    return results


def expected_bucket_name(normalized: dict) -> str:
    """
    Recompute the Unity Catalog S3 bucket name the same way
    modules/unity-catalog-data/locals.tf does
    (`${workspace_name}-${aws_account_id}-${region}-uc`) - kept in sync by
    convention/comment on both sides rather than a shared output, since
    Terraform and Python can't literally share a function. If that naming
    convention ever changes, update both.
    """

    return (
        f"{normalized['workspace']['name']}-{normalized['cloud']['account']}-"
        f"{normalized['cloud']['region']}-uc"
    )


def check_catalog_contents(
    catalog_name: str,
    expected_bucket_name: str,
    workspace_profile: str | None,
) -> CheckResult:
    """
    Verifies the catalog's live isolation_mode and storage_root - needs a
    workspace-scoped Databricks profile (`databricks auth login --host
    <workspace_url>`), since `databricks catalogs get` is a workspace-level
    API, unlike every other check here which uses the account-console
    profile. Reports SKIPPED (not FAIL) when no such profile is given -
    the check exists and works, it just wasn't run this time.
    """

    if not workspace_profile:
        return CheckResult(
            "governance.unity_catalog.catalog",
            SKIPPED,
            "No --workspace-profile given. Run `databricks auth login "
            "--host <workspace_url>` once, then pass the resulting "
            "profile name here to verify live catalog contents/isolation.",
        )

    catalog, error = run_databricks(
        ["catalogs", "get", catalog_name], workspace_profile
    )

    if catalog is None:
        return CheckResult(
            "governance.unity_catalog.catalog",
            FAIL,
            f"Could not fetch catalog: {error}",
        )

    isolation_mode = catalog.get("isolation_mode")
    storage_root = catalog.get("storage_root", "") or ""

    if isolation_mode != "ISOLATED":
        return CheckResult(
            "governance.unity_catalog.catalog",
            FAIL,
            f"isolation_mode={isolation_mode!r} (expected 'ISOLATED')",
        )

    if not storage_root.startswith(f"s3://{expected_bucket_name}"):
        return CheckResult(
            "governance.unity_catalog.catalog",
            FAIL,
            f"storage_root={storage_root!r} does not point at the expected "
            f"bucket {expected_bucket_name!r}",
        )

    return CheckResult(
        "governance.unity_catalog.catalog",
        PASS,
        f"isolation_mode=ISOLATED, storage_root={storage_root!r}",
    )


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
            "against what the resolver resolved for it. AWS-only. Run "
            "this after terraform apply, with infrastructure/aws/workspace/ "
            "already terraform init'd against this workspace's "
            "backend-config."
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
        "--workspace-profile",
        help="Optional workspace-scoped Databricks CLI profile "
        "(`databricks auth login --host <workspace_url>`), separate from "
        "--profile. Enables the governance.unity_catalog.catalog check "
        "(live catalog isolation/storage_root); omitted, that check "
        "reports SKIPPED rather than running.",
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
        # AWS-only script - "aws" is hardcoded, not auto-detected the way
        # generate_tfvars.py/generate_backend_config.py do via
        # loader.resolve_normalized_path(), since there's nothing to
        # disambiguate here.
        else ROOT / "normalized" / "aws" / f"{args.workspace}.yaml"
    )

    normalized = load_yaml(normalized_path)
    environment = normalized["workspace"]["environment"]

    deployment_path = (
        Path(args.deployment)
        if args.deployment
        else ROOT
        / "infrastructure"
        / "deployments"
        / "aws"
        / environment
        / args.workspace
        / "deployment.yaml"
    )

    deployment = load_yaml(deployment_path)
    inventory = load_yaml(ROOT / "platform" / "inventory" / "aws.yaml")

    databricks_account_id = resolve_databricks_account_id(
        normalized["cloud"]["account"],
        inventory,
        normalized["cloud"].get("databricks_account_id"),
        deployment.get("databricks", {}).get("account_id"),
    )

    results = run_checks(
        normalized,
        deployment,
        inventory,
        databricks_account_id,
        args.profile,
        args.workspace_profile,
    )

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
