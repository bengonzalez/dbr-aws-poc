from pathlib import Path
import yaml


def resolve_normalized_path(root: Path, workspace: str, provider: str | None) -> Path:
    """
    Find normalized/<provider>/<workspace>.yaml. Scripts that only take
    --workspace (generate_tfvars.py, generate_backend_config.py) don't know
    a workspace's cloud provider up front the way resolver/main.py does
    (it reads the request, which already has cloud.provider, before
    choosing where to write) - so this auto-detects by checking every
    provider's normalized/ subdirectory, same "fail loudly on genuine
    ambiguity, stay ergonomic for the common case" convention as the rest
    of this project (e.g. resolver.py's resolve_required_value()). A
    workspace name colliding across providers is rare by convention, not
    by any enforced uniqueness check - see CLAUDE.md Sec8 milestone 35's
    first real occurrence of this (two workspaces both named
    'isolated-proof', one per cloud, as a deliberate sanity-check pair).
    """

    normalized_root = root / "normalized"

    if provider:
        path = normalized_root / provider / f"{workspace}.yaml"

        if not path.exists():
            raise FileNotFoundError(
                f"No normalized config at {path} - run resolver/main.py first."
            )

        return path

    candidates = sorted(normalized_root.glob(f"*/{workspace}.yaml"))

    if len(candidates) == 0:
        raise FileNotFoundError(
            f"No normalized/<provider>/{workspace}.yaml found for any "
            f"provider - run resolver/main.py first."
        )

    if len(candidates) > 1:
        providers = ", ".join(sorted(path.parent.name for path in candidates))

        raise ValueError(
            f"Workspace '{workspace}' has a normalized config under more "
            f"than one provider ({providers}) - pass --provider to "
            f"disambiguate which one you mean."
        )

    return candidates[0]


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