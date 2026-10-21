"""
Azure analog of validate_deployment.py's checks (CLAUDE.md §8 milestone
43), dispatched from validate_deployment.py's main() when the workspace's
normalized config is under normalized/azure/. Kept in its own module for
the same reason as generate_tfvars_azure.py: parallel cloud-specific code,
not interleaved branches.

Same check names and statuses (PASS/FAIL/N/A/NOT_IMPLEMENTED/SKIPPED) and
the same blocking/evidence handling as the AWS harness, so a CI gate reads
both the same way. What differs:

- Auth: no --profile/--workspace-profile. Every call goes through the
  active `az login` session - `az` for ARM state, and the databricks CLI
  with DATABRICKS_AUTH_TYPE=azure-cli against the workspace URL, the same
  auth the Azure root's own databricks provider uses. So the catalog
  check always runs (never SKIPPED), unlike AWS.
- More of the posture is checkable, because more of it is built on
  Azure: brought-key identity, the Unity Catalog storage account's own
  key (encryption.application_data), the compliance security profile,
  and centralized audit logging (the per-workspace diagnostic setting
  from milestone 40). logging.centralized is a real PASS/FAIL here, not
  NOT_IMPLEMENTED: if the profile requires it and no Log Analytics
  destination is configured for this subscription, that's reported as a
  FAIL, since the mechanism exists and simply isn't switched on.
- Prerequisite, same as AWS: infrastructure/azure/workspace/ must already
  be `terraform init`'d against this workspace's backend-config. Unlike
  AWS, this also verifies the outputs belong to this workspace (via the
  rg-<name> resource group naming convention) instead of trusting it.
"""

from pathlib import Path
import json
import os
import shutil
import subprocess

from generate_tfvars_azure import resolve_azure_account_inventory
from validate_deployment import (
    FAIL,
    NOT_APPLICABLE,
    NOT_IMPLEMENTED,
    PASS,
    CheckResult,
    get_terraform_outputs,
)

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE_ROOT = ROOT / "infrastructure" / "azure" / "workspace"

KEY_VAULT_SOURCE = "microsoft.keyvault"


def run_az(args: list[str]) -> tuple[dict | list | None, str | None]:
    """Run an az CLI command. Returns (parsed_json, None) or (None, error) -
    never raises, same contract as validate_deployment.run_databricks()."""

    az = shutil.which("az")

    if az is None:
        return None, "'az' CLI not found on PATH."

    result = subprocess.run([az] + args + ["-o", "json"], capture_output=True, text=True, check=False)

    if result.returncode != 0:
        return None, result.stderr.strip() or result.stdout.strip()

    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, f"Could not parse az CLI output: {result.stdout!r}"


def run_databricks_workspace(args: list[str], workspace_url: str) -> tuple[dict | None, str | None]:
    """Run a workspace-level databricks CLI command against workspace_url,
    authenticated through the active az session (no CLI profile)."""

    databricks = shutil.which("databricks")

    if databricks is None:
        return None, "'databricks' CLI not found on PATH."

    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("DATABRICKS_")
    }
    env["DATABRICKS_HOST"] = workspace_url
    env["DATABRICKS_AUTH_TYPE"] = "azure-cli"

    result = subprocess.run(
        [databricks] + args + ["-o", "json"], capture_output=True, text=True, check=False, env=env
    )

    if result.returncode != 0:
        return None, result.stderr.strip() or result.stdout.strip()

    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, f"Could not parse databricks CLI output: {result.stdout!r}"


def _get(data: dict | None, *path, default=None):
    """Nested lookup that tolerates missing levels and ARM's inconsistent
    key casing (e.g. keyVaultUri vs KeyVaultUri)."""

    current = data

    for key in path:
        if not isinstance(current, dict):
            return default

        match = next((k for k in current if k.lower() == key.lower()), None)

        if match is None:
            return default

        current = current[match]

    return current


def _key_vault_and_name(arm_key_id: str) -> tuple[str, str]:
    """(vault name, key name) from .../vaults/<vault>/keys/<key>."""

    parts = arm_key_id.split("/")

    return parts[8].lower(), parts[10].lower()


def _check_brought_key(
    label: str, arm_key_id: str | None, vault_uri: str | None, key_name: str | None
) -> str | None:
    """None if no key was brought or the live key matches it; otherwise a
    mismatch message."""

    if not arm_key_id:
        return None

    expected_vault, expected_key = _key_vault_and_name(arm_key_id)
    actual_vault = (vault_uri or "").lower().removeprefix("https://").split(".")[0]

    if actual_vault != expected_vault or (key_name or "").lower() != expected_key:
        return (
            f"{label} uses vault={actual_vault!r} key={key_name!r}, but the "
            f"request brought vault={expected_vault!r} key={expected_key!r}"
        )

    return None


def _not_deployed(normalized: dict, reason: str) -> list[CheckResult]:
    """Every check FAILs (or is N/A) when there's no live workspace -
    mirrors the AWS harness's short-circuit."""

    results = [
        CheckResult("workspace.exists", FAIL, reason),
        CheckResult("network.required", FAIL, "workspace not deployed"),
    ]

    for name, setting in (
        ("encryption.required", "workspace"),
        ("encryption.application_data", "application_data"),
    ):
        if normalized["encryption"][setting] == "customer_managed":
            results.append(CheckResult(name, FAIL, "workspace not deployed"))
        else:
            results.append(CheckResult(name, NOT_APPLICABLE, f"encryption.{setting} is platform_managed"))

    if normalized["governance"]["unity_catalog"]:
        results.append(CheckResult("governance.unity_catalog", FAIL, "workspace not deployed"))
        results.append(CheckResult("governance.unity_catalog.catalog", FAIL, "workspace not deployed"))

    if normalized["governance"].get("compliance_standards"):
        results.append(CheckResult("governance.compliance_profile", FAIL, "workspace not deployed"))

    results.append(_identity_check())

    if normalized["logging"]["centralized"]:
        results.append(CheckResult("logging.centralized", FAIL, "workspace not deployed"))
    else:
        results.append(CheckResult("logging.centralized", NOT_APPLICABLE, "logging.centralized is false"))

    return results


def _identity_check() -> CheckResult:
    return CheckResult(
        "identity.required",
        NOT_IMPLEMENTED,
        "no SCIM/user/group provisioning exists anywhere in this pipeline yet",
    )


def check_network(normalized: dict, deployment: dict, workspace: dict) -> CheckResult:
    vnet_id = _get(workspace, "properties", "parameters", "customVirtualNetworkId", "value")
    no_public_ip = _get(workspace, "properties", "parameters", "enableNoPublicIp", "value")

    detail = f"customVirtualNetworkId={vnet_id!r}, enableNoPublicIp={no_public_ip!r}"

    if not vnet_id or no_public_ip is not True:
        return CheckResult("network.required", FAIL, detail + " (expected VNet injection with no public IP)")

    if normalized["network"]["strategy"] == "custom":
        expected = deployment.get("network", {}).get("existing_vpc_id") or normalized["network"].get(
            "existing_vpc_id"
        )

        if (expected or "").lower() != vnet_id.lower():
            return CheckResult("network.required", FAIL, detail + f" (expected the client VNet {expected!r})")

    return CheckResult("network.required", PASS, detail)


def check_workspace_encryption(normalized: dict, workspace: dict) -> CheckResult:
    encryption = normalized["encryption"]

    if encryption["workspace"] != "customer_managed":
        return CheckResult(
            "encryption.required",
            NOT_APPLICABLE,
            "encryption.workspace is platform_managed - Microsoft-managed keys",
        )

    entities = _get(workspace, "properties", "encryption", "entities") or {}
    managed_services = _get(entities, "managedServices") or {}
    managed_disk = _get(entities, "managedDisk") or {}
    dbfs = _get(workspace, "properties", "parameters", "encryption", "value") or {}

    sources = {
        "managedServices": _get(managed_services, "keySource"),
        "managedDisk": _get(managed_disk, "keySource"),
        "dbfsRoot": _get(dbfs, "keySource"),
    }

    detail = ", ".join(f"{name}={source!r}" for name, source in sources.items())

    if any((source or "").lower() != KEY_VAULT_SOURCE for source in sources.values()):
        return CheckResult("encryption.required", FAIL, detail + " (expected Microsoft.Keyvault for all three)")

    mismatches = [
        message
        for message in (
            _check_brought_key(
                "managedServices",
                encryption.get("existing_managed_services_key_id"),
                _get(managed_services, "keyVaultProperties", "keyVaultUri"),
                _get(managed_services, "keyVaultProperties", "keyName"),
            ),
            _check_brought_key(
                "managedDisk",
                encryption.get("existing_workspace_storage_key_id"),
                _get(managed_disk, "keyVaultProperties", "keyVaultUri"),
                _get(managed_disk, "keyVaultProperties", "keyName"),
            ),
        )
        if message
    ]

    if mismatches:
        return CheckResult("encryption.required", FAIL, "; ".join(mismatches))

    return CheckResult("encryption.required", PASS, detail)


def check_application_data_encryption(normalized: dict, storage_account_name: str | None) -> CheckResult:
    encryption = normalized["encryption"]

    if encryption["application_data"] != "customer_managed":
        return CheckResult(
            "encryption.application_data",
            NOT_APPLICABLE,
            "encryption.application_data is platform_managed - Microsoft-managed keys",
        )

    if not storage_account_name:
        return CheckResult(
            "encryption.application_data",
            FAIL,
            "no unity_catalog_storage_account_name in terraform output (Unity Catalog off?)",
        )

    account, error = run_az(["storage", "account", "show", "-n", storage_account_name])

    if account is None:
        return CheckResult("encryption.application_data", FAIL, f"Could not fetch storage account: {error}")

    source = _get(account, "encryption", "keySource")
    vault_uri = _get(account, "encryption", "keyVaultProperties", "keyVaultUri")
    key_name = _get(account, "encryption", "keyVaultProperties", "keyName")

    detail = f"{storage_account_name}: keySource={source!r}, keyName={key_name!r}"

    if (source or "").lower() != KEY_VAULT_SOURCE:
        return CheckResult("encryption.application_data", FAIL, detail + " (expected Microsoft.Keyvault)")

    mismatch = _check_brought_key(
        "UC storage account", encryption.get("existing_application_data_key_id"), vault_uri, key_name
    )

    if mismatch:
        return CheckResult("encryption.application_data", FAIL, mismatch)

    return CheckResult("encryption.application_data", PASS, detail)


def check_unity_catalog(
    normalized: dict, inventory: dict, workspace_url: str, storage_account_name: str | None
) -> list[CheckResult]:
    results = []

    current, error = run_databricks_workspace(["metastores", "current"], workspace_url)

    if current is None:
        results.append(CheckResult("governance.unity_catalog", FAIL, f"Could not fetch current metastore: {error}"))
    else:
        actual = current.get("metastore_id")

        # Azure auto-assigns the region's metastore; only an explicit
        # override (request > inventory region entry) pins a specific one.
        region_inventory = (
            resolve_azure_account_inventory(normalized["cloud"]["account"], inventory)
            .get("regions", {})
            .get(normalized["cloud"]["region"], {})
        )
        expected = normalized["governance"].get("existing_metastore_id") or region_inventory.get("metastore_id")

        if not actual:
            status, detail = FAIL, "no metastore assigned"
        elif expected and actual != expected:
            status, detail = FAIL, f"expected={expected!r}, actual={actual!r}"
        else:
            status, detail = PASS, f"metastore_id={actual!r}" + ("" if expected else " (auto-assigned)")

        results.append(CheckResult("governance.unity_catalog", status, detail))

    catalog_name = normalized["workspace"]["name"]
    catalog, error = run_databricks_workspace(["catalogs", "get", catalog_name], workspace_url)

    if catalog is None:
        results.append(CheckResult("governance.unity_catalog.catalog", FAIL, f"Could not fetch catalog: {error}"))
        return results

    isolation_mode = catalog.get("isolation_mode")
    storage_root = catalog.get("storage_root") or ""
    expected_root = f"abfss://uc-root@{storage_account_name}.dfs.core.windows.net"

    if isolation_mode != "ISOLATED":
        status, detail = FAIL, f"isolation_mode={isolation_mode!r} (expected 'ISOLATED')"
    elif not storage_root.startswith(expected_root):
        status, detail = FAIL, f"storage_root={storage_root!r} (expected {expected_root!r})"
    else:
        status, detail = PASS, f"isolation_mode=ISOLATED, storage_root={storage_root!r}"

    results.append(CheckResult("governance.unity_catalog.catalog", status, detail))

    return results


def check_compliance_profile(normalized: dict, workspace: dict) -> CheckResult | None:
    standards = normalized["governance"].get("compliance_standards") or []

    if not standards:
        return None

    profile = _get(workspace, "properties", "enhancedSecurityCompliance", "complianceSecurityProfile") or {}
    enabled = _get(profile, "value")
    live_standards = sorted(s.upper() for s in (_get(profile, "complianceStandards") or []))

    detail = f"complianceSecurityProfile={enabled!r}, standards={live_standards}"

    if (enabled or "").lower() != "enabled" or sorted(s.upper() for s in standards) != live_standards:
        return CheckResult(
            "governance.compliance_profile", FAIL, detail + f" (expected Enabled with {sorted(standards)})"
        )

    return CheckResult("governance.compliance_profile", PASS, detail)


def check_centralized_logging(
    normalized: dict, deployment: dict, inventory: dict, workspace_resource_id: str
) -> CheckResult:
    if not normalized["logging"]["centralized"]:
        return CheckResult("logging.centralized", NOT_APPLICABLE, "logging.centralized is false")

    # Same deployment > inventory precedence as generate_tfvars_azure.py.
    expected = deployment.get("log_analytics_workspace_id") or resolve_azure_account_inventory(
        normalized["cloud"]["account"], inventory
    ).get("log_analytics_workspace_id")

    if not expected:
        return CheckResult(
            "logging.centralized",
            FAIL,
            "the profile requires centralized logging, but no "
            "log_analytics_workspace_id is configured for this subscription - "
            "apply infrastructure/azure/account/ with enable_audit_log_delivery "
            "and record its output in platform/inventory/azure.yaml",
        )

    settings, error = run_az(["monitor", "diagnostic-settings", "list", "--resource", workspace_resource_id])

    if settings is None:
        return CheckResult("logging.centralized", FAIL, f"Could not list diagnostic settings: {error}")

    if isinstance(settings, dict):
        settings = settings.get("value", [])

    matching = [s for s in settings if (_get(s, "workspaceId") or "").lower() == expected.lower()]

    if not matching:
        return CheckResult(
            "logging.centralized", FAIL, f"no diagnostic setting sends to {expected!r}"
        )

    enabled = sorted(log.get("category") for log in matching[0].get("logs", []) if log.get("enabled"))

    return CheckResult(
        "logging.centralized",
        PASS if enabled else FAIL,
        f"{matching[0].get('name')!r} -> Log Analytics, categories={enabled}",
    )


def run_checks_azure(normalized: dict, deployment: dict, inventory: dict) -> list[CheckResult]:
    outputs = get_terraform_outputs(WORKSPACE_ROOT)
    name = normalized["workspace"]["name"]

    # The shared root reports whichever workspace was last init'd - refuse
    # to validate a different one's live state under this name.
    actual_rg = outputs.get("resource_group_name")

    if actual_rg and actual_rg != f"rg-{name}":
        raise RuntimeError(
            f"infrastructure/azure/workspace/ is initialized against a "
            f"different workspace (resource group {actual_rg!r}, expected "
            f"'rg-{name}') - re-run terraform init with this workspace's "
            f"backend-config first."
        )

    workspace_resource_id = outputs.get("workspace_resource_id")

    if not workspace_resource_id:
        return _not_deployed(
            normalized,
            "No workspace_resource_id in terraform output - this workspace "
            "has not been applied (or was applied before this output existed; "
            "a plain terraform apply adds it).",
        )

    workspace, error = run_az(["resource", "show", "--ids", workspace_resource_id])

    if workspace is None:
        return _not_deployed(normalized, f"Could not fetch workspace: {error}")

    state = _get(workspace, "properties", "provisioningState")

    results = [
        CheckResult("workspace.exists", PASS if state == "Succeeded" else FAIL, f"provisioningState={state!r}"),
        check_network(normalized, deployment, workspace),
        check_workspace_encryption(normalized, workspace),
        check_application_data_encryption(normalized, outputs.get("unity_catalog_storage_account_name")),
    ]

    if normalized["governance"]["unity_catalog"]:
        results.extend(
            check_unity_catalog(
                normalized,
                inventory,
                outputs.get("workspace_url"),
                outputs.get("unity_catalog_storage_account_name"),
            )
        )

    compliance = check_compliance_profile(normalized, workspace)

    if compliance is not None:
        results.append(compliance)

    results.append(_identity_check())
    results.append(check_centralized_logging(normalized, deployment, inventory, workspace_resource_id))

    return results
