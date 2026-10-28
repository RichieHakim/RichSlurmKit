#!/bin/bash
# Uninstaller for RichSlurmKit.
# Default: remove the sentinel block from ~/.bashrc and the path-links mod.
# --purge: also remove config.yaml, the zmx and devtunnel binaries, and the
# saved VS Code tunnel login.
set -euo pipefail

RSK_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
purge=0
for arg in "$@"; do
    case "$arg" in
        --purge) purge=1 ;;
        -h|--help)
            echo "Usage: ./uninstall.sh [--purge]"
            echo "  --purge   Also delete config.yaml and ~/.local/share/richslurmkit/ (binaries, tunnel login)"
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
    echo "Purged config.yaml and ~/.local/share/richslurmkit/"
    echo "(Left in place: job logs in $RSK_ROOT/logs/.)"
fi

echo "Done. Re-source ~/.bashrc (or open a new shell) to clear PATH/aliases."
