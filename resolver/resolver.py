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

    network_resources = network_strategy_config["resources"]

    # ---------------------------------------------------------
    # Resolve platform network inventory
    # ---------------------------------------------------------

    aws_inventory = inventory["aws"]

    account_inventory = None

    for account_name, account in aws_inventory["accounts"].items():
        if account["account_id"] == account_id:
            account_inventory = account
            break

    if account_inventory is None:
        raise ValueError(
            f"AWS account '{account_id}' is not defined "
            f"in the platform inventory."
        )

    region = request["cloud"]["region"]

    region_inventory = account_inventory["regions"].get(region)

    if region_inventory is None:
        raise ValueError(
            f"AWS region '{region}' is not defined for "
            f"account '{account_id}' in the platform inventory."
        )

    if not region_inventory["approved"]:
        raise ValueError(
            f"AWS region '{region}' is not approved for "
            f"account '{account_id}'."
        )

    network_inventory = region_inventory["networks"].get("primary")

    if network_inventory is None:
        raise ValueError(
            f"No primary network is defined for "
            f"account '{account_id}' and region '{region}'."
        )

    subnet_inventory = network_inventory["subnets"]["private"]

    subnet_allocation = subnet_inventory.get("allocation")

    if subnet_inventory["ownership"] == "terraform":

        if subnet_allocation is None:
            raise ValueError(
                "Terraform-owned private subnets require "
                "an allocation definition."
            )

        if (
            subnet_allocation["count"]
            != len(subnet_allocation["availability_zones"])
        ):
            raise ValueError(
                "Private subnet allocation count does not match "
                "the number of availability zones."
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

            "requirements": {
                "vpc": {
                    "ownership": network_resources["vpc"]["ownership"],
                },

                "subnets": {
                    "ownership": network_resources["subnets"]["ownership"],

                    "allocation": {
                        "source": "platform",
                        "count": subnet_allocation["count"],
                        "availability_zones": (
                            subnet_allocation["availability_zones"]
                        ),
                        "cidr_source": subnet_allocation["cidr_source"],
                    },
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
        },

        "data": {
            "classification": data_classification,
        },

        "encryption": {
            "workspace": profile["encryption"]["workspace"],
            "application_data": profile["encryption"]["application_data"],
        },

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
