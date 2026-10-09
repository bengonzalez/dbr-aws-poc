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
   infrastructure/workspace/<name>.deployment.yaml   (small, hand-maintained:
            |                existing resource ids, concrete subnet CIDRs —
            |                see §8's tfvars-generator milestone)
            v
   resolver/generate_tfvars.py --workspace <name>
            v
   infrastructure/workspace/<name>.tfvars.json   (generated — do not hand-edit)
            v
   infrastructure/workspace/*.tf   (terraform root — one deployment per workspace)
            |
            v
   modules/*   (reusable building blocks: network, IAM, storage, KMS, UC, ...)
            |
            v
   AWS + Databricks account/workspace APIs
```

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
| `resolver/` (`main.py`, `resolver.py`, `loader.py`, `validator.py`, `generate_tfvars.py`) | Working, has gaps | Resolves request+profile+policies+inventory → normalized YAML, then (new, §8) `generate_tfvars.py` turns that + a small per-workspace deployment file into a `*.tfvars.json`. See §5 gaps. |
| `schemas/` | Working, has a gap | `workspace-request.schema.json`, `normalized-config.schema.json` actively used. `profile.schema.json` exists but is **never actually validated against** — see §5. No schema for the new `*.deployment.yaml` files yet — deliberate, kept lightweight (plain key-presence checks in `generate_tfvars.py`), see §8. |
| `profiles/{dev,stage,live}.yaml` | Working, inconsistent | Per-environment defaults. `dev.yaml` is missing a `network.architecture` key that `stage.yaml`/`live.yaml` both have — not currently caught because profile.schema.json validation isn't wired in. |
| `policies/{network,security,data,governance,validation}.yaml` | Working | Platform-wide rules the resolver enforces (encryption requirements, UC requirements, network strategy → architecture mapping, validation blocking per env). |
| `platform/inventory/aws.yaml` | Stale placeholder, still unused | Declares the `dev` account's primary network, but `vpc.id` is still `vpc-PLACEHOLDER` — never updated to the real `vpc-60c2a81d` even though the resolver reads this file. The actual VPC id is supplied via the new `infrastructure/workspace/<name>.deployment.yaml` (§8) instead — a deliberate choice to keep this inventory file and the resolver untouched for now (see §8's tfvars-generator milestone for why). Still worth fixing the placeholder eventually (§5.3), just no longer blocking anything. |
| `normalized/*.yaml` | Working — **was silently gitignored, now fixed** | Resolver output per workspace request. `CLAUDE.md` previously (incorrectly) stated these were committed; `.gitignore` actually had a stale `normalized/` rule (its own comment called it "the normalized **virtual environment** directory," which doesn't match what's in there) that had been silently excluding every file in this directory from version control. Removed 2026-10-09 — these now will be tracked going forward. |
| `infrastructure/workspace/*.deployment.yaml` | **New, working** | One per workspace (e.g. `document-ai-dev.deployment.yaml`). Committed. Holds only what the resolver doesn't produce: existing resource ids (`platform.vpc_id`/`route_table_ids`), concrete subnet CIDRs, and optional ownership overrides / bring-your-own KMS keys. See §8. |
| `infrastructure/workspace/*.tfvars.json` | **New, generated — do not hand-edit** | Output of `resolver/generate_tfvars.py --workspace <name>`. Regenerate after any change to the matching `normalized/*.yaml` or `*.deployment.yaml`, then commit the result (same convention as the old hand-written `dev.tfvars`). |
| `infrastructure/workspace/local.auto.tfvars` (gitignored) / `local.auto.tfvars.example` (committed) | **New** | Holds only `databricks_profile` — the one value that's operator/machine-specific, not workspace configuration, and should never be committed. Terraform auto-loads `local.auto.tfvars` alongside whatever `-var-file` is passed. |
| `infrastructure/nonprod/poc/` | Frozen POC | The original one-shot POC that validated the approach end-to-end. Not touched going forward; kept for reference. |
| `infrastructure/workspace/` | **Active development — dev workspace is live** | Wires: `workspace-network` module (per-resource existing-or-create, §8), `workspace-endpoints` module (gated, §8), `databricks_mws_networks`, `databricks_mws_credentials`, `workspace-iam-role` module, `workspace-kms` module (gated on `customer_managed`, supports bring-your-own-key), `databricks_mws_customer_managed_keys` (gated), and `databricks_mws_workspaces.this` — the actual workspace. **Applied for dev** on 2026-10-09: workspace id `7474659907556205`, url `https://dbc-fd8d68d5-bd8c.cloud.databricks.com`, deployed with `dev.tfvars` (`custom` strategy, `platform_managed` encryption — unaffected by the later ownership-override rework; confirmed via a zero-diff `terraform plan` after each change). |
| `infrastructure/platform/` | Empty placeholder, deliberately not pursued yet | Would be shared/platform-owned Terraform state used by multiple workspaces. Considered for a shared KMS key during this session's architecture review and explicitly rejected for now — see §8: every workspace creates and owns its own KMS key(s) in its own state. Revisit only if a real need for cross-workspace sharing shows up. |
| `infrastructure/application/` | Empty placeholder | Reserved for application-level resources layered on top of a workspace. Not started. |
| `modules/networking`, `modules/kms`, `modules/security`, `modules/storage`, `modules/endpoints` | POC-era, superseded for the factory | Built for the single-shot POC (`infrastructure/nonprod/poc`). Hardcode `var.project_name`, use a placeholder `ec2.amazonaws.com` trust policy in `security` (explicitly flagged in that file's own comment as provisional), single KMS key, 2-bucket storage. `modules/kms` is superseded by `modules/workspace-kms`, and `modules/endpoints` by `modules/workspace-endpoints`, for the factory path (§8) — both POC modules stay only for `infrastructure/nonprod/poc`, don't extend them further. `networking`/`security`/`storage` still need generalized replacements if/when needed. |
| `modules/workspace-network`, `modules/workspace-endpoints`, `modules/workspace-iam-role`, `modules/workspace-kms` | Working | Factory-style modules used by `infrastructure/workspace`. `workspace-network` supports independent existing-or-create per sub-resource (vpc/routing/security-group) — both `custom` and `isolated` strategies are now real, not just modeled in config (§8). `workspace-endpoints` (new) provides the S3 gateway + STS (+ KMS, conditionally) interface endpoints needed whenever there's no NAT. `workspace-iam-role` uses proper Databricks cross-account trust + restricted policy. `workspace-kms` provisions the customer-managed workspace-storage + managed-services keys, gated on `encryption.workspace == "customer_managed"`, with optional bring-your-own-existing-key inputs per key (§8). |
| `modules/databricks-account/`, `modules/databricks-workspace/`, `modules/unity-catalog-data/`, `modules/unity-catalog-workspace/` | **Empty — not started** | Planned module boundaries (names mirror the Databricks SRA repo's `databricks_account/*` and `databricks_workspace/*` module split). Need actual content. |
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

## 5. Known gaps / inconsistencies to resolve

1. **Profile schema is never validated.** `resolver/main.py` validates the
   workspace request and the normalized output, but never calls
   `validate_document()` against `schemas/profile.schema.json` for the loaded
   profile. This is how `profiles/dev.yaml`'s missing `network.architecture`
   key has gone unnoticed.
2. **`profile.schema.json`'s `network.architecture` enum is incomplete, and the
   field is dead.** It only allows `client_managed` / `platform_managed`, but
   `policies/network.yaml`'s `custom` strategy resolves to architecture
   `hybrid` (and `normalized-config.schema.json` correctly allows `hybrid`).
   `resolver.py` never reads `profile["network"]["architecture"]` at all — it
   recomputes architecture itself from `policies/network.yaml`. So
   `stage.yaml`/`live.yaml`'s declared `architecture: client_managed` is
   inert and already disagrees with what the resolver actually produces
   (`hybrid`). **Decision (2026-10-09): explicitly deferred, not fixed this
   pass** — noted here as a known cleanup item (remove the field from the
   profile schema/files, since the resolver is the real source of truth for
   architecture) rather than acted on, to keep the networking/KMS rework
   (§8) bounded.
3. **`platform/inventory/aws.yaml` VPC id is a stale placeholder** (`vpc-PLACEHOLDER`)
   even though the real VPC (`vpc-60c2a81d`) has been known since the POC. The
   resolver reads this file for subnet-allocation validation but the normalized
   output has no `platform` block at all — `var.platform.vpc_id` /
   `var.platform.route_table_ids` in `infrastructure/workspace` are supplied
   directly via `dev.tfvars`, completely bypassing the inventory file. Fix the
   placeholder and decide whether the resolver should start emitting a
   `platform` block into the normalized config so this stops being hand-maintained.
4. **No normalized-YAML → tfvars generator — done, see §8.** `resolver/
   generate_tfvars.py` now does this. `infrastructure/workspace/dev.tfvars`
   (hand-written, HCL) is superseded by the generated
   `document-ai-dev.tfvars.json` — both currently produce an identical
   zero-diff `terraform plan` against the live dev workspace.
   **Decision (2026-10-09): keep `dev.tfvars` for now, flagged for removal.**
   It's redundant now that the generated file is proven equivalent, but the
   user wants to keep it around a bit longer (e.g. as a sanity-check
   reference) before deleting it. Treat it as cleanup debt — safe to delete
   once the generated `*.tfvars.json` workflow has proven itself over a few
   more iterations, but don't remove it unprompted.
5. **`terraform_data.workspace_configuration` in `infrastructure/workspace/main.tf`**
   (lines ~30–67) is leftover/scratch — it stores resolved inputs in a no-op
   resource for inspection but isn't part of the real deployment.
   **Decision: flagged as cleanup debt, not removed yet.** Remove once it's no
   longer needed for inspecting resolved values during development.
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
8. **No workspace-level validation harness yet.** `policies/validation.yaml`
   defines `blocking`/`evidence`/`negative_tests` per environment, but nothing
   in the repo currently executes those checks against a live deployment.
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
  `modules/unity-catalog-workspace` / `modules/unity-catalog-data` should take.
- SRA disables legacy features (Hive metastore, DBFS, no-isolation shared
  clusters) both at account level and workspace level, and enables compliance
  security profile / enhanced security monitoring / automatic cluster update
  as explicit opt-in modules. None of this exists yet in this repo and should
  be considered once the base workspace resource lands.

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
   **Not started.**
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

## 9. Conventions observed (keep consistent)

- Every new workspace deployment gets its own Terraform state boundary under
  `infrastructure/workspace` (or successor root) — never share state across
  workspaces.
- Modules take a `workspace_name` (not `project_name` like the POC modules) and
  tag resources with `ManagedBy = terraform`, `Component = ...`, plus the
  common tag set in `infrastructure/workspace/locals.tf`.
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
- Standing up a new workspace end-to-end: write
  `workspace-requests/<env>/<name>.yaml` → run `resolver/main.py --request
  ... --account ...` → write `infrastructure/workspace/<name>.deployment.yaml`
  (existing ids + concrete subnet CIDRs, see §8) → run
  `resolver/generate_tfvars.py --workspace <name>` → `terraform plan
  -var-file=infrastructure/workspace/<name>.tfvars.json`. Never hand-edit a
  `*.tfvars.json` — regenerate it. `*.deployment.yaml` and `*.tfvars.json`
  are both committed; `local.auto.tfvars` (the Databricks CLI profile) never
  is.
