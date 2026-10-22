"""
CI-agnostic pipeline driver (CLAUDE.md §8 milestone 48). Every real step
lives here, so GitLab (AWS) and Jenkins (Azure) stay thin wrappers that
only handle triggers, identity, the manual approval gate and artifacts.
Every subcommand also runs locally.

  changed   Which workspace requests a change touches (vs. a base ref).
            Deleted requests are reported and fail the run - teardown stays
            a deliberate operator action (resolver/teardown.py).
  prepare   LOCAL, by whoever authors a request: resolve + generate every
            derived file (normalized config, tfvars, backend key, the
            subnet pin, a stub deployment.yaml) so they get committed with
            the request and reviewed in the merge request.
  verify    CI: regenerate from the committed request and fail if anything
            differs from what's committed - the reviewed files are exactly
            what gets planned.
  plan      CI: two-file terraform init for this workspace, then
            terraform plan -out=<file>, plus a readable copy.
  apply     CI, after manual approval: apply exactly that saved plan, then
            run resolver/validate_deployment.py (blocking per the
            workspace's validation policy).

Every subcommand that takes a workspace takes the request file path, which
already carries the cloud, environment and name - so there's no
name-collision ambiguity across clouds.

Identity is the CI job's concern: by the time this runs, the job's
environment must already be authenticated (see ci/README.md). plan and
apply refuse to run if the live cloud account/subscription doesn't match
the request's resolved one.
"""

from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

sys.path.insert(0, str(ROOT / "resolver"))

from loader import load_yaml  # noqa: E402


class PipelineError(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"[pipeline] {message}", flush=True)


def run(command: list[str], cwd: Path = ROOT, check: bool = True, env: dict | None = None) -> subprocess.CompletedProcess:
    executable = shutil.which(command[0])

    if executable is None:
        raise PipelineError(f"'{command[0]}' not found on PATH.")

    result = subprocess.run(
        [executable] + command[1:], cwd=cwd, capture_output=True, text=True, env=env
    )

    if check and result.returncode != 0:
        raise PipelineError(
            f"`{' '.join(command[:4])} ...` failed (exit {result.returncode}):\n"
            f"{(result.stdout + result.stderr).strip()[-4000:]}"
        )

    return result


class Workspace:
    """Everything about one workspace, derived from its request file."""

    def __init__(self, request_path: str):
        self.request_path = Path(request_path)

        if not (ROOT / self.request_path).exists():
            raise PipelineError(f"No request file at {self.request_path}.")

        request = load_yaml(ROOT / self.request_path)

        self.name = request["workspace"]["name"]
        self.environment = request["workspace"]["environment"]
        self.provider = request["cloud"]["provider"]

        expected_parent = Path("workspace-requests") / self.provider / self.environment

        if self.request_path.parent.as_posix() != expected_parent.as_posix():
            raise PipelineError(
                f"{self.request_path} declares {self.provider}/{self.environment}, "
                f"so it belongs under {expected_parent}/."
            )

        self.deployment_dir = ROOT / "infrastructure" / "deployments" / self.provider / self.environment / self.name
        self.normalized_path = ROOT / "normalized" / self.provider / f"{self.name}.yaml"
        self.root = ROOT / "infrastructure" / self.provider / "workspace"

    @property
    def var_file(self) -> str:
        return f"../../deployments/{self.provider}/{self.environment}/{self.name}/terraform.tfvars.json"

    @property
    def generated_paths(self) -> list[Path]:
        return [self.normalized_path, self.deployment_dir]


# ---------------------------------------------------------------------------
# changed
# ---------------------------------------------------------------------------


def cmd_changed(args) -> int:
    pattern = f"workspace-requests/{args.cloud}/"

    result = run(["git", "diff", "--name-status", "--no-renames", args.base, args.head, "--", pattern])

    changed, deleted = [], []

    for line in result.stdout.splitlines():
        status, path = line.split("\t", 1)

        if not path.endswith(".yaml") or Path(path).name == "TEMPLATE.yaml":
            continue

        (deleted if status == "D" else changed).append(path)

    report = {"cloud": args.cloud, "base": args.base, "changed": sorted(changed), "deleted": sorted(deleted)}

    if args.output:
        Path(args.output).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(report, indent=2))

    if deleted:
        log(
            f"{len(deleted)} request(s) deleted: {', '.join(deleted)}. CI doesn't tear "
            f"workspaces down - run resolver/teardown.py deliberately, then re-run."
        )
        return 3

    return 0


# ---------------------------------------------------------------------------
# prepare / verify
# ---------------------------------------------------------------------------


def generate(ws: Workspace, account: str) -> None:
    log(f"resolving {ws.request_path} for account {account}")
    run([sys.executable, "resolver/main.py", "--request", ws.request_path.as_posix(), "--account", account])

    deployment = ws.deployment_dir / "deployment.yaml"

    if not deployment.exists():
        deployment.parent.mkdir(parents=True, exist_ok=True)
        deployment.write_text("api_version: v1\n", encoding="utf-8")
        log(f"created stub {deployment.relative_to(ROOT)}")

    for script in ("generate_tfvars.py", "generate_backend_config.py"):
        run([sys.executable, f"resolver/{script}", "--workspace", ws.name, "--provider", ws.provider])


def cmd_prepare(args) -> int:
    ws = Workspace(args.request)
    generate(ws, args.account)

    log("generated - commit these with the request:")
    for path in ws.generated_paths:
        print(f"  {path.relative_to(ROOT).as_posix()}")

    return 0


def cmd_verify(args) -> int:
    ws = Workspace(args.request)

    if not ws.normalized_path.exists():
        raise PipelineError(
            f"{ws.normalized_path.relative_to(ROOT).as_posix()} isn't committed. Run "
            f"`python ci/pipeline.py prepare --request {ws.request_path.as_posix()} "
            f"--account <id>` and commit the result with the request."
        )

    account = load_yaml(ws.normalized_path)["cloud"]["account"]
    generate(ws, account)

    paths = [p.relative_to(ROOT).as_posix() for p in ws.generated_paths]
    status = run(["git", "status", "--porcelain", "--untracked-files=all", "--"] + paths).stdout.strip()

    if status:
        diff = run(["git", "diff", "--"] + paths, check=False).stdout
        print(status)
        print(diff[-6000:])
        raise PipelineError(
            "The committed generated files don't match the request. Run "
            f"`python ci/pipeline.py prepare --request {ws.request_path.as_posix()} "
            f"--account {account}` locally and commit the result."
        )

    log(f"{ws.name}: committed generated files match the request")
    return 0


# ---------------------------------------------------------------------------
# plan / apply
# ---------------------------------------------------------------------------


def check_cloud_identity(ws: Workspace) -> None:
    """Refuse to touch a cloud account other than the one the request
    resolved to - the CI job's credentials decide where Terraform writes."""

    expected = str(load_yaml(ws.normalized_path)["cloud"]["account"])

    if ws.provider == "aws":
        actual = json.loads(run(["aws", "sts", "get-caller-identity", "--output", "json"]).stdout)["Account"]
    else:
        actual = json.loads(run(["az", "account", "show", "-o", "json"]).stdout)["id"]

    if actual.lower() != expected.lower():
        raise PipelineError(
            f"The job is authenticated to {ws.provider} account {actual}, but "
            f"{ws.name} resolves to {expected} - refusing to continue."
        )

    log(f"{ws.provider} identity matches {expected}")


def terraform_init(ws: Workspace) -> None:
    log(f"terraform init against {ws.provider}/{ws.environment}/{ws.name}'s backend")
    run(
        [
            "terraform", "init", "-input=false", "-reconfigure",
            "-backend-config=backend.tfbackend",
            f"-backend-config=../../deployments/{ws.provider}/{ws.environment}/{ws.name}/backend.tfbackend",
        ],
        cwd=ws.root,
    )


def cmd_plan(args) -> int:
    ws = Workspace(args.request)
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    plan_file = out_dir / f"{ws.provider}-{ws.name}.tfplan"

    check_cloud_identity(ws)
    terraform_init(ws)

    log("terraform plan")
    result = run(
        [
            "terraform", "plan", "-input=false", "-no-color", "-detailed-exitcode",
            f"-var-file={ws.var_file}", f"-out={plan_file}",
        ],
        cwd=ws.root,
        check=False,
    )

    if result.returncode not in (0, 2):
        raise PipelineError(f"terraform plan failed:\n{(result.stdout + result.stderr)[-4000:]}")

    readable = run(["terraform", "show", "-no-color", str(plan_file)], cwd=ws.root).stdout
    (out_dir / f"{ws.provider}-{ws.name}.plan.txt").write_text(readable, encoding="utf-8")

    summary = next((line for line in result.stdout.splitlines() if line.startswith(("Plan:", "No changes"))), "")
    log(f"{ws.name}: {summary or 'see plan output'} -> {plan_file.name}")

    return 0


def cmd_apply(args) -> int:
    ws = Workspace(args.request)
    plan_file = Path(args.plan_dir).resolve() / f"{ws.provider}-{ws.name}.tfplan"

    if not plan_file.exists():
        raise PipelineError(f"No saved plan at {plan_file} - the plan stage's artifact is missing.")

    check_cloud_identity(ws)
    terraform_init(ws)

    # A saved plan only applies against the exact state it was made from;
    # Terraform itself rejects it as stale if anything changed since the
    # plan was approved.
    log(f"terraform apply {plan_file.name}")
    run(["terraform", "apply", "-input=false", "-no-color", str(plan_file)], cwd=ws.root)

    log("validating the deployed workspace")
    command = [sys.executable, "resolver/validate_deployment.py", "--workspace", ws.name, "--provider", ws.provider]

    if ws.provider == "aws" and args.databricks_profile:
        command += ["--profile", args.databricks_profile]

    env = dict(os.environ)

    if ws.provider == "aws" and env.get("DATABRICKS_AUTH_TYPE"):
        # The validator's AWS checks are account-level API calls.
        tfvars = json.loads((ws.deployment_dir / "terraform.tfvars.json").read_text(encoding="utf-8"))
        env.setdefault("DATABRICKS_HOST", "https://accounts.cloud.databricks.com")
        env["DATABRICKS_ACCOUNT_ID"] = tfvars["databricks_account_id"]

    validation = subprocess.run(command, cwd=ROOT, env=env)

    return validation.returncode


# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="CI-agnostic workspace pipeline driver.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("changed", help="List workspace requests changed between two refs.")
    p.add_argument("--cloud", required=True, choices=["aws", "azure"])
    p.add_argument("--base", required=True, help="Base ref/SHA (merge-request target, or the previous commit on the default branch).")
    p.add_argument("--head", default="HEAD")
    p.add_argument("--output", help="Also write the JSON report here.")
    p.set_defaults(func=cmd_changed)

    p = sub.add_parser("prepare", help="LOCAL: generate every derived file for a request, to commit with it.")
    p.add_argument("--request", required=True)
    p.add_argument("--account", required=True, help="AWS account id / Azure subscription id the workspace deploys into.")
    p.set_defaults(func=cmd_prepare)

    p = sub.add_parser("verify", help="CI: fail if committed generated files don't match the request.")
    p.add_argument("--request", required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("plan", help="CI: terraform plan -out for one workspace.")
    p.add_argument("--request", required=True)
    p.add_argument("--out-dir", required=True)
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("apply", help="CI: apply the saved plan, then validate.")
    p.add_argument("--request", required=True)
    p.add_argument("--plan-dir", required=True)
    p.add_argument("--databricks-profile", help="AWS, local runs only; CI uses DATABRICKS_* environment variables.")
    p.set_defaults(func=cmd_apply)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PipelineError, ValueError, FileNotFoundError) as error:
        print(f"\n[pipeline] FAILED: {error}\n", file=sys.stderr)
        raise SystemExit(1)
