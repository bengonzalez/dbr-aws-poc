def resolve_required_value(
    attribute: str,
    values: list[tuple[str, str]],
) -> str:
    """
    Resolve a value that must be consistent across all sources.

    Raises ValueError if multiple sources require different values.
    """

    unique_values = {value for _, value in values}

    if len(unique_values) > 1:
        details = "\n".join(
            f"  - {source}: {value}"
            for source, value in values
        )

        raise ValueError(
            f"Conflicting requirements for '{attribute}':\n"
            f"{details}"
        )

    return next(iter(unique_values))

def validate_encryption_requirements(
    profile_encryption: dict,
    security_policy: dict,
    data_encryption_policy: dict,
) -> None:
    """
    Validate that the encryption implementation selected by the
    environment profile satisfies the requirements imposed by
    both the security policy and the data classification policy.
    """

    # ---------------------------------------------------------
    # Security policy requirements
    # ---------------------------------------------------------

    security_encryption = security_policy["workspace"]["encryption"]

    if security_encryption.get("required", False):

        workspace_encryption = profile_encryption.get("workspace")
        application_data_encryption = profile_encryption.get(
            "application_data"
        )

        if not workspace_encryption:
            raise ValueError(
                "Encryption is required by the security policy, "
                "but the profile does not define workspace encryption."
            )

        if not application_data_encryption:
            raise ValueError(
                "Encryption is required by the security policy, "
                "but the profile does not define application data encryption."
            )

    # ---------------------------------------------------------
    # Data classification requirements
    # ---------------------------------------------------------

    if data_encryption_policy.get("required", False):

        workspace_encryption = profile_encryption.get("workspace")
        application_data_encryption = profile_encryption.get(
            "application_data"
        )

        if not workspace_encryption:
            raise ValueError(
                "Encryption is required by the data policy, "
                "but the profile does not define workspace encryption."
            )

        if not application_data_encryption:
            raise ValueError(
                "Encryption is required by the data policy, "
                "but the profile does not define application data encryption."
            )

    # ---------------------------------------------------------
    # Stronger data classification requirement
    # ---------------------------------------------------------

    if data_encryption_policy.get(
        "customer_managed_required",
        False,
    ):

        if profile_encryption.get("workspace") != "customer_managed":
            raise ValueError(
                "Customer-managed encryption is required by the "
                "data policy for workspace encryption, but the "
                "selected profile does not provide it."
            )

        if profile_encryption.get("application_data") != "customer_managed":
            raise ValueError(
                "Customer-managed encryption is required by the "
                "data policy for application data encryption, but "
                "the selected profile does not provide it."
            )

def resolve_configuration(
    request: dict,
    profile: dict,
    network_policy: dict,
    security_policy: dict,
    data_policy: dict,
    governance_policy: dict,
    validation_policy: dict,
    inventory: dict,
    account_id: str,
) -> dict:

    environment = request["workspace"]["environment"]
    network_strategy = request["network"]["strategy"]
    data_classification = request["data"]["classification"]

    # ---------------------------------------------------------
    # Resolve network
    # ---------------------------------------------------------

    network_strategy_config = network_policy["strategies"].get(
        network_strategy
    )

    if network_strategy_config is None:
        raise ValueError(
            f"Network strategy '{network_strategy}' is not defined."
        )

    allowed_strategies = network_policy["allowed_strategies"].get(
        environment
    )

    if allowed_strategies is None:
        raise ValueError(
            f"No allowed network strategies are defined for "
            f"environment '{environment}' in policies/policies.yaml's "
            f"network_policy."
        )

    if network_strategy not in allowed_strategies:
        raise ValueError(
            f"Network strategy '{network_strategy}' is not allowed for "
            f"environment '{environment}'. Allowed strategies: "
            f"{', '.join(allowed_strategies)}."
        )

    network_resources = network_strategy_config["resources"]

    # ---------------------------------------------------------
    # Resolve platform network inventory
    #
    # Only the region-approval check lives here. Concrete VPC/subnet
    # values (ids, CIDRs, the subnet_defaults sizing/AZ convention) are
    # account-specific facts not known until deployment.yaml names the
    # real account/subscription - resolved in resolver/generate_tfvars.py
    # instead, same boundary as the metastore id / connectivity
    # resolution. Keyed generically by cloud.provider so the same block
    # works for platform/inventory/aws.yaml's "accounts" and
    # platform/inventory/azure.yaml's "accounts" (Azure subscriptions,
    # same key names reused for a single generic code path here).
    # ---------------------------------------------------------

    provider = request["cloud"]["provider"]
    provider_inventory = inventory[provider]

    account_inventory = None

    for account_name, account in provider_inventory["accounts"].items():
        if account["account_id"] == account_id:
            account_inventory = account
            break

    if account_inventory is None:
        raise ValueError(
            f"{provider} account/subscription '{account_id}' is not "
            f"defined in the platform inventory."
        )

    region = request["cloud"]["region"]

    region_inventory = account_inventory["regions"].get(region)

    if region_inventory is None:
        raise ValueError(
            f"{provider} region '{region}' is not defined for "
            f"account/subscription '{account_id}' in the platform "
            f"inventory."
        )

    if not region_inventory["approved"]:
        raise ValueError(
            f"{provider} region '{region}' is not approved for "
            f"account/subscription '{account_id}'."
        )

    # ---------------------------------------------------------
    # Resolve data classification
    # ---------------------------------------------------------

    data_classification_config = data_policy["classifications"].get(
        data_classification
    )

    if data_classification_config is None:
        raise ValueError(
            f"Data classification '{data_classification}' is not defined."
        )

    # ---------------------------------------------------------
    # Resolve governance
    # ---------------------------------------------------------

    governance_uc_required = (
        governance_policy["unity_catalog"]["required"]
    )

    workspace_binding = governance_policy["workspace_binding"].get(
        environment
    )

    if workspace_binding is None:
        raise ValueError(
            f"No Unity Catalog workspace binding policy exists "
            f"for environment '{environment}'."
        )

    # ---------------------------------------------------------
    # Validate encryption requirements
    # ---------------------------------------------------------

    data_encryption_policy = data_classification_config["encryption"]

    validate_encryption_requirements(
        profile_encryption=profile["encryption"],
        security_policy=security_policy,
        data_encryption_policy=data_encryption_policy,
    )

    # ---------------------------------------------------------
    # Resolve validation
    # ---------------------------------------------------------

    validation_profile = validation_policy["profiles"].get(
        environment
    )

    if validation_profile is None:
        raise ValueError(
            f"No validation policy exists for environment '{environment}'."
        )

    # ---------------------------------------------------------
    # Resolve governance requester input - a pure passthrough, not
    # resolved from any policy/profile (unlike unity_catalog/
    # workspace_binding above). Optional: a request naming no
    # catalog_admin_principal just leaves the catalog ungranted.
    # ---------------------------------------------------------

    governance = {
        "unity_catalog": governance_uc_required,
        "workspace_binding": workspace_binding,
    }

    request_governance = request.get("governance", {})

    for key in ("catalog_admin_principal", "compliance_standards", "existing_metastore_id"):
        if key in request_governance:
            governance[key] = request_governance[key]

    # ---------------------------------------------------------
    # Resolve encryption requester input - plain passthrough (bring-your-
    # own KMS key ARNs), same treatment as governance.catalog_admin_principal
    # above. encryption.workspace/application_data stay entirely profile-
    # derived - the requester never picks the encryption MODE, only
    # optionally supplies an existing key once customer_managed applies.
    # ---------------------------------------------------------

    encryption = {
        "workspace": profile["encryption"]["workspace"],
        "application_data": profile["encryption"]["application_data"],
    }

    request_encryption = request.get("encryption", {})

    for key in (
        "existing_workspace_storage_key_arn",
        "existing_workspace_storage_key_alias",
        "existing_managed_services_key_arn",
        "existing_managed_services_key_alias",
        # Azure's Key Vault equivalents (CLAUDE.md §8 milestone 42).
        "existing_workspace_storage_key_id",
        "existing_managed_services_key_id",
        "existing_application_data_key_id",
    ):
        if key in request_encryption:
            encryption[key] = request_encryption[key]

    # ---------------------------------------------------------
    # Resolve network requester input - plain passthroughs, not
    # resolved against any policy here (same treatment as
    # governance.catalog_admin_principal above). Which AWS/Databricks
    # account the workspace runs on (needed to validate/resolve these
    # against the platform inventory) isn't known until deployment.yaml
    # names it, so that resolution happens in
    # resolver/generate_tfvars.py, not here. All optional: a request
    # naming none of these just leaves them for generate_tfvars.py's own
    # defaults (inventory lookups / explicit deployment.yaml overrides).
    # ---------------------------------------------------------

    request_network = request.get("network", {})

    network = {
        "strategy": network_strategy,
        "architecture": network_strategy_config["architecture"],
        "connectivity": request_network.get("connectivity", "auto"),

        "requirements": {
            "vpc": {
                "ownership": network_resources["vpc"]["ownership"],
            },

            "subnets": {
                "ownership": network_resources["subnets"]["ownership"],
            },

            "routing": {
                "ownership": network_resources["routing"]["ownership"],
            },

            "security_groups": {
                "ownership": (
                    network_resources["security_groups"]["ownership"]
                ),
            },

            "endpoints": {
                "ownership": network_resources["endpoints"]["ownership"],
            },
        },
    }

    for key in (
        "vpc_cidr",
        "existing_vpc_id",
        "existing_vpc_cidr",
        "existing_security_group_id",
        "existing_route_table_ids",
        "existing_subnet_ids",
    ):
        if key in request_network:
            network[key] = request_network[key]

    # ---------------------------------------------------------
    # Resolve cloud requester input - databricks_account_id is a plain
    # passthrough override, same treatment as the network/governance
    # passthroughs above. Which AWS account this workspace runs on
    # (account_id) is a pipeline/operator input (the --account flag),
    # not requester-controlled - only the Databricks account it
    # registers with inside that AWS account is ever requester-
    # overridable, and only for the rare case the AWS account's
    # inventory default isn't the right one.
    # ---------------------------------------------------------

    cloud = {
        "provider": request["cloud"]["provider"],
        "region": request["cloud"]["region"],
        "account": account_id,
    }

    if "databricks_account_id" in request.get("cloud", {}):
        cloud["databricks_account_id"] = request["cloud"]["databricks_account_id"]

    # ---------------------------------------------------------
    # Build normalized configuration
    # ---------------------------------------------------------

    normalized = {
        "api_version": "v1",

        "workspace": {
            "name": request["workspace"]["name"],
            "environment": environment,
            "isolation": profile["workspace"]["isolation"],
        },

        "cloud": cloud,

        "application": request["application"],

        "ownership": request["ownership"],

        "network": network,

        "data": {
            "classification": data_classification,
        },

        "encryption": encryption,

        "governance": governance,

        "compute": {
            "policy": profile["compute"]["policy"],
        },

        "logging": {
            "level": profile["logging"]["level"],
            "centralized": profile["logging"]["centralized"],
            "audit": profile["logging"].get("audit", False),
        },

        "validation": {
            "required": validation_policy["defaults"]["required"],
            "blocking": validation_profile["blocking"],
            "negative_tests": validation_policy["defaults"]["negative_tests"],
            "evidence": validation_profile["evidence"],
        },

        "tags": request.get("tags", {}),
    }

    return normalized
