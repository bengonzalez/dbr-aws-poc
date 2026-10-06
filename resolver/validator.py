import json
from pathlib import Path

from jsonschema import Draft202012Validator


def load_schema(path: Path) -> dict:
    """Load a JSON Schema file."""

    if not path.exists():
        raise FileNotFoundError(f"Schema file not found: {path}")

    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def validate_document(
    document: dict,
    schema_path: Path,
    document_name: str,
) -> None:
    """
    Validate a document against a JSON Schema.

    Raises ValueError when validation fails.
    """

    schema = load_schema(schema_path)

    validator = Draft202012Validator(schema)

    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: list(error.absolute_path),
    )

    if not errors:
        return

    messages = []

    for error in errors:
        path = ".".join(str(part) for part in error.absolute_path)

        if not path:
            path = "<root>"

        messages.append(
            f"{path}: {error.message}"
        )

    raise ValueError(
        f"{document_name} failed schema validation:\n"
        + "\n".join(f"  - {message}" for message in messages)
    )