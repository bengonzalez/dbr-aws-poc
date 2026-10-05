from pathlib import Path
import yaml


def load_yaml(path: Path) -> dict:
    """Load a YAML file and return its contents as a dictionary."""

    if not path.exists():
        raise FileNotFoundError(f"Configuration file not found: {path}")

    with path.open("r", encoding="utf-8") as file:
        data = yaml.safe_load(file)

    if data is None:
        raise ValueError(f"Configuration file is empty: {path}")

    if not isinstance(data, dict):
        raise ValueError(
            f"Configuration file must contain a YAML object: {path}"
        )

    return data