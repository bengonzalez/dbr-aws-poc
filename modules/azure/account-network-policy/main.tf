# Account-level Databricks network policy - direct port of
# modules/aws/account-network-policy (CLAUDE.md §10 backlog item #1a /
# §8 milestone 40). Creates a NEW, named policy - distinct from the
# account's own un-deletable "default-policy" every workspace uses today
# (confirmed from the provider's own docs) - so this module's existence
# changes nothing for any existing workspace until that workspace's own
# `network_policy_id` is explicitly set to this policy's id (see
# resolver/generate_tfvars_azure.py and
# modules/azure/workspace-deployment's network_policy_id variable).
#
# Real finding worth remembering (confirmed from the provider's current
# docs): egress.network_access's restriction_mode governs how
# SERVERLESS workloads reach the internet - it has no effect on
# classic, VNet-injected compute, which is the only compute shape this
# factory builds for Azure today (CLAUDE.md §1/§6). So restrict_egress
# is safe to flip on without any classic-cluster lockout risk. The real
# lockout risk in this resource is on the INGRESS side -
# context_based_ingress_ip_acl governs public access to the workspace/
# account console UI itself, and a wrong IP range there really can lock
# an operator out.

resource "databricks_account_network_policy" "this" {
  provider = databricks.mws

  account_id        = var.databricks_account_id
  network_policy_id = substr("${var.resource_prefix}-np", 0, 32) # provider requires <= 32 chars

  egress = {
    network_access = {
      restriction_mode = var.restrict_egress ? "RESTRICTED_ACCESS" : "FULL_ACCESS"

      allowed_internet_destinations = var.restrict_egress ? [
        for d in var.allowed_internet_destinations : {
          destination               = d
          internet_destination_type = "DNS_NAME"
        }
      ] : []

      policy_enforcement = {
        enforcement_mode = "ENFORCED"
      }
    }
  }

  # Only sent when an ingress IP allow-list is requested. Any ingress block
  # - even the permissive one below - needs context-based ingress, a gated
  # account feature: an account without it rejects the whole policy with
  # "Feature `CBI Policy Private Access` has not been enabled for account"
  # (found applying this for real, CLAUDE.md �8 milestone 44). Omitting it
  # matches the account's own default-policy, which has no ingress block.
  # Setting context_based_ingress_ip_acl still needs Databricks to enable
  # that feature on the account first.
  ingress = length(var.context_based_ingress_ip_acl) == 0 ? null : {
    # No endpoints are registered against this policy by default, so this
    # has no practical effect until PrivateLink/private-endpoint
    # registration is in play - safe to leave permissive.
    private_access = {
      restriction_mode = "ALLOW_ALL_REGISTERED_ENDPOINTS"
    }

    # Preserves pre-network-policy cross-workspace access behavior.
    cross_workspace_access = {
      restriction_mode = "LEGACY_MODE"
    }

    public_access = {
      restriction_mode = length(var.context_based_ingress_ip_acl) > 0 ? "RESTRICTED_ACCESS" : "FULL_ACCESS"

      allow_rules = length(var.context_based_ingress_ip_acl) > 0 ? [
        {
          label = "${var.resource_prefix}-ingress-allow"
          origin = {
            included_ip_ranges = {
              ip_ranges = var.context_based_ingress_ip_acl
            }
          }
        }
      ] : []
    }
  }
}
