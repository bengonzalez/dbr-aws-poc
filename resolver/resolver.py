def resolve_configuration(
    request: dict,
    profile: dict,
    network_policy: dict,
    security_policy: dict,
    data_policy: dict,
    governance_policy: dict,
    validation_policy: dict,
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

    network_resources = network_strategy_config["resources"]

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
    # Build normalized configuration
    # ---------------------------------------------------------

    normalized = {
        "api_version": "v1",

        "workspace": {
            "name": request["workspace"]["name"],
            "environment": environment,
            "isolation": profile["workspace"]["isolation"],
        },

        "cloud": {
            "provider": request["cloud"]["provider"],
            "region": request["cloud"]["region"],
            "account": account_id,
        },

        "application": request["application"],

        "ownership": request["ownership"],

        "network": {
            "strategy": network_strategy,
            "architecture": network_strategy_config["architecture"],
            "requirements": network_resources,
        },

        "data": {
            "classification": data_classification,
        },

        "encryption": data_classification_config["encryption"],

        "governance": {
            "unity_catalog": governance_uc_required,
            "workspace_binding": workspace_binding,
        },

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