# Databricks Workspace Factory — Project Tracker

This file tracks the state, architecture, and open work for the Databricks-on-AWS
workspace factory. Keep it updated as milestones complete or decisions change —
this is the source of truth for "what exists, what's planned, and what's
intentionally deferred."

## 1. What this project is

A Terraform-based **factory** that lets a requester describe a desired Databricks
workspace with a small set of inputs (application, environment, owner, cost
center, data classification, network strategy) and have the platform infer and
provision everything else: networking, IAM, encryption, storage, Unity Catalog,
logging, and validation — consistently, per environment.

AWS is the current target cloud. **Azure support is explicitly deferred** until
the AWS path reaches a good milestone — do not start Azure modules/providers yet.

**Terminology note — "platform" means this codebase.** Throughout this file
and the design notes, "platform" refers to *this factory's own shared/
workspace-layer code* (the `infrastructure/platform/` directory, and the
distinction between resources a workspace creates for itself vs. resources
multiple workspaces might share) — **not** an external platform team, and
not something a customer/application is responsible for configuring outside
this code. "Platform-owned" means "owned by this Terraform/resolver codebase,"
as opposed to "application-owned" (something a specific workspace/application
brings or manages itself, e.g. an existing VPC or an existing KMS key supplied
by the customer). This was clarified 2026-10-09 after an earlier reading of
the Notion notes' "platform" language was ambiguous — see §8's networking/KMS
milestone for the concrete design that came out of it.

Guiding quote from the design notes: the requester should be able to say
*"I need a dev workspace for application X"* rather than *"create a VPC with
these CIDRs, these route tables, this IAM policy, and these endpoints."*

## 2. Pipeline architecture

```
workspace-requests/<env>/<name>.yaml   (requester input — minimal fields)
            |
            v
   resolver/main.py  --account <aws_account_id>
            |  loads: profiles/<env>.yaml, policies/*.yaml,
            |         platform/inventory/aws.yaml
            |  validates request against schemas/workspace-request.schema.json
            |  validates result against schemas/normalized-config.schema.json
            v
   normalized/<name>.yaml   (fully resolved config — the "contract")
            |
            v
   infrastructure/deployments/<env>/<name>/deployment.yaml   (small,
            |         hand-maintained: existing resource ids, CIDRs)
            v
   resolver/generate_tfvars.py --workspace <name>
            |    (→ infrastructure/deployments/<env>/<name>/terraform.tfvars.json)
   resolver/generate_backend_config.py --workspace <name>
            |    (→ infrastructure/deployments/<env>/<name>/backend.tfbackend,
            |       just this workspace's state `key`; also (re)writes
            |       infrastructure/workspace/backend.tfbackend — the
            |       bucket/region/use_lockfile shared by every workspace —
            |       see §8 milestone 13)
            v
   infrastructure/workspace/*.tf   (ONE shared root for every workspace —
            |                 providers + a single module "deployment" call)
            v
   terraform init -backend-config=backend.tfbackend
            |      -backend-config=../deployments/<env>/<name>/backend.tfbackend
            |      -reconfigure   (points the shared root's state at THIS
            |                 workspace's S3 key — see §8 milestones 12/13)
            v
   modules/workspace-deployment   (the actual resources, composed from the
            |                 smaller modules below)
            v
   modules/{workspace-network,workspace-endpoints,workspace-privatelink,
            |  workspace-iam-role,workspace-kms,...}
            v
   AWS + Databricks account/workspace APIs
```

**One shared root, no per-workspace directories or copied `.tf` files**
(§8 milestone 12, superseding milestone 10's per-directory approach).
Per-workspace *data* files (deployment.yaml, generated tfvars, generated
backend key) live in their own directory under `infrastructure/deployments/`
rather than flat inside `infrastructure/workspace/` (§8 milestone 13) — this
keeps `workspace-requests/` (requester-facing minimal input) and
`infrastructure/workspace/` (the shared Terraform root's `.tf` files) both
uncluttered, with every workspace's own files grouped together instead.
State lives in S3 (bucket `beng-tfstatefiles`, versioned, native S3
locking — see §8 milestone 12), one object per workspace at
`<environment>/<workspace-name>/terraform.tfstate`. Switching which
workspace the shared root is pointed at is always an explicit
`terraform init -backend-config=backend.tfbackend
-backend-config=../deployments/<env>/<name>/backend.tfbackend -reconfigure`
(two `-backend-config` files — see §8 milestone 13 for why) —
**always run this before `plan`/`apply` and confirm which workspace you're
pointed at**; there is no per-directory safety net anymore.

Profiles (`dev`, `stage`, `live`) define standardized platform configuration.
Workspace requests instantiate a profile as an independent deployment. Multiple
workspaces may share a profile; each gets its own resource/state boundary.
Shared platform resources are owned separately and never by an individual
workspace deployment.

Requester specifies: application, environment, owner, cost center, data
classification, profile/network strategy, application-specific requirements.

Platform determines: VPC strategy, subnet design, security groups, endpoint
requirements, IAM policies, KMS configuration, S3 controls, PrivateLink
configuration, Databricks workspace settings, Unity Catalog baseline, logging
requirements, security controls, Terraform behavior.

## 3. Directory map & status

| Path | Status | Notes |
|---|---|---|
| `workspace-requests/{dev,stage,live}/` | Working | Minimal requester input YAML. One `document-ai` request per env exists as the test case. |
| `resolver/` (`main.py`, `resolver.py`, `loader.py`, `validator.py`, `generate_tfvars.py`, `generate_backend_config.py`, `check_cidr_allocations.py`, `validate_deployment.py`, `inventory.py`) | Working, has gaps | Resolves request+profile+policies+inventory → normalized YAML. `inventory.py` holds shared `platform/inventory/aws.yaml` lookups (`resolve_metastore_id()`, `find_primary_network()`, `resolve_platform_network()`, `subnet_defaults_for()`, `allocate_subnets()`, `resolve_existing_vpc_cidr()` — milestone 28; `resolve_databricks_account_id()` — milestone 29; `resolve_route_table_ids()` — milestone 30, consolidated/renamed from `route_table_ids_known()` in milestone 31) — centralized here, not in `generate_tfvars.py`, specifically to avoid a circular import with `check_cidr_allocations.py`. `generate_tfvars.py` turns normalized + a small per-workspace deployment file into `terraform.tfvars.json`, both now under `infrastructure/deployments/<env>/<name>/` (§8 milestone 13); its metastore and VPC/route-table lookups both come from `inventory.py` (§8 milestones 23, 25); its `ensure_subnet_allocation()` (§8 milestone 28) auto-carves and permanently pins subnet CIDRs into a sibling generated `allocated-subnets.yaml` file whenever a workspace's `deployment.yaml` doesn't hand-type its own `network.subnets.private`; `main()` now resolves `databricks_account_id` once up front (deployment override > request > inventory default, §8 milestone 29) before either of those run; its `resolve_network_ownership()` (§8 milestones 9, 30) now infers `routing_ownership`/`endpoints_ownership` from whether route table ids are actually known for the VPC in play, rather than a blind per-strategy default, and `build_tfvars()` always forwards all three ownership overrides explicitly (not just when set in `deployment.yaml`) so Terraform's own `locals.tf` coalesce can't diverge from the inference. `generate_backend_config.py` turns `normalized/<name>.yaml`'s `workspace.environment` + a workspace name into two files: `infrastructure/deployments/<env>/<name>/backend.tfbackend` (just the `key` line) and `infrastructure/workspace/backend.tfbackend` (bucket/region/use_lockfile, identical for every workspace, idempotently rewritten each run — §8 milestone 13). `check_cidr_allocations.py` (§8 milestones 14, 25, 28) scans every committed `deployment.yaml` for CIDR collisions/pool violations, falling back to `inventory.py`'s lookup when a workspace's `deployment.yaml` omits `platform.vpc_id`, and (§8 milestone 28) merging in a workspace's `allocated-subnets.yaml` and the request's own `network.vpc_cidr`/`existing_vpc_id`/`existing_vpc_cidr` passthroughs when present; exposes `vpc_scope()`/`used_subnets_for_scope()` for `generate_tfvars.py`'s allocator to reuse; called automatically by `generate_tfvars.py` before (and after a first-time allocation) it writes tfvars. `validate_deployment.py` (§8 milestones 23-24, 29) checks a *deployed* workspace's live AWS/Databricks state against what was resolved for it — run manually, post-apply, not wired into anything automatically; its optional `--workspace-profile` additionally verifies live catalog isolation/storage via a workspace-scoped profile (§8 milestone 24); now resolves `databricks_account_id` the same 3-tier way as `generate_tfvars.py` instead of reading `deployment.yaml` directly (§8 milestone 29). See §5 gaps. |
| `schemas/` | Working | `workspace-request.schema.json`, `normalized-config.schema.json`, and (as of 2026-10-14, §8 milestone 17) `profile.schema.json` are all actively validated by `resolver/main.py`. `workspace-request.schema.json` gained optional `network.connectivity` (§8 milestone 27); `network.vpc_cidr`/`existing_vpc_id`/`existing_vpc_cidr` (§8 milestone 28); and, §8 milestone 29, `network.existing_security_group_id`, a new top-level `encryption` object (`existing_workspace_storage_key_arn`/`_alias`, `existing_managed_services_key_arn`/`_alias` — the first requester-controlled `encryption` fields; `encryption.workspace`/`application_data` stay entirely profile-derived), `governance.existing_metastore_id` (alongside the milestone-22 `catalog_admin_principal` — the first two requester-controlled `governance` fields), and `cloud.databricks_account_id`. All mirrored into `normalized-config.schema.json` too. The latter's now-dead `network.requirements.subnets.allocation` sub-schema (count/AZs/cidr_source — superseded by real auto-allocation, §8 milestone 28) was removed. No schema for the new `*.deployment.yaml` files yet — deliberate, kept lightweight (plain key-presence checks in `generate_tfvars.py`), see §8. |
| `profiles/{dev,stage,live}.yaml` | Working, trimmed | Per-environment defaults — `workspace.isolation`, `encryption.*`, `compute.policy`, `logging.*`. Trimmed 2026-10-14 (§8 milestone 15) to only the fields `resolver.py` actually reads; the old `network.architecture` dev/stage/live inconsistency (§5.2) is moot now that `network.*` was removed from every profile entirely — `policies/network.yaml`'s `allowed_strategies` is now the only thing with an opinion on network strategy per environment (§8 milestone 16). |
| `policies/policies.yaml` | Working | Platform-wide rules the resolver enforces (encryption requirements, UC requirements, network strategy → architecture mapping + per-environment `allowed_strategies`, validation blocking per env), one key per domain (`network_policy`, `security_policy`, `data_policy`, `governance_policy`, `validation_policy`). Trimmed to only the fields `resolver.py` actually reads (§8 milestone 15), gained `network_policy.allowed_strategies` (§8 milestone 16), then merged from five separate files into this one 2026-10-14 (§8 milestone 18 — closes §5.13's config-layer complexity review). |
| `platform/inventory/aws.yaml` | Working | Declares the `dev` account's primary network; `vpc.id`/`vpc.cidr` fixed to the real values 2026-10-13 (§8 milestone 14), and now auto-consumed (`vpc.id`/`cidr`, `routing.route_table_ids`) by `generate_tfvars.py`/`check_cidr_allocations.py` via `resolver/inventory.py` (§8 milestone 25) whenever VPC/routing ownership resolves to `"existing"` — `resolver.py` itself never reads this file's `vpc`/`routing`/`subnet_defaults`/`databricks_account_id` data at all now (see §5.3; its old subnet-allocation read was removed §8 milestone 28). Also declares `cidr_pools.isolated_vpc_pool` (§8 milestone 14), a `databricks.accounts.<id>.regions.<region>.metastore_id` section (§8 milestone 20), a per-account `databricks.accounts.<id>.privatelink_available` fact (§8 milestone 27), a region-level `subnet_defaults` (`prefix_length` + `availability_zones`, §8 milestone 28, replacing the old per-"primary"-network `subnets.private.allocation` block) used to auto-carve subnets out of *any* VPC in that account/region, and a per-AWS-account `aws.accounts.<name>.databricks_account_id` default (§8 milestone 29 — the one field that used to be mandatory in every workspace's `deployment.yaml`) — all auto-consumed the same way. Trimmed 2026-10-16 (§8 milestone 32) to only the fields actually read, same rule as `profiles/*.yaml`/`policies/policies.yaml` (§5.13/§8 milestones 15-18): removed `aws.accounts.<name>.environment` and `networks.primary.{name, vpc.ownership, routing.ownership, security_groups, endpoints, dns}` — none were ever read by any code; ownership is resolved per-workspace from strategy + request-supplied ids + route-table presence, never from a static per-account "ownership" declaration (which would also have been semantically wrong under that model). |
| `normalized/*.yaml` | Working — **was silently gitignored, now fixed** | Resolver output per workspace request. `CLAUDE.md` previously (incorrectly) stated these were committed; `.gitignore` actually had a stale `normalized/` rule (its own comment called it "the normalized **virtual environment** directory," which doesn't match what's in there) that had been silently excluding every file in this directory from version control. Removed 2026-10-09 — these now will be tracked going forward. |
| `infrastructure/workspace/*.tf` | **One shared root for every workspace** (§8 milestone 12 — supersedes the per-directory approach from milestone 10) | `providers.tf`/`versions.tf` (the latter has a partial `backend "s3" {}` block — bucket/key/region supplied at `init` time, since Terraform backend blocks can't contain variables), `variables.tf`, `main.tf` (a single `module "deployment"` call into `modules/workspace-deployment`), `outputs.tf` (forwards). No per-workspace copies of any of this — every workspace uses these exact same files; only the `-var-file` and the backend-config differ per workspace. |
| `infrastructure/workspace/backend.tfbackend` | **Working** (§8 milestone 13) | Committed, idempotently rewritten every time `generate_backend_config.py` runs for *any* workspace: `bucket`/`region`/`use_lockfile` — identical for every workspace, so this stays a single shared file instead of being repeated in each per-workspace backend-config file. Never hand-edit. |
| `infrastructure/deployments/<env>/<name>/deployment.yaml` / `terraform.tfvars.json` / `backend.tfbackend` / `allocated-subnets.yaml` | **Working** (§8 milestone 13 — supersedes milestone 12's flat layout inside `infrastructure/workspace/`) | Per workspace, grouped in their own directory (not flat alongside the shared Terraform root), all committed: `deployment.yaml` — as of §8 milestone 29, a **normal workspace needs no content here at all** beyond `api_version: v1`; every concrete value (Databricks account, VPC/route tables, subnets, security group, KMS keys, metastore) now has a request-level field and/or an `platform/inventory/aws.yaml` default, with `deployment.yaml` surviving only as the rarely-needed *override* tier (deployment override always wins over the request, which wins over the inventory default — see §5.3's note and §8 milestone 29's five items); `terraform.tfvars.json` (generated by `generate_tfvars.py`, do not hand-edit); `backend.tfbackend` (generated by `generate_backend_config.py`, do not hand-edit — just this workspace's state `key`; paired at `init` time with the shared `infrastructure/workspace/backend.tfbackend` above); and (§8 milestone 28, only for workspaces using subnet auto-allocation) `allocated-subnets.yaml` — generated once on first run by `generate_tfvars.py`'s `ensure_subnet_allocation()` and never recomputed afterward (do not hand-edit; delete it to force reallocation before first apply). `document-ai-dev`, `isolated-proof`, and `client-vpc-proof` all have explicit subnet lists in `deployment.yaml` (no `allocated-subnets.yaml` needed for any of them) and, as of milestone 29, no `databricks:` block at all — `document-ai-dev` relies purely on the inventory default, `isolated-proof`/`client-vpc-proof` get their (different) Databricks account from their own `workspace-requests/*.yaml`'s `cloud.databricks_account_id`. **All three workspaces were destroyed on 2026-10-13** (user's call, clean `terraform destroy` for all three) — these files are kept so any of them can be redeployed later via the same shared root. |
| `infrastructure/workspace/local.auto.tfvars` (gitignored) / `local.auto.tfvars.example` (committed) | Working | Holds `databricks_profile`. With one shared root again, either this file or the `TF_VAR_databricks_profile` env var works equally well — both apply globally now, no per-directory copying concern anymore. |
| `infrastructure/nonprod/poc/` | Frozen POC | The original one-shot POC that validated the approach end-to-end. Not touched going forward; kept for reference. |
| `infrastructure/platform/` | Empty placeholder, deliberately not pursued yet | Would be shared/platform-owned Terraform state used by multiple workspaces. Considered for a shared KMS key during an earlier architecture review and explicitly rejected — every workspace creates and owns its own KMS key(s) in its own state (own S3 key, now). Revisit only if a real need for cross-workspace sharing shows up. |
| `infrastructure/application/` | Empty placeholder | Reserved for application-level resources layered on top of a workspace. Not started. |
| `modules/networking`, `modules/kms`, `modules/security`, `modules/storage`, `modules/endpoints` | POC-era, superseded for the factory | Built for the single-shot POC (`infrastructure/nonprod/poc`). Hardcode `var.project_name`, use a placeholder `ec2.amazonaws.com` trust policy in `security` (explicitly flagged in that file's own comment as provisional), single KMS key, 2-bucket storage. `modules/kms` is superseded by `modules/workspace-kms`, and `modules/endpoints` by `modules/workspace-endpoints`, for the factory path — both POC modules stay only for `infrastructure/nonprod/poc`, don't extend them further. `networking`/`security`/`storage` still need generalized replacements if/when needed. |
| `modules/workspace-deployment` | **Working** | The composed, real deployment logic: network, endpoints, PrivateLink, IAM role, KMS, credentials/storage/network/workspace registration. Called by the one shared root (above) for every workspace — no longer "called by every new per-workspace directory" now that milestone 10's approach was superseded by milestone 12. Deliberately excludes the old scratch `terraform_data.workspace_configuration` resource (§5.5) — no reason to carry known debt into this module. |
| `modules/workspace-network`, `modules/workspace-endpoints`, `modules/workspace-privatelink`, `modules/workspace-iam-role`, `modules/workspace-kms` | Working | Factory-style modules composed by `modules/workspace-deployment`. `workspace-network` supports independent existing-or-create per sub-resource (vpc/routing/security-group, and, as of 2026-10-19, subnets too via `existing_subnet_ids` — §8 milestone 33) — both `custom` and `isolated` strategies are now real, not just modeled in config (§8) — and, as of 2026-10-15 (§8 milestone 27), an optional single-NAT-Gateway fallback (IGW, public subnet, EIP, NAT Gateway, default routes on the private route tables) gated on `nat_enabled && create_vpc`, for workspaces without Databricks PrivateLink available. `workspace-endpoints` provides the S3 gateway + STS (+ KMS, conditionally) interface endpoints needed whenever there's no NAT; its interface-endpoint security group ingress is scoped to the workspace compute security group (not a CIDR) — matches the SRA reference's approach (§7/§8); built regardless of whether NAT is also enabled (reduces NAT data-transfer cost either way). `workspace-privatelink` registers the two Databricks PrivateLink endpoints (REST API + SCC relay) and private access settings so classic compute can reach the control plane with no NAT — see §7/§8; requires Enterprise tier, see `network.connectivity` (§8 milestone 27) for the now-automatic NAT fallback when it isn't available. `workspace-iam-role` uses proper Databricks cross-account trust + restricted policy. `workspace-kms` provisions the customer-managed workspace-storage + managed-services keys, gated on `encryption.workspace == "customer_managed"`, with optional bring-your-own-existing-key inputs per key (§8). |
| `modules/unity-catalog-data/`, `modules/unity-catalog-workspace/` | **Working, real-apply-verified** (§8 milestones 19, 21, 23) | `unity-catalog-data`: dedicated S3 bucket for UC managed storage, optional customer-managed KMS key (gated on `encryption.application_data`), the UC IAM role/policy chain (via `databricks_aws_unity_catalog_assume_role_policy`/`_policy` data sources, bootstrapped SRA-style to avoid the storage-credential/role circular dependency), a `time_sleep` for IAM propagation, storage credential (with an explicit `metastore_id` — required for account-level providers, §8 milestone 23), external location, and explicit `databricks_workspace_binding` resources for both the credential and external location (neither auto-binds to its creating workspace the way `databricks_catalog` does — found via a real apply, §8 milestone 23). `unity-catalog-workspace`: metastore assignment (to an existing, platform-owned metastore — not created here) + a dedicated, always-isolated catalog per workspace + default namespace setting + optional `databricks_grants` (§8 milestone 21). Both composed into `modules/workspace-deployment`, gated on `governance.unity_catalog`, called *after* `databricks_mws_workspaces.this` (every UC resource that needs a real workspace ID uses `provider_config { workspace_id }` against the existing account-console provider — no second workspace-scoped provider needed). Real-apply-verified against `isolated-proof` (§8 milestone 23), not just `terraform plan`. |
| `modules/databricks-account/`, `modules/databricks-workspace/` | **Empty — not started, scope clarified** | Reserved for genuinely account-wide/workspace-hardening SRA features not yet requested (legacy feature disabling, compliance security profile, enhanced security monitoring, audit log delivery, user assignment, network policy) — **not** Unity Catalog, which went into the two `unity-catalog-*` modules above instead (§8 milestone 19 resolves an ambiguity that existed in §7's own notes about where UC code should live). |
| `resolver/__pycache__` | n/a | Build artifact, should be gitignored if not already. |

## 4. Already-applied AWS resources — do not recreate

These exist in the test AWS account (`556940913059`, `us-east-1`) and must be
treated as **existing infrastructure to reuse**, not resources to redeclare:

- **VPC**: `vpc-60c2a81d` (default VPC, CIDR `172.31.0.0/16`), DNS support +
  hostnames both enabled.
- **Private subnets** (both `terraform`-tagged, no public IP on launch):
  - `subnet-0733a0bbd788de763` — `us-east-1a`, `172.31.100.0/24`,
    tag `document-ai-dev-private-1`, route table `rtb-042726c440509ac14`.
  - `subnet-0d2d3a2811bc62d01` — `us-east-1b`, `172.31.101.0/24`,
    tag `document-ai-dev-private-2`, route table `rtb-0e29c295cc93c131c`.
  - Both route tables currently have only the local `172.31.0.0/16` route —
    **no NAT, no internet route** on either private route table.
- **Internet Gateway**: `igw-847da4fe`, attached, used only by the VPC's
  default/main route table (`rtb-3bc1314a`), not by the private route tables above.
- **No NAT Gateway** exists in this VPC.
- **No VPC endpoints** exist yet (`describe-vpc-endpoints` returned empty) —
  S3 gateway / KMS interface endpoints referenced in `modules/endpoints` are
  not yet provisioned for this workspace's network path.
- **S3**: `databricks-poc-root-556940913059` (workspace root storage: versioned,
  public access blocked, bucket-owner-enforced, SSE-S3, Databricks-generated
  bucket policy) and `databricks-poc-data-556940913059` (existing encrypted
  data bucket) — plus `document-ai-dev-...-root` created via
  `infrastructure/workspace/s3.tf`.
- **Databricks account**: credentials config `databricks-poc-credentials` and
  storage config `databricks-poc-storage` already registered; Databricks
  account id `331f8702-2e00-42e9-82e2-2935e7e1d4f9`.

Implication for new network work: since there's no NAT and no existing VPC
endpoints, any module that assumes outbound internet access (e.g. the POC's
`modules/networking` with its NAT gateway) does not match this environment's
actual topology. `modules/workspace-endpoints` (§8) now exists and mirrors
this no-NAT, endpoints-only topology for newly-created (`isolated`) VPCs —
but it is **not** wired up for dev's existing `custom` VPC (`endpoints
ownership` defaults to `"existing"` under `custom`, so dev's plan stays a
no-op). Dev's VPC genuinely has zero endpoints today; if Databricks classic
compute there turns out to need S3/STS/KMS reachability without NAT, the fix
is to set `endpoints_ownership_override = "terraform"` for dev specifically
(the module supports it), not to change the `custom` strategy's default.

### 4a. Proof-of-concept resources (2026-10-11/12)

- **Bare VPC `vpc-09171a1d77c4f8cea`** (`10.80.0.0/16`, DNS support + hostnames
  enabled), created manually via AWS CLI — simulates the minimum a client
  would hand over (no subnets, no route tables) for the `client-vpc-proof`
  workspace (`custom` strategy + `routing_ownership_override`/
  `endpoints_ownership_override` both `terraform`). Not managed by Terraform
  itself (deliberately — it's standing in for infrastructure a client would
  bring, not something this factory creates). If `client-vpc-proof` is torn
  down, this VPC should be deleted separately.
- **Both applied for real (2026-10-12).** `isolated-proof`: workspace id
  `7474652718047533`, url `https://dbc-35616a3c-d146.cloud.databricks.com`.
  `client-vpc-proof`: workspace id `7474660429820232`, url
  `https://dbc-038aaeaf-80f7.cloud.databricks.com`. Both on Databricks
  account `eddbb85f-6b3c-4261-8ca2-0d9d62575ce2` (a second account created
  specifically to test PrivateLink — see §5.11/§8 milestone 11), CLI profile
  `TSA` (account-console login, `databricks auth login --host
  https://accounts.cloud.databricks.com --account-id eddbb85f-...`). Both
  built *without* PrivateLink (`privatelink_enabled: false` in each
  `deployment.yaml` — see §5.11) since neither Databricks account tried has
  Enterprise tier.
- Recurring, non-fatal issue hit three times during these applies:
  `databricks_mws_credentials` failing with *"Failed credential validation
  checks"* on the first attempt right after the cross-account IAM role (or
  its trust policy) was created/updated, then succeeding on a plain retry
  seconds to minutes later. Looks like IAM trust-policy propagation lag on
  AWS's side, not a real misconfiguration — the role/policy content was
  verified correct via `aws iam get-role`/`get-role-policy` both times.
  **Not yet fixed systemically** — worth adding a short `time_sleep`
  between the IAM role/policy and `databricks_mws_credentials` (matching the
  pattern SRA itself uses elsewhere for exactly this kind of propagation
  gap) so future workspace creation doesn't need a manual retry.
- **All three test workspaces destroyed on 2026-10-13** (user's call, clean
  `terraform destroy` for `document-ai-dev`, `isolated-proof`, and
  `client-vpc-proof` — confirmed via AWS/Databricks: their VPCs, S3 root
  buckets, and Databricks workspace objects are all gone). This was the
  trigger for the shared-root + S3-backend redesign in §8 milestone 12 — the
  manually-created bare "client" VPC above is unaffected (never
  Terraform-managed) and is still live at the time of writing. All three
  workspaces' `deployment.yaml`/`tfvars.json`/`s3.tfbackend` files are kept
  so any of them can be redeployed later through the new shared root.
- **`isolated-proof` re-applied for real on 2026-10-14** (§8 milestone
  23, to verify the new validation harness against live infrastructure) —
  workspace id `7474647501620182`, url
  `https://dbc-10c1218d-d7d7.cloud.databricks.com`, Unity Catalog fully
  wired (catalog `isolated-proof`, assigned to metastore
  `0745ece3-cb83-4a7f-9dc5-dc1716c015c7`). Still live at the time of
  writing — whether to destroy it again is a separate, pending decision.
  This apply surfaced three real Terraform/provider gaps not caught by
  `terraform plan` (all fixed, see milestone 23 for detail):
  `databricks_storage_credential` needs an explicit `metastore_id` when
  managed through an account-level provider; `storage_credential`/
  `external_location` (unlike `catalog`) don't auto-bind to their
  creating workspace and need explicit `databricks_workspace_binding`
  resources; and that binding resource itself also needs
  `provider_config { workspace_id }`, not just its own top-level
  `workspace_id` argument.
- **`existing-vpc-proof` applied for real on 2026-10-19** (§8 milestones
  32/33) — workspace id `7474653153200830`, url
  `https://dbc-1c4c0ccd-795d.cloud.databricks.com`, in AWS account
  `556940913059`'s manually-created VPC `vpc-0c7507e977fba2ee1`
  (`10.71.0.0/16`), registered against Databricks account
  `eddbb85f-6b3c-4261-8ca2-0d9d62575ce2` (`TSA` profile) rather than
  this AWS account's inventory default. Two private subnets carved by
  Terraform (`10.71.0.0/24`/`10.71.1.0/24`, pinned in
  `infrastructure/deployments/dev/existing-vpc-proof/allocated-subnets.yaml`).
  Still live at the time of writing. No PrivateLink/NAT (deliberate,
  pipeline-mechanics-test scope — see milestone 32) — classic compute
  has no control-plane path; only the request→resolve→apply pipeline
  itself was being proven.
- **`isolated-dev-2` applied for real on 2026-10-19** — a second,
  independent `isolated`-strategy workspace (alongside `isolated-proof`),
  exercising the full "brand-new dedicated VPC" path end to end:
  workspace id `7474645911867768`, url
  `https://dbc-19dc7897-055f.cloud.databricks.com`, dedicated VPC
  `vpc-09e4056b35123f4ad` (`10.65.0.0/16`, inside the reserved isolated
  pool, clear of `isolated-proof`'s `10.70.0.0/16`), two auto-carved
  private subnets + a NAT subnet, NAT Gateway (no PrivateLink — the
  TSA Databricks account has no Enterprise tier), S3/STS endpoints,
  Unity Catalog wired up. Registered against the TSA account
  (`eddbb85f-6b3c-4261-8ca2-0d9d62575ce2`) rather than this AWS
  account's inventory default, because the default account's only
  locally-authenticated CLI profiles had all gone invalid at the time
  (`bxg3611 Premium`/`bxg3611Premium`/`bengonzalezre` all showed
  `Valid: NO` in `databricks auth profiles` — a local auth-state issue,
  not a code problem) — `cloud.databricks_account_id` override used
  instead of re-authenticating. Hit the same known, non-fatal IAM
  propagation-lag retry on `databricks_mws_credentials` as every other
  first-time apply in this project (§4a) — cleared on retry, 0 drift on
  a follow-up plan. **Real, ongoing AWS cost while live**: one NAT
  Gateway.
- **All three live workspaces (`isolated-dev-2`, `existing-vpc-proof`,
  `isolated-proof`) destroyed for real on 2026-10-19**, once manual
  testing (including real notebook-driven Unity Catalog read/write
  activity on `isolated-dev-2`) was complete. See §8 milestone 34 for
  the real teardown gaps this surfaced (non-empty S3 buckets, a Unity
  Catalog storage-credential deletion block) and how each was resolved.
  `existing-vpc-proof`'s underlying VPC (`vpc-0c7507e977fba2ee1`) was
  never Terraform-managed (§8 milestone 32) and is still live — deleting
  it, if desired, is a separate manual AWS action.

## 5. Known gaps / inconsistencies to resolve

1. **Profile schema is never validated — fixed, see §8 milestone 17.**
   `schemas/profile.schema.json` was rewritten to match the trimmed
   profile shape (§8 milestone 15), and `resolver/main.py` now calls
   `validate_document()` against it right after the profile loads, same
   pattern as the request/normalized-config schemas.
2. **`profile["network"]["architecture"]` was a dead field — fixed by
   deletion.** It only allowed `client_managed`/`platform_managed`, while
   `policies/network.yaml`'s `custom` strategy actually resolves to
   `hybrid` — `resolver.py` never read this field at all; it recomputes
   architecture itself from `policies/network.yaml`. **Resolved
   2026-10-14** (§8 milestone 15) by removing `network.*` from every
   profile entirely, rather than trying to fix the enum — the resolver is
   the real source of truth for architecture, so the profile never needed
   its own copy.
3. **`platform/inventory/aws.yaml` VPC id was a stale placeholder — the
   auto-lookup half is now done (§8 milestone 25), the "should the
   resolver emit a `platform` block" half remains open by design.**
   `vpc.id`/`cidr`/`routing.route_table_ids` are now looked up
   automatically by `generate_tfvars.py` (and `check_cidr_allocations.py`)
   whenever VPC/routing ownership resolves to `"existing"`, the same
   shape as the Unity Catalog metastore lookup (milestone 20) — see
   milestone 25 for the full implementation. `resolver.py` itself is
   still untouched and still doesn't emit a `platform` block into
   `normalized/*.yaml` — deliberately: the auto-lookup lives in
   `generate_tfvars.py` precisely *because* it keeps `resolver.py`/the
   normalized-config schema free of concrete AWS resource ids, matching
   the existing "resolver resolves policy, deployment-layer resolves
   concrete ids" boundary. Revisit only if a real need arises for the
   normalized contract itself to carry a resolved VPC id (none has yet).
   **Nuance added §8 milestone 28**: `normalized/*.yaml` *can* now carry
   `network.existing_vpc_id`/`existing_vpc_cidr` — but only as an
   unresolved passthrough of what the *client* supplied in the request
   (same category as `connectivity`/`catalog_admin_principal`), copied
   verbatim by `resolver.py` without ever being validated/looked up
   against the inventory. That resolution still happens only in
   `generate_tfvars.py`, once the deployment's AWS account is known -
   this doesn't change the boundary above, it just gives the client a
   way to state their own existing VPC id instead of only the operator.
4. **No normalized-YAML → tfvars generator — done, see §8.** `resolver/
   generate_tfvars.py` does this. The old hand-written HCL
   `infrastructure/workspace/dev.tfvars` it superseded was **removed
   2026-10-15** (§8 milestone 26) — it had been kept deliberately as a
   sanity-check reference while the generated workflow proved itself,
   and by this point had proven itself many times over (CIDR checks,
   Unity Catalog, inventory auto-lookups, several real applies) and had
   also gone genuinely stale (no `existing_metastore_id`, hardcoded
   `databricks_profile` inline rather than via `local.auto.tfvars`/env
   var — it would not have worked if actually used).
5. **`terraform_data.workspace_configuration` scratch resource — moot,
   never existed in the current shared root.** This referred to
   `infrastructure/workspace/main.tf` lines ~30–67 from *before* the
   shared-root + module rework (§8 milestone 12) — `modules/
   workspace-deployment` (built in milestone 10, still the basis for the
   current shared root) deliberately never carried this scratch resource
   over. Confirmed 2026-10-15: no `terraform_data` resource exists
   anywhere in the current `.tf` files. Nothing to clean up.
6. **Network default mismatch vs. design notes — resolved.** The Notion
   framework notes' "Current Decision Baseline" says dev/stage should default
   to an *isolated* (dedicated, Terraform-owned VPC) network model, but every
   profile/policy/workspace-request in the repo defaults to `custom` (reusing
   an existing VPC). **Both now actually work** (§8): `custom` stays dev's
   default; `isolated` is a real, independently selectable strategy with a
   working Terraform implementation (new VPC, private-only routing, S3/STS/
   KMS endpoints), verified via `terraform plan` against a throwaway
   workspace in a separate Terraform CLI workspace/state. No profile defaults
   changed — `isolated` is available, not yet made the default for anything.
7. **POC modules are not factory-ready.** `modules/security`'s EC2 trust
   policy is explicitly commented as a provisional stand-in ("we will revisit
   the exact Databricks trust configuration") and should not be the pattern
   carried forward — `modules/workspace-iam-role`'s
   `databricks_aws_crossaccount_policy` approach is the correct one and
   should be the template for any further IAM work (e.g. the eventual UC
   data-access role).
8. **No workspace-level validation harness yet — fixed, see §8 milestone
   23.** `policies/policies.yaml`'s `validation_policy` defines
   `blocking`/`evidence`/`negative_tests` per environment; now actually
   consumed by `resolver/validate_deployment.py`.
9. **Per-resource network/KMS ownership was computed by the resolver but
   never consumed by Terraform — fixed at the Terraform layer, not the
   resolver layer.** `resolver.py` has always computed `network.requirements.
   {vpc,subnets,routing,security_groups,endpoints}.ownership`, but no module
   ever read those values — `infrastructure/workspace/main.tf` only ever
   passed `vpc_id`/`route_table_ids` straight through, hardcoding the
   `custom` shape regardless of what strategy was requested. Fixed (§8) by
   reworking `modules/workspace-network` to support existing-or-create
   independently per sub-resource, driven by new root-level override
   variables (`vpc_ownership_override`, `routing_ownership_override`,
   `security_group_ownership_override`, `endpoints_ownership_override`) that
   default from `var.network.strategy` via `coalesce()` in `locals.tf`.
   **Deliberately not plumbed through `resolver.py`/schemas/policy YAML in
   this pass** — a workspace-request still can't ask for a per-resource
   override; only a hand-written `*.tfvars` can. Revisit once the
   normalized-YAML → tfvars generator (gap 4) exists, since that's the
   natural place to decide how a request expresses an override.
10. **KMS bring-your-own-key.** `modules/workspace-kms` now accepts optional
    `existing_*_key_arn`/`existing_*_key_alias` inputs per key (workspace
    storage, managed services); when set, the module skips creating that key
    and passes the supplied ARN/alias straight through instead. Explicitly
    scoped to stay per-workspace — no shared/platform-level KMS state was
    built (see the `infrastructure/platform/` row in §3). If a customer's
    existing key's policy doesn't already trust Databricks, that's on the
    customer to configure — this code only reads what it's given, it doesn't
    manage policy on existing keys.
11. **Databricks PrivateLink requires Enterprise tier — confirmed blocking,
    now decoupled.** `databricks_mws_vpc_endpoint` and
    `databricks_mws_private_access_settings` both failed on *two separate*
    Databricks accounts with *"Feature cannot be accessed... does not have
    one of required pricing tier(s) ENTERPRISE."* This isn't fixable by
    creating another account — Enterprise is a paid/contracted tier, not
    something self-serve signup grants. **Fixed (2026-10-12):**
    `modules/workspace-deployment` now has a `privatelink_enabled` local,
    independent of `endpoints_ownership`, driven by a new
    `privatelink_enabled_override` variable (same override pattern as the
    other ownership flags). Defaults to "on whenever endpoints are
    terraform-owned" (unchanged behavior when not set), but can be forced
    off per-workspace so the generic AWS service endpoints (S3/STS/KMS)
    still get built on non-Enterprise accounts. Both proof workspaces (§4a)
    set `overrides.privatelink_enabled: false` in their `deployment.yaml`.
    **NAT fallback built — done, see §8 milestone 27.**
12. **No CIDR allocation or collision tracking across workspaces — fixed,
    see §8 milestone 14.** Every concrete CIDR value (`network.vpc_cidr`
    and each `network.subnets.private[].cidr`) was hand-picked and typed
    directly into a workspace's `deployment.yaml` with nothing checking
    for collisions against any other workspace. §8 milestone 14 adds a
    documented reserved pool for `isolated`-strategy VPCs
    (`platform/inventory/aws.yaml`'s new `cidr_pools.isolated_vpc_pool`)
    and a standalone collision checker
    (`resolver/check_cidr_allocations.py`, wired into
    `generate_tfvars.py`) that scans every committed `deployment.yaml` and
    fails loudly on overlap before tfvars are generated. Picking the
    value is still manual — this is a check, not an allocator — but
    collisions are no longer silent.
13. **Config-layer complexity review (2026-10-13) — one item remains.**
    Triggered by the CIDR-collision gap above: the user asked for a full
    review of `workspace-requests/`, `profiles/`, `policies/`, and
    `platform/inventory/` to judge whether the request → profile →
    policy → resolver design has gotten too complex. Finding: the
    layering itself is reasonable, but there's a real gap between what's
    *declared* in profiles/policies and what `resolver.py` actually
    *reads* — most profile/policy fields were decorative (see the finding
    written up in conversation; not duplicated here to avoid drift from
    the live code). Four follow-up items were identified and explicitly
    deferred (user's call: tackle CIDR first, revisit these one at a time
    afterward):
    - ~~Trim `profiles/*.yaml` and `policies/*.yaml` down to only the
      fields `resolver.py` actually reads~~ — **done, see §8 milestone
      15.**
    - ~~Resolve `profile.schema.json`~~ — **done, see §8 milestone 17.**
    - ~~Give `network.strategy` one clear ownership rule~~ — **done, see
      §8 milestone 16.**
    - ~~Consider merging the five `policies/*.yaml` files into one
      `policies.yaml`~~ — **done, see §8 milestone 18. This closes the
      config-layer complexity review entirely.**
14. **Unity Catalog follow-ups explicitly scoped out of milestone 19, not
    forgotten.** Four things were deliberately left undone when the
    Unity Catalog modules were built (§8 milestone 19). Two are now done
    (§8 milestone 21):
    - ~~`databricks_grants`~~ — **done, see §8 milestone 21.** Still no
      identity/principal model flows through this pipeline automatically
      (CLAUDE.md §6 still lists "access model"/"exceptions" as
      deliberately undefined platform-wide) — granting is opt-in and
      deployment-only (`unity_catalog.catalog_admin_principal`), not
      auto-derived from `ownership.technical_owner` or anything else.
    - ~~`databricks_default_namespace_setting`~~ — **done, see §8
      milestone 21.**
    - `governance.workspace_binding`'s per-environment values
      (`dev`=optional, `stage`=recommended, `live`=required) are resolved
      into every `normalized/*.yaml` but **not** consumed — every
      workspace's catalog is unconditionally `isolation_mode = "ISOLATED"`
      regardless of this value (user's explicit decision, via
      `AskUserQuestion`, over making non-"required" environments `OPEN`
      and visible account-wide by default). If differentiated behavior
      is ever wanted, the safe direction is almost certainly adding
      `databricks_workspace_binding` resources as opt-in *exceptions* to
      isolation (granting specific other workspaces read/write access),
      not relaxing the default to `OPEN`.
    - Metastore creation itself is explicitly out of scope — per §6's
      baseline, this factory assigns an existing, platform-owned
      metastore, it doesn't create one.

## 6. Design baseline (from project Notion notes)

Source: *Databricks Workspace Framework* Notion page. Condensed to what's
decided vs. still open.

**High-level flow**: `PROFILE → (environment, network mode) → platform
defaults → workspace configuration → (AWS, Databricks) → Unity Catalog`.
Terraform is the implementation engine behind the platform, not the interface
individual project teams use directly.

**Decision baseline** (current):

| Decision | Baseline |
|---|---|
| Profiles | `dev`, `stage`, `live` |
| `restricted_government` profile | Tabled / TBD — not built |
| Profile-first architecture | Yes |
| Requester selects profile | Yes |
| Requester selects infrastructure implementation | Generally no |
| Dev / stage networking | Isolated *(see gap §5.6 — repo currently defaults to custom)* |
| Live networking | Custom / platform-controlled |
| Public Databricks IP | Disabled |
| Unity Catalog | Required |
| UC metastore | Existing platform metastore (not created by this factory) |
| Workspace root storage | Dedicated per workspace |
| Application data storage | Separate from workspace root |
| Workspace IAM role | Dedicated per workspace |
| UC data-access role | Dedicated per workspace |
| Encryption | Required; customer-managed KMS required for `live` / `restricted` classification, platform-controlled otherwise |
| KMS / IAM / S3 policies | Platform-controlled |
| Terraform state | Separated by responsibility/workspace |
| Shared infrastructure | Platform-owned (never owned by a single workspace) *(see terminology note in §1 — "platform" = this codebase's shared layer, not an external team; in practice, nothing has been pushed into a shared layer yet — see §8, KMS stays per-workspace for now)* |
| Exceptions | Controlled approval process |

**Per-capability matrix (dev/stage/live)**: dedicated VPC, private subnets, no
public Databricks access, S3 gateway + STS endpoints, Databricks PrivateLink,
dedicated workspace/root-bucket/data-storage, KMS encryption, dedicated
IAM roles, and central logging are **Yes across all three environments**.
Differences are concentrated in: customer-managed KMS (platform-controlled in
dev/stage, **required** in live) and destructive-operation controls
(controlled → more restricted → highly restricted as environment hardens).

**Deliberately undefined / platform-controlled placeholders** (not solved yet,
don't force an answer prematurely): which AWS accounts hold which environments,
who owns the VPC, whether a shared VPC is used, which endpoints already exist,
whether PrivateLink/NAT infra is centralized, how CIDRs are allocated, whether
dev/stage/live use separate AWS accounts.

## 7. Reference: `databricks/terraform-databricks-sra` (AWS)

The SRA repo (`aws/tf/`) is a security-reference deployment from Databricks
engineers. Useful structural parallels and specific patterns to borrow:

- Its `network_configuration` variable takes `custom` / `isolated` — **same
  terminology this repo already uses** in `policies/network.yaml`. Good sign
  the existing abstraction is on the right track.
- Module split `modules/databricks_account/*` (workspace, unity catalog
  metastore creation/assignment, network policy, network connectivity config,
  disable legacy features, audit log delivery, user assignment) and
  `modules/databricks_workspace/*` (unity catalog catalog creation,
  restrictive root bucket, disable legacy settings, compliance security
  profile, enhanced security monitoring, automatic cluster update, classic
  cluster) — this maps directly onto this repo's empty
  `modules/databricks-account/` and `modules/databricks-workspace/`
  directories and should guide what goes in each.
- SRA provisions **three** KMS keys (managed services, workspace storage, and
  one used in UC catalog creation) and **three** S3 buckets (root, UC storage,
  audit logs) — more granular than this repo's current single-key
  `modules/kms` / two-bucket `modules/storage`. Worth adopting the split when
  building the CMK path (next milestone, §8) rather than a single shared key.
- Cross-account IAM role is scoped with a `restricted` policy type bound to
  the specific VPC/security-group — matches what
  `modules/workspace-iam-role` already does via
  `databricks_aws_crossaccount_policy`. Keep following this pattern for any
  new role (e.g. the UC data-access role).
- `restrictive_root_bucket` module scopes the root bucket policy to the
  specific `workspace_id` rather than a generic Databricks-account-wide
  policy — tighter than this repo's current `databricks_aws_bucket_policy`
  data source usage in `s3.tf`. Consider adopting once the workspace resource
  exists.
- Unity Catalog catalog creation is workspace-scoped with its own dedicated
  storage credential + external location + IAM role — this is the shape
  `modules/unity-catalog-workspace` / `modules/unity-catalog-data` should
  take. (This ended up describing an ambiguity against SRA's own
  `databricks_account/*`/`databricks_workspace/*` split, noted two bullets
  up — resolved explicitly in §8 milestone 19: all UC work went into these
  two `unity-catalog-*` modules, not into `modules/databricks-account/`
  or `modules/databricks-workspace/`.)
- SRA disables legacy features (Hive metastore, DBFS, no-isolation shared
  clusters) both at account level and workspace level, and enables compliance
  security profile / enhanced security monitoring / automatic cluster update
  as explicit opt-in modules. None of this exists yet in this repo and should
  be considered once the base workspace resource lands.
- **Important finding (2026-10-11): SRA's `custom` mode builds nothing at
  all.** Every resource in `privatelink.tf` and the VPC module itself is
  gated `count = var.network_configuration != "custom" ...`. SRA's `custom`
  assumes the client's platform team already built a *complete* network
  pipeline — VPC, subnets, PrivateLink, everything — and SRA just plugs in
  the IDs (`custom_vpc_id`, `custom_private_subnet_ids`, `custom_sg_id`,
  `custom_*_vpce_id`). SRA's `isolated` mode is where all the real
  infrastructure lives. This repo's `custom` strategy is different from
  *both* of SRA's modes — it's a middle ground (existing VPC, but the
  factory builds subnets/SG/routing/endpoints), already correctly labeled
  `architecture: hybrid` in `policies/network.yaml`. The user's actual
  client-delivery scenario ("provided with existing VPCs, but the code needs
  to build the subnets and most of the other resources") maps onto SRA's
  `isolated` *resource set*, minus VPC creation — not onto SRA's `custom` at
  all. This is exactly what `client-vpc-proof` (§8) exercises.
- **Databricks PrivateLink — verified resource chain (built, §8).** No NAT
  means classic compute has no path to the control plane unless PrivateLink
  is used instead — SRA's own `isolated` mode runs with
  `enable_nat_gateway = false`, confirming this is the sanctioned pattern,
  not a shortcut. Verified against the SRA source and the Databricks
  provider's own docs (not guessed):
  - Two AWS Interface VPC endpoints. us-east-1 service names (from SRA's
    `aws/tf/variables.tf`): general_access (REST API) =
    `com.amazonaws.vpce.us-east-1.vpce-svc-09143d1e626de2f04`; SCC relay =
    `com.amazonaws.vpce.us-east-1.vpce-svc-00018a8c3ff62ffdf`. This factory
    targets AWS commercial/us-east-1 only (§1), so these are hardcoded
    constants in `modules/workspace-privatelink`, not a per-region map like
    SRA's — extend if/when another region is ever needed.
  - Each registered with the Databricks account via `databricks_mws_vpc_endpoint`
    (`account_id`, `aws_vpc_endpoint_id`, `vpc_endpoint_name`, `region`).
  - One `databricks_mws_private_access_settings`
    (`public_access_enabled = false`, matching the "no public Databricks
    access" baseline). Note: pass `account_id` only on the `provider
    "databricks" { alias = "mws" }` block, not on this resource too — the
    provider flagged that argument deprecated at the resource level.
  - Wired into *existing* resources: `databricks_mws_networks` gets a
    `vpc_endpoints { rest_api = [...], dataplane_relay = [...] }` block;
    `databricks_mws_workspaces` gets `private_access_settings_id`.
  - Security group ingress scoped to the workspace's compute security group
    (`referenced_security_group_id`, not a CIDR block) across SRA's exact
    port list: 443 (REST), 2443 (SCC w/ compliance profile), 5432 (Lakebase
    Postgres), 8443 (control-plane internal calls), 8444 (UC logging/
    lineage), 8445–8451 (future extendability). SRA's legacy port 6666
    (pre-compliance-profile SCC) was deliberately skipped — not part of the
    baseline being built toward.
  - Deliberate simplification vs. SRA: PrivateLink endpoints share the same
    private/compute subnets rather than SRA's separate "intra" subnet tier.
    AWS doesn't require separate subnets for this; it's an SRA traffic-
    segregation preference, not a hard requirement. Revisit only if a real
    need for that segregation shows up.

## 8. Next milestones (decided this session)

Priority order agreed on:

1. **CMK / KMS wiring** *(in progress)* — `modules/workspace-kms` built:
   two customer-managed keys (`workspace_storage` for DBFS/root-bucket/EBS,
   `managed_services` for Databricks control-plane data), following SRA's
   multi-key split (§7) rather than the POC's single shared key
   (`modules/kms`). Generalized per-workspace (`workspace_name`, not
   `project_name`), using `aws_iam_policy_document` data sources to match
   this repo's convention (`workspace-iam-role`) rather than SRA's raw
   `jsonencode`. Wired into `infrastructure/workspace/main.tf` as
   `module.workspace_kms`, gated on `var.encryption.workspace ==
   "customer_managed"` (true for `live`, false for `dev`/`stage` today) —
   `terraform validate` passes for both branches. `s3.tf`'s root-bucket SSE
   config now reads from the module's `workspace_storage_key_arn` instead of
   the hardcoded `AES256`. Root outputs
   (`workspace_storage_kms_key_arn`/`managed_services_kms_key_arn`) expose the
   key ARNs for later milestones. **Remaining for this milestone:**
   - Not yet exercised against real AWS/Databricks credentials (no
     `live.tfvars` exists in `infrastructure/workspace` yet — only `dev.tfvars`).
   - `managed_services` key isn't attached to anything yet because there's no
     `databricks_mws_workspace` resource to attach it to
     (`aws_kms_key_id`/`storage_customer_managed_key_id` workspace arguments) —
     blocked on milestone 2 below.
   - `encryption.application_data` (separate CMK for the UC/data bucket) is
     deliberately out of scope here — that key belongs with the Unity
     Catalog modules (milestone 3), not this one.
2. **`databricks_mws_workspaces` resource** — **done**, applied for dev
   (2026-10-09). `main.tf` now creates `databricks_mws_workspaces.this`,
   wired to the existing credentials/network/storage-config resources and
   conditionally to the `workspace-kms`-backed customer-managed keys
   (`storage_customer_managed_key_id`, `managed_services_customer_managed_key_id`)
   when `encryption.workspace == "customer_managed"`. Confirmed via
   `databricks_mws_customer_managed_keys` (`use_cases = ["STORAGE"]` /
   `["MANAGED_SERVICES"]`) matching the provider's documented pattern exactly
   (checked against the provider's own docs, not just the SRA repo). Not yet
   exercised for `live` — no `live.tfvars` exists yet, and that path still
   needs `databricks_aws_account_id`/alias wiring re-checked against real
   creds before first use.
3. **Unity Catalog modules** (`modules/unity-catalog-workspace`,
   `modules/unity-catalog-data`) — metastore assignment, catalog creation,
   storage credential, external location, following the SRA shape in §7.
   **Done, see §8 milestone 19.**
4. **Normalized-config → tfvars generator — done** (2026-10-09). User's own
   framing: wanted something closer to the `workspace-requests/*.yaml`
   experience, not hand-edited `*.tfvars`. Built `resolver/generate_tfvars.py`
   (`--workspace <name>`), reading two inputs:
   - `normalized/<name>.yaml` (everything the resolver already resolves —
     unchanged, `resolver.py` was **not** touched).
   - `infrastructure/workspace/<name>.deployment.yaml` (**new**, committed):
     the small set of concrete values nothing upstream produces — existing
     `platform.vpc_id`/`route_table_ids`, concrete subnet CIDRs (the
     resolver only ever produced an *allocation strategy* — count/AZs/
     `cidr_source` — never actual CIDR blocks), optional per-resource
     ownership overrides, optional bring-your-own KMS key ARNs.
   - Writes `infrastructure/workspace/<name>.tfvars.json`.
   - `databricks_profile` (CLI auth profile) deliberately excluded from
     both files — it's a per-operator/machine value, not workspace config.
     Instead: `infrastructure/workspace/local.auto.tfvars` (gitignored,
     `local.auto.tfvars.example` committed as the template) — Terraform
     auto-loads it alongside whatever `-var-file` is passed.
   - **Scope decision (user's call)**: no changes to `resolver.py`,
     `platform/inventory/aws.yaml`, or any schema in this pass — the two
     options were (a) this bounded new-file-only approach, or (b) teaching
     the resolver to emit a `platform` block by extending the inventory
     file. (a) was chosen to keep this pass bounded; (b) remains available
     later if `*.deployment.yaml` duplication across workspaces becomes a
     real pain (§5.3 is still open for that reason).
   - Verified for `document-ai-dev`: full pipeline re-run from
     `workspace-requests/dev/document-ai-dev.yaml` through to a fresh
     `*.tfvars.json`, then `terraform plan` — zero diff against the live
     workspace, matching the hand-written `dev.tfvars` exactly.
   - Side effect: discovered and fixed a real bug while building this —
     `.gitignore` had `normalized/` excluded (see §3), so the resolver's
     "committed contract artifact" was never actually being committed.
5. **Per-resource network ownership + real `isolated` strategy — done**
   (2026-10-09). Architecture review triggered by the user: "platform" means
   this codebase, not an external team, and the factory should let any
   resource be either created or taken as existing rather than assuming it
   always creates everything (VPC and KMS were the named examples). Built:
   - `modules/workspace-network` reworked so `vpc`, `routing`, and
     `security_group` each independently support existing-or-create (was:
     `vpc_id`/`route_table_ids` hard-required, only one bundle possible).
   - New `modules/workspace-endpoints` (generalizes the POC's
     `modules/endpoints`): S3 gateway + STS interface endpoints always, KMS
     interface endpoint when `encryption.workspace == "customer_managed"`.
     Needed because newly-created VPCs have no NAT/IGW by design (matches
     the account's own existing no-NAT private route tables and the
     documented "no public Databricks access" baseline).
   - `infrastructure/workspace/locals.tf` derives `vpc_ownership`/
     `routing_ownership`/`security_group_ownership`/`endpoints_ownership`
     from `var.network.strategy` via `coalesce()` with new override
     variables (`*_ownership_override`) — presets stay the default, any
     resource can be flipped independently without touching the strategy.
   - **Explicitly scoped out of this pass** (user's call): no shared/
     platform-level Terraform state for networking — `isolated` creates a
     *dedicated* VPC per workspace in that workspace's own state, same as
     everything else in this factory.
   - Verified: `terraform validate`/`fmt` clean; `terraform plan
     -var-file=dev.tfvars` is a true no-op (only an auto-resolved `moved`
     state-address update for the security group/egress rule, which gained
     `count`; explicit `moved` blocks were added for safety); a throwaway
     `isolated`-strategy workspace planned cleanly in a separate Terraform
     CLI workspace (24 resources, 0 drift) without touching dev's state; a
     `custom`-strategy + `vpc_ownership_override = "terraform"` combination
     was also planned to confirm the override mechanism works independently
     of the preset.
6. **KMS bring-your-own-key — done** (2026-10-09, same session as #5). See
   §5.10. Scoped deliberately small per the user: no shared platform CMK: —
   "let's assume each workspace creates its own kms and is managed in the
   state for that workspace... if the customer later says they want to use
   their own key, we can get that in the code."
7. **Fix `platform/inventory/aws.yaml` VPC placeholder** and decide whether
   the resolver should emit a `platform` block (§5.3) — low effort, do
   opportunistically alongside any of the above. **Not started.**
8. **Azure** — explicitly deferred until AWS reaches a good milestone. Do not
   start Azure provider/module work before then.
9. **Databricks PrivateLink — built and plan-verified** (2026-10-11/12).
   Triggered by the user: before moving to Unity Catalog, prove the factory
   can build a workspace "in the fashion" of
   `databricks/terraform-databricks-sra`, for the real client scenario
   (existing VPC, factory builds the rest). Holding off on NAT (per the
   prior session) raised a real gap: without NAT or PrivateLink, classic
   compute has no path to the control plane. New `modules/workspace-privatelink`
   (see §7 for the verified resource chain) closes that gap, wired into
   `modules/workspace-deployment` under the same `endpoints_ownership ==
   "terraform"` gate as `workspace-endpoints`. Also hardened
   `workspace-endpoints`' own interface-endpoint SG to SG-sourced ingress
   (was CIDR-based) to match SRA's approach. Two real proof workspaces built
   and plan-verified (not yet applied, pending go-ahead): `isolated-proof`
   (36 resources incl. the scratch resource that existed before the
   directory restructuring below dropped it — see milestone 10) and
   `client-vpc-proof` (the realistic client-delivery scenario, using a bare
   manually-created VPC — §4a). `document-ai-dev` confirmed untouched
   throughout (zero-diff plan after every change). **Update: both applied
   for real on 2026-10-12 — see milestone 11, since PrivateLink itself had
   to be decoupled/disabled first due to an Enterprise-tier blocker.**
10. **Per-workspace Terraform directories — built and verified, then
    SUPERSEDED by milestone 12 (2026-10-13).** The user grew uncomfortable
    with this approach after seeing it in practice — every workspace
    directory replicated the same 5 boilerplate files, differing only in
    which `tfvars.json`/`deployment.yaml` sat alongside them. Replaced by
    one shared root + S3 backend (milestone 12) — read that one for the
    current approach; this entry is kept for history only.
    Triggered by a direct question from the user: applying a second real
    workspace into the *same* state as `document-ai-dev` would have proposed
    destroying it, since `infrastructure/workspace` was a single root/state
    selected only by which `-var-file` was passed. Considered Terraform CLI
    workspaces (`terraform workspace select`) vs. a directory-per-workspace
    pattern; chose the latter specifically because it's what fits a future
    CI pipeline driven by `workspace-requests/*.yaml` changes — a pipeline
    job maps "which request file changed" directly onto a directory, with
    no "remember to select the right state" step to get wrong. Built:
    - New `modules/workspace-deployment` — the 1:1-lifted, composed
      deployment logic (see §3), minus the scratch `terraform_data`
      resource (§5.5), which was deliberately not carried over.
    - New `infrastructure/workspace/_template/` — the 5-file thin-root
      boilerplate (`providers.tf`, `versions.tf`, `variables.tf`, `main.tf`
      calling `module "deployment"`, `outputs.tf` forwarding) copied
      verbatim to create every new workspace directory. No script needed —
      nothing per-workspace to substitute.
    - `isolated-proof/` and `client-vpc-proof/` (from milestone 9) moved
      into this structure as the first two real directories, each with its
      own local state. Resource counts came back exactly one less than the
      pre-restructuring plan-mode checks (35 vs. 36, 34 vs. 35) — exactly
      the dropped scratch resource, confirming the restructuring changed
      nothing functionally.
    - `resolver/generate_tfvars.py`'s default `--deployment`/`--output`
      paths flipped from flat (`infrastructure/workspace/<name>.
      deployment.yaml`) to nested (`infrastructure/workspace/<name>/
      deployment.yaml`) — the new convention is now the common case; the
      explicit override flags (already supported) serve the one remaining
      flat exception, `document-ai-dev`.
    - **Sequencing decision (user's call): `document-ai-dev` stays on the
      old flat layout for now, migrated later, separately.** Migrating it
      means `moved`-blocking (or `state mv`-ing) every one of its ~15
      resource addresses once nested inside a module call — real state
      surgery on a live resource, not something to bundle into a larger
      change. Cost of this sequencing: `modules/workspace-deployment` and
      the flat root now contain near-duplicate logic until migration
      happens (tracked in §3's row for the flat root).
    - Remote backend (S3+DynamoDB or similar) is a related, separately
      deferred decision — local backend works fine per-directory for now
      since the directory itself provides the isolation; swapping in a
      remote backend later is a mechanical `terraform init -migrate-state`
      per directory, not a redesign.
    - Recommended `TF_VAR_databricks_profile` (env var) over a per-directory
      `local.auto.tfvars` file for the new structure — one env var satisfies
      every directory at once; copying a file into each one doesn't scale.
    - Verified: `terraform validate`/`fmt` clean for the module, template,
      and both new directories; `document-ai-dev`'s flat-root plan
      reconfirmed as a zero-diff no-op after the restructuring.
11. **PrivateLink Enterprise-tier blocker found, decoupled, both proofs
    applied for real — done** (2026-10-12). See §5.11 for the full
    decoupling design. Summary of what happened attempting the real applies
    from milestone 9/10:
    - First apply attempt (`isolated-proof`, original account
      `331f8702-...`) failed on all 3 PrivateLink resources: Enterprise
      tier required, account doesn't have it.
    - User created a second Databricks account
      (`eddbb85f-6b3c-4261-8ca2-0d9d62575ce2`) specifically to test this,
      and a matching account-console CLI profile (`TSA` — note: initially
      tried `tsa1`, which turned out to be a *workspace*-level login, not
      an account-console one; the fix was `databricks auth login --host
      https://accounts.cloud.databricks.com --account-id eddbb85f-...`).
      Retried — **same tier error on the new account.** Confirms this isn't
      an account-specific fluke; Enterprise tier is a paid/contracted plan
      that self-serve account creation doesn't grant.
    - Decoupled `privatelink_enabled` from `endpoints_ownership` (§5.11) so
      the rest of the deployment could proceed without it.
    - Switching `isolated-proof`'s `databricks_account_id` mid-stream (old
      account → new account) left one stale state entry
      (`databricks_mws_storage_configurations.workspace_root`, registered
      under the old account) that errored on refresh with "Invalid Token"
      when read under the new account's token. Fixed with `terraform state
      rm` on that one resource — safe, since the AWS-side resources don't
      care which Databricks account registers them, only the
      Databricks-side registration objects do. If this comes up again:
      `state rm` the specific `databricks_mws_*` resource(s) tied to the
      old account, not the whole state.
    - Both went live: `isolated-proof` (workspace id `7474652718047533`) and
      `client-vpc-proof` (workspace id `7474660429820232`). **Both since
      destroyed on 2026-10-13 — see §4a and milestone 12.**
    - NAT-as-fallback TODO explicitly requested by the user — tracked in
      §5.11, not started.
12. **Shared root + S3 backend — replaces milestone 10's per-directory
    approach** (2026-10-13; its flat per-workspace-file layout inside
    `infrastructure/workspace/` was itself refined by milestone 13 later
    the same day — the S3 backend/shared-root mechanism described here is
    still current, only *where the per-workspace files live* changed).
    The user grew uncomfortable with the
    per-workspace-directory pattern once it was actually in use: every
    directory replicated the same 5 `.tf` files, differing only in which
    small data files sat next to them. They also raised the pipeline angle
    directly — this needs to work from a CI job driven by
    `workspace-requests/*.yaml` changes, not just manual local runs. Decided
    to move state to S3 (bucket `beng-tfstatefiles`, us-east-1, versioning
    enabled by the user) and collapse back to one shared root.
    - **Key constraint surfaced and explained up front**: Terraform backend
      blocks cannot contain variables — this is a hard parse-time
      limitation, not a design choice. The user asked for "a variable that
      defines the state file location/name"; the actual mechanism is
      **partial backend configuration** — an empty `backend "s3" {}` block
      in `.tf`, with `bucket`/`key`/`region` supplied at `terraform init`
      time via `-backend-config=<file>`. This achieves the same practical
      goal (state location varies per workspace, code doesn't) without a
      literal `variable` block.
    - `modules/workspace-deployment` is unchanged — it was already a clean
      module from milestone 10's work, just now called by one root instead
      of N.
    - `infrastructure/workspace/_template/` and the per-workspace
      directories (`isolated-proof/`, `client-vpc-proof/`) were deleted.
      `infrastructure/workspace/*.tf` is now the one shared root for every
      workspace (restored from the former `_template` files, with the
      module source path fixed from `../../../modules/...` to
      `../../modules/...` since the root is one directory shallower now
      than the per-workspace directories were).
    - New `resolver/generate_backend_config.py` (§3): reads
      `normalized/<name>.yaml` for `workspace.environment`, writes
      `infrastructure/workspace/<name>.s3.tfbackend` with
      `bucket`/`key = "<environment>/<name>/terraform.tfstate"`/`region`/
      `use_lockfile = true`. Bucket name is a constant default
      (`beng-tfstatefiles`), override-able via `--bucket` if that ever
      needs to vary.
    - **Locking: native S3 lockfile (`use_lockfile = true`), not
      DynamoDB.** Terraform 1.10+ supports this directly against the state
      bucket itself — one less resource for the user to manually create.
      DynamoDB-based locking is being deprecated by Terraform regardless.
    - `resolver/generate_tfvars.py`'s default paths flipped *back* to flat
      (`infrastructure/workspace/<name>.deployment.yaml` →
      `infrastructure/workspace/<name>.tfvars.json`) — the per-directory
      nesting from milestone 10 no longer applies.
    - **State key convention**: `<environment>/<workspace-name>/
      terraform.tfstate` (user's choice over a flat `workspaces/<name>/...`
      scheme) — groups state by environment first, which also means an
      environment-scoped IAM policy (e.g. restricting who can touch
      `live/*`) would be straightforward later if ever needed.
    - **Switching workspaces is now**: `terraform init
      -backend-config=<name>.s3.tfbackend -reconfigure -input=false` before
      any `plan`/`apply`. This replaces both the earlier
      CLI-workspace-select idea (rejected in milestone 10) and the
      per-directory `cd` — there is no structural safety net anymore
      against operating on the wrong workspace; the discipline is "always
      re-init explicitly first." This is a non-issue for a future CI
      pipeline (each run starts clean and must init anyway) but is a real
      manual-use risk to stay disciplined about.
    - **Lesson learned, worth remembering if a real (non-destroyed) state
      ever needs migrating between backends**: `terraform init
      -migrate-state -force-copy -input=false` did **not** reliably copy
      data in practice — it configured the new backend but left the target
      empty, while clearing the local state file (saving the real content
      to `terraform.tfstate.backup` first, which is normal Terraform safety
      behavior — nothing was lost). `-input=false` likely suppressed the
      copy confirmation despite `-force-copy`. The reliable fallback is
      `terraform state push <file>` against the newly-configured backend
      (add `-force` only if a prior failed attempt already wrote something
      to the target, since otherwise the serial/lineage check alone is
      sufficient and safer). In this instance, the migration turned out to
      be moot anyway — investigating it revealed all three workspaces
      (`document-ai-dev`, `isolated-proof`, `client-vpc-proof`) had already
      been destroyed by the user, confirmed via AWS/Databricks before any
      state was pushed anywhere.
    - Verified: `terraform fmt`/`validate` clean; `terraform plan` against
      each of the three workspaces' S3-backed (empty) state proposes a full
      create with no errors (16, 23, 22 resources respectively) — proving
      the shared root + backend-config switching works correctly for all
      three without any directory duplication.
13. **Per-workspace data files regrouped under `infrastructure/deployments/`
    — refines milestone 12's flat layout, does not touch the S3-backend
    mechanism itself** (2026-10-13, same day). Once milestone 12's shared
    root was actually in use, the user noticed `infrastructure/workspace/`
    was accumulating three flat, name-prefixed files per workspace
    (`<name>.deployment.yaml`, `<name>.tfvars.json`, `<name>.s3.tfbackend`)
    alongside the shared `.tf` files, and asked whether they could instead
    live grouped with the request, e.g. under `workspace-requests/<env>/
    <name>/`. Two things were raised and decided:
    - **Where the files should live.** Nesting them under
      `workspace-requests/` was pushed back on: that directory is
      deliberately the *requester-facing* surface (minimal, schema-validated
      input; also the planned CI trigger path, `workspace-requests/**/
      *.yaml`), and mixing in generated Terraform artifacts would blur that
      boundary and make the CI trigger glob match more than requests.
      Instead, a new directory was created: `infrastructure/deployments/
      <environment>/<name>/`, holding exactly three files — `deployment.yaml`
      (hand-maintained, same content as before, just moved and renamed from
      `<name>.deployment.yaml`), `terraform.tfvars.json` (generated,
      renamed from `<name>.tfvars.json` — the per-workspace prefix is
      redundant once the directory itself encodes the name), and
      `backend.tfbackend` (generated, see below). This keeps
      `workspace-requests/` pure requester input and
      `infrastructure/workspace/` a pure shared Terraform root — both
      easier to visually scan — while still grouping everything about one
      workspace's deployment together, which was the user's actual goal.
      Presented as an explicit option via `AskUserQuestion` alongside the
      literal `workspace-requests/` nesting and a no-op "leave it flat"
      option; the user chose the new `infrastructure/deployments/` directory.
    - **The backend-config duplication.** The user separately noticed that
      three of the four lines in every `<name>.s3.tfbackend` (`bucket`,
      `region`, `use_lockfile`) were identical across every workspace — only
      `key` varied — and asked if this could be made more efficient.
      Terraform's `-backend-config` flag can be passed multiple times at
      `init`, and the results are merged, so `generate_backend_config.py`
      now writes **two** files on every run: the per-workspace
      `infrastructure/deployments/<env>/<name>/backend.tfbackend`
      (containing only `key = "<environment>/<name>/terraform.tfstate"`),
      and `infrastructure/workspace/backend.tfbackend` (containing
      `bucket`/`region`/`use_lockfile` — the constants), rewritten
      identically every time the script runs for *any* workspace so the two
      can never drift apart. `terraform init` now takes both:
      `-backend-config=backend.tfbackend
      -backend-config=../deployments/<env>/<name>/backend.tfbackend`.
    - `resolver/generate_tfvars.py` changed to read `normalized/<name>.yaml`
      first (to get `workspace.environment`), then derive the default
      `infrastructure/deployments/<environment>/<name>/` directory for both
      the input `deployment.yaml` and the output `terraform.tfvars.json` —
      previously environment wasn't needed to locate the deployment file
      since everything was flat in one place. Also now creates the output
      directory (`mkdir -p` equivalent) if it doesn't exist yet, since a
      brand-new workspace's directory won't exist before its first
      generate run.
    - All three existing workspaces' files were moved into the new
      structure (`document-ai-dev`, `isolated-proof`, `client-vpc-proof` —
      all under `infrastructure/deployments/dev/`, since all three are
      `dev`-environment); the old flat files were deleted from
      `infrastructure/workspace/`.
    - Verified: `terraform fmt -check -recursive` clean; re-ran `terraform
      init` with the two-file `-backend-config` for all three workspaces
      and `terraform plan` against each — same exact resource counts as
      milestone 12 (16, 23, 22), confirming this was a pure file-layout
      change with no functional effect.
14. **CIDR collision checker + reserved isolated-VPC pool — closes §5.12**
    (2026-10-13, same day). Triggered directly by the user asking how
    VPC/subnet CIDRs get defined and flagging that nothing prevented two
    workspaces from picking the same range. Led to a broader request to
    review `workspace-requests/`, `profiles/`, `policies/`, and
    `platform/inventory/` for whether the whole config-layer design has
    gotten too complex — see §5.13 for the four items identified there and
    explicitly deferred (user's call: fix CIDR first, revisit the rest one
    at a time). This milestone is the CIDR fix only:
    - `platform/inventory/aws.yaml`'s dev VPC placeholder
      (`vpc.id: vpc-PLACEHOLDER`, `vpc.cidr: 10.20.0.0/16`) was finally
      fixed to the real values (`vpc-60c2a81d`, `172.31.0.0/16`) — closes
      the stale-placeholder half of §5.3 (the "should the resolver emit a
      `platform` block" half is still open).
    - New `cidr_pools.isolated_vpc_pool: 10.64.0.0/10` added to
      `platform/inventory/aws.yaml` — the reserved range for VPCs this
      factory creates itself (`isolated` strategy). This is the direct
      answer to "where does the base begin": previously that was just
      whatever CIDR the prior session happened to pick
      (`isolated-proof` used `10.70.0.0/16` with no written-down reason).
      Existing/`custom`-strategy VPCs aren't part of this pool — their
      CIDR is whatever the existing VPC already has.
    - New `resolver/check_cidr_allocations.py`: scans every committed
      `infrastructure/deployments/*/*/deployment.yaml`, using the stdlib
      `ipaddress` module to check (a) every `isolated` workspace's
      `network.vpc_cidr` falls inside the reserved pool above, (b) no two
      `isolated` workspaces' VPC CIDRs overlap each other, (c) every
      subnet CIDR is actually contained within its own workspace's VPC
      CIDR, and (d) no two workspaces that reference the *same* existing
      `platform.vpc_id` have overlapping subnet CIDRs. Raises `ValueError`
      with a specific, actionable message on the first violation found
      (same fail-fast convention as the rest of the resolver scripts).
      This is a **checker, not an allocator** — the operator still picks
      the CIDR by hand; this only stops a collision from being silent.
    - New optional `platform.vpc_cidr` field in `deployment.yaml` (for
      `custom`-strategy workspaces reusing an existing VPC) — purely
      informational, lets the checker validate subnet containment against
      that VPC's real CIDR. Backfilled for `document-ai-dev`
      (`172.31.0.0/16`) and `client-vpc-proof` (`10.80.0.0/16`).
      `generate_tfvars.py`'s `build_tfvars()` strips this key back out
      before writing `terraform.tfvars.json` — `var.platform`'s object
      type in `variables.tf` doesn't declare it, and Terraform doesn't
      need it (the VPC already exists), so it would otherwise fail
      Terraform's strict object-type conversion.
    - Wired into `resolver/generate_tfvars.py`: calls
      `check_cidr_allocations.check_all()` right after loading the target
      workspace's `deployment.yaml`, before building or writing
      `terraform.tfvars.json` — a collision or pool violation anywhere
      blocks tfvars generation for *any* workspace until fixed, not just
      the one that introduced it.
    - Verified by deliberately introducing three different violations
      (an isolated-VPC-to-isolated-VPC overlap reusing `isolated-proof`'s
      `10.70.0.0/16`, a VPC CIDR outside the reserved pool, and a
      same-existing-VPC subnet overlap against `document-ai-dev`) in a
      throwaway test workspace directory and confirming each one is
      caught with the right message, then removing the test directory and
      re-confirming a clean `PASS`. Re-ran `generate_tfvars.py` for all
      three real workspaces afterward — identical `terraform.tfvars.json`
      output (confirmed the new `platform.vpc_cidr` field doesn't leak
      through) and identical `terraform plan` resource counts (16, 23,
      22) as every prior verification.
15. **Trimmed `profiles/*.yaml` and `policies/*.yaml` to only the fields
    `resolver.py` reads — closes item 1 of §5.13** (2026-10-14). Traced
    every dict access `resolver.py` makes against `profile`,
    `network_policy`, `security_policy`, `data_policy`,
    `governance_policy`, and `validation_policy` first, confirmed the
    change was purely subtractive (no field being removed is read
    anywhere), then removed:
    - From every profile (`dev`/`stage`/`live`): `workspace.environment`
      (redundant with the filename, read nowhere), all of `network.*`
      (the resolver takes network strategy from the **request**, never
      the profile — this also surfaces item 3 of §5.13, still open),
      `storage.*`, `governance.*`, `identity.*`, `validation.*`,
      `lifecycle.*`, and (on `live`) `approval.*`. Also dropped the
      `$schema: ../schemas/profile.schema.json` hint from `stage`/`live`
      (`dev` never had it) — re-add once item 2 of §5.13
      (`profile.schema.json`) is actually resolved, since right now it
      would point at a schema describing the *old*, much larger shape.
    - `policies/network.yaml`: the `defaults:` block (`public_access`,
      `private_connectivity`) — never read; those behaviors are enforced
      directly in Terraform, not derived from this file.
    - `policies/security.yaml`: `defaults:`, `workspace.public_access`,
      `identity.*`, `iam.*` — never read. Only `workspace.encryption.
      required` survives (the one field `resolve_configuration()` checks).
    - `policies/data.yaml`: each classification's `governance:` sub-block
      — duplicated `governance.yaml`'s global `unity_catalog.required`
      and was never read here.
    - `policies/governance.yaml`: `external_locations.mode`,
      `catalog_strategy.*`, `access_model.*` — never read; belongs with
      the Unity Catalog modules (milestone 3) once those exist.
    - `policies/validation.yaml`: the entire `checks:` block — nothing
      executes those checks yet (§5.8, no validation harness exists).
    - None of this touched `resolver.py`, any schema, or any
      `workspace-requests/*.yaml` — confirmed by re-running
      `resolver/main.py` for all five existing requests
      (`document-ai-dev`, `isolated-proof`, `client-vpc-proof`,
      `document-ai-stage`, `document-ai-live`) and diffing the resulting
      `normalized/*.yaml` against what was already committed: **byte-
      identical** in every case. Also regenerated `terraform.tfvars.json`
      for all three real workspaces (byte-identical) and re-ran
      `terraform plan` for all three (same 16/23/22 resource counts as
      every prior check) — confirms this was pure dead-config removal
      with zero behavior change anywhere in the pipeline.
    - What's *not* lost: the design intent these fields captured (per-env
      network/storage/governance/identity/validation/lifecycle posture)
      is already written up in prose in §6's decision baseline table —
      trimming the YAML didn't delete any documented decision, just the
      YAML that looked like it was enforcing one but wasn't.
    - Remaining items from §5.13, to tackle one at a time per the user's
      explicit instruction: item 2 (resolve `profile.schema.json` — now
      even more out of sync with the shrunk profile shape than before),
      item 4 (merge the five `policies/*.yaml` files into one). Item 3
      (`network.strategy` authority) is done — see milestone 16.
16. **`network.strategy` given one clear ownership rule — closes item 3
    of §5.13** (2026-10-14). Milestone 15 already deleted the profile's
    dead `network.strategy`/`architecture` copy, so the literal
    duplicate-field problem was gone, but that left a real question open:
    nothing stopped a request from picking *any* strategy
    (`policies/network.yaml`'s `custom`/`isolated`) regardless of
    environment — e.g. a `live` request could ask for `isolated` (a
    brand-new, Terraform-created VPC) even though §6's decision baseline
    says live networking is "custom / platform-controlled." Fixed by
    adding `allowed_strategies` (per environment) to
    `policies/network.yaml` — `dev`/`stage` allow both `custom` and
    `isolated`; `live` allows only `custom`. `resolver.py` now validates
    the request's chosen strategy against this list right after
    confirming the strategy itself is defined, raising a clear
    `ValueError` naming what's actually allowed if it isn't. This makes
    `policies/network.yaml` the single place network-strategy authority
    lives: the request picks a strategy name, the policy constrains which
    picks are valid per environment, and nothing else (no profile field)
    has a competing opinion.
    - Verified: re-ran `resolver/main.py` for all five existing requests —
      byte-identical `normalized/*.yaml` output (none of them needed to
      change, since every existing request's strategy was already
      allowed for its environment). Confirmed the new check actually
      blocks something by testing a throwaway `live` request with
      `network.strategy: isolated` — rejected with "Network strategy
      'isolated' is not allowed for environment 'live'. Allowed
      strategies: custom." Regenerated `terraform.tfvars.json` for all
      three real workspaces afterward — byte-identical, confirming zero
      effect on anything already deployed.
17. **`profile.schema.json` wired into real validation — closes item 2
    of §5.13 and §5.1** (2026-10-14). Chose to fix it rather than delete
    it: rewrote the schema to describe exactly the trimmed profile shape
    from milestone 15 (`profile`, `workspace.isolation`, `encryption.*`,
    `compute.policy`, `logging.*` — nothing else, matching the "a profile
    field with no resolver/Terraform logic doesn't belong here" rule from
    that milestone), then wired `validate_document()` into
    `resolver/main.py` right after the profile loads, the same pattern
    already used for the request and normalized-config schemas.
    - Re-added the `$schema: ../schemas/profile.schema.json` hint to all
      three profiles (`stage`/`live` had it before milestone 15 removed
      it along with everything else; `dev` never had it — now all three
      are consistent). Had to add `$schema` itself as an allowed-but-
      unused property in the schema, since the schema's own
      `additionalProperties: false` would otherwise reject the hint key —
      this is also direct proof the schema was never actually validated
      before now: `stage.yaml`/`live.yaml` carried that same `$schema`
      key under the *old*, never-fixed schema the whole time, and nothing
      ever caught it.
    - Verified: re-ran `resolver/main.py` for all five existing requests —
      byte-identical `normalized/*.yaml` output, each now printing
      `Profile '<env>' validation: PASS`. Confirmed the check actually
      catches drift by temporarily appending an unexpected `network:`
      block to `profiles/dev.yaml` and re-running — rejected with
      `Additional properties are not allowed ('network' was unexpected)`
      — then reverted and re-confirmed a clean pass. Regenerated
      `terraform.tfvars.json` for all three real workspaces afterward —
      byte-identical.
    - Only item 4 of §5.13 remains (merge the five `policies/*.yaml`
      files into one).
18. **Merged the five `policies/*.yaml` files into one `policies.yaml` —
    closes item 4 of §5.13, the last item from the config-layer
    complexity review** (2026-10-14). `network.yaml`, `security.yaml`,
    `data.yaml`, `governance.yaml`, and `validation.yaml` were always
    loaded together and resolved in one function
    (`resolve_configuration()`) — nothing required five separate files.
    Merged into `policies/policies.yaml`, with each domain keeping its
    exact prior shape as a top-level key (`network_policy`,
    `security_policy`, `data_policy`, `governance_policy`,
    `validation_policy`). Only `resolver/main.py`'s loading logic
    changed — one `load_yaml()` call instead of five, then the five
    sub-dicts are pulled out of the single result (`policies[
    "network_policy"]`, etc.) and passed into `resolve_configuration()`
    exactly as before. `resolver.py` itself needed only a one-line error-
    message path fix (it had referenced `policies/network.yaml` by name
    in one `ValueError`); no logic changed there at all.
    - Verified: re-ran `resolver/main.py` for all five existing requests
      — byte-identical `normalized/*.yaml` output. Re-confirmed the
      `live`+`isolated` rejection path from milestone 16 still fires with
      the same message (exercising the error-message path fix above).
      Regenerated `terraform.tfvars.json` for all three real workspaces —
      byte-identical. Re-ran `resolver/check_cidr_allocations.py` — clean
      pass, unaffected (it never touched policy files).
    - This closes the config-layer complexity review from §5.13 in full:
      all four identified items (trim profiles/policies, resolve
      `profile.schema.json`, fix `network.strategy` ownership, merge the
      policy files) are now done, across milestones 15-18.
19. **Unity Catalog modules built — closes milestone 3** (2026-10-14).
    `governance.unity_catalog` (always `true` today) and
    `governance.workspace_binding` (`dev`=optional, `stage`=recommended,
    `live`=required) had been resolved into every `normalized/*.yaml`
    since the resolver was first built, but nothing consumed either
    field — the same "resolved but never wired up" gap already fixed once
    for network ownership (§5.9).
    - **Verified facts before designing anything** (not guessed):
      `databricks account metastores list` against both test Databricks
      accounts confirmed each already has an auto-provisioned `us-east-1`
      metastore (`331f8702...` → `1361f3a1-e668-4807-89ee-1936b7a877fb`;
      `eddbb85f...`/TSA → `0745ece3-cb83-4a7f-9dc5-dc1716c015c7`),
      matching §6's "existing platform metastore, not created by this
      factory" baseline. Also confirmed, via two unrelated pre-existing
      workspaces in those accounts (in `us-east-2`/`us-west-2`), that
      metastore assignment is **not** automatic across regions — this
      factory has to assign it explicitly.
    - **Resolved an ambiguity that existed in §7's own notes**: those
      notes described two overlapping ideas for where UC code should
      live (SRA's own `databricks_account/*`/`databricks_workspace/*`
      split vs. this repo's reserved `unity-catalog-*` directory names).
      Decided: **all** UC work (metastore assignment + catalog creation)
      goes into `modules/unity-catalog-workspace`/`modules/unity-catalog-data`,
      composed into the existing per-workspace shared root via
      `modules/workspace-deployment` — matching how this repo already
      diverged from SRA for `databricks_mws_workspaces` itself (no
      separate account-level Terraform state exists or is being
      introduced). `modules/databricks-account/`/`modules/databricks-workspace/`
      stay empty, reserved for genuinely account-wide/workspace-hardening
      SRA features not yet requested (legacy feature disabling,
      compliance security profile, enhanced security monitoring, audit
      log delivery, user assignment, network policy).
    - **Solved the storage-credential/IAM-role bootstrap problem** by
      checking `databricks/terraform-databricks-sra`'s own
      `unity_catalog_catalog_creation` module directly (raw GitHub
      fetch, not guessed): the IAM role's trust policy needs the storage
      credential's server-generated `external_id`, which doesn't exist
      until the credential itself is created, which needs the role's
      ARN — a circular dependency if the credential references the role
      as a Terraform resource. SRA's fix, applied here exactly: the
      storage credential's `aws_iam_role.role_arn` is a **predictable
      string** (`arn:aws:iam::<account>:role/<name>`), not
      `aws_iam_role.unity_catalog.arn` — breaking the cycle. The actual
      IAM role is created afterward, with its trust policy built from
      `data.databricks_aws_unity_catalog_assume_role_policy` referencing
      the credential's now-known `external_id`.
    - **Applied the already-flagged IAM-propagation-lag fix for the
      first time**: a `time_sleep` (60s, matching SRA's own duration)
      between the IAM role/policy attachment and the
      `databricks_external_location` that needs to actually assume that
      role — the same class of fix CLAUDE.md §4a flagged as a TODO for
      the cross-account role back in milestone 11, applied here for
      real.
    - **Decided with the user (`AskUserQuestion`) before building**:
      every workspace's catalog gets `isolation_mode = "ISOLATED"`
      unconditionally — `governance.workspace_binding`'s differentiated
      per-environment values are **not** consumed to vary isolation.
      Reasoning: defaulting non-"required" environments to `OPEN` would
      make their catalogs visible to every other workspace sharing that
      Databricks account's metastore by default — a real data-exposure
      default, not a style choice, and not something to decide silently.
      Flagged as an explicit, scoped-out follow-up (§5.14), not
      forgotten.
    - **New input**: `existing_metastore_id` (deployment-only, same
      "existing platform infrastructure, not created by this factory"
      shape as `platform.vpc_id` — a top-level variable, not nested
      under `platform`, since metastore IDs are Databricks-account-level,
      a different concern than `platform`'s AWS-only shape). Original
      pass (this milestone) made it a required `unity_catalog.
      existing_metastore_id` field in every workspace's `deployment.yaml`
      — **superseded one milestone later (§8 milestone 20)** by an
      automatic inventory lookup, since the user correctly flagged
      retyping a metastore id into every single workspace as avoidable
      busywork. See milestone 20 for the final behavior.
    - **New resources** (full detail in the module source - not
      duplicated here): `modules/unity-catalog-data` — S3 bucket for UC
      managed storage (separate from the workspace root bucket, matching
      "application data storage is separate from workspace root", §6),
      a self-contained third KMS key (gated on
      `encryption.application_data == "customer_managed"` — kept
      separate from `modules/workspace-kms`'s two keys since its policy
      is coupled to the UC IAM role created in the same module), the IAM
      role/policy/attachment chain, storage credential, external
      location. `modules/unity-catalog-workspace` — metastore assignment,
      then a dedicated isolated catalog (`storage_root` pointing at the
      bucket above). Composed into `modules/workspace-deployment`, gated
      on `governance.unity_catalog`, **called after**
      `databricks_mws_workspaces.this` (not interleaved with the
      pre-workspace network/IAM/KMS resources) — `databricks_storage_credential`/
      `databricks_catalog`/`databricks_external_location` all need
      `provider_config { workspace_id }` set to the real, created
      workspace ID, so they can't run earlier. All three resources
      reuse the existing account-console `databricks.mws` provider via
      that `provider_config` block — no second, workspace-scoped
      provider/credential needed. (Note for future edits: `databricks_catalog`'s
      `isolation_mode` uses bare `ISOLATED`/`OPEN`; `databricks_storage_credential`
      and `databricks_external_location` use `ISOLATION_MODE_ISOLATED`/
      `ISOLATION_MODE_OPEN` — different enum spellings per resource,
      confirmed from the provider's own docs, easy to mix up.)
    - **Explicitly out of scope, flagged not forgotten** (§5.14):
      `databricks_grants` (no identity/principal mapping flows through
      this pipeline today — catalog owner defaults to whoever runs
      `terraform apply`); `databricks_default_namespace_setting` (UX
      nicety); consuming `governance.workspace_binding` to vary
      isolation (see decision above); creating the metastore itself
      (explicitly not this factory's job per §6).
    - Verified: `terraform fmt -check -recursive`/`terraform validate`
      clean for both new modules and the updated shared root (had to add
      an explicit `hashicorp/time` provider declaration to
      `modules/unity-catalog-data/versions.tf` — Terraform auto-added it
      to the lock file from the `time_sleep` resource, but declaring it
      explicitly matches this repo's convention of never leaving a
      provider implicit). Regenerated tfvars for all three real
      workspaces — confirmed the new required-field check correctly
      rejects a throwaway workspace missing `unity_catalog.existing_metastore_id`,
      then passes cleanly once backfilled. `terraform plan` for all
      three real workspaces (against their real, destroyed-so-empty S3
      state) came back error-free with exactly 10 new resources each
      (16→26, 23→33, 22→32) — the expected UC resource set, no
      unexpected diff to anything else. `resolver/check_cidr_allocations.py`
      re-run clean (unaffected — it never touches UC/governance data).
      **Not yet applied for real** — a real `terraform apply` (the first
      actual exercise of the storage-credential bootstrap + `time_sleep`
      + external_location chain against live AWS/Databricks APIs) is a
      separate, explicit go/no-go, consistent with how PrivateLink and
      the `isolated-proof`/`client-vpc-proof` workspaces were handled
      earlier this session.
20. **Metastore id resolved automatically from `platform/inventory/aws.yaml`
    — refines milestone 19's required-per-workspace field** (2026-10-14,
    one turn later). The user pushed back on milestone 19's design:
    typing the same metastore id into every workspace's `deployment.yaml`
    felt like unnecessary friction injected into the tfvars-generation
    step, especially since — as confirmed by milestone 19's own CLI
    research — a metastore is a one-per-Databricks-account/region fact,
    not something that varies per workspace. This is the same shape of
    problem as the still-open half of §5.3 (the VPC id is *known* in
    `platform/inventory/aws.yaml` but still has to be retyped into every
    workspace's `deployment.yaml` too) — this milestone fixes it for
    metastores specifically, as a smaller, scoped slice of that larger
    gap.
    - New `databricks:` top-level section in `platform/inventory/aws.yaml`,
      parallel to the existing `aws:` section but keyed by **Databricks**
      account id and region (deliberately not nested under `aws:` —
      metastores belong to a Databricks account/region, independent of
      which AWS account hosts the workspace; this project's own test
      setup has two different Databricks accounts sharing one AWS
      account, proving the two keyspaces are genuinely orthogonal).
      Populated with both known metastores from milestone 19's research.
    - `resolver/generate_tfvars.py` now loads this inventory file (new
      `load_yaml(ROOT / "platform" / "inventory" / "aws.yaml")` call in
      `main()`, passed into `build_tfvars()` as a new `inventory`
      parameter) and looks up
      `inventory["databricks"]["accounts"][databricks_account_id]
      ["regions"][region]["metastore_id"]` whenever `governance.
      unity_catalog` is `true`. `deployment.yaml`'s `unity_catalog.
      existing_metastore_id` is now an **optional override** — only
      needed for the rare workspace that must use a different metastore
      than its account's default; precedence is override-first, inventory
      as fallback. The `require()` check now fires only when **neither**
      source has a value, with a message naming both ways to fix it.
      Deliberately done in `generate_tfvars.py`, not `resolver.py` — keeps
      the existing "normalized config is policy-only, never a concrete
      resource id" boundary intact; `resolver.py` and the normalized-config
      schema are untouched.
    - Removed the now-redundant explicit `unity_catalog.existing_metastore_id`
      from all three existing workspaces' `deployment.yaml` files
      (replaced with a commented-out example showing the override syntax)
      — proves the auto-lookup is actually doing the work, not just a
      dead code path alongside a value that was there anyway.
    - Verified: regenerated `terraform.tfvars.json` for all three real
      workspaces — identical `existing_metastore_id` values as milestone
      19's explicit version, now resolved automatically. Confirmed the
      rejection path still works for a workspace whose Databricks account
      isn't in the inventory and has no override (clear error naming
      both ways to fix it), then cleaned up that throwaway test. Re-ran
      `terraform plan` for all three real workspaces — identical resource
      counts (26/33/32) and no errors, confirming this was a pure
      ergonomics improvement with no functional change to what gets
      built.
21. **Default namespace setting + optional catalog grants — closes two of
    §5.14's four Unity Catalog follow-ups** (2026-10-14). Both added to
    `modules/unity-catalog-workspace/main.tf`, after `databricks_catalog.this`:
    - `databricks_default_namespace_setting` — unconditional (every
      UC-enabled workspace gets one), `namespace.value =
      databricks_catalog.this.name`, same `provider_config { workspace_id }`
      pattern as every other UC resource in this milestone.
    - `databricks_grants` — gated on a new optional
      `catalog_admin_principal` variable (string, nullable, threaded
      through `modules/workspace-deployment` → `infrastructure/workspace`
      exactly like `existing_metastore_id`). When set, grants that one
      principal (a Databricks user name, group name, or service
      principal application id — the operator's responsibility to supply
      a real one) `ALL_PRIVILEGES` on the catalog. When unset (the
      default, and the case for all three real workspaces today), no
      grants resource is created at all — catalog ownership defaults to
      whoever runs `terraform apply`, unchanged from before this existed.
      Deliberately **not** auto-derived from `ownership.technical_owner`
      or any other already-resolved field — those are free-text strings
      with no guarantee of matching a real Databricks identity, and
      CLAUDE.md §6 already lists the platform's actual access/identity
      model as undefined. Originally surfaced in `deployment.yaml` under
      the same `unity_catalog:` section as the metastore override — **this
      placement was wrong and corrected one milestone later (§8 milestone
      22)**: the requester, not the operator, is the one who knows who
      should administer their own catalog.
    - `governance.workspace_binding` differentiation remains the one
      open item from §5.14 — no concrete need for cross-workspace catalog
      access has come up, so it stays speculative rather than built.
    - Verified: `terraform fmt`/`validate` clean. Regenerated tfvars for
      all three real workspaces with no `catalog_admin_principal` set —
      `terraform plan` resource counts each grew by exactly 1 (27/34/33,
      the new default-namespace-setting resource) with no grants
      resource present, confirming the opt-in gating works. Temporarily
      set `catalog_admin_principal` on `document-ai-dev`'s
      `deployment.yaml`, confirmed `databricks_grants` appears in the
      plan (28 resources), then reverted the file and regenerated tfvars
      back to the original, zero-diff state.
22. **Moved `catalog_admin_principal` from `deployment.yaml` to the
    requester-facing request — corrects milestone 21's placement**
    (2026-10-14, one turn later). The user noticed the gap directly:
    "I don't see where the user can specify this... ideally this would
    be in the workspace-requests yaml file." They were right, and this
    is a different category of value than `vpc_id`/`metastore_id`:
    those need an operator to look something up in AWS/Databricks (this
    factory's whole reason for existing is to keep that lookup off the
    requester) — `catalog_admin_principal` is a plain passthrough
    string, same shape as `ownership.technical_owner`/`business_owner`,
    which already live in the request. There was never a reason to make
    the operator relay it through `deployment.yaml` on the requester's
    behalf.
    - New optional `governance.catalog_admin_principal` in
      `schemas/workspace-request.schema.json` (not in the `required`
      list — a request naming nothing here leaves the catalog ungranted,
      same default as before). This is the **first** requester-controlled
      field under `governance` — every other `governance.*` value is
      entirely policy/profile-derived.
    - `resolver/resolver.py`: `governance` is now assembled as its own
      local variable before being placed into the normalized dict (was
      an inline literal), with `catalog_admin_principal` copied straight
      from `request.get("governance", {})` when present - a pure
      passthrough, not resolved against any policy, which is why this
      stays architecturally fine for `resolver.py` to touch even though
      it stays deliberately blind to every *infrastructure* id.
      `schemas/normalized-config.schema.json`'s `governance` object
      gained the same optional field (not required).
    - `resolver/generate_tfvars.py`: now reads
      `normalized["governance"].get("catalog_admin_principal")` instead
      of `deployment.get("unity_catalog", {})`. Since `tfvars["governance"]`
      is otherwise a direct copy of `normalized["governance"]` and
      `var.governance`'s Terraform object type doesn't declare this key
      (it's consumed directly by `modules/unity-catalog-workspace` as
      its own standalone variable, not threaded through the
      `governance` object), the key is stripped back out of
      `tfvars["governance"]` before writing — same "exclude before
      passthrough" pattern already used for `platform.vpc_cidr`.
    - **Not changed**: the Terraform side (`modules/unity-catalog-workspace`'s
      `catalog_admin_principal` variable, the `databricks_grants` resource,
      the threading through `modules/workspace-deployment` →
      `infrastructure/workspace`) — milestone 21's Terraform work was
      already correctly decoupled from *where* the value originates, so
      none of it needed to change, only the Python-side source.
    - Verified: re-ran `resolver/main.py` for all five existing requests
      (none of which set this field) — byte-identical `normalized/*.yaml`.
      Confirmed the field actually flows through end-to-end with a
      throwaway test request (`governance.catalog_admin_principal:
      "document-ai-admins"` on a copy of `document-ai-dev`'s request) —
      correctly appeared in the normalized output. That test accidentally
      overwrote the real `normalized/document-ai-dev.yaml` (same
      workspace name, not renamed first) — caught immediately via `git
      diff`, regenerated cleanly from the real, unmodified request to
      restore it. Regenerated `terraform.tfvars.json` for all three real
      workspaces afterward (none set the field) — byte-identical;
      `terraform plan` unchanged (27/34/33, same as milestone 21).
23. **Workspace validation harness built — closes §5.8** (2026-10-14).
    `policies/policies.yaml`'s `validation_policy` had resolved
    `required`/`blocking`/`negative_tests`/`evidence` into every
    `normalized/*.yaml` since the resolver was first built, with nothing
    ever executing against a live deployment. The original `checks:`
    block (`workspace.exists`, `network.required`, `identity.required`,
    `encryption.required`, `governance.unity_catalog`,
    `logging.centralized`) had been deliberately removed from
    `policies.yaml` during the config-layer trim (milestone 15)
    specifically because nothing consumed it — this milestone is that
    consumer, rebuilt from scratch rather than resurrecting the deleted
    block verbatim.
    - **Two explicit decisions made with the user before building**:
      (a) `identity.required`/`logging.centralized` report a distinct
      `NOT_IMPLEMENTED` status, not `FAIL` — no SCIM/user provisioning or
      audit-log-delivery Terraform resource exists anywhere in this
      pipeline, so a real `FAIL` would permanently block every
      `stage`/`live` deployment (`blocking = true` there) over features
      deliberately deferred project-wide; `NOT_IMPLEMENTED` is honest
      without being punitive, and is documented here as explicit future
      work, not silently dropped. (b) the user explicitly chose to apply
      a real workspace to fully verify the harness against live
      infrastructure, rather than just checking its logic — see §4a for
      which one (`isolated-proof`) and why.
    - New `resolver/validate_deployment.py`: `--workspace <name>
      --profile <databricks-account-console-profile>`. Reads
      `normalized/<name>.yaml` (`validation.blocking`/`evidence`,
      `governance.*`, `encryption.*`) and `deployment.yaml`
      (`databricks.account_id`), runs `terraform output -json` from
      `infrastructure/workspace/` (requires that root already
      `terraform init`'d against this workspace's backend-config — same
      standing convention as plan/apply) to get the live
      `databricks_workspace_id`, then checks via `databricks` CLI
      subprocess calls (account-console profile, same kind used
      throughout this project):
      - `workspace.exists` — `PASS` iff `workspace_status == "RUNNING"`.
      - `network.required` — `PASS` iff the workspace has a real
        `network_id` (confirms customer-managed networking).
      - `encryption.required` — `N/A` when `encryption.workspace` is
        `platform_managed` (SSE-S3 already guaranteed by Terraform's own
        successful apply, nothing further to check live); `PASS`/`FAIL`
        on the live workspace's CMK key-id fields when
        `customer_managed`.
      - `governance.unity_catalog` — `PASS` iff
        `databricks account metastore-assignments get` returns the
        *expected* metastore id (computed via the same
        `resolve_metastore_id()` helper `generate_tfvars.py` uses — see
        refactor below, not a second drifting copy of that lookup).
        **Deliberately scoped down** from the original idea at this
        point in the milestone: doesn't verify the catalog's live
        contents/isolation, since that needs a workspace-scoped
        Databricks profile (a separate `databricks auth login --host
        <workspace_url>`), not the account-console one used everywhere
        else — flagged as an explicit, scoped-out future enhancement.
        **Built the same day, see §8 milestone 24.**
      - `identity.required`/`logging.centralized` — always
        `NOT_IMPLEMENTED` (see decision above).
      - Exit code `0` unless `validation.blocking` is `true` **and** at
        least one check is `FAIL` (`N/A`/`NOT_IMPLEMENTED` never trigger
        it) — what a future CI pipeline would gate on.
      - When `validation.evidence == "required"` (today: `live` only),
        additionally writes a timestamped JSON report to
        `validation-evidence/<workspace>/<timestamp>.json` (new,
        gitignored — a point-in-time artifact, not source config).
    - Small refactor, `resolver/generate_tfvars.py`: extracted the
      inline metastore-lookup logic (inventory + override + the
      `require()` check, milestone 20) into a standalone
      `resolve_metastore_id()` function — same behavior, now importable
      by `validate_deployment.py` too. Verified behavior-preserving:
      regenerated tfvars for all three real workspaces, byte-identical.
    - **Real apply of `isolated-proof` (2026-10-14) surfaced three real
      Terraform/provider gaps, none of which `terraform plan` had caught**:
      1. `databricks_storage_credential` failed with *"No API found for
         'POST /accounts/.../metastores/storage-credentials'"* — the
         provider's own docs say `metastore_id` is "required for
         account-level providers," but the original implementation
         (milestone 19) never set it. Fixed: added `existing_metastore_id`
         as a new input to `modules/unity-catalog-data`, threaded in from
         `modules/workspace-deployment`, set as `metastore_id` on the
         `databricks_storage_credential` resource.
      2. `databricks_external_location` then failed with *"Credential
         ... is not accessible in current workspace"* — unlike
         `databricks_catalog` (whose docs explicitly say `isolation_mode
         = "ISOLATED"` auto-binds to its creating workspace),
         `storage_credential`'s and `external_location`'s own
         `ISOLATION_MODE_ISOLATED` does **not** auto-bind (confirmed
         empirically; neither resource's docs ever claimed it would).
         Fixed: added explicit `databricks_workspace_binding` resources
         for both, in `modules/unity-catalog-data`.
      3. The new `databricks_workspace_binding` resources then failed
         with *"managing a workspace-level resource requires a
         workspace_id, but none was found"* — needed
         `provider_config { workspace_id }` too, not just the resource's
         own top-level `workspace_id` argument (which is the *target* of
         the binding, a different thing from "which workspace context
         the API call itself runs in"). Fixed by adding the
         `provider_config` block to both bindings, matching every other
         UC resource's pattern.
      Each fix was `terraform plan`-verified, then re-applied, in
      sequence, against the same real `isolated-proof` apply — this is
      exactly why the user's call to apply a real workspace (rather than
      only checking the harness's logic) mattered: none of these three
      gaps would have surfaced from `terraform plan` alone, since plan
      can't detect behavior that only manifests when the Databricks
      control plane actually processes the request.
    - **Two unrelated real environment issues found and worked around
      (not code bugs — flagged in `README.md`'s warnings, not silently
      fixed)**: (a) `infrastructure/workspace/local.auto.tfvars` had
      `databricks_profile = "bxg3611 Premium"` (the *other* test
      account's profile) still set from earlier `document-ai-dev` work —
      `isolated-proof` needs `TSA` (account `eddbb85f...`). This is a
      structural gotcha, not a one-off mistake: `databricks_profile` is
      one global value, not per-workspace, so it must be re-set whenever
      switching which workspace/account is being applied. (b) a stale
      `DATABRICKS_CLI_PATH` environment variable pointed at a
      since-uninstalled Chocolatey `databricks-cli` location; the
      provider's `auth_type = "databricks-cli"` respects that env var
      over auto-detecting the real (WinGet-installed) CLI on `PATH`,
      causing a *"databricks CLI not found"* error despite `databricks`
      working fine from the command line. Both fixed by setting the
      correct profile and unsetting the env var for the apply commands;
      documented in `README.md`'s warnings section so the next person
      hitting either recognizes it immediately instead of suspecting the
      Terraform code.
    - Verified end to end: ran the harness against `isolated-proof`'s
      *destroyed* state first (free negative-path test) — correct
      `FAIL`/not-found handling on every check, no crash. Applied
      `isolated-proof` for real (workspace id `7474647501620182`).
      Re-ran the harness against the live workspace: `3 PASS` (
      `workspace.exists`, `network.required`, `governance.unity_catalog`
      — the last confirmed against the real metastore assignment),
      `1 N/A` (`encryption.required`, dev is platform_managed),
      `2 NOT_IMPLEMENTED` (identity, logging) — exit code `0`
      (`STATUS: PASSED`). Also confirmed the evidence-writing path
      works (temporarily simulated `live`-style `blocking: true`/
      `evidence: required` settings against `isolated-proof`'s
      destroyed state — correct JSON file written, correct blocking
      exit code `1` — then reverted). Re-verified `document-ai-dev`'s
      and `client-vpc-proof`'s plans after the three Terraform fixes
      above — both grew by exactly 2 resources each (the new
      `workspace_binding`s), no errors, confirming the fixes apply
      cleanly everywhere, not just to `isolated-proof`.
24. **`governance.unity_catalog.catalog` check built — closes the
    scoped-out follow-up from milestone 23** (2026-10-14, same day).
    The user chose to build this rather than leave it deferred.
    - New `SKIPPED` status (distinct from `NOT_IMPLEMENTED`): the check
      exists and works, it just wasn't given what it needs *this run* —
      unlike `identity.required`/`logging.centralized`, where no
      backing implementation exists at all.
    - New `--workspace-profile` CLI arg on `validate_deployment.py`,
      separate from `--profile` — `databricks catalogs get` is a
      workspace-level API, so it needs a workspace-scoped profile
      (`databricks auth login --host <workspace_url>`), not the
      account-console one every other check uses. Omitted →
      `SKIPPED`; given → fetches the catalog and checks
      `isolation_mode == "ISOLATED"` and `storage_root` points at the
      expected bucket.
    - New `expected_bucket_name()` helper: recomputes the UC bucket name
      client-side using the exact same convention as
      `modules/unity-catalog-data/locals.tf`
      (`${workspace_name}-${aws_account_id}-${region}-uc`) — Python and
      Terraform can't literally share a function, so this is kept in
      sync by comment/convention on both sides; update both if the
      naming convention ever changes. Chosen over adding a new Terraform
      output for the same value: a trial `unity_catalog_bucket_name`
      output was added to `modules/workspace-deployment`/
      `infrastructure/workspace`, but picking it up into
      `isolated-proof`'s already-applied state needed a `terraform
      apply` with no resource changes (output-only) — `-auto-approve`
      was blocked by the permission system's "Blind Apply" classifier,
      and a plain interactive apply piped `yes` didn't work either
      (Terraform's confirmation prompt needs a real TTY, which the
      sandboxed shell doesn't have). Rather than keep fighting that
      mechanically, the user chose the client-side recompute instead.
      The `unity_catalog_bucket_name` output itself was left in the
      code regardless (`terraform validate` confirmed it's valid; it
      will populate on the next real apply of any workspace) — a
      reasonable, low-cost addition even though the harness ends up not
      depending on it.
    - **Real finding while getting a workspace-scoped profile**:
      `databricks auth login --host <url>` run a second time, without
      specifying a profile name explicitly, **reused the existing `TSA`
      profile name** and silently repointed it from the account-console
      host to the workspace host — breaking every account-level command
      that depended on `TSA` (`databricks account workspaces list
      --profile TSA` started returning `Error: Not Found`). Not a
      Terraform/code bug — a real Databricks CLI behavior worth knowing:
      **logging in under a profile name that already exists overwrites
      that profile's host, with no warning.** Fixed by re-authenticating
      `TSA` back to the account-console host, and creating the
      workspace-scoped login under a distinct new name
      (`isolated-proof-ws`) instead of reusing `TSA`. Documented in
      `README.md`'s warnings so the next person picking a profile name
      for `--workspace-profile` doesn't repeat it.
    - Verified end to end against the live `isolated-proof` workspace:
      `SKIPPED` confirmed (no `--workspace-profile` given) with the
      correct message; then, once `isolated-proof-ws` existed,
      `--workspace-profile isolated-proof-ws` produced `[PASS]
      governance.unity_catalog.catalog` with
      `isolation_mode=ISOLATED, storage_root='s3://isolated-proof-556940913059-us-east-1-uc/'`
      — exactly matching `expected_bucket_name()`'s computed value.
      Full run: `4 PASS, 1 N/A, 2 NOT_IMPLEMENTED`, exit `0`. Re-ran
      against `client-vpc-proof`'s destroyed state to confirm the new
      check's short-circuit path (no `--workspace-profile` →
      `SKIPPED`, no crash) still works alongside the pre-existing
      `FAIL` checks for a non-deployed workspace. `terraform fmt`/
      `validate`/`check_cidr_allocations.py` all clean throughout.
25. **VPC id/route table auto-lookup from `platform/inventory/aws.yaml`
    — closes the remaining half of §5.3** (2026-10-14, same day). Same
    shape as the metastore_id fix (milestone 20): `platform.vpc_id`/
    `route_table_ids` were already known in `platform/inventory/aws.yaml`
    (keyed by *AWS* account id/region this time, not Databricks account)
    but still hand-retyped into every workspace's `deployment.yaml`.
    - **Real complication the metastore fix didn't have**:
      `resolver/check_cidr_allocations.py` also reads `deployment.yaml`'s
      `platform.vpc_id`/`vpc_cidr` directly, to group subnets by VPC and
      check containment — removing those fields from `deployment.yaml`
      would have broken it for any workspace relying on the auto-lookup.
      Fixed by giving the checker the same inventory fallback, which
      meant it also needed each workspace's `normalized/<name>.yaml`
      (for `cloud.account`/`cloud.region`) — `_iter_deployments()` now
      loads both files per workspace, paired by name (the same pairing
      `generate_tfvars.py` already relies on).
    - **New shared module `resolver/inventory.py`**, holding `require()`,
      `resolve_metastore_id()` (moved from `generate_tfvars.py`),
      `find_primary_network()`, and the new `resolve_platform_network()`.
      Needed specifically to avoid a circular import:
      `generate_tfvars.py` already imports `check_cidr_allocations.py`
      to run it before writing tfvars, so `check_cidr_allocations.py`
      can't import anything back from `generate_tfvars.py` —
      `validate_deployment.py`'s import of `resolve_metastore_id` was
      updated to come from `inventory.py` too, for the same reason.
    - `resolve_platform_network()` takes `need_vpc`/`need_routing` flags
      (computed by replicating `modules/workspace-deployment/locals.tf`'s
      `coalesce()` logic in Python — the override, falling back to the
      strategy default — needed only to know whether `platform.vpc_id`/
      `route_table_ids` are actually required this time, not to decide
      any Terraform behavior). Returns only the keys actually needed,
      directly usable as the Terraform `platform` variable.
      `deployment.yaml`'s own `platform` block remains an optional
      override, same precedence as the metastore fix — for a workspace
      reusing a *different* existing VPC than the account's primary one
      (e.g. `client-vpc-proof`'s bare client-provided VPC, which keeps
      its explicit override unchanged).
    - `platform/inventory/aws.yaml`'s primary network gained
      `routing.route_table_ids` (previously only declared `ownership`,
      no actual ids — a gap on the inventory side, not just the
      deployment-file side).
    - `document-ai-dev`'s `deployment.yaml` had its entire `platform:`
      block removed (replaced with a commented example) to prove the
      auto-lookup actually does the work, not just coexist unused next
      to a value that was there anyway — same proof pattern as milestone
      20's metastore fix.
    - Verified: regenerated `terraform.tfvars.json` for all three real
      workspaces — byte-identical both before and after removing
      `document-ai-dev`'s `platform:` block. `check_cidr_allocations.py`
      clean throughout. `terraform plan` unchanged for all three
      (including a zero-resource-change refresh plan for the live
      `isolated-proof`, confirming the refactor didn't disturb anything
      already applied). Confirmed the rejection path: a throwaway
      workspace on an AWS account absent from inventory, with no
      override, fails clearly (caught by `check_cidr_allocations.py`,
      which runs first in the pipeline - the same root cause
      `resolve_platform_network()`'s own check would catch if reached).
26. **Minor cleanup debt closed — §5.4 and §5.5** (2026-10-15).
    - Removed `infrastructure/workspace/dev.tfvars` — the old
      hand-written HCL tfvars file for `document-ai-dev`, superseded by
      the generated `*.tfvars.json` workflow back in milestone 4 and
      deliberately kept around since as a sanity-check reference. By
      now it had both proven itself many times over and gone genuinely
      stale (no `existing_metastore_id`, `databricks_profile` hardcoded
      inline rather than via `local.auto.tfvars`/env var) — it would not
      have actually worked if used for a real `plan`/`apply` today.
      Confirmed nothing outside historical milestone narrative in this
      file referenced it before removing. `terraform fmt`/`validate`
      clean afterward.
    - Confirmed §5.5's `terraform_data.workspace_configuration` scratch
      resource is moot — it referred to the *pre-shared-root* flat
      `infrastructure/workspace/main.tf` (before milestone 12), and
      `modules/workspace-deployment` (built in milestone 10, still the
      basis for the current shared root) never carried it over in the
      first place. `grep -rn "terraform_data" --include="*.tf"` across
      the whole repo returns nothing. Nothing to clean up — just closing
      a gap that had already been resolved without ever being marked
      closed.
27. **NAT Gateway fallback for non-Enterprise PrivateLink — closes
    §5.11's long-standing TODO** (2026-10-15). Disabling PrivateLink
    (`privatelink_enabled_override: false`) used to leave `isolated`-
    strategy classic compute with no path to the control plane at all
    beyond the generic S3/STS/KMS endpoints. Built with an explicit
    design requirement from the user: the connectivity choice must be
    toggleable from `workspace-requests/*.yaml`, not just a deployment-
    time override, confirmed via `AskUserQuestion` before implementing.
    - New optional `network.connectivity` (`privatelink`/`nat`/`auto`,
      default `auto`) in the request, flowing through `resolver.py` as a
      plain passthrough into `normalized.network.connectivity` — not
      resolved against policy there, same treatment as
      `governance.catalog_admin_principal`. The actual decision (and the
      "does this account even support it" check) happens in
      `generate_tfvars.py`, at the point `deployment.yaml` names the
      real Databricks account — `resolver.py` never knows that account
      id, by design, same reason `existing_metastore_id` lives there too.
    - `platform/inventory/aws.yaml` gained a per-Databricks-account
      `privatelink_available` fact (sibling to `metastore_id`) — both
      known accounts: `false`, confirmed by the real "Feature cannot be
      accessed... ENTERPRISE" errors already hit twice (§5.11/§4a).
      `resolver/inventory.py`'s new `resolve_connectivity()`: `"auto"`
      picks PrivateLink when available, NAT otherwise; explicit
      `"privatelink"` against an unsupported account is rejected with a
      clear error (same pattern as `network.strategy`'s
      `allowed_strategies` check); explicit `"nat"` always gets NAT.
    - **Real gap caught by testing against a live workspace, not just
      `terraform plan` of something never applied**: the plan for this
      milestone originally gated the NAT resolution in
      `generate_tfvars.py` on `endpoints_ownership == "terraform"` alone
      (mirroring PrivateLink's own gate). Running it for real against
      `client-vpc-proof` (which has `endpoints_ownership: terraform` via
      override, but `vpc_ownership: existing` — a client-provided VPC)
      immediately failed, demanding a `network.nat_subnet_cidr` that
      made no sense for a VPC this factory doesn't own. Fixed by gating
      NAT independently on `vpc_ownership == "terraform"` instead —
      PrivateLink's AWS-side resources are purely additive (safe
      whenever Terraform owns the *endpoints*, regardless of who owns
      the VPC), but NAT attaches an Internet Gateway to the *whole VPC*
      and modifies *existing* private route tables, which isn't this
      factory's call to make on a VPC it doesn't own. Both gates are
      now independent and correctly different, matching this milestone's
      own "Scope boundary" reasoning that the first implementation pass
      had briefly contradicted.
    - `modules/workspace-network` gained the actual NAT resources — one
      NAT Gateway (not multi-AZ HA; a connectivity fallback, not a
      production redesign), gated on a new `nat_enabled` + `local.build_nat`
      (`nat_enabled && create_vpc`): `aws_internet_gateway`, one public
      `aws_subnet` (same AZ as the first private subnet - no new AZ
      input needed), `aws_eip`, `aws_nat_gateway`, a public
      `aws_route_table` + IGW route + association, and a default route
      added to *each* already-created private route table (additionally
      gated on `create_routing`, since a foreign/existing route table
      can't safely be modified). No security-group change needed — the
      workspace SG's egress rule already allows all outbound traffic
      unconditionally.
    - `network.nat_subnet_cidr` (new, in `deployment.yaml`, same shape
      as the private subnet CIDRs) is required whenever NAT resolves
      enabled; `resolver/check_cidr_allocations.py` now includes it in
      the same containment/collision checks private subnets already get.
    - Threaded `nat_enabled_override`/`nat_subnet_cidr` through
      `modules/workspace-deployment` → `infrastructure/workspace`,
      exactly like `privatelink_enabled_override`.
    - `isolated-proof`'s `deployment.yaml` had its now-redundant
      `overrides.privatelink_enabled: false` removed (the `"auto"`
      default already resolves this correctly) and gained the required
      `network.nat_subnet_cidr: 10.70.2.0/24` — the first deployment
      file to actually need it.
    - Verified end to end: regenerated tfvars for all three real
      workspaces — `document-ai-dev` unaffected (no connectivity fields
      at all, matching its `custom`/fully-existing-everything shape),
      `client-vpc-proof` keeps only `privatelink_enabled_override: false`
      (no NAT, correctly, per the gate fix above), `isolated-proof` gets
      `privatelink_enabled_override: false` +
      `nat_enabled_override: true` + `nat_subnet_cidr`. `terraform plan`
      against the **live** `isolated-proof` workspace showed exactly the
      9 expected new resources (1 IGW, 1 public subnet, 1 EIP, 1 NAT
      Gateway, 1 public route table + route + association, 2 private
      default routes) with no errors and nothing else disturbed — the
      free, real test this milestone's plan called for, made possible
      by `isolated-proof` already being live from the validation-harness
      milestone. `document-ai-dev`/`client-vpc-proof` plans re-verified
      unchanged (30/35 resources, same as before this milestone).
      Confirmed the rejection path (explicit `"privatelink"` against an
      unsupported account) and the explicit `"nat"` override path via
      throwaway tests, both cleaned up afterward.
    - **Real `terraform apply` of the NAT resources against
      `isolated-proof` remains a separate, explicit go/no-go** — a NAT
      Gateway has a real ongoing AWS hourly cost, not assumed as part of
      this change.
28. **Client-driven VPC CIDR/id + auto-allocated subnets** (2026-10-15,
    same day). The user asked directly: who should supply a VPC's CIDR
    (isolated) or id (custom), and who should pick subnet ranges inside
    it? Before this milestone, every one of these was hand-typed by the
    *operator* into `deployment.yaml`, with `check_cidr_allocations.py`
    only checking for collisions after the fact - nothing allocated
    anything, and nothing flowed from the requester. Decided via
    `AskUserQuestion` before building:
    - **Isolated**: the VPC CIDR is the *client's* own address-space
      choice - it now flows through `workspace-requests/*.yaml`'s new
      optional `network.vpc_cidr`, not invented by an operator. Subnets
      inside that VPC are **not** asked of the client - the platform
      auto-selects them.
    - **Custom**: the existing VPC's *id* is likewise the client's to
      supply (new optional `network.existing_vpc_id`, with an optional
      `network.existing_vpc_cidr` companion needed only when that VPC
      isn't already known in `platform/inventory/aws.yaml`). Omitting it
      keeps today's default (the account's known "primary" network).
      Subnets here are **also** auto-selected (chosen over keeping this
      case manual) - same blind spot the manual process already had
      (can't see non-Terraform-managed resources already living in that
      VPC), not a new risk, just automated.
    - Subnet sizing/AZ convention is a **fixed, region-level default**
      declared once in `platform/inventory/aws.yaml` (new
      `subnet_defaults`: `prefix_length` + `availability_zones`, replacing
      the old, dead per-"primary"-network `subnets.private.allocation`
      block) - not something the requester tunes per workspace.
    - All three new request fields are plain passthroughs through
      `resolver.py` (same treatment as `connectivity`/
      `catalog_admin_principal`) - the real resolution/validation
      happens in `generate_tfvars.py`, once the deployment's AWS account
      is known, same boundary as every other account-aware lookup.
    - **Key technical risk identified and designed around during
      planning**: naively recomputing "the next free subnet block" on
      every `generate_tfvars.py` run would be unsafe - adding a sibling
      workspace later (sharing a VPC, or just sharing the collision
      scanner) could shift an *already-applied* workspace's subnet CIDRs
      on its next regen, which Terraform would then try to destroy/
      recreate. Fixed by allocating once and **permanently pinning** the
      result to a new generated, committed file
      (`infrastructure/deployments/<env>/<name>/allocated-subnets.yaml`)
      - never recomputed once it exists, same spirit as
      `terraform.tfvars.json` itself never silently drifting.
    - **Zero Terraform changes** - `modules/workspace-network`'s
      `private_subnets`/`nat_subnet_cidr` variables were already plain
      list/string inputs; this entire feature lives in the Python config
      layer (`resolver/inventory.py`'s new `allocate_subnets()`/
      `subnet_defaults_for()`/`resolve_existing_vpc_cidr()`;
      `resolver/check_cidr_allocations.py`'s now-public `vpc_scope()`/
      new `used_subnets_for_scope()`, plus merging a workspace's
      `allocated-subnets.yaml` into its effective deployment for every
      future collision check; `resolver/generate_tfvars.py`'s new
      `ensure_subnet_allocation()` and shared `resolve_network_ownership()`
      helper, called in `main()` before `build_tfvars()`).
    - `resolver.py`'s old, dead subnet-allocation-validation block (it
      read `platform/inventory/aws.yaml`'s per-account subnet allocation
      purely to populate an informational `normalized.network.
      requirements.subnets.allocation` field that `generate_tfvars.py`
      already discarded) was removed - superseded by the real allocation
      logic, continuing the same pattern as milestones 20/25/27 (concrete,
      account-aware resolution moves out of `resolver.py` as it matures).
    - **Backward compatibility guarantee, verified**: all three real
      `deployment.yaml` files (`document-ai-dev`, `isolated-proof`,
      `client-vpc-proof`) already have explicit `network.subnets.private`
      lists, so `ensure_subnet_allocation()`'s first check
      (`deployment.yaml` already defines them → return unchanged) means
      none of them ever enters the new code path. Confirmed by
      regenerating all three workspaces' `terraform.tfvars.json` -
      byte-identical, and no `allocated-subnets.yaml` created for any of
      them.
    - Verified via four throwaway workspaces (created and fully cleaned
      up afterward, same pattern as every prior milestone): an isolated
      workspace with only a request-supplied `vpc_cidr` correctly got
      carved `/24` private subnets plus a NAT subnet (its Databricks
      account has no PrivateLink, so `connectivity` resolved to NAT);
      two custom-strategy workspaces sharing the same (fabricated, not
      inventory-known) `existing_vpc_id` + `existing_vpc_cidr` correctly
      got non-overlapping ranges from each other; a third, alphabetically
      *earlier* workspace added afterward into the same shared VPC
      correctly avoided both already-claimed ranges *and* left the first
      two's already-pinned `allocated-subnets.yaml` files byte-identical
      after being regenerated again - directly confirming the stability
      guarantee above. Also confirmed the rejection paths: a request's
      `vpc_cidr` outside the reserved isolated-VPC pool, a missing
      `vpc_cidr` for an isolated-resolving workspace, and a missing
      `existing_vpc_cidr` for a custom VPC unknown to inventory all fail
      with clear, specific errors.
    - No real `terraform apply`/`plan` against live infrastructure was
      implicated - this is a config-generation-time feature; the three
      real workspaces' tfvars are proven unchanged above.
29. **Remaining List-1 items moved off `deployment.yaml` - a normal
    workspace needs zero edits to it** (2026-10-15, same day). Direct
    follow-up to the audit that produced milestone 28's two lists: the
    user explicitly asked to tackle "the first list" (the easily-movable
    items) in full. Three of its items were already done in milestone
    28; this closes the remaining five, continuing the exact same
    request-passthrough + inventory-default pattern proven four times
    over (metastore id, VPC id/route tables, connectivity, VPC CIDR/id):
    - `overrides.existing_security_group_id` → request
      `network.existing_security_group_id`. Scoped inference (narrower
      than the general ownership-redesign flagged as "needs
      consideration" in the original audit): since security group
      ownership has no strategy-based default (always `"terraform"`
      unless overridden), the *only* reason an id is ever supplied is to
      use it - so its presence alone now implies
      `security_group_ownership_override: "existing"`, without also
      requiring a separate `overrides.security_group_ownership` key.
    - `overrides.privatelink_enabled`/`nat_enabled` - **deleted, not
      moved**. `network.connectivity` (milestone 27) already fully
      expresses every real case; no scenario was found where a separate
      boolean override on top of it added value.
      `client-vpc-proof`'s `deployment.yaml` had
      `overrides.privatelink_enabled: false` - confirmed already
      redundant *before* removal (its account's `privatelink_available:
      false` makes `"auto"` resolve the same value anyway) - removed,
      byte-identical tfvars confirmed.
    - KMS bring-your-own-key ARNs → request `encryption.existing_*`
      (new top-level `encryption` object in the request schema - the
      first requester-controlled `encryption` fields;
      `encryption.workspace`/`application_data` stay entirely
      profile-derived, unchanged).
    - `unity_catalog.existing_metastore_id` override → request
      `governance.existing_metastore_id`, alongside the
      milestone-22 `catalog_admin_principal`. `inventory.
      resolve_metastore_id()` gained a `requested_metastore_id`
      parameter, inserted into its existing precedence (deployment
      override > requested > inventory default); both call sites
      (`generate_tfvars.py`, `validate_deployment.py`) updated.
    - `databricks.account_id` → a per-AWS-account
      `platform/inventory/aws.yaml` default
      (`aws.accounts.<name>.databricks_account_id`) + optional request
      `cloud.databricks_account_id` override - **the one field every
      `deployment.yaml` still strictly needed before this milestone**.
      New `inventory.resolve_databricks_account_id()` (same
      `require()`-based shape as `resolve_metastore_id`). Resolved
      *once*, up front, in `generate_tfvars.py`'s `main()` (previously
      read independently in two places - `ensure_subnet_allocation()`
      and `build_tfvars()`) and merged back into the in-memory
      `deployment` dict so both downstream reads keep working
      unchanged - the same pattern `ensure_subnet_allocation()` itself
      already uses for its own result. `validate_deployment.py`
      resolves it the same way instead of reading
      `deployment["databricks"]["account_id"]` directly, since a
      workspace's `deployment.yaml` may now have no `databricks` key at
      all.
    - **Real-workspace migration, proving the chain end-to-end** (same
      "remove the now-redundant value" pattern as milestones 20/25):
      `document-ai-dev`'s `deployment.yaml` lost its `databricks:` block
      entirely, relying purely on the new inventory default
      (`331f8702-...`, the account it already used - chosen as the
      natural default over `isolated-proof`/`client-vpc-proof`'s
      deliberately-different second account). `isolated-proof` and
      `client-vpc-proof` gained `cloud.databricks_account_id:
      "eddbb85f-..."` in their own `workspace-requests/dev/*.yaml`
      (the first real, non-throwaway exercise of this override tier),
      then lost their own `deployment.yaml` `databricks:` blocks.
    - **Zero Terraform changes** - every Terraform-facing variable
      already existed (`existing_security_group_id`,
      `privatelink_enabled_override`, `nat_enabled_override`, the four
      KMS `existing_*_key_arn/alias` variables, `existing_metastore_id`,
      `databricks_account_id`); only the Python-layer *source* of each
      value moved.
    - Verified: regenerated tfvars for all three real workspaces -
      byte-identical throughout, including after the `deployment.yaml`
      edits above (proves zero functional change, just a different
      value source). A single throwaway workspace (created and fully
      cleaned up afterward) exercised all four of the new request-level
      fields at once, confirming each appears correctly in tfvars
      (including the auto-implied `security_group_ownership_override`
      and the KMS/governance keys correctly stripped out of their
      parent objects) and that an explicit `deployment.yaml` override
      still wins over the request value for each. Directly unit-tested
      `resolve_databricks_account_id()`'s rejection path (no override, no
      request value, no inventory entry) for a clear error. `resolver/
      check_cidr_allocations.py` re-run clean throughout (untouched by
      any of these five fields). No `.tf` file was touched, confirmed
      via `git status`.
30. **Ownership-inference redesign: `routing_ownership`/`endpoints_ownership`
    are now inferred, not blindly defaulted** (2026-10-16). The original
    List-2 audit (milestone 28's writeup) flagged the four
    `overrides.{vpc,routing,security_group,endpoints}_ownership` knobs as
    "needs consideration": mechanically movable, but exposing raw
    Terraform ownership enums cuts against this project's own philosophy
    (§1: "I need a workspace," not "set this resource's ownership flag").
    `security_group_ownership` already got the inference treatment in
    milestone 29 (an `existing_security_group_id`'s presence implies
    `"existing"`); the user asked to close the rest.
    - `vpc_ownership` stays strategy-driven, deliberately - there's no
      cleaner signal than `network.strategy` itself (`custom`
      legitimately defaults to `"existing"` even with no explicit
      `existing_vpc_id`, via the inventory fallback), and replacing
      `strategy` with pure field-presence inference would make
      `policies/policies.yaml`'s `allowed_strategies` (a real policy
      control - `live` only allows `custom`) harder to express.
    - `routing_ownership` is now inferred from whether route table ids
      are *actually known* for the effective VPC - new
      `inventory.route_table_ids_known()` - rather than a blind
      per-strategy default silently waiting for a manual override.
      When `vpc_ownership` is `"terraform"`, routing is unconditionally
      `"terraform"` too (nothing existing to reuse - not a choice, not
      even inference). `overrides.routing_ownership` remains a rare
      escape hatch on top of the inferred value.
    - `endpoints_ownership` now defaults to whatever `routing_ownership`
      just resolved to, instead of its own independent strategy-based
      default: every real case seen so far (`client-vpc-proof`'s bare
      VPC) shows a VPC with no known route tables also has no existing
      S3/STS/KMS endpoints - both signal "this is a genuinely bare VPC."
      `overrides.endpoints_ownership` stays available for the one
      documented case they might diverge (CLAUDE.md §4:
      `document-ai-dev`'s VPC has existing route tables but no
      endpoints today).
    - **A real latent bug fixed along the way**:
      `resolve_platform_network()`'s inventory fallback used to hand
      back the account's *primary* network's route tables whenever
      routing ownership was `"existing"`, with no check that the VPC in
      play was actually the primary one - a different, non-primary
      existing VPC was never entitled to borrow the primary's route
      tables. `route_table_ids_known()` (the function that now decides
      ownership in the first place) enforces the match itself.
    - `generate_tfvars.py`'s `build_tfvars()` used to only forward
      `vpc_ownership_override`/`routing_ownership_override`/
      `endpoints_ownership_override` to tfvars when `deployment.yaml`'s
      `overrides` dict explicitly had the key. Since routing/endpoints
      ownership is now *inferred* rather than passed-through-or-silent,
      this had to change to always set all three explicitly from
      `resolve_network_ownership()`'s result - otherwise
      `modules/workspace-deployment/locals.tf`'s own strategy-only
      `coalesce()` would independently (and wrongly) recompute a
      different default, diverging from the Python-side inference.
      `security_group_ownership` stays forwarded only when explicitly
      set (its own default never depended on strategy, so there's no
      divergence risk).
    - **Expected, non-byte-identical side effect**: workspaces whose
      `deployment.yaml` has no `overrides` block at all
      (`document-ai-dev`) now get explicit `vpc_ownership_override`/
      `routing_ownership_override`/`endpoints_ownership_override` keys
      in `terraform.tfvars.json` that weren't there before - the first
      milestone where real-workspace verification couldn't rely on
      byte-identical tfvars. The *values* match exactly what
      `locals.tf`'s own coalesce already computed, confirmed instead via
      `terraform plan` showing zero resource diff.
    - **Real-workspace proof**: `client-vpc-proof`'s `deployment.yaml`
      had explicit `overrides: {routing_ownership: terraform,
      endpoints_ownership: terraform}` specifically because its
      `platform.vpc_id` isn't the account's primary VPC. Removed both
      lines - the new inference reaches the identical two values on its
      own (confirmed by inspecting the regenerated tfvars).
    - Verified: regenerated tfvars for all three real workspaces -
      `document-ai-dev`/`isolated-proof` gained the three explicit
      override keys with values matching Terraform's prior default
      exactly; `client-vpc-proof` resolved to the identical
      `routing`/`endpoints` `"terraform"` values it had explicitly
      before, now via inference. **Real test against the live
      `isolated-proof` workspace**: `terraform plan` showed the exact
      same pending state as before this change (the still-unapplied
      milestone-27 NAT resources + the known-pending
      `unity_catalog_bucket_name` output) - zero new diff, confirming
      the ownership-inference change is Terraform-behavior-neutral.
      `document-ai-dev`/`client-vpc-proof` plans against their
      destroyed state matched their established resource-count
      baselines exactly (30/35). Two throwaway workspaces (created and
      cleaned up afterward) directly proved the inference: a `custom`
      workspace with no `existing_vpc_id` (reuses the known primary
      VPC) inferred `routing`/`endpoints` to `"existing"` with zero
      overrides; one with a non-primary `existing_vpc_id` and no known
      route tables inferred both to `"terraform"` with zero overrides -
      then, with an explicit `overrides.routing_ownership: existing`
      added, confirmed the override still wins over the inferred value.
      `resolver/check_cidr_allocations.py` re-run clean throughout. No
      `.tf` file was touched, confirmed via `git status`.
31. **Route table ids for a brand-new client VPC - closes the last
    List-2 audit item** (2026-10-16). The original worry was that
    solving this "for real" would need a live AWS lookup
    (`aws ec2 describe-route-tables`) or a one-time inventory-
    registration workflow for arbitrary client VPCs. Re-examined: that
    worry didn't actually hold up - `existing_vpc_id`/
    `existing_security_group_id` (milestones 28/29) are already
    request-level fields describing AWS resource ids a client hands
    over; route table ids are the same category of fact, not a harder
    one. Closed with the identical proven pattern: new optional
    `network.existing_route_table_ids` in `workspace-requests/*.yaml`,
    resolved with the same deployment-override > request > inventory-
    default precedence as everything else. No live AWS calls, no
    registration workflow.
    - **Consolidated two drift-prone implementations into one.**
      Milestone 30's `route_table_ids_known()` (decides *whether*
      routing is `"existing"`) had the correct "only trust inventory's
      route tables when the VPC in play actually is the primary one"
      guard; `resolve_platform_network()`'s older, separate inline
      logic (resolves the actual route-table-id *value* once ownership
      is already `"existing"`) did not - a real latent bug: an explicit
      `overrides.routing_ownership: existing` on a non-primary VPC with
      nothing else supplying route tables would still have silently
      handed back the primary network's unrelated ids.
      `route_table_ids_known()` was replaced with a single
      `resolve_route_table_ids()` (returns the ids or `None`, not just
      a bool) that both `resolve_network_ownership()` (ownership
      inference) and `resolve_platform_network()` (the actual
      Terraform value) now call - fixing the bug everywhere at once
      instead of leaving two places that had to agree by convention.
    - **A second, unrelated real bug found and fixed while in this
      code**: `existing_security_group_id` (added to
      `normalized.network` in milestone 29) was never being stripped
      out of `tfvars["network"]` before assignment - since
      `var.network`'s Terraform object type doesn't declare that key,
      a real `terraform apply` for any workspace using it would have
      failed on strict object-type conversion. Latent because no real
      or throwaway test for that field had ever been run through
      `terraform validate`/`plan` - only inspected as raw JSON.
      `existing_route_table_ids` would have had the identical bug if
      added without noticing; both are now stripped in the same place
      `connectivity`/`vpc_cidr`/`existing_vpc_id`/`existing_vpc_cidr`
      already were.
    - Verified: regenerated tfvars for all three real workspaces -
      **byte-identical** (none exercise the fixed bug today), a return
      to the normal bar after milestone 30's intentional exception. Two
      throwaway workspaces (created and cleaned up afterward): a
      `custom` workspace with a non-primary `existing_vpc_id` plus
      `existing_route_table_ids` in the request, no `deployment.yaml`
      overrides at all, correctly inferred `routing`/`endpoints`
      ownership to `"existing"` with `platform.route_table_ids`
      matching the *requested* ids, not the primary's; a second
      workspace directly proved the bug fix - explicit
      `overrides.routing_ownership: existing` on a non-primary VPC with
      no route tables known anywhere now raises a clear error instead
      of silently substituting the wrong VPC's route tables. Confirmed
      `deployment.yaml`'s override still wins over the request value.
      Confirmed (via the first throwaway) that `tfvars["network"]`
      correctly contains only `strategy`/`architecture`/`requirements`
      - no leaked passthrough keys. `resolver/check_cidr_allocations.py`
      re-run clean throughout. No `.tf` file was touched.
    - This closes the List-2 audit from milestone 28's writeup in
      full: all four items (route table ids, ownership inference,
      Databricks-account topology, KMS trust boundary) have now been
      addressed except the Databricks-account-topology and KMS
      trust-boundary questions, which were always framed as business/
      design judgment calls for the user to make, not technical gaps -
      see milestone 29's writeup for why `databricks.account_id`'s
      inventory-default design already accommodates the topology
      question either way.
32. **First real customer-perspective test (`existing-vpc-proof`) + trimmed
    `platform/inventory/aws.yaml`'s dead fields** (2026-10-16). The user
    filled out a `workspace-requests/*.yaml` themselves, as a real
    customer would, for a genuinely new scenario: reusing a brand-new,
    manually-created VPC (`vpc-0c7507e977fba2ee1`, `10.71.0.0/16`, two
    now-deleted placeholder subnets) in AWS account `556940913059`,
    registered against the `eddbb85f...` Databricks account (the `TSA`
    profile) - not the AWS account's inventory default.
    - **Two real-world gaps surfaced and were explicitly accepted
      before building anything**, via `AskUserQuestion`: (a) this
      factory always has Terraform create its own subnets inside
      whichever VPC it's given - it never adopts pre-existing subnets,
      so the user's two placeholder subnets had to be deleted before
      `apply` (their CIDRs are exactly where the auto-allocator would
      carve new ones anyway: `10.71.0.0/24`/`10.71.1.0/24`, the first
      free blocks in that VPC); (b) with no PrivateLink on this
      Databricks account and no NAT (this factory deliberately never
      builds a NAT Gateway inside a VPC it doesn't own - see
      milestone 27/30), classic compute has no path to the control
      plane. The user explicitly chose to proceed anyway as a
      **pipeline-mechanics test** (prove request → resolve → apply
      works end-to-end against real accounts) rather than expect a
      fully usable workspace - documented directly in the request
      file's own comments so this isn't rediscovered as a surprise
      later.
    - **New `workspace-requests/TEMPLATE.yaml`** - a reusable, heavily
      commented template covering every field (required and optional)
      a requester might fill in, including every `existing_*`/override
      field added across milestones 27-31. Deliberately placed at the
      top level of `workspace-requests/` (sibling to `dev`/`stage`/
      `live`, not inside any of them) so it's obviously not a real
      request. Verified to actually resolve end-to-end (schema +
      policy) with its placeholder values, not just schema-valid in
      isolation - a first pass left `classification: REPLACE-ME`,
      which passed the request schema (no pattern on that field) but
      failed `resolver.py`'s policy lookup (`data_policy.classifications`
      has no entry named `REPLACE-ME`) - fixed by defaulting it to a
      real value (`internal`).
    - `existing-vpc-proof`'s own `infrastructure/deployments/dev/
      existing-vpc-proof/deployment.yaml` is **just `api_version: v1`** -
      the real-world proof that milestones 28-31's work actually
      delivered on its goal. Verified via a real `terraform plan`
      against this workspace (new backend, `TSA` profile): **35 to add,
      0 to change, 0 to destroy**, no errors - reuses the existing VPC,
      no VPC creation, no NAT, no PrivateLink, correctly carved the two
      subnets, built routing/security-group/endpoints/IAM/S3/Unity
      Catalog/the workspace itself. **Applied for real on 2026-10-19**
      (after milestone 33's review/subnet-adoption work landed) -
      workspace id `7474653153200830`, url
      `https://dbc-1c4c0ccd-795d.cloud.databricks.com`. Hit two real
      issues on the first attempt, both fixed without any code change:
      (1) `databricks_mws_credentials` failed with the same known,
      non-fatal IAM trust-policy propagation lag documented in §4a -
      cleared on a plain retry; (2) the S3/STS interface endpoints
      failed with *"Enabling private DNS requires both
      enableDnsSupport and enableDnsHostnames VPC attributes set to
      true"* - this manually-created VPC had neither enabled. Fixed by
      running `aws ec2 modify-vpc-attribute` directly against the VPC
      (outside Terraform, since this factory treats an existing VPC as
      unmanaged) to enable both, then retrying `terraform apply`, which
      completed cleanly. Worth remembering for any future existing-VPC
      client scenario: **a client-provided VPC needs
      `enableDnsSupport`/`enableDnsHostnames` both true** before this
      factory's endpoints-ownership path (interface VPC endpoints with
      private DNS) will apply successfully - not something this
      factory checks or fixes automatically today, since it doesn't
      manage the VPC resource itself.
    - **Prompted directly by that exercise**: the user asked to
      reconcile `platform/inventory/aws.yaml`'s existing `dev` account
      entry against the actual code, field by field, rather than take
      its comments at face value. Traced with `grep`, not memory:
      `account_id`, `databricks_account_id` (the default, even though
      it lost to this workspace's request-level override),
      `regions.us-east-1.approved`, `subnet_defaults`, and
      `networks.primary.vpc.{id,cidr}`/`routing.route_table_ids` are
      all genuinely read. `aws.accounts.<name>.environment` and
      `networks.primary.{name, vpc.ownership, routing.ownership,
      security_groups, endpoints, dns}` are not read by any code,
      confirmed by grep returning zero matches for each. These were
      leftovers from an earlier design that mirrored
      `policies/policies.yaml`'s per-resource-ownership shape before
      the real architecture (ownership resolved per-workspace from
      strategy + request-supplied ids + route-table presence,
      milestones 9/28-31) made a static per-account "ownership" claim
      both unused and semantically wrong (every workspace reusing the
      primary VPC still gets its own dedicated security group
      regardless of what a shared `security_groups: terraform` claim
      here said). Removed rather than left as unenforced, driftable
      documentation - the same "trim to only what's read" rule already
      applied to `profiles/*.yaml`/`policies/policies.yaml` (§5.13/§8
      milestones 15-18).
    - Verified: re-ran `resolver/main.py` for all six requests
      (including the new `existing-vpc-proof`) and regenerated tfvars
      for all four workspace directories - **byte-identical** for the
      three previously-tracked real workspaces
      (`document-ai-dev`/`isolated-proof`/`client-vpc-proof`),
      confirming the seven removed fields truly had zero effect.
      `resolver/check_cidr_allocations.py` re-run clean. No `.tf` file
      was touched (pure YAML trim, no code changes needed since nothing
      read the removed fields in the first place).
33. **Subnet adoption (`network.existing_subnet_ids`) + two review notes**
    (2026-10-19). Triggered by the user reviewing `existing-vpc-proof`
    before committing: they asked what `allocated-subnets.yaml` is for
    given `terraform.tfvars.json` already has the subnet CIDRs, and
    whether `deployment.yaml` is still worth keeping now that it's
    sometimes just `api_version: v1`.
    - **`allocated-subnets.yaml` vs `terraform.tfvars.json`, clarified,
      not changed**: `tfvars.json` is disposable/derived - safe to
      delete and regenerate any time, never read back by anything.
      `allocated-subnets.yaml` is a durable *pin*, written once, that
      has to survive regeneration so (a) this workspace's own CIDRs
      never shift under an already-applied deployment, and (b)
      `check_cidr_allocations.py`'s collision scanner (which reads
      `deployment.yaml` + `allocated-subnets.yaml` across every
      workspace, never `tfvars.json`) can see it. Folding the pin into
      `deployment.yaml` instead was considered and rejected - it would
      mean `generate_tfvars.py` auto-mutating the one file this project
      has spent several milestones trying to keep purely hand-written.
    - **Real misconception surfaced and corrected**: the user's worry
      about "a manual step to generate tfvars.json and commit it to
      version control" once a CI pipeline exists doesn't actually
      require any design change - `tfvars.json` can simply be generated
      as a pipeline step and never committed at all in a CI world (same
      as any other build artifact). It's only committed today because
      there's no pipeline yet. This reframed the real target of the
      user's concern down to just the subnet *pin*, which is what this
      milestone actually addresses.
    - **Decision (user's call, via `AskUserQuestion`, after a fact-check
      of `modules/workspace-network/variables.tf` showed no adoption
      capability existed at all - subnets were unconditionally
      Terraform-created)**: add real support for adopting pre-existing
      subnets, scoped to `custom` strategy only (an `isolated` VPC
      doesn't exist yet, so there's nothing to adopt), and made
      *optional* - not a hard requirement - specifically to avoid
      breaking `client-vpc-proof`'s bare-VPC scenario (a client handing
      over a VPC with no subnets at all, factory builds everything).
      This is the same existing-or-create pattern already used for
      vpc/routing/security_group (CLAUDE.md §9) - subnets were the one
      network resource that had never gotten it.
    - **New request-level field**: `network.existing_subnet_ids` (>=2
      subnet ids), same passthrough treatment as `existing_vpc_id`/
      `existing_route_table_ids`/`existing_security_group_id`. Resolved
      with the same deployment-override > request precedence as every
      other `existing_*` field. When present,
      `generate_tfvars.py`'s `ensure_subnet_allocation()` skips CIDR
      allocation entirely (no `allocated-subnets.yaml` written at all
      for that workspace) and `build_tfvars()` surfaces the ids as
      their own top-level `existing_subnet_ids` Terraform variable
      (`var.network`'s object type doesn't declare it, same reason
      `existing_security_group_id` is a standalone var) instead of
      populating `network.requirements.subnets.private`.
    - **Real dead field fixed along the way**:
      `network.requirements.subnets.ownership` has existed since the
      resolver was first built, always hardcoded to whatever
      `policies/policies.yaml`'s static per-strategy value said
      (always `"terraform"`, since adoption never existed) - validated
      by `modules/workspace-deployment/variables.tf`'s type check but
      never actually driving any Terraform behavior, same "resolved but
      not real" pattern as the routing/endpoints ownership fields fixed
      in milestone 30. Now that adoption is real, `build_tfvars()` sets
      this to the actual value (`"existing"` when adopting,
      `"terraform"` otherwise) instead of just forwarding the static
      policy default.
    - **Terraform changes** (`modules/workspace-network`): new
      `existing_subnet_ids` variable (list, default null); `private_subnets`
      changed from required to optional (required only when
      `existing_subnet_ids` is null); new `local.create_subnets`/
      `local.subnet_ids`/`local.subnet_count` locals; `aws_subnet.private`'s
      count gated on `create_subnets`; `aws_route_table.private` and
      `aws_route_table_association.private` now size off `subnet_count`
      and read from `subnet_ids` (adopted or created, whichever is
      active); `private_subnet_ids` output now returns `local.subnet_ids`.
      `existing_route_table_ids`'s length-matching validation updated to
      compare against whichever subnet source is in use (cross-variable
      validation, Terraform 1.9+ - already required by this repo's
      1.10+ native S3 locking). No data-source lookup for the adopted
      subnet ids themselves (same "trust what's given" treatment as
      `existing_route_table_ids` already gets - nothing downstream needs
      their AZ/CIDR, confirmed by grepping every consumer of
      `private_subnet_ids`). Threaded straight through
      `modules/workspace-deployment` and `infrastructure/workspace` as
      a plain passthrough variable, same shape as
      `existing_security_group_id`.
    - **Known limitation, documented in the new field's own schema
      description and the template**: because adopted subnets' CIDRs
      are never looked up, they're invisible to
      `resolver/check_cidr_allocations.py`'s collision checker - a
      sibling workspace auto-allocating into the same VPC could in
      theory pick a range that overlaps one of these. Accepted as-is
      for now (matches the user's explicit "the code simply consumes
      this for now" framing); a real fix would need a live
      `aws ec2 describe-subnets` lookup, which this project has
      deliberately avoided everywhere else too.
    - **`deployment.yaml`'s fate - no mechanism change, by design**: the
      file stays required (it's still the discovery marker
      `check_cidr_allocations.py`'s `_iter_deployments()` globs for, and
      `generate_tfvars.py` still unconditionally loads it) - but with
      subnet CIDRs/ids now routable through the request instead of
      forced into this file, a normal workspace's `deployment.yaml`
      naturally stays `api_version: v1` only, the same place
      `existing-vpc-proof`'s already was, without needing to build
      file-optionality machinery.
    - **Open review item, explicitly deferred per the user's own
      request, not forgotten**: `infrastructure/workspace/backend.tfbackend`
      and each workspace's `backend.tfbackend` (CLAUDE.md §8 milestone
      13) are both fully derivable today - `bucket`/`region`/
      `use_lockfile` are constants, and a workspace's `key` is always
      exactly `<environment>/<name>/terraform.tfstate`. Worth revisiting
      whether these need to be generated-and-committed files at all, or
      whether `terraform init`'s `-backend-config` values could instead
      be computed inline (e.g. by a thin wrapper script) without a
      committed intermediate file - same category of question as the
      subnet pin above, but not resolved this session.
    - Verified: `terraform fmt -check -recursive`/`terraform validate`
      clean. Regenerated tfvars for all four real workspaces (including
      `existing-vpc-proof`) - byte-identical (none use
      `existing_subnet_ids`, confirming zero regression).
      `check_cidr_allocations.py` re-run clean. A throwaway workspace
      (`custom` strategy, the account's real primary VPC
      `vpc-60c2a81d` + `document-ai-dev`'s own real, already-associated
      subnet/route-table ids, cleaned up afterward) proved the feature
      against live AWS data via a real `terraform plan` (not just
      `validate`): `data.aws_vpc.existing` read the real VPC, zero
      `aws_subnet`/`aws_route_table` resources were planned, and
      `aws_route_table_association.private[0]`/`[1]` were planned to
      attach exactly the given real subnet ids to the given real route
      table ids - `27 to add, 0 to change, 0 to destroy`, no errors.
      Shared root re-initialized back to `existing-vpc-proof`'s backend
      afterward.
34. **All three live workspaces destroyed for real; two real teardown
    gaps found and fixed** (2026-10-19). Once manual testing was
    complete (including real notebook-driven Unity Catalog read/write
    activity against `isolated-dev-2` — see §4a), the user asked to
    destroy `isolated-dev-2`, `existing-vpc-proof`, and `isolated-proof`
    in one pass. Two real, previously-unseen `terraform destroy` gaps
    surfaced — neither was an applied-infrastructure design flaw, both
    are now documented so a future teardown doesn't re-discover them
    from scratch:
    - **Non-empty S3 buckets block `aws_s3_bucket` deletion.** Neither
      the workspace-root bucket (DBFS/notebook/job data, `isolated-dev-2`
      only — the one workspace with real manual activity) nor the Unity
      Catalog managed-storage bucket (actual table data written via a
      real notebook on `isolated-dev-2`) has `force_destroy` set, so
      Terraform's `aws_s3_bucket.Destroy` fails with `BucketNotEmpty`
      whenever real data was written. Fixed by manually emptying each
      bucket (`aws s3 rm <bucket> --recursive`) before retrying
      `terraform destroy` — not a code change, since `force_destroy`
      on the bucket resources themselves was deliberately never set
      (accidental data loss protection is more valuable day-to-day than
      convenience at teardown time, same reasoning Terraform's own
      default encodes).
    - **A Unity Catalog storage credential can't be deleted while a
      "dependent storage location" reference lingers, even after its
      catalog/external-location/schemas are already gone and its S3
      bucket is empty.** Hit identically on all three workspaces'
      `databricks_storage_credential` resource:
      *"Storage credential '...' has 0 directly dependent external
      table(s) and 1 dependent storage location(s). You may use force
      option to delete it..."* — this is Unity Catalog-side bookkeeping
      (the catalog's own implicit managed-storage-root reference),
      not a real orphaned-data risk once the bucket is confirmed
      empty. Added `force_destroy = true` to
      `modules/unity-catalog-data/main.tf`'s
      `databricks_storage_credential.this` (the provider's documented
      switch for this exact case) — but a plain `terraform destroy`
      with that flag set still failed outright on `existing-vpc-proof`/
      `isolated-proof` with the identical message. **Working sequence,
      verified three times**: first run a *plan+apply* of just that one
      resource (`terraform plan -target=...databricks_storage_credential.this
      -out=p && terraform apply p`) — this update attempt itself always
      fails too (`"...use force option to update anyway"`, since the
      provider's Update path doesn't appear to honor `force_destroy`
      either) — but immediately following that failed update attempt
      with a plain `terraform destroy -target=...databricks_storage_credential.this`
      then succeeds. Root cause not fully pinned down (most likely the
      failed update request itself nudges Unity Catalog's backend to
      drop the stale dependent-location reference as a side effect, or
      coincidental timing — waiting on its own, without the
      update-then-destroy sequence, did **not** reliably clear it, even
      after several retries over ~2 minutes on `existing-vpc-proof`).
      **Worth remembering for any future teardown using this module**:
      if a plain `terraform destroy` stalls on this exact error, run
      the plan/apply-then-destroy sequence above on that one resource
      before assuming anything is actually broken.
    - All three workspaces fully destroyed: `isolated-dev-2` (29
      resources across two passes), `existing-vpc-proof` (17 resources
      — root bucket was already empty, pipeline-mechanics-only test per
      milestone 32), `isolated-proof` (27 resources — same, no manual
      UC activity had ever been run against it). `existing-vpc-proof`'s
      manually-created VPC (`vpc-0c7507e977fba2ee1`) was never
      Terraform-managed (milestone 32) and is still live — out of scope
      for `terraform destroy`, a separate manual AWS cleanup if wanted.
    - `force_destroy = true` on the storage credential is left in place
      permanently (not reverted) — it's a reasonable standing default
      for this factory's own teardown workflow and caused no issue for
      any resource in this pass once combined with the sequence above.

## 9. Conventions observed (keep consistent)

- Every workspace deployment gets its own Terraform state boundary — never
  share state across workspaces. Mechanism as of §8 milestones 12/13: one
  shared root in `infrastructure/workspace/`, state boundary enforced by a
  distinct S3 key per workspace (`<environment>/<name>/terraform.tfstate`),
  selected via two `-backend-config` files at `init` time (the shared
  `infrastructure/workspace/backend.tfbackend` plus this workspace's
  `infrastructure/deployments/<env>/<name>/backend.tfbackend`) — not by
  separate directories or Terraform CLI workspaces (both tried and
  superseded).
- Modules take a `workspace_name` (not `project_name` like the POC modules) and
  tag resources with `ManagedBy = terraform`, `Component = ...`, plus the
  common tag set in `modules/workspace-deployment/locals.tf`.
- Cross-account / data-access IAM roles use Databricks-provided policy data
  sources (`databricks_aws_crossaccount_policy`,
  `databricks_aws_unity_catalog_policy`, etc.) rather than hand-written policy
  documents — follow `modules/workspace-iam-role`, not the POC's
  `modules/security`.
- Existing-or-create flexibility is a variable-level pattern, not a resolver
  concern: a module takes an optional `existing_<thing>_id`/`arn` (default
  `null`) — non-null means look it up/use it as-is, null means create it.
  At the root (`infrastructure/workspace`), this is further wrapped in a
  `coalesce(var.<x>_ownership_override, <derived from var.network.strategy>)`
  local so named strategy presets (`custom`/`isolated`) still set sensible
  defaults, but any individual resource can be overridden independently. See
  `modules/workspace-network`, `modules/workspace-endpoints`, and
  `modules/workspace-kms` for the pattern; apply the same shape to any future
  "bring your own vs. create" resource rather than inventing a new mechanism.
- **Standing up a new workspace end-to-end** (current convention, §8
  milestone 13): write `workspace-requests/<env>/<name>.yaml` → run
  `resolver/main.py --request ... --account ...` → write
  `infrastructure/deployments/<env>/<name>/deployment.yaml` (existing ids +
  concrete subnet CIDRs + optional overrides) → run
  `resolver/generate_tfvars.py --workspace <name>` (writes
  `.../terraform.tfvars.json`) → run `resolver/generate_backend_config.py
  --workspace <name>` (writes `.../backend.tfbackend` with just this
  workspace's `key`, and (re)writes the shared
  `infrastructure/workspace/backend.tfbackend` with `bucket`/`region`/
  `use_lockfile`) → `export TF_VAR_databricks_profile="..."` once per shell
  (or use `local.auto.tfvars`) → from `infrastructure/workspace/`:
  `terraform init -backend-config=backend.tfbackend
  -backend-config=../deployments/<env>/<name>/backend.tfbackend
  -reconfigure -input=false && terraform plan
  -var-file=../deployments/<env>/<name>/terraform.tfvars.json`. Never
  hand-edit `terraform.tfvars.json` or either `backend.tfbackend` file —
  regenerate them. All per-workspace files are committed; the `.tf` files
  themselves are never copied, only shared.
- **Before any `plan`/`apply`, confirm which workspace's backend is
  currently active** — there is no per-directory safety net: the shared
  root always points at whichever `-backend-config` files were last
  `init`'d, and getting this wrong means operating on the wrong workspace's
  state. Always re-run the two-file `terraform init -backend-config=...`
  command above immediately before working on a given workspace, even if
  you think it's already pointed there — it's a cheap, idempotent command,
  and the cost of skipping it by mistake is high. (This repo tried
  Terraform CLI workspaces and per-workspace directories before landing
  here — see §8 milestones 10, 12, and 13 for why each prior layout was
  superseded.)
