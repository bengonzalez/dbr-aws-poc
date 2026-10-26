#!/usr/bin/env bash
# End-to-end demo of a client-built VPC handoff (CLAUDE.md §10 item #15).
#
#   ./demo.sh vpc        build the client-shaped VPC, write the filled handoff
#   ./demo.sh import     check the handoff against AWS, write the request
#   ./demo.sh plan       generate files and plan the workspace
#   ./demo.sh apply      apply that plan, then validate the workspace
#   ./demo.sh teardown   destroy the workspace (teardown.py --purge-files)
#   ./demo.sh vpc-down   destroy the VPC; remove the handoff and request
#   ./demo.sh up         vpc + import + plan + apply
#   ./demo.sh down       teardown + vpc-down
#
# Settings (environment variables, defaults in brackets):
#   NAME [tsa-shape-proof]  ENV [dev]  REQ_ID [REQ-00200]
#   DBX_ACCOUNT [TSA account]  DBX_PROFILE [TSA]  COST_CENTER [platform-test]
#   SUBMITTED_BY [$USER]  TGW [false]  AUTO_APPROVE [unset]
#
# Needs AWS credentials for account 556940913059 and a valid account-console
# Databricks profile. Run from Git Bash (Windows) or any POSIX shell.

set -euo pipefail

NAME=${NAME:-tsa-shape-proof}
ENV=${ENV:-dev}
REQ_ID=${REQ_ID:-REQ-00200}
DBX_ACCOUNT=${DBX_ACCOUNT:-eddbb85f-6b3c-4261-8ca2-0d9d62575ce2}
DBX_PROFILE=${DBX_PROFILE:-TSA}
COST_CENTER=${COST_CENTER:-platform-test}
SUBMITTED_BY=${SUBMITTED_BY:-${USER:-${USERNAME:-demo}}}
TGW=${TGW:-false}

FIXTURE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$FIXTURE/../../.." && pwd)
HANDOFF="client-handoffs/aws/$ENV/$NAME.yaml"
REQUEST="workspace-requests/aws/$ENV/$NAME.yaml"
PLAN_DIR="$FIXTURE/.demo/plan"

cd "$ROOT"

say() { printf '\n==> %s\n' "$*"; }

vpc() {
    say "Building the client VPC ($NAME)"
    terraform -chdir="$FIXTURE" init -input=false >/dev/null
    terraform -chdir="$FIXTURE" apply -input=false ${AUTO_APPROVE:+-auto-approve} \
        -var "workspace_name=$NAME" -var "environment=$ENV" \
        -var "databricks_account_id=$DBX_ACCOUNT" -var "create_transit_gateway=$TGW"
    say "Handoff written to $HANDOFF"
}

import() {
    say "Importing $HANDOFF"
    python resolver/import_client_handoff.py --handoff "$HANDOFF" \
        --request-id "$REQ_ID" --submitted-by "$SUBMITTED_BY" \
        --cost-center "$COST_CENTER" --force
}

plan() {
    say "Generating files and planning $NAME"
    local account
    account=$(aws sts get-caller-identity --query Account --output text)
    python ci/pipeline.py prepare --request "$REQUEST" --account "$account"
    rm -rf "$PLAN_DIR" && mkdir -p "$PLAN_DIR"
    python ci/pipeline.py plan --request "$REQUEST" --out-dir "$PLAN_DIR"
}

apply() {
    say "Applying $NAME"
    python ci/pipeline.py apply --request "$REQUEST" --plan-dir "$PLAN_DIR" \
        --databricks-profile "$DBX_PROFILE"
}

teardown() {
    say "Tearing down workspace $NAME"
    python resolver/teardown.py --workspace "$NAME" --provider aws --yes --purge-files
}

vpc_down() {
    say "Destroying the client VPC ($NAME)"
    terraform -chdir="$FIXTURE" init -input=false >/dev/null
    terraform -chdir="$FIXTURE" destroy -input=false ${AUTO_APPROVE:+-auto-approve} \
        -var "workspace_name=$NAME" -var "environment=$ENV" \
        -var "databricks_account_id=$DBX_ACCOUNT" -var "create_transit_gateway=$TGW"
    rm -f "$REQUEST"
    rm -rf "$FIXTURE/.demo"
}

case "${1:-}" in
    vpc) vpc ;;
    import) import ;;
    plan) plan ;;
    apply) apply ;;
    teardown) teardown ;;
    vpc-down) vpc_down ;;
    up) vpc; import; plan; apply ;;
    down) teardown; vpc_down ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
esac
