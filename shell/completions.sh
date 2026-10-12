# Bash tab-completion for the zellij wrappers (z / zc / zcr / zz / zzc / zzcr)
# and the zmx wrappers (m / mc / mcr / mrevive).
# Completes live session names so you can do e.g.  `z a my_ses<TAB>`.
# Sourced from shellrc.sh. Bash only (guarded below); harmless if skipped.

# Only meaningful in an interactive bash with the `complete` builtin.
if [ -n "${BASH_VERSION:-}" ]; then

_rsk_zellij_sessions() {
    # Short list = bare session names, one per line. Running sessions only,
    # which is what you can attach/switch to.
    zellij list-sessions -s 2>/dev/null
}

# `z` is a thin passthrough to `zellij`, so complete zellij subcommands on the
# first word and session names wherever a session name is expected.
_rsk_complete_z() {
    local cur prev sub
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    sub="${COMP_WORDS[1]}"

    # `... -s NAME` / `... --session NAME`
    case "$prev" in
        -s|--session)
            COMPREPLY=( $(compgen -W "$(_rsk_zellij_sessions)" -- "$cur") )
            return ;;
    esac

    # First token after `z`: offer the common subcommands (and their aliases).
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "\
attach kill-session delete-session list-sessions options setup action run edit \
kill-all-sessions delete-all-sessions \
a k d ls ka da ac e" -- "$cur") )
        return
    fi

    # Inside a subcommand that takes a session name, complete names
    # (but not when the user is typing an option like -c).
    case "$sub" in
        a|attach|k|kill-session|d|delete-session)
            if [ "${cur:0:1}" != "-" ]; then
                COMPREPLY=( $(compgen -W "$(_rsk_zellij_sessions)" -- "$cur") )
            fi
            return ;;
    esac
}
complete -F _rsk_complete_z z

# zc / zcr / zz / zzc / zzcr take an optional session name as their sole positional arg. Offer
# existing names so attaching to a running one is a tab away (typing a brand
# new name still works -- compgen just won't suggest anything). For parity with
# `z a <name>`, also complete the slot after an optional leading `a`/`attach`.
_rsk_complete_zc() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [ "$COMP_CWORD" -eq 2 ]; then
        case "${COMP_WORDS[1]}" in
            a|attach) ;;   # name lives in slot 2 -- complete it
            *) return ;;
        esac
    elif [ "$COMP_CWORD" -ne 1 ]; then
        return
    fi
    COMPREPLY=( $(compgen -W "$(_rsk_zellij_sessions)" -- "$cur") )
}
complete -F _rsk_complete_zc zc zcr zz zzc zzcr

# --- zmx wrappers (m / mc / mcr / mrevive) ---------------------------------

_rsk_zmx_sessions() {
    ZMX_DIR="${ZMX_DIR:-/tmp/zmx-$UID}" zmx list --short 2>/dev/null
}

# `m` passes through to zmx: complete its subcommands (long and short forms)
# first, then session names for the subcommands that take one.
_rsk_complete_m() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "\
attach run send print write detach list ls end kill history get set clear print-env \
wait tail completions version help a r s p wr d l k g cl hi w t c v h" -- "$cur") )
        return
    fi
    case "${COMP_WORDS[1]}" in
        a|attach|r|run|s|send|p|print|wr|write|end|k|kill|hi|history|g|get|set|cl|clear|print-env|w|wait|t|tail)
            COMPREPLY=( $(compgen -W "$(_rsk_zmx_sessions)" -- "$cur") ) ;;
    esac
}
complete -F _rsk_complete_m m

_rsk_complete_mc() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    [ "$COMP_CWORD" -eq 1 ] || return
    COMPREPLY=( $(compgen -W "$(_rsk_zmx_sessions)" -- "$cur") )
}
complete -F _rsk_complete_mc mc mcr

# mrevive: recorded session names (one JSON file each) plus its options.
_rsk_complete_mrevive() {
    local cur="${COMP_WORDS[COMP_CWORD]}" dir names f
    dir="${RSK_M_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/richslurmkit/m-sessions}"
    names=""
    for f in "$dir"/*.json; do
        [ -e "$f" ] || continue
        f="${f##*/}"; names+=" ${f%.json}"
    done
    COMPREPLY=( $(compgen -W "all --forget --dry-run$names" -- "$cur") )
}
complete -F _rsk_complete_mrevive mrevive

fi
