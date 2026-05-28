# RichSlurmKit

Bash toolkit for launching Jupyter / VS Code tunnels and managing SLURM jobs.
The shipped `config.example.yaml` is a placeholder template — you have to
plug in your own account, partition, and resource values before anything
will run.

## Install

```bash
git clone <repo-url> ~/RichSlurmKit
cd ~/RichSlurmKit
./install.sh
source ~/.bashrc
```

The installer is non-interactive: it copies `config.example.yaml → config.yaml`
(if missing) and adds one `source` line to `~/.bashrc`. Requires `conda`, `python`, `envsubst`, `tmux`, `ssh`.
PyYAML auto-installs to your user pip site-packages.

To uninstall: `./uninstall.sh` (use `--purge` to also drop `config.yaml` and
the cached devtunnel binary).

## First-time setup

After install, open `config.yaml` and replace every `YOUR_*` placeholder.
Discover your cluster's values with:

```bash
sshare -U $USER             # accounts you can charge to
sinfo -s                    # available partitions
sinfo -p <part> -o "%N %G"  # GRES strings (gpu:1 vs gpu:h100:1 etc.)
scontrol show partition <p> # per-partition CPU / mem / time limits
```

Also check:

- `login_host:` — the installer's guess is whatever this login node calls
  itself. Many clusters use a load-balanced alias (e.g. `login.cluster.edu`)
  that's different. Fix it here if `p`'s ssh-tunnel one-liner needs to work
  from outside the cluster.
- `conda_env:` — the global default env. Create it before running `v` or `p`.
  Each preset can also set its own `conda_env:` to override the global one.
  CLI `--env` overrides everything.
- `interactive: partition:` — defaults to `shared`, which doesn't exist on
  every cluster. Adjust.

Then:

```bash
v --list         # confirm the presets look right
v                # submit preset 1
```

## Commands

| cmd | what it does |
|---|---|
| `v` | Launch a VS Code Remote Tunnel + Jupyter on a compute node. `v [N]` selects a preset |
| `vclean` | Delete stale VS Code tunnel registrations from your account |
| `p` | Launch a Jupyter session + open an SSH tunnel to it. `p [N]` selects a preset |
| `pp` | Reconnect SSH tunnel to your running `p` job. Auto-picks if exactly one is running; prompts if multiple. Pass a job id (`pp 12345`) to target a specific one. |
| `interactive` | Drop into an `srun` shell using the `interactive:` block in `config.yaml` |
| `q [SECS]` | Watch `sacct` for your running/pending jobs |
| `s` | `sshare` for your user |
| `n` | `watch nvidia-smi` |
| `c` / `cr` | Personal shortcut: `claude --dangerously-skip-permissions` (resume with `cr`). Delete these if you don't use Claude Code. |
| `t [name]` | Create (or attach to) a tmux session. Auto-names `session_N` if no name given. |
| `tc [name]` / `tcr [name]` | Like `t`, but launches `c` / `cr` inside the session. Auto-names `claude_N`. If the named session already exists, just attaches. |
| `z [name]` / `zc [name]` / `zcr [name]` | Same as `t` / `tc` / `tcr` but using [zellij](https://github.com/zellij-org/zellij) instead of tmux (mouse-scroll works natively). Requires `zellij` on `PATH`. |

### zellij keybindings

For terminal multiplexing, I recommend installing and using `zellij`. It's a bit friendlier than tmux for agentic coding TUIs.

`install.sh` symlinks `zellij/config.kdl` to `~/.config/zellij/config.kdl`.
Two zellij defaults (`Ctrl+o`, `Ctrl+g`) collide with Claude Code's bindings
(expand details, open in `$EDITOR`), so we unbind them and move zellij's
session-mode prefix to `Ctrl+\`:

| key | action |
|---|---|
| `Ctrl+\` then `d` | Detach (session keeps running) |
| `Ctrl+\` then `q` | Quit (kills session) |
| `Ctrl+\` then `g` | Toggle Locked mode (zellij passes all keys through) |
| `Ctrl+\` then `Esc` | Cancel — back to Normal mode |

`Ctrl+\` is chosen because it's universally free on macOS / Linux / Windows
and in VS Code's integrated terminal. Alt/Option is avoided because on macOS
it produces special characters (`Option+d` → `∂`) unless the terminal is
specifically reconfigured.

All other zellij defaults are unchanged. If you hit another claude-code key
that zellij eats (e.g. `Ctrl+p`/`Ctrl+t`/`Ctrl+r`/`Ctrl+s` enter pane/tab/
resize/scroll modes), add the same `unbind` pattern to `zellij/config.kdl`.

If you already have a `~/.config/zellij/config.kdl`, the installer leaves it
alone and prints a pointer to this file so you can copy what you want.

`v` and `p` share a CLI:

```
v               # preset 1, all defaults
v 3             # preset 3
v 3 --account foo --partition shared
v --list        # show presets
v --help        # full flag list
```

Overridable flags: `--account`, `--partition`, `--gres`, `--cores`, `--mem`,
`--time`, `--env`. `--keep-rendered` stashes the rendered job file in
`~/.local/state/richslurmkit/` for debugging.

## Config

`config.yaml` lives next to this README, gitignored. Every script re-reads it
on each invocation, so edits take effect immediately (no rebuild, no
re-source). Add or reorder presets freely.

See `config.example.yaml` for the schema and required edits.

## Where things go

- SLURM logs + `--keep-rendered` job files: `<repo>/logs/` (gitignored).
  Sibling of `config.yaml`; the absolute path is printed by `v`/`p` on submit.
- Cached `devtunnel` binary (auto-installed by `vclean`): `~/.local/share/richslurmkit/bin/devtunnel`
- Rendered job templates (per-submit): `/tmp/rsk-*.job` (auto-deleted)
