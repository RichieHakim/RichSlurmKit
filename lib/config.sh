# Sourced by every bin/ script. Loads RSK_* environment from config.yaml.
# Read fresh on each invocation -> edits to config.yaml are hot.

# Find repo root if not already set by shellrc.sh.
if [[ -z "${RSK_ROOT:-}" ]]; then
    _rsk_self="$(readlink -f "${BASH_SOURCE[0]}")"
    RSK_ROOT="$(dirname "$(dirname "$_rsk_self")")"
    export RSK_ROOT
fi

RSK_CONFIG="${RSK_CONFIG:-$RSK_ROOT/config.yaml}"
export RSK_CONFIG

if [[ ! -f "$RSK_CONFIG" ]]; then
    echo "RichSlurmKit: config.yaml missing. Run $RSK_ROOT/install.sh" >&2
    return 1 2>/dev/null || exit 1
fi

# Pick a python: prefer the active env's, else system python3.
_rsk_python="$(command -v python3 || command -v python)"
if [[ -z "$_rsk_python" ]]; then
    echo "RichSlurmKit: python not found on PATH." >&2
    return 1 2>/dev/null || exit 1
fi

_rsk_config_out="$("$_rsk_python" "$RSK_ROOT/lib/load_config.py" "$RSK_CONFIG")" || {
    echo "RichSlurmKit: failed to parse $RSK_CONFIG" >&2
    return 1 2>/dev/null || exit 1
}
eval "$_rsk_config_out"
unset _rsk_config_out _rsk_python _rsk_self

# Identity (always available to templates).
RSK_USER="${USER}"
export RSK_USER

# Where slurm logs and `--keep-rendered` job files land. Lives inside the
# repo (gitignored) so it's a sibling of config.yaml -- one folder for
# everything. Logs survive across re-clones if you cp the dir; otherwise
# they're per-clone.
RSK_STATE_DIR="$RSK_ROOT/logs"
export RSK_STATE_DIR
mkdir -p "$RSK_STATE_DIR"

# Where the devtunnel binary gets cached.
RSK_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/richslurmkit"
export RSK_DATA_DIR
