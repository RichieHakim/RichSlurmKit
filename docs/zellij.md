# zellij helpers (`z*`)

Before [`m`](../README.md#sessions-m), RichSlurmKit kept sessions alive with
[zellij](https://github.com/zellij-org/zellij). These commands still work if
`zellij` is on your `PATH`, but `m` is the default now (see
[why](#why-m-is-the-default)).

| cmd | what it does |
|---|---|
| `z [args...]` | Alias for `zellij`; passes all arguments straight through. `z a <name>` attaches *coactively* (leaves other clients connected). |
| `zz [name]` | **Solo-attach.** Detaches all *other* zellij clients first, then attaches (creating the session if needed), so you get a clean, full-size session with a green border. Use this instead of `z a` when a reattach comes up small with a blue border. See [below](#solo-zz-vs-coactive-attach). |
| `zc [name]` / `zcr [name]` | Launch `c` / `cr` in a new session, auto-naming `claude_N`. If the named session already exists, just attach (coactively). |
| `zzc [name]` / `zzcr [name]` | Solo variants of `zc` / `zcr`: detach all other zellij clients first, then create-or-attach. |
| `zsolo` | Just the dedup step: detach every other zellij client on this node. |
| `zopen <file>` | Open a file in VS Code without waiting. zellij runs it when you Alt+click a path. |

## Setup

When zellij is installed, `install.sh` symlinks `zellij/config.kdl` to
`~/.config/zellij/config.kdl`. If you install zellij later, re-run
`./install.sh`. If you already have a `~/.config/zellij/config.kdl`, the
installer leaves it alone and prints a pointer to this repo's file so you can
copy what you want. `./uninstall.sh` removes the symlink if it still points
here.

## Keybindings

Two zellij defaults (`Ctrl+o`, `Ctrl+g`) collide with Claude Code's bindings
(expand details, open in `$EDITOR`), so the config unbinds them and moves
zellij's session-mode prefix to `Ctrl+\`:

| key | action |
|---|---|
| `Ctrl+\` then `d` | Detach (session keeps running) |
| `Ctrl+\` then `q` | Quit (kills session) |
| `Ctrl+\` then `g` | Toggle Locked mode (zellij passes all keys through) |
| `Ctrl+\` then `Esc` | Cancel, back to Normal mode |

`Ctrl+\` is free on macOS, Linux and Windows and in VS Code's integrated
terminal. Alt/Option is avoided because on macOS it produces special characters
(`Option+d` gives `∂`) unless the terminal is reconfigured.

All other zellij defaults are unchanged. If you hit another Claude Code key
that zellij eats (e.g. `Ctrl+p`/`Ctrl+t`/`Ctrl+r`/`Ctrl+s` enter
pane/tab/resize/scroll modes), add the same `unbind` pattern to
`zellij/config.kdl`. The file's comments also cover scrollback (`Ctrl+s`
Scroll mode, since Claude Code captures the mouse wheel).

**Clicking file paths.** Cmd+click on a plain path does nothing inside zellij.
Alt+click (Option+click on macOS) instead: zellij's `link` plugin runs `zopen`,
which opens the file in VS Code. Line numbers are not passed.

## Solo (`zz*`) vs coactive attach

A zellij session can have several clients attached at once. When it does,
zellij sizes the session to the **smallest** attached client and tints the
extra client's focus **blue**. After a VS Code or terminal reload the old client
often lingers (the node-local zellij server outlives your terminal), so a plain
reattach lands you in a session that's small and blue-bordered.

The `zz` prefix means "solo": those commands detach every *other* zellij client
first, so you're the only one and the session fills your terminal (green
border). Each has a coactive counterpart that leaves other clients attached
(for when you want several live views: pairing, or watching one session while
working in another):

| solo (dedup first) | coactive | does |
|---|---|---|
| `zz <name>` | `z a <name>` | attach to a session |
| `zzc [name]` | `zc [name]` | create-or-attach + `claude` |
| `zzcr [name]` | `zcr [name]` | create-or-attach + `claude --resume` |

The shared dedup lives in `zsolo`. Detaching a client never stops the programs
in a session's panes (a running `claude` keeps going): those belong to the
session's `zellij --server`, which `zsolo` never touches. It signals only
`zellij` client processes: SIGTERM first, then SIGKILL for any client still
attached about 2s later. The escalation is needed because a client whose
terminal has stopped draining its pty (closed VS Code window, dropped ssh) never
finishes zellij's graceful detach and ignores SIGTERM, and that's exactly the
stale client you're clearing. Reattach to get any view back.

Run a `zz*` command from a **plain terminal** (the fresh one a reload gives
you); that's where the dedup fires. From inside a session it can't dedup
itself, so it just attaches or switches.

`zsolo` is **node-wide**: it detaches every client you have on that machine, not
just the session you're heading for. That's the intent when you're reconnecting
after a reload, but running it while you're working in another session drops
you out of that one too.

## Moving sessions to `m`

The repo's `c` records Claude conversations inside zellij sessions the same way
it does inside zmx ones, so `mrevive` can carry them over. Run `m` once in the
old job to refresh the records, end that job, then run `mrevive` in the new one:
each session comes back as an `m` session with the same name and conversation.
A session whose job is still running is never revived, so a conversation is
never open twice.

## Why `m` is the default

zellij redraws every pane through its own terminal emulator. That layer is
behind the slow scrolling, the copy and path clicking that don't behave like
VS Code's, and the small blue-framed screen after a reattach. Claude Code also
turns off its fast scrolling when it sees tmux or zellij. zmx, which `m` wraps,
only keeps the session alive and passes output straight to your terminal. What
you give up is zellij's panes and tabs; use VS Code's terminal tabs and splits
instead.
