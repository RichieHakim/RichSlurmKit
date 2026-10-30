#!/bin/bash
# Uninstaller for RichSlurmKit.
# Default: remove the sentinel block from ~/.bashrc, the path-links mod and the
# claude-paste VS Code extension.
# --purge: also remove config.yaml, the zmx and devtunnel binaries, the saved
# VS Code tunnel login, and pasted images.
set -euo pipefail

RSK_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
purge=0
for arg in "$@"; do
    case "$arg" in
        --purge) purge=1 ;;
        -h|--help)
            echo "Usage: ./uninstall.sh [--purge]"
            echo "  --purge   Also delete config.yaml, ~/.local/share/richslurmkit/ (binaries, tunnel login)"
            echo "            and ~/.cache/claude-paste/ (pasted images)"
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

bashrc="$HOME/.bashrc"
sentinel_start="# >>> RichSlurmKit >>>"
sentinel_end="# <<< RichSlurmKit <<<"

if [[ -f "$bashrc" ]] && grep -qF "$sentinel_start" "$bashrc"; then
    tmp=$(mktemp)
    awk -v s="$sentinel_start" -v e="$sentinel_end" '
        $0 == s { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip
    ' "$bashrc" > "$tmp"
    # Write through, so a symlinked ~/.bashrc stays a symlink with its mode.
    cat "$tmp" > "$bashrc"
    rm -f "$tmp"
    echo "Removed RichSlurmKit block from ~/.bashrc"
else
    echo "No RichSlurmKit block found in ~/.bashrc"
fi

zellij_cfg_src="$RSK_ROOT/zellij/config.kdl"
zellij_cfg_dst="$HOME/.config/zellij/config.kdl"
if [[ -L "$zellij_cfg_dst" ]] && [[ "$(readlink -f "$zellij_cfg_dst")" == "$(readlink -f "$zellij_cfg_src")" ]]; then
    rm -f "$zellij_cfg_dst"
    echo "Removed zellij config symlink"
fi

# The path-links Claude Code mod and the folder marketplace install.sh added for it.
if command -v claude &>/dev/null; then
    if [[ "$(claude plugin list 2>/dev/null)" == *"path-links@rsk-local"* ]] &&
       claude plugin uninstall path-links@rsk-local >/dev/null; then
        echo "Removed the path-links Claude Code mod"
    fi
    if [[ "$(claude plugin marketplace list 2>/dev/null)" == *"($RSK_ROOT/mods/path-links)"* ]]; then
        claude plugin marketplace remove rsk-local >/dev/null || true
    fi
fi

# The claude-paste VS Code extension, then the commandsToSkipShell entry it
# added to the node's Remote settings. `code` reaches VS Code only from one of
# its terminals.
if command -v code &>/dev/null &&
   code --list-extensions 2>/dev/null | grep -qx richslurmkit.claude-paste &&
   code --uninstall-extension richslurmkit.claude-paste >/dev/null 2>&1; then
    echo "Removed the claude-paste VS Code extension"
fi
machine_settings="$HOME/.vscode-server/data/Machine/settings.json"
if [[ -f "$machine_settings" ]] && grep -qF claudePaste.paste "$machine_settings"; then
    python3 - "$machine_settings" <<'EOF' && echo "Removed claudePaste.paste from $machine_settings"
import json, sys
path, key = sys.argv[1], "terminal.integrated.commandsToSkipShell"
try:
    settings = json.load(open(path))
except ValueError:
    sys.exit(f"{path} isn't plain JSON; remove claudePaste.paste from {key} by hand.")
rest = [c for c in settings.get(key, []) if c != "claudePaste.paste"]
if rest:
    settings[key] = rest
else:
    settings.pop(key, None)
with open(path, "w") as f:
    f.write(json.dumps(settings, indent=4) + "\n")
EOF
    rm -f "$machine_settings.bak-claude-paste"
fi

if [[ $purge -eq 1 ]]; then
    rm -f "$RSK_ROOT/config.yaml"
    # The zmx binary lives in the data dir below; drop our symlink to it.
    zmx_link="$HOME/.local/bin/zmx"
    if [[ -L "$zmx_link" && "$(readlink "$zmx_link")" == "${XDG_DATA_HOME:-$HOME/.local/share}/richslurmkit/"* ]]; then
        rm -f "$zmx_link"
    fi
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/richslurmkit"
    # The job template keeps the tunnel login here regardless of XDG_DATA_HOME.
    rm -rf "$HOME/.local/share/richslurmkit/vscode-cli-auth"
    rm -rf "$HOME/.cache/claude-paste"
    echo "Purged config.yaml, ~/.local/share/richslurmkit/ and ~/.cache/claude-paste/"
    echo "(Left in place: job logs in $RSK_ROOT/logs/.)"
fi

echo "Done. Re-source ~/.bashrc (or open a new shell) to clear PATH/aliases."
