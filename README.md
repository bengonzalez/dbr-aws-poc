# Databricks Workspace Factory

A Terraform + Python pipeline that turns a small, requester-supplied YAML
file into a fully provisioned Databricks workspace — networking, IAM,
encryption, storage, and workspace registration — without the requester
having to specify any cloud-level details themselves.

**AWS is the mature, real-apply-tested path** — everything below is
written for it. **Azure support exists but is deliberately bounded**
(an `isolated`-equivalent strategy only, no real `terraform apply` yet) —
see `CLAUDE.md`'s §8 milestone 35 and `workspace-requests/azure/TEMPLATE.yaml`
if you're working on the Azure side; its directories mirror AWS's one-for-one
(`modules/azure/`, `infrastructure/azure/workspace/`,
`workspace-requests/azure/`, `infrastructure/deployments/azure/`) but the
step-by-step instructions below are AWS-specific.

> For the detailed architecture, design decisions, and project history, see
> [`CLAUDE.md`](CLAUDE.md). This file is the practical "how do I run this"
> guide.

## Directory structure

Every cloud-specific location is grouped under a top-level `<cloud>/`
segment (`aws`/`azure`), mirroring `databricks/terraform-databricks-sra`'s
own split. Shown below for AWS; Azure's shape is one-for-one identical
under `azure/` wherever it appears (`modules/azure/...`,
`infrastructure/azure/workspace/`, `workspace-requests/azure/<env>/`,
`infrastructure/deployments/azure/<env>/<name>/`) except where noted.

```
.
├── workspace-requests/
│   ├── aws/
│   │   ├── dev/<name>.yaml
│   │   ├── stage/<name>.yaml
│   │   ├── live/<name>.yaml
│   │   └── TEMPLATE.yaml
│   └── azure/                       # Bounded scope - see CLAUDE.md §8 milestone 35
│       ├── dev/<name>.yaml
│       └── TEMPLATE.yaml
│
├── normalized/                      # Resolver output - the fully resolved
│   ├── aws/<name>.yaml              # "contract" for one workspace (generated, cloud-
│   └── azure/<name>.yaml            #   scoped - a workspace name is conventionally
│                                     #   unique per provider, not globally)
│
├── resolver/                        # Python pipeline (request → Terraform inputs)
│   ├── main.py                      # workspace-request → normalized/<provider>/<name>.yaml
│   ├── resolver.py                  # core resolution logic (profiles + policies)
│   ├── loader.py / validator.py     # YAML loading + JSON Schema validation
│   ├── generate_tfvars.py           # normalized + deployment.yaml → terraform.tfvars.json
│   │                                 #   (AWS body; dispatches to generate_tfvars_azure.py
│   │                                 #   for Azure workspaces)
│   ├── generate_tfvars_azure.py     # Azure's tfvars generation - smaller, bounded scope
│   └── generate_backend_config.py   # normalized → backend.tfbackend (both the per-workspace
│                                     #   key file and the shared constants file, AWS or Azure
│                                     #   shaped depending on the workspace's cloud.provider)
│
├── schemas/                         # JSON Schemas: workspace-request, normalized-config, profile
├── profiles/{dev,stage,live}.yaml   # Per-environment platform defaults
├── policies/                        # Platform-wide rules (network/security/data/governance/validation)
├── platform/inventory/
│   ├── aws.yaml                     # Known existing AWS infra per account/region
│   └── azure.yaml                   # Azure's much smaller equivalent (no account-level
│                                     #   Databricks id - Unity Catalog auto-assigns per tenant)
│
├── infrastructure/
│   ├── aws/workspace/               # THE AWS Terraform root - shared by every AWS workspace
│   │   ├── providers.tf             # AWS + Databricks (account-console) providers
│   │   ├── versions.tf              # Provider/Terraform version pins + partial S3 backend
│   │   ├── variables.tf             # Full input contract (see modules/aws/workspace-deployment)
│   │   ├── main.tf                  # Single `module "deployment"` call
│   │   ├── outputs.tf               # Forwards module outputs
│   │   │
│   │   ├── backend.tfbackend        # GENERATED (and idempotent - same content every run):
│   │   │                            #   bucket/region/use_lockfile, identical for every workspace
│   │   └── local.auto.tfvars        # Gitignored: your own Databricks CLI profile name
│   │
│   ├── azure/workspace/             # THE Azure Terraform root - parallel sibling, same shape.
│   │   │                            #   No local.auto.tfvars equivalent - auth_type = "azure-cli"
│   │   │                            #   reuses whatever `az login` session is active.
│   │   └── ...                      #   (providers.tf/versions.tf/variables.tf/main.tf/outputs.tf/
│   │                                 #   backend.tfbackend, same roles as the AWS root above)
│   │
│   ├── deployments/                 # Per-workspace deployment files, grouped by workspace -
│   │   ├── aws/<env>/<name>/        #   kept separate from workspace-requests/ (requester-facing
│   │   │   ├── deployment.yaml      #   input) and infrastructure/<cloud>/workspace/ (shared TF root)
│   │   │   ├── terraform.tfvars.json#   deployment.yaml: committed, hand-maintained (existing
│   │   │   ├── backend.tfbackend    #   resource ids, overrides - subnet CIDRs now optional).
│   │   │   └── allocated-subnets.yaml# terraform.tfvars.json / backend.tfbackend / allocated-
│   │   │                            #   subnets.yaml (only created if subnets were auto-
│   │   │                            #   carved, pinned once written): GENERATED - never
│   │   │                            #   hand-edit.
│   │   └── azure/<env>/<name>/      #   same deployment.yaml/terraform.tfvars.json/backend.tfbackend
│   │                                #   shape - no allocated-subnets.yaml (no auto-allocation yet)
│   │
│   ├── nonprod/poc/                 # Frozen original proof of concept - reference only
│   ├── platform/                    # Reserved, empty (no shared/cross-workspace state exists)
│   └── application/                 # Reserved, empty (no app-layer resources yet)
│
├── modules/
│   ├── aws/
│   │   ├── workspace-deployment/    # Composed deployment logic (used by infrastructure/aws/workspace)
│   │   ├── workspace-network/       # VPC/subnets/routing/security group (existing-or-create)
│   │   ├── workspace-endpoints/     # S3 gateway + STS (+ KMS) interface endpoints
│   │   ├── workspace-privatelink/   # Databricks PrivateLink (requires Enterprise tier)
│   │   ├── workspace-iam-role/      # Cross-account IAM role
│   │   ├── workspace-kms/           # Customer-managed KMS keys (+ bring-your-own-key)
│   │   ├── unity-catalog-data/, unity-catalog-workspace/  # Unity Catalog
│   │   └── databricks-account/, databricks-workspace/     # Planned, empty
│   ├── azure/
│   │   ├── workspace-deployment/    # Network + workspace creation only (Unity Catalog composed
│   │   │                            #   in infrastructure/azure/workspace/ itself - see CLAUDE.md)
│   │   ├── workspace-network/       # VNet + two delegated subnets + NSG (create-only, no
│   │   │                            #   existing-VNet reuse yet)
│   │   └── unity-catalog-data/, unity-catalog-workspace/  # ADLS Gen2 + access connector chain
│   └── aws-poc/                     # POC-era, used only by infrastructure/nonprod/poc - kept
│       │                            #   visually distinct from modules/aws/ since it's frozen/
│       │                            #   superseded, not part of the active factory path
│       └── networking/, kms/, security/, storage/, endpoints/
│
├── requirements.txt                 # Python deps for resolver/ (PyYAML, jsonschema)
└── CLAUDE.md                        # Detailed architecture tracker and decision history
```

**There is exactly one copy of the Terraform code** (`infrastructure/aws/workspace/`
+ `modules/aws/`). Every workspace — `dev`, `stage`, `live`, however many there
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
   `workspace-requests/aws/<env>/<name>.yaml` with the minimal fields
   (application, environment, owner, cost center, data classification,
   network strategy). See existing files in that directory for examples.

   **For `isolated` strategy**, also supply `network.vpc_cidr` — the CIDR
   block for your new, dedicated VPC. This is **your** choice as the
   requester (your network team's address-space allocation), not
   something an operator invents — it must fall inside the reserved
   range declared in `platform/inventory/aws.yaml`'s
   `cidr_pools.isolated_vpc_pool`, checked automatically. You do **not**
   need to pick subnet ranges — the platform carves them automatically.

   **For `custom` strategy**, if you're handing over your own existing
   VPC (rather than using the account's default one), supply
   `network.existing_vpc_id`, plus `network.existing_vpc_cidr` if that
   VPC isn't already known to the platform (`platform/inventory/aws.yaml`).
   Again, you do not need to pick subnet ranges yourself — they're
   auto-carved out of the VPC's address space, avoiding every range
   already claimed by another committed workspace sharing that VPC. If
   you're also handing over an existing security group, supply
   `network.existing_security_group_id` too — no separate ownership
   override is needed, its presence is enough. If your existing VPC
   *already has* usable route tables you want new subnets attached to
   (rather than fresh ones Terraform creates), supply
   `network.existing_route_table_ids` too — its presence alone resolves
   routing (and, by default, endpoints) ownership to `existing`; omit
   it for a bare VPC with nothing to reuse yet. If your existing VPC
   *already has subnets* you want used as-is (instead of letting the
   platform carve new ones), supply `network.existing_subnet_ids`
   (at least two, in different AZs) — the platform adopts them rather
   than creating anything. **Caution**: that VPC needs
   `enableDnsSupport`/`enableDnsHostnames` both enabled, or the S3/STS
   interface endpoints will fail to apply; and because adopted
   subnets' CIDRs are never looked up, they're invisible to the
   cross-workspace collision checker — don't combine this with another
   workspace auto-allocating into the same VPC.

   **Other optional request fields**, each with a platform-wide default
   so most workspaces never need them: `cloud.databricks_account_id`
   (override which Databricks account this workspace registers with —
   defaults to the AWS account's known default in
   `platform/inventory/aws.yaml`), `encryption.existing_workspace_storage_key_arn`/
   `existing_workspace_storage_key_alias`/`existing_managed_services_key_arn`/
   `existing_managed_services_key_alias` (bring your own KMS keys instead
   of ones the platform creates — only meaningful once
   `encryption.workspace` resolves to `customer_managed`), and
   `governance.existing_metastore_id` (register with a different Unity
   Catalog metastore than the Databricks account/region's known default).

2. **Resolve it.**
   ```
   python resolver/main.py --request workspace-requests/aws/<env>/<name>.yaml --account <aws_account_id>
   ```
   Produces `normalized/aws/<name>.yaml` — the fully resolved configuration.

3. **Write the deployment file (usually just an `api_version: v1` stub).**
   A normal workspace needs **no edits here at all** — every concrete
   value (Databricks account, VPC/route tables, subnets, security group,
   KMS keys, metastore) now comes from the request or
   `platform/inventory/aws.yaml` by default. `deployment.yaml` still
   exists as the rarely-needed **override** layer, for the one case
   where an already-submitted request needs correcting without
   resubmitting it, or a value genuinely varies independently of the
   request (e.g. reusing a *different* existing network than the
   request named). Copy an existing workspace's `deployment.yaml` for
   the commented-out override syntax if you ever need it.

   **Subnet CIDRs are now optional here** — if you leave
   `network.subnets.private` out, the next step auto-carves and
   permanently pins them for you (based on your request's `vpc_cidr`/
   `existing_vpc_id`/`existing_vpc_cidr` and the fixed subnet-sizing/AZ
   convention declared in `platform/inventory/aws.yaml`'s
   `subnet_defaults`). You can still hand-type explicit subnet CIDRs here
   if you need to override the auto-carved result for a specific
   workspace — an explicit list always wins.

4. **Generate the Terraform inputs.**
   ```
   python resolver/generate_tfvars.py --workspace <name>
   python resolver/generate_backend_config.py --workspace <name>
   ```
   `generate_tfvars.py` first runs `resolver/check_cidr_allocations.py`
   against every committed workspace's `deployment.yaml` and fails loudly
   on any collision or pool violation. If `deployment.yaml` didn't specify
   subnet CIDRs, it then auto-allocates them (writing a new, generated
   `infrastructure/deployments/aws/<env>/<name>/allocated-subnets.yaml` —
   **do not hand-edit this file; delete it to force reallocation before
   first apply**, since it's permanently pinned on every run afterward)
   and re-runs the collision check once more before writing tfvars.
   Produces `infrastructure/deployments/aws/<env>/<name>/terraform.tfvars.json`
   and `.../backend.tfbackend` (just this workspace's state `key`), and
   (re)writes `infrastructure/aws/workspace/backend.tfbackend` (the
   bucket/region/use_lockfile settings shared by every workspace).

5. **Set your Databricks CLI profile.** Either export it for the shell
   session (`export TF_VAR_databricks_profile="your-profile-name"`) or copy
   `infrastructure/aws/workspace/local.auto.tfvars.example` to
   `local.auto.tfvars` and fill it in (gitignored, never committed).

6. **Point the shared root at this workspace's state.** From
   `infrastructure/aws/workspace/`, pass **both** backend-config files - the
   shared one first, then this workspace's:
   ```
   terraform init \
     -backend-config=backend.tfbackend \
     -backend-config=../../deployments/aws/<env>/<name>/backend.tfbackend \
     -reconfigure -input=false
   ```

7. **Plan, review, then apply.**
   ```
   terraform plan  -var-file=../../deployments/aws/<env>/<name>/terraform.tfvars.json
   terraform apply -var-file=../../deployments/aws/<env>/<name>/terraform.tfvars.json
   ```
   Read the plan before applying. See warnings below.

8. **(Optional) Validate the deployment.** After a successful apply, with
   `infrastructure/aws/workspace/` still pointed at this workspace's backend:
   ```
   python resolver/validate_deployment.py --workspace <name> --profile <same-profile-as-apply>
   ```
   Checks the live workspace against what was resolved for it (workspace
   running, network/encryption/Unity Catalog wiring) and reports
   `PASS`/`FAIL`/`N/A`/`NOT_IMPLEMENTED`/`SKIPPED` per check. Exits
   non-zero only when a real check fails **and** the environment's
   `validation.blocking` is true (`dev` is not; `stage`/`live` are).
   `identity.required`/`logging.centralized` always report
   `NOT_IMPLEMENTED` — no SCIM/user provisioning or audit-log-delivery
   Terraform resource exists in this pipeline yet.

   To also verify the catalog's live isolation/storage (not just its
   metastore assignment), pass a **second, workspace-scoped** profile:
   ```
   python resolver/validate_deployment.py --workspace <name> --profile <account-profile> --workspace-profile <workspace-profile>
   ```
   Get one with `databricks auth login --host <workspace_url>` (the
   workspace URL is `terraform output databricks_workspace_url`).
   **Give it a name different from any account-console profile you
   already use** — logging in under an *existing* profile name silently
   repoints that name's host (account-console → that workspace),
   breaking every account-level command that used to work under it.
   This bit us once already: re-authenticating fixed it, but it's easy
   to do by accident since the CLI doesn't warn you.

## ⚠️ Warnings for manual deployments

- **Always re-run step 6 before touching any workspace, every time.**
  There is no per-directory safety net anymore — the shared root always
  operates against whichever `-backend-config` was last initialized. If
  you skip this and run `plan`/`apply` while still pointed at a different
  workspace, Terraform will propose **destroying that other workspace**
  and creating this one instead. This is the single most important rule
  in this repository.
- **Never hand-edit `terraform.tfvars.json` or either `backend.tfbackend`
  file.** All three are generated from `normalized/aws/<name>.yaml` and
  `deployment.yaml`. Manual edits will silently drift from the source of
  truth and be overwritten the next time someone regenerates them.
- **Always read the plan before applying.** An unexpected `destroy` in the
  plan almost always means you're pointed at the wrong workspace's state
  (see the first warning), not that something is actually wrong with the
  target workspace.
- **`terraform destroy` carries the same backend risk as `apply`.** Confirm
  which `-backend-config` is active before running it.
- **`local.auto.tfvars`'s `databricks_profile` must match the workspace
  you're applying, every time — it's one global setting, not per-workspace.**
  Workspaces on different Databricks accounts need different profiles
  (e.g. the account-console profile authenticated for account A won't
  authenticate against account B). Getting this wrong fails loudly
  (`databricks CLI not found` / auth errors) rather than silently
  applying to the wrong account, but it's easy to forget when switching
  between workspaces. Same applies if `DATABRICKS_CLI_PATH` is set in
  your shell environment and points at a stale/uninstalled CLI location —
  the provider respects it over auto-detecting the CLI on `PATH`; unset
  it if you hit `databricks CLI not found` despite `databricks` working
  fine from the command line.
- **`databricks_mws_credentials` can fail on the very first apply attempt**
  right after the cross-account IAM role is created, with *"Failed
  credential validation checks."* This is IAM trust-policy propagation lag,
  not a real error — a plain retry a few seconds to minutes later typically
  succeeds. See `CLAUDE.md` for details.
- **Databricks PrivateLink (`modules/aws/workspace-privatelink`) requires an
  Enterprise-tier Databricks account.** You don't normally need to do
  anything about this: a request's `network.connectivity` defaults to
  `"auto"`, which automatically falls back to a NAT Gateway whenever the
  target Databricks account doesn't have PrivateLink available
  (`platform/inventory/aws.yaml`'s `privatelink_available` per account —
  update it there if a new account's tier status is ever wrong). Set
  `network.connectivity: "nat"` or `"privatelink"` explicitly in the
  request to force one or the other; an explicit `"privatelink"` against
  an account without it is rejected with a clear error. NAT only applies
  to workspaces where Terraform creates the VPC itself — its public
  subnet CIDR is auto-carved alongside the private subnets whenever
  `deployment.yaml` doesn't hand-type its own `network.subnets.private`
  (see step 3/4 above); if you do hand-type subnets, you also need to
  hand-type a `network.nat_subnet_cidr`, same shape as the private subnet
  CIDRs. A NAT Gateway has a real, ongoing AWS hourly cost — review the
  plan before applying for that reason too.
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
   `normalized/<provider>/<name>.yaml`.
2. **generate** — run `generate_tfvars.py` and `generate_backend_config.py`.
   Artifacts: `infrastructure/deployments/aws/<env>/<name>/terraform.tfvars.json`,
   `.../backend.tfbackend`, and `infrastructure/aws/workspace/backend.tfbackend`.
3. **validate** — `terraform fmt -check -recursive`, then `terraform init
   -backend-config=backend.tfbackend
   -backend-config=../../deployments/aws/<env>/<name>/backend.tfbackend
   -reconfigure -input=false` and `terraform validate`. A fresh pipeline run
   always starts with a clean checkout, so there's no "forgot to
   reconfigure" risk here the way there is for manual/local use.
4. **plan** — `terraform plan
   -var-file=../../deployments/aws/<env>/<name>/terraform.tfvars.json
   -out=plan.tfplan`. Post the plan as an MR comment (`gitlab-terraform`
   style tooling, or a simple script piping `terraform show -no-color
   plan.tfplan`) so a reviewer can read it before anything is applied.
   Artifact: `plan.tfplan`.
5. **apply** — `terraform apply plan.tfplan`. Make this job
   `when: manual` and run it in a **protected GitLab environment**
   requiring approval — never apply automatically on merge, at least until
   this pipeline has a track record.

**Known gap to resolve before this can actually run in CI**:
`infrastructure/aws/workspace/providers.tf` currently authenticates to
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
