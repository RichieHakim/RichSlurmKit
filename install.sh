#!/bin/bash
# RichSlurmKit installer. Non-interactive on a clean install.
# - Verifies conda, envsubst, PyYAML
# - Creates config.yaml from config.example.yaml if missing
# - Auto-detects login_host (best-effort) and writes it to config.yaml
# - Adds a marker block to ~/.bashrc that sources shell/shellrc.sh
set -euo pipefail

RSK_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RSK_CONFIG="$RSK_ROOT/config.yaml"
RSK_EXAMPLE="$RSK_ROOT/config.example.yaml"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# In-place sed replacement of top-level scalars (preserves comments).
sed_set() {
    local key="$1" value="$2"
    local esc; esc=$(printf '%s' "$value" | sed -e 's/[&#]/\\&/g')
    sed -i -E "s#^(${key}:)[[:space:]].*#\1 ${esc}#" "$RSK_CONFIG"
}

green "=== RichSlurmKit installer ==="
echo "Repo: $RSK_ROOT"
echo

# 1. Tool checks
if ! command -v conda &>/dev/null; then
    red "Error: 'conda' is not on your PATH."
    red "Install miniconda from https://docs.conda.io/projects/miniconda/en/latest/ and re-run."
    exit 1
fi
if ! command -v envsubst &>/dev/null; then
    red "Error: 'envsubst' is not on your PATH (it ships with the gettext package)."
    red "Install with: apt-get install gettext  /  brew install gettext  /  module load gettext"
    exit 1
fi
python_bin="$(command -v python3 || command -v python)"
if ! "$python_bin" -c 'import yaml' &>/dev/null; then
    yellow "Installing PyYAML (to your user pip site-packages, no admin needed)..."
    "$python_bin" -m pip install --user pyyaml >/dev/null 2>&1
fi
green "Dependencies OK (conda, envsubst, PyYAML)"

# 2. config.yaml
config_was_new=0
if [[ -f "$RSK_CONFIG" ]]; then
    green "Found existing config: $RSK_CONFIG (leaving as-is)"
else
    cp "$RSK_EXAMPLE" "$RSK_CONFIG"
    green "Created config: $RSK_CONFIG"
    config_was_new=1
fi

# 3. Remind about login_host if blank
eval "$("$python_bin" "$RSK_ROOT/lib/load_config.py" "$RSK_CONFIG")"
if [[ -z "${RSK_LOGIN_HOST:-}" ]]; then
    yellow "login_host is blank in $RSK_CONFIG."
    yellow "  Set it to the public alias you SSH into this cluster with"
    yellow "  (e.g. login.rc.fas.harvard.edu, o2.hms.harvard.edu)."
    yellow "  Only needed if you use 'p' from off-cluster."
fi

# 4. ~/.bashrc marker block
bashrc="$HOME/.bashrc"
sentinel_start="# >>> RichSlurmKit >>>"
sentinel_end="# <<< RichSlurmKit <<<"
source_line="source \"$RSK_ROOT/shell/shellrc.sh\""

if [[ -f "$bashrc" ]] && grep -qF "$sentinel_start" "$bashrc"; then
    green "~/.bashrc already wired up"
else
    {
        echo ""
        echo "$sentinel_start"
        echo "$source_line"
        echo "$sentinel_end"
    } >> "$bashrc"
    green "Added source line to ~/.bashrc"
fi

# 5. Detect whether config still has REPLACE-me placeholders; tailor the
# closing message to whichever state the user is actually in.
needs_edits=0
if grep -qE 'YOUR_[A-Z_]+' "$RSK_CONFIG"; then
    needs_edits=1
fi

echo
if [[ $needs_edits -eq 1 ]]; then
    yellow "=== Required edits before 'v' or 'p' will work ==="
    cat <<EOF

Open $RSK_CONFIG and replace every YOUR_* placeholder:
  - YOUR_GPU_ACCOUNT, YOUR_CPU_ACCOUNT    (your SLURM account names)
  - YOUR_H100_PARTITION, YOUR_A100_PARTITION, YOUR_PREEMPT_PARTITION
                                          (your cluster's partition names)
  - 'partition: shared' under 'interactive:' (rename if your cluster uses
    a different name for the default CPU partition)
  - 'conda_env: base' (change if your jupyter env has a different name)

To discover values on your cluster:
  sshare -U \$USER             # accounts you can charge to
  sinfo -s                      # partitions and node counts
  scontrol show partition <p>   # per-partition limits (CPU / mem / time)

Then:
  source ~/.bashrc
  v --list           # show your configured presets
  v                  # submit using preset 1 (the first listed)

Removing this kit later:  ./uninstall.sh   (--purge also drops config)
EOF
else
    green "=== Looks customized; you should be good ==="
    cat <<EOF

  source ~/.bashrc   (if you haven't already, in this shell)
  v --list           # confirm presets
  v                  # submit using preset 1

Removing this kit later:  ./uninstall.sh   (--purge also drops config)
EOF
fi
