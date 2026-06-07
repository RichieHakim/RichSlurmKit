# Single entrypoint sourced from ~/.bashrc. Sets RSK_ROOT, adds bin/ to PATH,
# defines the path-shortcut aliases. Lightweight on purpose -- no YAML parse
# happens here; that's deferred until a script actually needs config.

RSK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RSK_ROOT

case ":$PATH:" in
    *":$RSK_ROOT/bin:"*) ;;
    *) export PATH="$RSK_ROOT/bin:$PATH" ;;
esac

source "$RSK_ROOT/shell/aliases.sh"
source "$RSK_ROOT/shell/completions.sh"  # tab-complete session names for z/zc/zcr
