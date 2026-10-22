// Azure workspace pipeline (Jenkins, multibranch). A thin wrapper: every real
// step lives in ci/pipeline.py, shared with the GitLab (AWS) pipeline.
// One-time identity setup and the full list of prerequisites: ci/README.md.
//
// Flow: pull requests touching workspace-requests/azure/** get detect +
// verify + plan; the default branch additionally waits for a manual
// approval (input step) and then applies exactly the plan from this build,
// then validates the workspace.
//
// Expects:
//   - an agent labelled 'databricks-azure' with python3/pip, terraform,
//     az CLI and databricks CLI;
//   - the "OpenID Connect Provider" plugin, with an id-token credential
//     'azure-federated-token' (audience api://AzureADTokenExchange) that an
//     Entra federated credential on the deploying app trusts;
//   - string credentials 'azure-client-id', 'azure-tenant-id',
//     'azure-subscription-id' (identifiers, not secrets).

// Script-binding variables (no `def`), so the declarative pipeline's
// closures below can read them.
DEFAULT_BRANCH = 'main'
APPROVERS = 'databricks-platform-approvers' // Jenkins user/group ids allowed to approve

// Workload identity federation - no stored client secret. Terraform's
// azurerm/azuread providers and the azurerm backend use the ARM_* OIDC
// variables; `az login --federated-token` covers the az CLI, the Databricks
// provider (auth_type azure-cli) and the validator. The id-token credential
// mints a fresh token on each binding, so the apply after approval (maybe
// much later) gets its own.
def withAzureIdentity(Closure body) {
  withCredentials([
    string(credentialsId: 'azure-federated-token', variable: 'ARM_OIDC_TOKEN'),
    string(credentialsId: 'azure-client-id', variable: 'ARM_CLIENT_ID'),
    string(credentialsId: 'azure-tenant-id', variable: 'ARM_TENANT_ID'),
    string(credentialsId: 'azure-subscription-id', variable: 'ARM_SUBSCRIPTION_ID'),
  ]) {
    withEnv(['ARM_USE_OIDC=true']) {
      sh '''
        az login --service-principal -u "$ARM_CLIENT_ID" -t "$ARM_TENANT_ID" \
          --federated-token "$ARM_OIDC_TOKEN" --output none
        az account set --subscription "$ARM_SUBSCRIPTION_ID"
      '''
      body()
    }
  }
}

pipeline {
  agent { label 'databricks-azure' }

  options {
    disableConcurrentBuilds()
    timestamps()
  }

  environment {
    TF_IN_AUTOMATION = 'true'
    PLAN_DIR = 'plans'
  }

  stages {
    stage('Detect') {
      steps {
        sh 'python3 -m pip install --quiet -r requirements.txt'
        script {
          def base
          if (env.CHANGE_TARGET) {
            sh "git fetch --no-tags origin +refs/heads/${env.CHANGE_TARGET}:refs/remotes/origin/${env.CHANGE_TARGET}"
            base = "origin/${env.CHANGE_TARGET}"
          } else {
            base = env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: 'HEAD~1'
          }
          // Exits 3 (failing the build) if a request was deleted - CI never
          // tears a workspace down.
          sh "python3 ci/pipeline.py changed --cloud azure --base ${base} --output changed.json"
          env.REQUESTS = sh(
            returnStdout: true,
            script: "python3 -c \"import json; print(' '.join(json.load(open('changed.json'))['changed']))\""
          ).trim()
          if (!env.REQUESTS) {
            echo 'No Azure request changes.'
          }
        }
      }
    }

    stage('Plan') {
      when { expression { env.REQUESTS } }
      steps {
        withAzureIdentity {
          sh '''
            for request in $REQUESTS; do
              python3 ci/pipeline.py verify --request "$request"
              python3 ci/pipeline.py plan --request "$request" --out-dir "$PLAN_DIR"
            done
          '''
        }
        archiveArtifacts artifacts: 'plans/*.plan.txt, changed.json'
        stash name: 'plans', includes: 'plans/**'
      }
    }

    stage('Approve') {
      when { expression { env.BRANCH_NAME == DEFAULT_BRANCH && env.REQUESTS } }
      steps {
        input message: "Apply the archived plans for: ${env.REQUESTS}?", ok: 'Apply', submitter: APPROVERS
      }
    }

    stage('Apply') {
      when { expression { env.BRANCH_NAME == DEFAULT_BRANCH && env.REQUESTS } }
      steps {
        unstash 'plans'
        withAzureIdentity {
          sh '''
            for request in $REQUESTS; do
              python3 ci/pipeline.py apply --request "$request" --plan-dir "$PLAN_DIR"
            done
          '''
        }
      }
    }
  }

  post {
    always {
      sh 'az logout || true'
    }
  }
}
