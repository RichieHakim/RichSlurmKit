#!/bin/bash
# Uninstaller for RichSlurmKit.
# Default: just remove the sentinel block from ~/.bashrc.
# --purge: also remove config.yaml and the devtunnel binary.
set -euo pipefail

RSK_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
purge=0
for arg in "$@"; do
    case "$arg" in
        --purge) purge=1 ;;
        -h|--help)
            echo "Usage: ./uninstall.sh [--purge]"
            echo "  --purge   Also delete config.yaml and ~/.local/share/richslurmkit/"
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
    mv "$tmp" "$bashrc"
    echo "Removed RichSlurmKit block from ~/.bashrc"
else
    echo "No RichSlurmKit block found in ~/.bashrc"
fi

if [[ $purge -eq 1 ]]; then
    rm -f "$RSK_ROOT/config.yaml"
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/richslurmkit"
    echo "Purged config.yaml and ~/.local/share/richslurmkit/"
    echo "(SLURM logs in ~/.local/state/richslurmkit/ left in place.)"
fi

echo "Done. Re-source ~/.bashrc (or open a new shell) to clear PATH/aliases."
