# Bash tab-completion for the zellij wrappers (z / zc / zcr / zz / zzc / zzcr).
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

fi
