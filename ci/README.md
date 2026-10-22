# CI pipelines

Two CI systems drive the same factory:

| Cloud | CI system | Wrapper | Approval gate |
|---|---|---|---|
| AWS | GitLab CI | [`.gitlab-ci.yml`](../.gitlab-ci.yml) | `when: manual` apply job + a protected environment (`aws-workspaces`) that requires approval |
| Azure | Jenkins (multibranch) | [`Jenkinsfile`](../Jenkinsfile) | `input` step restricted to an approvers list |

Both wrappers are thin: triggers, identity, the approval gate and artifacts.
Every real step is in [`ci/pipeline.py`](pipeline.py), so behaviour is identical on both
clouds and every step can be run locally.

## Flow

1. **A requester adds or edits** `workspace-requests/<cloud>/<env>/<name>.yaml`, then runs
   ```
   python ci/pipeline.py prepare --request workspace-requests/<cloud>/<env>/<name>.yaml --account <aws-account-id | azure-subscription-id>
   ```
   and commits the generated files with the request: `normalized/<cloud>/<name>.yaml` and
   `infrastructure/deployments/<cloud>/<env>/<name>/`. Reviewers see exactly what will be
   applied (CIDRs, keys, flags) in the merge/pull request.
2. **On the merge/pull request**, CI runs:
   - `changed`: which requests changed. A **deleted** request fails the run; CI never tears
     anything down (use `resolver/teardown.py` deliberately).
   - `verify`: regenerate and fail if the committed files differ.
   - `plan`: `terraform plan -out`. The readable plan is kept as an artifact.
3. **After merge to the default branch**, the same steps run again. Then:
   - an approver approves;
   - `apply` applies **exactly that saved plan**. Terraform rejects it as stale if state moved
     since.
   - `resolver/validate_deployment.py` runs. A `blocking` validation policy (stage/live) fails
     the job on any FAIL.
4. Before touching anything, `plan` and `apply` check that the job's cloud identity is the
   account/subscription the request resolved to.

## One-time identity setup (workload identity federation, no stored secrets)

### AWS + GitLab

1. **AWS IAM OIDC provider** for the GitLab instance: issuer `https://<gitlab-host>`, audience
   `sts.amazonaws.com`.
2. **IAM role** (`AWS_ROLE_ARN`) with a trust policy for `sts:AssumeRoleWithWebIdentity` from
   that provider. Condition `<gitlab-host>:sub` should cover this project, e.g.
   `project_path:<group>/<project>:ref_type:branch:ref:*`. Permissions must cover everything
   `modules/aws/*` creates (VPC/subnets/endpoints, IAM roles/policies, S3, KMS), plus the state
   bucket (`beng-tfstatefiles` or the client's equivalent).
3. **Databricks service principal** in the target Databricks account:
   - make it an **account admin**: workspaces, credentials, storage configs and network configs
     are account-level APIs;
   - add a **federation policy** for it: issuer `https://<gitlab-host>`, audience = the
     Databricks account id, subject = the same project/ref pattern as above.
   - Put its application id in `DATABRICKS_CLIENT_ID`.
4. GitLab CI/CD variables: `PIPELINE_IMAGE`, `AWS_ROLE_ARN`, `DATABRICKS_CLIENT_ID`,
   `DATABRICKS_ACCOUNT_ID`.
5. **Protected environment** `aws-workspaces` with required approvals, and the default branch
   protected.

> **Verify first:** Databricks documents token federation with workspace hosts. The AWS root
> talks to the **account** host (`accounts.cloud.databricks.com`). Confirm `env-oidc` works there
> with a one-off job before relying on it:
> `databricks account workspaces list` with `DATABRICKS_HOST=https://accounts.cloud.databricks.com`.

### Azure + Jenkins

1. **Jenkins** needs the **OpenID Connect Provider** plugin. Its issuer
   (`https://<jenkins-host>/oidc`) must be reachable by Entra ID to fetch signing keys. Create an
   *id-token* credential `azure-federated-token` with audience `api://AzureADTokenExchange`.
2. **Entra app registration + service principal**, with a **federated credential**: issuer = the
   Jenkins issuer URL, subject = the token's `sub` (by default the Jenkins job URL), audience
   `api://AzureADTokenExchange`.
3. **Azure roles** for that service principal on the subscription (or the target resource
   groups):
   - **Contributor**;
   - **Role Based Access Control Administrator**: the Unity Catalog, key and private-link
     modules create role assignments;
   - access to the Terraform state storage account.
   
   It also needs Microsoft Graph application permission **Application.Read.All**, because
   `modules/azure/workspace-kms` looks up the `AzureDatabricks` app.
4. Jenkins string credentials `azure-client-id`, `azure-tenant-id`, `azure-subscription-id`.
   These are identifiers, not secrets.
5. An agent labelled `databricks-azure` with `python3`/`pip`, `terraform`, `az` and the
   `databricks` CLI. Set `APPROVERS` in the `Jenkinsfile` to the people/groups allowed to
   approve applies.

No Databricks account-admin role is needed on Azure unless a workspace attaches an account
network policy (`network_policy_id`). Everything else uses the workspace-scoped provider; a
service principal that creates a workspace is its admin.

## Running the steps locally

Use the same commands as CI, with your own `az login` / AWS credentials. On AWS, pass
`--databricks-profile TSA` to `apply` (or rely on `infrastructure/aws/workspace/local.auto.tfvars`
for plan):

```
python ci/pipeline.py changed --cloud azure --base main
python ci/pipeline.py verify  --request workspace-requests/azure/dev/isolated-proof.yaml
python ci/pipeline.py plan    --request workspace-requests/azure/dev/isolated-proof.yaml --out-dir plans
python ci/pipeline.py apply   --request workspace-requests/azure/dev/isolated-proof.yaml --plan-dir plans
```

## Not yet

- Teardown from CI (deleted requests only fail the run).
- One job per workspace (dynamic child pipelines / parallel stages). Today one job loops over the
  changed requests.
- A shared pipeline image definition.
