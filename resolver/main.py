from pathlib import Path
import argparse
import yaml

from loader import load_yaml
from resolver import resolve_configuration
from validator import validate_document

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(
        description="Databricks workspace configuration resolver"
    )

    parser.add_argument(
        "--request",
        required=True,
        help="Path to workspace request YAML",
    )

    parser.add_argument(
        "--account",
        required=True,
        help="AWS account ID or Azure subscription ID (depending on the request's cloud.provider)",
    )

    args = parser.parse_args()

    request_path = ROOT / args.request

    request = load_yaml(request_path)

    request_schema_path = ROOT / "schemas" / "workspace-request.schema.json"

    validate_document(
        document=request,
        schema_path=request_schema_path,
        document_name="Workspace request",
    )
    print("Workspace request validation: PASS")

    environment = request["workspace"]["environment"]
    provider = request["cloud"]["provider"]

    profile_path = ROOT / "profiles" / f"{environment}.yaml"
    policies_path = ROOT / "policies" / "policies.yaml"
    inventory_path = ROOT / "platform" / "inventory" / f"{provider}.yaml"

    profile = load_yaml(profile_path)
    policies = load_yaml(policies_path)
    inventory = load_yaml(inventory_path)

    network_policy = policies["network_policy"]
    security_policy = policies["security_policy"]
    data_policy = policies["data_policy"]
    governance_policy = policies["governance_policy"]
    validation_policy = policies["validation_policy"]

    profile_schema_path = ROOT / "schemas" / "profile.schema.json"

    validate_document(
        document=profile,
        schema_path=profile_schema_path,
        document_name=f"Profile '{environment}'",
    )
    print(f"Profile '{environment}' validation: PASS")

    normalized = resolve_configuration(
        request=request,
        profile=profile,
        network_policy=network_policy,
        security_policy=security_policy,
        data_policy=data_policy,
        governance_policy=governance_policy,
        validation_policy=validation_policy,
        inventory=inventory,
        account_id=args.account,
    )

    normalized_schema_path = (
        ROOT / "schemas" / "normalized-config.schema.json"
    )

    validate_document(
        document=normalized,
        schema_path=normalized_schema_path,
        document_name="Normalized configuration",
    )

    print("Normalized configuration validation: PASS")

    output_directory = ROOT / "normalized"
    output_directory.mkdir(exist_ok=True)

    workspace_name = request["workspace"]["name"]

    output_path = (
        output_directory / f"{workspace_name}.yaml"
    )

    with output_path.open("w", encoding="utf-8") as file:
        yaml.safe_dump(
            normalized,
            file,
            sort_keys=False,
        )

    print(f"Normalized configuration written to:")
    print(output_path)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        print()
        print("Workspace Factory Validation")
        print("----------------------------")
        print()
        print("STATUS: FAILED")
        print()
        print(error)
        print()
        print("No provisioning was performed.")

        raise SystemExit(1)