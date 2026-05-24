from __future__ import annotations

import os
import sys
from pathlib import Path


DATA_HOME_ENV = "PCA_DATA_HOME"
DATA_FOLDER_NAME = "personalcontactsanalyzerDATA"

APP_ROOT = Path(__file__).resolve().parents[2]
WORKSPACE_ROOT = APP_ROOT.parent.parent
DEFAULT_DATA_HOME = WORKSPACE_ROOT / DATA_FOLDER_NAME


def configured_data_home() -> Path:
    raw = os.environ.get(DATA_HOME_ENV)
    if raw:
        return normalize_data_home(Path(raw).expanduser())
    return DEFAULT_DATA_HOME


def default_data_dir() -> Path:
    return configured_data_home() / "data"


def data_path(*parts: str) -> Path:
    return default_data_dir().joinpath(*parts)


def normalize_data_home(path: Path) -> Path:
    resolved = path.expanduser()
    if resolved.name == "data":
        return resolved.parent
    return resolved


def resolve_data_home_interactively() -> Path:
    candidate = configured_data_home()
    if candidate.exists():
        return candidate
    if not sys.stdin.isatty():
        raise SystemExit(
            f"Could not find data folder at {candidate}. Move {DATA_FOLDER_NAME} next to "
            f"mac-scripts, or set {DATA_HOME_ENV} to its path."
        )
    print(f"Could not find the data folder at: {candidate}", file=sys.stderr)
    print(
        f"Enter the path to {DATA_FOLDER_NAME} (or to its data subfolder). "
        f"Leave blank to create/use the default location.",
        file=sys.stderr,
    )
    raw = input("Data folder path: ").strip()
    if raw:
        chosen = normalize_data_home(Path(raw))
    else:
        chosen = candidate
    (chosen / "data").mkdir(parents=True, exist_ok=True)
    return chosen


def rebase_default_path(path: Path, old_data_home: Path, new_data_home: Path) -> Path:
    try:
        relative = path.relative_to(old_data_home)
    except ValueError:
        return path
    return new_data_home / relative
