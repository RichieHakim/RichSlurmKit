# RichSlurmKit

Bash toolkit for working on a Slurm cluster from VS Code: launch a VS Code
tunnel (plus Jupyter) or a Jupyter-over-ssh job on a compute node, keep
terminal and Claude Code sessions alive across disconnects with `m`, and bring
them back after the job ends. The shipped `config.example.yaml` is a
placeholder template: you have to plug in your own account, partition, and
resource values before anything will run.

Developed and used daily on FASRC Cannon. On HMS O2, only a test job with ssh
into its node has been tried.

## Requirements

- Linux on x86_64 or aarch64 (`vclean` is x86_64 only).
- Slurm, and bash as your login shell. The toolkit hooks into `~/.bashrc`.
- On the login node: Python 3 (PyYAML is installed for you), `envsubst`
  (from gettext), `curl`, `ssh`.
- On compute nodes: `tmux` and `curl`.
- A Python env for jobs with `jupyterlab` installed. Activated with conda by
  default; set `activate:` in `config.yaml` for mamba or a venv.
- `v`: compute nodes need outbound internet. Each job downloads the VS Code
  CLI and opens a tunnel through Microsoft's servers, and the first one asks
  you to log in to GitHub.
- `p` / `pp`: you must be able to ssh from the login node into a node running
  your job.
- `install.sh` downloads zmx from GitHub.

## Check your cluster

On a login node:

```bash
uname -m                                 # x86_64 or aarch64
scontrol version                         # Slurm
getent passwd "$USER" | cut -d: -f7      # your login shell: should be bash
sinfo -s -o '%P %l'                      # partitions and time limits; * marks the default
command -v python3 envsubst curl ssh conda   # anything missing is not installed
```

Then test a compute node. Set `PART` to a partition from `sinfo`. If your
cluster requires an account, run `export SBATCH_ACCOUNT=youraccount` first.
This submits a 10-minute, 1-core job:

```bash
PART=short   # a partition you can use, from sinfo -s
sbatch -p "$PART" -t 10 -c 1 --mem=1G -J rsk-check -o /dev/null --wrap '
f=/tmp/rsk-check-$SLURM_JOB_ID
{ command -v tmux curl
  curl -sSI -m 10 https://update.code.visualstudio.com >/dev/null && echo "internet ok"
} >"$f" 2>&1
sleep 300'
```

Once it is running (`squeue -u "$USER"`), read its result over ssh and cancel
it:

```bash
jid=$(squeue -u "$USER" -h -n rsk-check -t R -o %i | head -1)
if [ -z "$jid" ]; then echo "rsk-check is not running yet; try again in a minute"
else
  ssh "$(squeue -h -j "$jid" -o %N)" "cat /tmp/rsk-check-$jid; rm -f /tmp/rsk-check-$jid"
  scancel "$jid"
fi
```

A good result prints the paths of `tmux` and `curl`, then `internet ok`.

- ssh is refused: `p` and `pp` won't work. `v` and `m` still do.
- `No such file`: your ssh login doesn't see the job's `/tmp`, where zmx keeps
  its sockets. Run `m` only from terminals inside the job, such as VS Code's
  terminal in a `v` job.
- `tmux` or `curl` missing: ask your admins, or install them into your env.
- No `internet ok`: `v` can't work. Use `p`.

## Install

```bash
git clone https://github.com/RichieHakim/RichSlurmKit.git ~/RichSlurmKit
cd ~/RichSlurmKit
./install.sh
source ~/.bashrc
```

The installer is non-interactive: it copies `config.example.yaml → config.yaml`
(if missing), adds one `source` line to `~/.bashrc`, and installs a pinned,
checksum-verified [zmx](https://github.com/neurosnap/zmx) binary for `m`.
If `claude` is installed, it also installs the
[path-links mod](#clicking-file-paths) as a Claude Code plugin.
It stops if `envsubst` or PyYAML is missing and can't be installed, and warns
if `conda` isn't on PATH. It is safe to run again: after a `git pull`, re-run
it to pick up new steps such as the mod.

To uninstall: `./uninstall.sh`, which also removes the mod. Add `--purge` to
also delete `config.yaml`, the zmx and devtunnel binaries, and the saved VS
Code tunnel login.

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

- `login_host:` ships blank. Set it to the hostname you ssh to from your
  laptop (often an alias like `login.cluster.edu`). Only `p` uses it, to
  print an ssh-tunnel command for use from off the cluster.
- `conda_env:` is the global default env. Create it, with `jupyterlab`, before
  running `v` or `p`. Each preset can set its own `conda_env:`, and `--env`
  overrides both.
- `activate:` is the line that activates the env inside jobs. The default
  (`source activate {env}`) suits conda; the example config shows mamba and
  venv versions.
- `interactive: partition:` defaults to `shared`, which doesn't exist on
  every cluster. Adjust.

Then:

```bash
v --list         # confirm the presets look right
v                # submit the default preset
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
| `c` / `cr` | `claude` with the `claude_flags` from `config.yaml` (`cr` resumes). |

`v` and `p` share a CLI:

```
v               # the default preset
v 3             # preset 3
v agent_host    # a preset by name
v 3 --account foo --partition shared
v --list        # show presets
v --help        # full flag list
```

Overridable flags: `--account`, `--partition`, `--gres`, `--cores`, `--mem`,
`--time`, `--env`. `--keep-rendered` keeps the rendered job file in
`<repo>/logs/` for debugging.

## Sessions (`m`)

`m` keeps terminal sessions (usually Claude Code) running on the compute node
when you close the terminal, reload VS Code, or switch laptops. It wraps
[zmx](https://github.com/neurosnap/zmx), which only keeps the session alive:
output goes straight to your terminal instead of being redrawn by a
multiplexer. There are no panes or tabs; use VS Code's terminal tabs and
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
| `m k <name>` | kill a session |

Anything else after `m` goes straight to zmx (`m help`).

Sessions live on the node they were started on. Start them from a terminal in
your `v` job (VS Code's terminal), not inside `interactive`: everything started
in an `srun` step dies when that step ends.

Several terminals can attach to one session, for example from two laptops.
They share one screen and one claude, and the size follows whichever terminal
typed last. `lib/zmx_install.sh` (run by `install.sh`) installs the pinned zmx
build. It never replaces a different installed version while sessions are
live, because zmx's README warns that a version change can kill them.

**Long jobs.** Sessions die with their job, so give them a long one. The
`agent_host` example preset (`v agent_host`) is a CPU job for the tunnel and
your claude sessions: 8 cores, 32G, 14 days. Point it at a partition that
allows multi-day runs (on FASRC Cannon, `intermediate`). Heavy work should
still go to its own `sbatch` job: everything in this one shares its 32G.
When a job ends, its claudes stop but their conversations are saved: in a
new job, `mcr` lets you pick one to resume.

### Other session managers

`t [name]` creates (or attaches to) a tmux session, auto-named `session_N`;
`tc` / `tcr` do the same and launch `c` / `cr` in it, auto-named `claude_N`.

The zellij helpers (`z`, `zz`, `zc`, `zcr`, `zzc`, `zzcr`, `zsolo`, `zopen`)
were the default before `m`. They still work and are documented in
[docs/zellij.md](docs/zellij.md).

## Clicking file paths

Claude Code prints file paths as plain text, and VS Code only makes a path
clickable when the whole path sits on one row. Claude breaks long paths across
rows, so in a narrow terminal most of them can't be clicked. The `path-links`
mod (`mods/path-links`, installed by `install.sh`) fixes this as Claude draws
its replies: each path that exists on this node becomes a link to your `v`
job's VS Code tunnel, and the link holds on every row the path spans. The
model is told nothing, and the saved conversation keeps the plain paths.

Cmd+click (Ctrl+click on Linux and Windows) a file to open it in the current
VS Code window, at its line if the path has one (`bin/m:12`). A directory
opens in a new window; no link can show a folder in the current window's
file explorer.

Links cover absolute and `~/` paths, relative paths with a slash (`lib/`,
`bin/m`), and bare file names (`fig.png`). Relative paths are resolved
against Claude's working directory. Code blocks, existing links and URLs are
left alone. The tunnel must run on the same node as Claude. Run
`/reload-plugins` in open sessions after installing or editing the mod.

The mod uses Claude Code's mod API, which is in early access, so a Claude
Code update can break it. Paths then show as plain text again.

## Config

`config.yaml` lives next to this README, gitignored. Every script re-reads it
on each invocation, so edits take effect immediately (no rebuild, no
re-source). Add or reorder presets freely.

See `config.example.yaml` for the schema and required edits.

## Warnings

- **Claude permissions.** `claude_flags` applies to `c`, `cr`, `mc` and
  `mcr`. `--dangerously-skip-permissions` lets Claude run any command
  without asking. Some clusters forbid it; check your site's policy.
- **Run Claude in a job.** Login nodes are shared, and some clusters kill
  long-running processes there. Use `mc` inside a `v` job.
- **Tunnel login.** `v` saves your GitHub tunnel login to
  `~/.local/share/richslurmkit/vscode-cli-auth/token.json` (mode 600), so
  later jobs skip the device code. Anyone who can read that file can use your
  tunnels. `./uninstall.sh --purge` deletes it.
- **Command names.** `bin/` goes first on your PATH, so every command in it
  hides any program with the same name, such as `mc` (Midnight Commander) or
  `tc` (traffic control). Shell functions and aliases, such as zoxide's `z`,
  still win over them.
- **Log cleanup.** Each `v` or `p` deletes the slurm logs in `<repo>/logs/` of
  jobs that are no longer queued or running.
- **Host keys.** `p` and `pp` ssh to compute nodes with host-key checking off,
  since nodes change from job to job.
- **devtunnel.** `vclean` downloads Microsoft's devtunnel CLI without
  checking a checksum.
- **Claude Code internals.** `m` reads `~/.claude/sessions/` to show each
  claude's title and status. That is not a public Claude Code interface, so a
  Claude Code update can break that column.

## Where things go

- SLURM logs + `--keep-rendered` job files: `<repo>/logs/` (gitignored, mode 700).
  Sibling of `config.yaml`; the absolute path is printed by `v`/`p` on submit.
- Saved VS Code tunnel login: `~/.local/share/richslurmkit/vscode-cli-auth/token.json`
- Cached `devtunnel` binary (auto-installed by `vclean`): `~/.local/share/richslurmkit/bin/devtunnel`
- zmx binary: `~/.local/share/richslurmkit/zmx/<version>/zmx`, linked from `~/.local/bin/zmx`.
  Session sockets and logs: `/tmp/zmx-<uid>/` on each node.
- Rendered job templates (per-submit): `/tmp/rsk-*.job` (auto-deleted)

## License

MIT. See [LICENSE](LICENSE).
