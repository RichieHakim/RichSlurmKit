#!/bin/bash
# RichSlurmKit installer.
# - Verifies conda is on PATH
# - Ensures PyYAML is importable (installs to --user if not)
# - Walks through a short config setup, writes ./config.yaml
# - Adds a sentinel-wrapped `source` line to ~/.bashrc
set -euo pipefail

RSK_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RSK_CONFIG="$RSK_ROOT/config.yaml"
RSK_EXAMPLE="$RSK_ROOT/config.example.yaml"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

green "=== RichSlurmKit installer ==="
echo "Repo:   $RSK_ROOT"
echo

# 1. conda check
if ! command -v conda &>/dev/null; then
    red "Error: 'conda' is not on your PATH."
    red "RichSlurmKit uses conda to activate environments inside SLURM jobs."
    red "Install miniconda from https://docs.conda.io/projects/miniconda/en/latest/"
    red "and re-run this script."
    exit 1
fi
green "Found conda: $(command -v conda)"

# 2. envsubst check
if ! command -v envsubst &>/dev/null; then
    red "Error: 'envsubst' is not on your PATH (provided by gettext)."
    red "On HPC clusters this is almost always present; ask sysadmin if not."
    exit 1
fi

# 3. PyYAML
python_bin="$(command -v python3 || command -v python)"
if ! "$python_bin" -c 'import yaml' &>/dev/null; then
    yellow "PyYAML not found; installing to --user site-packages..."
    "$python_bin" -m pip install --user pyyaml
fi
green "PyYAML OK"

# 4. config.yaml
if [[ -f "$RSK_CONFIG" ]]; then
    read -r -p "config.yaml already exists. Overwrite from example? [y/N] " ans
    if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
        cp "$RSK_EXAMPLE" "$RSK_CONFIG"
        yellow "Reset config.yaml from example."
    else
        echo "Keeping existing config.yaml."
    fi
else
    cp "$RSK_EXAMPLE" "$RSK_CONFIG"
fi

echo
echo "Basic settings (Enter to accept the shown default)."
echo "Defaults come from config.yaml; edit it later to tune presets and resources."
echo

# Pull defaults from the just-prepared config.yaml so config is the single
# source of truth -- editing config.example.yaml propagates here automatically.
eval "$("$python_bin" "$RSK_ROOT/lib/load_config.py" "$RSK_CONFIG")"

# Fallback for login_host: hostname -f if config has it empty.
default_login_host="${RSK_LOGIN_HOST:-}"
if [[ -z "$default_login_host" ]]; then
    default_login_host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
fi

prompt() {
    local label="$1" help="$2" default="$3" val
    # Label/help go to stderr so $(prompt ...) only captures the final value.
    printf '  %s\n    %s\n' "$label" "$help" >&2
    read -r -p "    [${default}]: " val
    printf '%s' "${val:-$default}"
}

login_host=$(prompt \
    "Login host" \
    "Hostname you SSH to from your laptop to reach this cluster. Used only by 'p' to print a laptop-side ssh-tunnel one-liner." \
    "$default_login_host")

conda_env=$(prompt \
    "Default conda env" \
    "Conda env activated inside SLURM jobs. Override per-call with 'v --env name'." \
    "${RSK_CONDA_ENV:-base}")

# In-place sed replacement of top-level scalars (preserves comments).
sed_set() {
    local key="$1" value="$2"
    # Escape any & and # in value for sed.
    local esc; esc=$(printf '%s' "$value" | sed -e 's/[&#]/\\&/g')
    sed -i -E "s#^(${key}:)[[:space:]].*#\1 ${esc}#" "$RSK_CONFIG"
}

sed_set login_host "$login_host"
sed_set conda_env  "$conda_env"

green "Wrote $RSK_CONFIG"

# 5. ~/.bashrc sentinel block
bashrc="$HOME/.bashrc"
sentinel_start="# >>> RichSlurmKit >>>"
sentinel_end="# <<< RichSlurmKit <<<"
source_line="source \"$RSK_ROOT/shell/shellrc.sh\""

if [[ -f "$bashrc" ]] && grep -qF "$sentinel_start" "$bashrc"; then
    yellow "RichSlurmKit block already present in ~/.bashrc; not modifying."
else
    {
        echo ""
        echo "$sentinel_start"
        echo "$source_line"
        echo "$sentinel_end"
    } >> "$bashrc"
    green "Added source line to ~/.bashrc"
fi

cat <<EOF

=== Done ===
Next steps:
  1.  source ~/.bashrc
  2.  Create your conda env if it doesn't exist: conda create -n ${conda_env} python=3.11 jupyterlab
  3.  Edit ${RSK_CONFIG} to customize SLURM presets (accounts, partitions, etc.)
  4.  Try:  v --list   then   v   to submit your first job.

If you previously had aliases or scripts in ~/.bashrc that overlap with
RichSlurmKit (v, p, pp, vclean, etc.), remove them so RichSlurmKit wins on PATH.

If you have running 'jupyter-tunnel' jobs from a pre-RichSlurmKit p script,
their logs don't carry the RSK_JOB_* lines, so the new pp won't be able to
reconnect to them. Either finish them with the old ssh -L command, or
re-submit via p.
EOF
