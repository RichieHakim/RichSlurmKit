# Sourced by the zmx-based m* commands (m, mc, mcr).

_rsk_mx_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
RSK_MX_PY="$_rsk_mx_root/lib/mx.py"

# Pin the socket dir. zmx otherwise prefers $XDG_RUNTIME_DIR, which is set in
# some shells (ssh logins) and not others (Slurm jobs), and terminals that
# disagree can't see each other's sessions. This is zmx's own default when
# neither XDG_RUNTIME_DIR nor TMPDIR is set. Sessions are per node.
export ZMX_DIR="${ZMX_DIR:-/tmp/zmx-$UID}"

if ! command -v zmx >/dev/null 2>&1; then
    echo "zmx is not installed. Install it with: $_rsk_mx_root/lib/zmx_install.sh" >&2
    exit 1
fi

rsk_mx_exists() { zmx list --short 2>/dev/null | grep -qxF -- "$1"; }

rsk_mx_next_name() {
    local i=0
    while rsk_mx_exists "claude_$i"; do i=$((i+1)); done
    echo "claude_$i"
}
