# RichSlurmKit

Bash toolkit for working on a Slurm cluster from VS Code: launch a VS Code
tunnel (plus Jupyter) or a Jupyter-over-ssh job on a compute node, keep
terminal and Claude Code sessions alive across disconnects with `m`, and bring
them back after the job ends. The shipped `config.example.yaml` is a
placeholder template: you have to plug in your own account, partition, and
resource values before anything will run.

## Install

```bash
git clone <repo-url> ~/RichSlurmKit
cd ~/RichSlurmKit
./install.sh
source ~/.bashrc
```

The installer is non-interactive: it copies `config.example.yaml → config.yaml`
(if missing), adds one `source` line to `~/.bashrc`, and installs a pinned,
checksum-verified [zmx](https://github.com/neurosnap/zmx) binary for `m`.
Requires `conda`, `python`, `envsubst`, `tmux`, `ssh`, and `curl`.
PyYAML auto-installs to your user pip site-packages.

To uninstall: `./uninstall.sh` (use `--purge` to also drop `config.yaml`, the
zmx binary, and the cached devtunnel binary).

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

- `login_host:` is the installer's guess at what this login node calls
  itself. Many clusters use a load-balanced alias (e.g. `login.cluster.edu`)
  that's different. Fix it here if `p`'s ssh-tunnel one-liner needs to work
  from outside the cluster.
- `conda_env:` is the global default env. Create it before running `v` or `p`.
  Each preset can also set its own `conda_env:` to override the global one.
  CLI `--env` overrides everything.
- `interactive: partition:` defaults to `shared`, which doesn't exist on
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
| `m [args...]` | Keep sessions alive; see [Sessions](#sessions-m). |
| `mc [name]` / `mcr [name]` | New session running `c` / `cr`, auto-named `claude_N`; attaches if it exists. |
| `mrevive` | Bring back claude sessions after their Slurm job ended. |
| `c` / `cr` | Personal shortcut: `claude --dangerously-skip-permissions` (resume with `cr`). Delete these if you don't use Claude Code. |

`v` and `p` share a CLI:

```
v               # preset 1, all defaults
v 3             # preset 3
v agent_host    # a preset by name
v 3 --account foo --partition shared
v --list        # show presets
v --help        # full flag list
```

Overridable flags: `--account`, `--partition`, `--gres`, `--cores`, `--mem`,
`--time`, `--env`. `--keep-rendered` stashes the rendered job file in
`~/.local/state/richslurmkit/` for debugging.

## Sessions (`m`)

`m` keeps terminal sessions (usually Claude Code) running on the compute node
when you close the terminal, reload VS Code, or switch laptops. It wraps
[zmx](https://github.com/neurosnap/zmx), which only keeps the session alive:
output goes straight to your terminal instead of being redrawn by a
multiplexer, so scrollback, selection, and Cmd+click on paths are handled by
VS Code itself. There are no panes or tabs; use VS Code's terminal tabs and
splits.

| | |
|---|---|
| `mc [name]` | new session running `c` (or attach if it exists) |
| `mcr [name]` | same, running `cr` (pick a conversation to resume) |
| `m` | list sessions here, with each claude's title and status |
| `m a <name>` | attach (from inside a session: switch this terminal) |
| `Ctrl+\` | detach this terminal (or just close the terminal) |
| `m d` | inside a session: detach every client of it |
| `m hi <name>` | print a session's scrollback |
| `m end <name>` | kill a session but keep it for `mrevive <name>` |
| `m k <name>` | kill a session and forget it |

Anything else after `m` goes straight to zmx (`m help`).

Sessions live on the node they were started on. Start them from a terminal in
your `v` job (VS Code's terminal), not inside `interactive`: everything started
in an `srun` step dies when that step ends.

Several terminals can attach to one session, for example from two laptops.
They share one screen and one claude, and the size follows whichever terminal
typed last. `lib/zmx_install.sh` (run by `install.sh`) installs the pinned zmx
build. It never replaces a different installed version while sessions are
live, because zmx's README warns that a version change can kill them.

**Reviving after a job ends.** Nothing survives the end of a Slurm job. The
repo's `c` and `cr` add a small Claude Code hook when they run inside a
session (`mc`, `mcr` and `mrevive` launch the repo's `c` by full path, so a
personal `c` earlier on PATH doesn't skip it), and every `m*` command also
snapshots the live claudes on the node, so each session's conversation id,
directory, host and job are recorded in
`~/.local/state/richslurmkit/m-sessions/`. In the next job, `mrevive` shows
them and `mrevive all` recreates each one (detached) with `c -r <id>`. A
session whose job is still running elsewhere is never revived, so two claudes
never share a conversation. Sessions you left with `/exit` or `m end` show as
`exited`; name them to revive anyway (`mrevive <name>`).

**Long jobs.** Sessions die with their job, so give them a long one. The
`agent_host` example preset (`v agent_host`) is a CPU job for the tunnel and
your claude sessions: 8 cores, 32G, 14 days. Point it at a partition that
allows multi-day runs (on FASRC Cannon, `intermediate`). Heavy work should
still go to its own `sbatch` job: everything in this one shares its 32G.

### Other session managers

`t [name]` creates (or attaches to) a tmux session, auto-named `session_N`;
`tc` / `tcr` do the same and launch `c` / `cr` in it, auto-named `claude_N`.

The zellij helpers (`z`, `zz`, `zc`, `zcr`, `zzc`, `zzcr`, `zsolo`, `zopen`)
were the default before `m`. They still work and are documented in
[docs/zellij.md](docs/zellij.md).

## Config

`config.yaml` lives next to this README, gitignored. Every script re-reads it
on each invocation, so edits take effect immediately (no rebuild, no
re-source). Add or reorder presets freely.

See `config.example.yaml` for the schema and required edits.

## Where things go

- SLURM logs + `--keep-rendered` job files: `<repo>/logs/` (gitignored).
  Sibling of `config.yaml`; the absolute path is printed by `v`/`p` on submit.
- Cached `devtunnel` binary (auto-installed by `vclean`): `~/.local/share/richslurmkit/bin/devtunnel`
- zmx binary: `~/.local/share/richslurmkit/zmx/<version>/zmx`, linked from `~/.local/bin/zmx`.
  Session sockets and logs: `/tmp/zmx-<uid>/` on each node.
- `mrevive` records: `~/.local/state/richslurmkit/m-sessions/`.
- Rendered job templates (per-submit): `/tmp/rsk-*.job` (auto-deleted)
