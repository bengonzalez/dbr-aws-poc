# Azure account-level deployment - template, not a real deployment

Unlike `infrastructure/deployments/aws/account/331f8702-.../`, no real
directory exists here yet, because the real Azure Databricks account id
is not known anywhere in this project (CLAUDE.md §10 backlog item #1a /
§8 milestone 40).

To stand this up for real:

1. Run `databricks auth login --host https://accounts.azuredatabricks.net`
   (interactive, opens a browser) to discover the real account id - it
   appears in the resulting profile / in the account console's URL/UI
   after you select or land on an account.
2. Copy `terraform.tfvars.json.example` and `backend.tfbackend.example`
   from this directory into a new, real
   `infrastructure/deployments/azure/account/<the-real-account-id>/`
   directory, filling in the real `databricks_account_id`.
3. Follow the same `terraform init -backend-config=... -backend-config=...`
   convention as every other root in this project (see CLAUDE.md §9).

Delete this TEMPLATE directory's README once a real directory exists,
or leave it - it does no harm either way.
