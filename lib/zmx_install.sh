#!/bin/bash
# Install zmx (https://github.com/neurosnap/zmx), the session-persistence tool
# behind the `m*` commands. Pinned version + sha256; installs to a versioned
# path under $RSK_DATA_DIR and points ~/.local/bin/zmx at it.
#
# zmx's README warns that switching between versions with IPC changes kills
# every running session, so this never replaces an installed zmx while
# sessions are alive unless you pass --force. Nothing upgrades zmx on its own.
#
# Usage: lib/zmx_install.sh [--force]
set -euo pipefail

ZMX_VERSION="0.8.1"
declare -A ZMX_SHA256=(
    [x86_64]="dfd75720b942466f28870731cc86dbc07afa72fb8f3bd5eeb4ff707e4eecebe8"
    [aarch64]="943eb44c812333fd450da12097521afd3339436e86f8c2ac618b905c4c9ece68"
)

force=0
[[ "${1:-}" == "--force" ]] && force=1

arch="$(uname -m)"
if [[ "$(uname -s)" != "Linux" || -z "${ZMX_SHA256[$arch]:-}" ]]; then
    echo "zmx_install: no pinned build for $(uname -s)/$arch; install zmx yourself." >&2
    exit 1
fi

data_dir="${RSK_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/richslurmkit}"
dest_dir="$data_dir/zmx/$ZMX_VERSION"
dest="$dest_dir/zmx"
link="$HOME/.local/bin/zmx"

if [[ "$(readlink -f "$link" 2>/dev/null)" == "$(readlink -f "$dest" 2>/dev/null)" && -x "$dest" ]]; then
    echo "zmx $ZMX_VERSION already installed ($link)"
    exit 0
fi

if [[ -e "$link" && $force -eq 0 ]]; then
    current="$("$link" version 2>/dev/null | awk '$1 == "zmx" {print $2}')"
    if [[ "$current" != "$ZMX_VERSION" ]] && "$link" list --short 2>/dev/null | grep -q .; then
        echo "zmx_install: zmx ${current:-?} is installed and has live sessions." >&2
        echo "  Switching versions can kill them. Re-run with --force when they can go." >&2
        exit 1
    fi
fi

if [[ ! -x "$dest" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    tarball="zmx-${ZMX_VERSION}-linux-${arch}.tar.gz"
    url="https://github.com/neurosnap/zmx/releases/download/v${ZMX_VERSION}/${tarball}"
    curl -fsSL "$url" -o "$tmp/$tarball"
    got="$(sha256sum "$tmp/$tarball" | awk '{print $1}')"
    if [[ "$got" != "${ZMX_SHA256[$arch]}" ]]; then
        echo "zmx_install: sha256 mismatch for $tarball (got $got)" >&2
        exit 1
    fi
    tar -C "$tmp" -xzf "$tmp/$tarball" zmx
    mkdir -p "$dest_dir"
    install -m 755 "$tmp/zmx" "$dest.tmp"
    mv -f "$dest.tmp" "$dest"
fi

# Atomic symlink swap: a running zmx keeps its own inode either way.
mkdir -p "$(dirname "$link")"
ln -sfn "$dest" "$link.tmp"
mv -Tf "$link.tmp" "$link"
echo "Installed zmx $ZMX_VERSION: $link -> $dest"
