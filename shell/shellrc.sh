# Single entrypoint sourced from ~/.bashrc. Sets RSK_ROOT, adds bin/ to PATH,
# defines the path-shortcut aliases. Lightweight on purpose -- no YAML parse
# happens here; that's deferred until a script actually needs config.

RSK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RSK_ROOT

# Put bin/ first on PATH, even when a parent shell already added it. ~/.bashrc
# may add other folders before sourcing this file, and a shell started inside
# another shell would otherwise find their same-named commands first.
_rsk_path=":$PATH:"
while [[ $_rsk_path == *":$RSK_ROOT/bin:"* ]]; do
    _rsk_path=${_rsk_path//":$RSK_ROOT/bin:"/:}
done
_rsk_path=${_rsk_path#:}
_rsk_path=${_rsk_path%:}
export PATH="$RSK_ROOT/bin${_rsk_path:+:$_rsk_path}"
unset _rsk_path

# zmx (for m*) installs to ~/.local/bin. Add it, last, if the system didn't.
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$PATH:$HOME/.local/bin" ;;
esac

source "$RSK_ROOT/shell/aliases.sh"
source "$RSK_ROOT/shell/completions.sh"  # tab-complete session names for z/zc/zcr

# Same zmx socket dir in every shell on a node (see lib/mx.sh), so a plain
# `zmx` sees the sessions the m* commands create.
export ZMX_DIR="${ZMX_DIR:-/tmp/zmx-$UID}"
