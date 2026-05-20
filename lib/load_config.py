#!/usr/bin/env python3
"""Read RichSlurmKit config.yaml and emit shell-evaluable RSK_* assignments.

Usage:  eval "$(python load_config.py /path/to/config.yaml)"

Top-level scalars       -> RSK_<KEY>
Nested 1-level scalars  -> RSK_<PARENT>_<KEY>
List `presets`          -> RSK_PRESET_COUNT + RSK_PRESET_<N>_<FIELD>
"""
import os
import shlex
import sys
from string import Template

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "RichSlurmKit: PyYAML not installed. Run: pip install --user pyyaml\n"
    )
    sys.exit(1)


def expand(value):
    """Allow ${HOME} and $USER style refs inside config values."""
    if isinstance(value, str):
        return Template(value).safe_substitute(os.environ)
    return value


def emit(name, value):
    if value is None:
        value = ""
    value = expand(value)
    print(f'{name}={shlex.quote(str(value))}')


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: load_config.py <config.yaml>\n")
        sys.exit(2)

    path = sys.argv[1]
    if not os.path.exists(path):
        sys.stderr.write(f"RichSlurmKit: config not found at {path}\n")
        sys.stderr.write("Run install.sh, or copy config.example.yaml -> config.yaml\n")
        sys.exit(1)

    with open(path) as f:
        data = yaml.safe_load(f) or {}

    presets = data.pop("presets", []) or []

    for key, value in data.items():
        var_base = f"RSK_{key.upper()}"
        if isinstance(value, dict):
            for sub_key, sub_value in value.items():
                emit(f"{var_base}_{sub_key.upper()}", sub_value)
        else:
            emit(var_base, value)

    emit("RSK_PRESET_COUNT", len(presets))
    for i, preset in enumerate(presets, start=1):
        if not isinstance(preset, dict):
            continue
        for field, val in preset.items():
            emit(f"RSK_PRESET_{i}_{field.upper()}", val)


if __name__ == "__main__":
    main()
