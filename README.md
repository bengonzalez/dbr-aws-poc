# Databricks Workspace Factory (AWS)

A Terraform + Python pipeline that turns a small, requester-supplied YAML
file into a fully provisioned Databricks workspace on AWS — networking,
IAM, encryption, storage, and workspace registration — without the
requester having to specify any AWS-level details themselves.

> For the detailed architecture, design decisions, and project history, see
> [`CLAUDE.md`](CLAUDE.md). This file is the practical "how do I run this"
> guide.

## Directory structure

```
.
├── workspace-requests/              # Requester input: minimal YAML per workspace
│   ├── dev/<name>.yaml
│   ├── stage/<name>.yaml
│   └── live/<name>.yaml
│
├── normalized/                      # Resolver output - the fully resolved
│   └── <name>.yaml                  # "contract" for one workspace (generated)
│
├── resolver/                        # Python pipeline (request → Terraform inputs)
│   ├── main.py                      # workspace-request → normalized/<name>.yaml
│   ├── resolver.py                  # core resolution logic (profiles + policies)
│   ├── loader.py / validator.py     # YAML loading + JSON Schema validation
│   ├── generate_tfvars.py           # normalized + deployment.yaml → terraform.tfvars.json
│   └── generate_backend_config.py   # normalized → backend.tfbackend (both the per-workspace
│                                     #   key file and the shared bucket/region/use_lockfile file)
│
├── schemas/                         # JSON Schemas: workspace-request, normalized-config, profile
├── profiles/{dev,stage,live}.yaml   # Per-environment platform defaults
├── policies/                        # Platform-wide rules (network/security/data/governance/validation)
├── platform/inventory/aws.yaml      # Known existing AWS infra per account/region
│
├── infrastructure/
│   ├── workspace/                   # THE Terraform root - shared by every workspace
│   │   ├── providers.tf             # AWS + Databricks (account-console) providers
│   │   ├── versions.tf              # Provider/Terraform version pins + partial S3 backend
│   │   ├── variables.tf             # Full input contract (see modules/workspace-deployment)
│   │   ├── main.tf                  # Single `module "deployment"` call
│   │   ├── outputs.tf               # Forwards module outputs
│   │   │
│   │   ├── backend.tfbackend        # GENERATED (and idempotent - same content every run):
│   │   │                            #   bucket/region/use_lockfile, identical for every workspace
│   │   └── local.auto.tfvars        # Gitignored: your own Databricks CLI profile name
│   │
│   ├── deployments/                 # Per-workspace deployment files, grouped by workspace -
│   │   └── <env>/<name>/            #   kept separate from workspace-requests/ (requester-facing
│   │       ├── deployment.yaml      #   input) and infrastructure/workspace/ (shared TF root)
│   │       ├── terraform.tfvars.json#   deployment.yaml: committed, hand-maintained (existing
│   │       └── backend.tfbackend    #   resource ids, concrete subnet CIDRs, overrides).
│   │                                #   terraform.tfvars.json / backend.tfbackend (the per-
│   │                                #   workspace `key` line only): GENERATED - never hand-edit.
│   │
│   ├── nonprod/poc/                 # Frozen original proof of concept - reference only
│   ├── platform/                    # Reserved, empty (no shared/cross-workspace state exists)
│   └── application/                 # Reserved, empty (no app-layer resources yet)
│
├── modules/
│   ├── workspace-deployment/        # Composed deployment logic (used by infrastructure/workspace)
│   ├── workspace-network/           # VPC/subnets/routing/security group (existing-or-create)
│   ├── workspace-endpoints/         # S3 gateway + STS (+ KMS) interface endpoints
│   ├── workspace-privatelink/       # Databricks PrivateLink (requires Enterprise tier)
│   ├── workspace-iam-role/          # Cross-account IAM role
│   ├── workspace-kms/               # Customer-managed KMS keys (+ bring-your-own-key)
│   ├── databricks-account/, databricks-workspace/, unity-catalog-*/  # Planned, empty
│   └── networking/, kms/, security/, storage/, endpoints/            # POC-era, used only by
│                                                                      #   infrastructure/nonprod/poc
│
├── requirements.txt                 # Python deps for resolver/ (PyYAML, jsonschema)
└── CLAUDE.md                        # Detailed architecture tracker and decision history
```

**There is exactly one copy of the Terraform code** (`infrastructure/workspace/`
+ `modules/`). Every workspace — `dev`, `stage`, `live`, however many there
end up being — runs through that same root. Nothing per-workspace gets
copied except the small per-workspace directory under `infrastructure/deployments/`.

## Prerequisites

- **Terraform** `>= 1.10` (native S3 state locking is required and relies
  on this)
- **Python 3.x** with `pip install -r requirements.txt`
- **AWS CLI**, configured with credentials for the target AWS account
- **Databricks CLI** (the current line, `v0.100+` — not the legacy
  pre-reset `v1.x` CLI), authenticated against the **account console**
  (not a workspace) for the target Databricks account:
  ```
  databricks auth login --host https://accounts.cloud.databricks.com --account-id <databricks_account_id>
  ```
- Access to the shared Terraform state bucket: S3 bucket `beng-tfstatefiles`
  (`us-east-1`), versioning enabled. This bucket is created and managed
  **manually** — nothing in this pipeline creates or expects to create it.

## Deploying a new workspace (manual steps)

Run these from the repository root unless noted otherwise.

1. **Write the request.** Create
   `workspace-requests/<env>/<name>.yaml` with the minimal fields
   (application, environment, owner, cost center, data classification,
   network strategy). See existing files in that directory for examples.

2. **Resolve it.**
   ```
   python resolver/main.py --request workspace-requests/<env>/<name>.yaml --account <aws_account_id>
   ```
   Produces `normalized/<name>.yaml` — the fully resolved configuration.

3. **Write the deployment file.** Create
   `infrastructure/deployments/<env>/<name>/deployment.yaml` with the
   handful of concrete values the resolver doesn't produce: existing VPC id
   / route table ids (if reusing an existing network), concrete subnet
   CIDRs, and any per-resource ownership overrides or bring-your-own-key
   settings. Copy an existing workspace's `deployment.yaml` as a starting
   template.

4. **Generate the Terraform inputs.**
   ```
   python resolver/generate_tfvars.py --workspace <name>
   python resolver/generate_backend_config.py --workspace <name>
   ```
   Produces `infrastructure/deployments/<env>/<name>/terraform.tfvars.json`
   and `.../backend.tfbackend` (just this workspace's state `key`), and
   (re)writes `infrastructure/workspace/backend.tfbackend` (the
   bucket/region/use_lockfile settings shared by every workspace).

5. **Set your Databricks CLI profile.** Either export it for the shell
   session (`export TF_VAR_databricks_profile="your-profile-name"`) or copy
   `infrastructure/workspace/local.auto.tfvars.example` to
   `local.auto.tfvars` and fill it in (gitignored, never committed).

6. **Point the shared root at this workspace's state.** From
   `infrastructure/workspace/`, pass **both** backend-config files - the
   shared one first, then this workspace's:
   ```
   terraform init \
     -backend-config=backend.tfbackend \
     -backend-config=../deployments/<env>/<name>/backend.tfbackend \
     -reconfigure -input=false
   ```

7. **Plan, review, then apply.**
   ```
   terraform plan  -var-file=../deployments/<env>/<name>/terraform.tfvars.json
   terraform apply -var-file=../deployments/<env>/<name>/terraform.tfvars.json
   ```
   Read the plan before applying. See warnings below.

## ⚠️ Warnings for manual deployments

- **Always re-run step 6 before touching any workspace, every time.**
  There is no per-directory safety net anymore — the shared root always
  operates against whichever `-backend-config` was last initialized. If
  you skip this and run `plan`/`apply` while still pointed at a different
  workspace, Terraform will propose **destroying that other workspace**
  and creating this one instead. This is the single most important rule
  in this repository.
- **Never hand-edit `terraform.tfvars.json` or either `backend.tfbackend`
  file.** All three are generated from `normalized/<name>.yaml` and
  `deployment.yaml`. Manual edits will silently drift from the source of
  truth and be overwritten the next time someone regenerates them.
- **Always read the plan before applying.** An unexpected `destroy` in the
  plan almost always means you're pointed at the wrong workspace's state
  (see the first warning), not that something is actually wrong with the
  target workspace.
- **`terraform destroy` carries the same backend risk as `apply`.** Confirm
  which `-backend-config` is active before running it.
- **`databricks_mws_credentials` can fail on the very first apply attempt**
  right after the cross-account IAM role is created, with *"Failed
  credential validation checks."* This is IAM trust-policy propagation lag,
  not a real error — a plain retry a few seconds to minutes later typically
  succeeds. See `CLAUDE.md` for details.
- **Databricks PrivateLink (`modules/workspace-privatelink`) requires an
  Enterprise-tier Databricks account.** On any other tier, set
  `overrides.privatelink_enabled: false` in the workspace's
  `deployment.yaml` — the generic AWS service endpoints still get built,
  just not PrivateLink itself.
- **Manual deployment doesn't scale past a handful of workspaces.** It's
  fine for testing and for standing up the pipeline itself, but the
  per-workspace-backend-selection discipline above depends entirely on
  human attention. Prefer the pipeline (below) for anything beyond initial
  testing.

## CI/CD pipeline (GitLab) — planned, not yet implemented

No `.gitlab-ci.yml` exists in this repository yet. This section describes
the intended shape so the manual steps above translate directly into
pipeline stages when it's built.

**Trigger**: a merge request that adds or changes a file under
`workspace-requests/**/*.yaml` or
`infrastructure/deployments/**/deployment.yaml`. Use `rules: changes` to
detect which file changed and derive `<env>`/`<name>` from its path — each
pipeline run should operate on exactly one workspace.

**Stages** (one job per stage, each consuming the previous stage's
artifacts):

1. **resolve** — run `resolver/main.py` for the changed request. Artifact:
   `normalized/<name>.yaml`.
2. **generate** — run `generate_tfvars.py` and `generate_backend_config.py`.
   Artifacts: `infrastructure/deployments/<env>/<name>/terraform.tfvars.json`,
   `.../backend.tfbackend`, and `infrastructure/workspace/backend.tfbackend`.
3. **validate** — `terraform fmt -check -recursive`, then `terraform init
   -backend-config=backend.tfbackend
   -backend-config=../deployments/<env>/<name>/backend.tfbackend
   -reconfigure -input=false` and `terraform validate`. A fresh pipeline run
   always starts with a clean checkout, so there's no "forgot to
   reconfigure" risk here the way there is for manual/local use.
4. **plan** — `terraform plan
   -var-file=../deployments/<env>/<name>/terraform.tfvars.json
   -out=plan.tfplan`. Post the plan as an MR comment (`gitlab-terraform`
   style tooling, or a simple script piping `terraform show -no-color
   plan.tfplan`) so a reviewer can read it before anything is applied.
   Artifact: `plan.tfplan`.
5. **apply** — `terraform apply plan.tfplan`. Make this job
   `when: manual` and run it in a **protected GitLab environment**
   requiring approval — never apply automatically on merge, at least until
   this pipeline has a track record.

**Known gap to resolve before this can actually run in CI**:
`infrastructure/workspace/providers.tf` currently authenticates to
Databricks via `auth_type = "databricks-cli"` + `profile`, which reads an
interactive CLI login from the runner's local config — that doesn't exist
on a CI runner and won't work unmodified. CI needs a **non-interactive**
Databricks auth method instead: a Databricks service principal using OAuth
M2M (client ID/secret), supplied via `DATABRICKS_CLIENT_ID`/
`DATABRICKS_CLIENT_SECRET` (or the equivalent provider arguments) as masked
GitLab CI/CD variables, rather than `profile`. Similarly, AWS credentials
for the runner should use GitLab's OIDC-to-AWS-IAM-role integration rather
than long-lived static access keys. Neither of these has been set up yet —
both are prerequisites for building the pipeline for real, not just for
this README.
