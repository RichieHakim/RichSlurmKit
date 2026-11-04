#!/bin/bash
# RichSlurmKit installer. Non-interactive on a clean install.
# - Verifies envsubst and PyYAML (installs PyYAML if missing); warns if no conda
# - Creates config.yaml from config.example.yaml if missing
# - Adds a marker block to ~/.bashrc that sources shell/shellrc.sh
# - Installs zmx (for `m`), and links the zellij config if zellij is installed
# - Installs the Claude Code mods (clickable file paths, /speak) if claude is installed
# - Installs the claude-paste VS Code extension (image paste) if run in a VS Code terminal
# - Checks that a new shell runs the kit's commands, not others with the same names
set -euo pipefail

RSK_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RSK_CONFIG="$RSK_ROOT/config.yaml"
RSK_EXAMPLE="$RSK_ROOT/config.example.yaml"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

green "=== RichSlurmKit installer ==="
echo "Repo: $RSK_ROOT"
echo

# 1. Tool checks
if ! command -v conda &>/dev/null; then
    yellow "Warning: 'conda' is not on your PATH. v and p activate an env inside the job"
    yellow "  with 'source activate <env>' unless you set 'activate:' in config.yaml."
fi
if ! command -v envsubst &>/dev/null; then
    red "Error: 'envsubst' is not on your PATH (it ships with the gettext package)."
    red "Install with: apt-get install gettext  /  brew install gettext  /  module load gettext"
    exit 1
fi
python_bin="$(command -v python3 || command -v python)"
if ! "$python_bin" -c 'import yaml' &>/dev/null; then
    yellow "Installing PyYAML (to your user pip site-packages, no admin needed)..."
    if ! "$python_bin" -m pip install --user pyyaml >/dev/null 2>&1; then
        red "Error: could not install PyYAML with: $python_bin -m pip install --user pyyaml"
        red "Install it another way (e.g. conda install pyyaml) and re-run."
        exit 1
    fi
fi
green "Dependencies OK (envsubst, PyYAML)"

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

# 5. zmx, for the m* commands. A failure here only affects m / mc / mcr, so
# it doesn't stop the rest of the install.
if "$RSK_ROOT/lib/zmx_install.sh"; then
    green "zmx ready (m / mc / mcr)"
else
    yellow "zmx not installed; m / mc / mcr won't work until it is."
    yellow "  Retry with: $RSK_ROOT/lib/zmx_install.sh"
fi

# 6. zellij config, only for people who use the z* helpers (docs/zellij.md).
# Symlink; leaves an existing config.kdl alone.
zellij_cfg_src="$RSK_ROOT/zellij/config.kdl"
zellij_cfg_dst="$HOME/.config/zellij/config.kdl"
if ! command -v zellij &>/dev/null; then
    echo "zellij not found; skipping its config (only the z* helpers need it)"
elif [[ -L "$zellij_cfg_dst" ]]; then
    if [[ "$(readlink -f "$zellij_cfg_dst")" == "$(readlink -f "$zellij_cfg_src")" ]]; then
        green "zellij config already linked"
    else
        yellow "zellij config is a symlink to $(readlink "$zellij_cfg_dst"); leaving as-is"
        yellow "  To use RichSlurmKit's bindings instead:"
        yellow "    ln -sf $zellij_cfg_src $zellij_cfg_dst"
    fi
elif [[ -e "$zellij_cfg_dst" ]]; then
    yellow "zellij config exists at $zellij_cfg_dst; leaving as-is"
    yellow "  To add RichSlurmKit's bindings, see zellij/config.kdl in this repo."
    yellow "  Summary: unbinds Ctrl+o and Ctrl+g (for Claude Code), moves the"
    yellow "  zellij session-mode prefix to Ctrl+\\ (then d/q/g for detach/quit/lock)."
else
    mkdir -p "$(dirname "$zellij_cfg_dst")"
    ln -s "$zellij_cfg_src" "$zellij_cfg_dst"
    green "Linked zellij config: $zellij_cfg_dst -> $zellij_cfg_src"
fi

# 7. The Claude Code mods in mods/: path-links, which makes file paths in
# Claude's replies clickable in VS Code (README, "Clicking file paths"), and
# speak, which adds /speak to hear a reply (README, "Hearing replies"). Claude
# reads them from their folders, so edits reach open sessions with
# /reload-plugins. The catalog used to be mods/path-links alone; adding mods/
# under the same name, rsk-local, moves it. A failure here only affects the mods.
mods_dir="$RSK_ROOT/mods"
if ! command -v claude &>/dev/null; then
    echo "claude not found; skipping the Claude Code mods"
elif [[ "$(claude plugin marketplace list 2>/dev/null)" != *"($mods_dir)"* ]] &&
     ! claude plugin marketplace add "$mods_dir" >/dev/null; then
    yellow "Could not add the Claude Code mods; file paths stay unclickable and there's no /speak."
    yellow "  Retry with: claude plugin marketplace add $mods_dir"
else
    installed="$(claude plugin list 2>/dev/null || true)"
    for mod in path-links speak; do
        if [[ $installed == *"$mod@rsk-local"* ]]; then
            green "$mod mod already installed"
        elif claude plugin install "$mod@rsk-local" >/dev/null; then
            green "Installed the $mod mod (run /reload-plugins in open Claude sessions)"
        else
            yellow "Could not install the $mod mod. Retry with: claude plugin install $mod@rsk-local"
        fi
    done
    # Not installed here: it's about 800 MB.
    data_dir="${RSK_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/richslurmkit}"
    if [[ ! -f $data_dir/kokoro/voices-v1.0.bin ]]; then
        echo "/speak needs Kokoro, about 800 MB. Install it with: $RSK_ROOT/lib/kokoro_install.sh"
    fi
fi

# 8. The claude-paste VS Code extension, which makes Ctrl+V in a VS Code
# terminal paste the laptop's clipboard image into Claude (README, "Pasting
# images"). `code` reaches VS Code only from one of its terminals, so from
# anywhere else this step is skipped. A failure here only affects pasting.
ext_dir="$RSK_ROOT/vscode/claude-paste"
ext_id="richslurmkit.claude-paste@$("$python_bin" -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$ext_dir/package.json")"
vsix_dir=""
if ! command -v code &>/dev/null || ! installed=$(code --list-extensions --show-versions 2>/dev/null); then
    echo "No VS Code window answered; skipping the claude-paste extension"
    echo "  To install it, run ./install.sh again from a VS Code terminal on the node."
elif grep -qxF "$ext_id" <<< "$installed"; then
    green "claude-paste extension already installed"
elif vsix_dir=$(mktemp -d) &&
     "$python_bin" "$ext_dir/pack.py" "$vsix_dir/claude-paste.vsix" &&
     code --install-extension "$vsix_dir/claude-paste.vsix" --force >/dev/null 2>&1; then
    green "Installed the claude-paste VS Code extension (Ctrl+V pastes images into Claude)"
else
    yellow "Could not install the claude-paste extension; Ctrl+V won't paste images into Claude."
    yellow "  Retry with: $python_bin $ext_dir/pack.py ~/claude-paste.vsix"
    yellow "              code --install-extension ~/claude-paste.vsix"
fi
[[ -n "$vsix_dir" ]] && rm -r "$vsix_dir"

# 9. Check that a new shell runs the kit's commands. shellrc.sh puts bin/ first
# on PATH, but lines in ~/.bashrc after the RichSlurmKit block, and aliases or
# shell functions with the same names, still come before it. The new shell's
# own output (login banners and such) goes to /dev/null; the check writes to
# fd 3, and ends with a marker line so a shell that died or hung isn't read as
# a pass.
cmds=("$RSK_ROOT"/bin/*)
shadowed=$(timeout -s KILL 30 bash -ic '
    bin=$1; shift
    for c in "$@"; do
        first=$(type -a -- "$c" 2>/dev/null | head -n 1)
        [[ $first == "$c is $bin/$c" ]] || echo "  $first"
    done >&3
    echo __rsk_done__ >&3' _ "$RSK_ROOT/bin" "${cmds[@]##*/}" 3>&1 </dev/null >/dev/null 2>&1) || true
if [[ "$shadowed" != *__rsk_done__ ]]; then
    yellow "Couldn't check which commands a new shell runs (bash -ic didn't finish)."
else
    shadowed=${shadowed%__rsk_done__}
    shadowed=${shadowed%$'\n'}
    if [[ -n "$shadowed" ]]; then
        yellow "In a new shell, these names run something other than the kit's command:"
        echo "$shadowed"
        yellow "  Something in ~/.bashrc after the RichSlurmKit block, or an alias or"
        yellow "  function with the same name, comes first. Remove or rename it to use the kit's."
    else
        green "New shells run the kit's commands"
    fi
fi

# 10. Detect whether config still has REPLACE-me placeholders; tailor the
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
