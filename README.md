# RichSlurmKit

Bash toolkit for launching Jupyter / VS Code tunnels and managing SLURM jobs.
Built and tested on Cannon (FASRC). Will likely need preset tweaks on other clusters.

## Install

```bash
git clone <repo-url> ~/RichSlurmKit
cd ~/RichSlurmKit
./install.sh
source ~/.bashrc
```

The installer prompts for a few basics, writes `config.yaml`, and adds one
`source` line to `~/.bashrc`. Requires `conda`, `python`, `envsubst`, `tmux`,
`ssh`. `PyYAML` is auto-installed.

To uninstall: `./uninstall.sh` (use `--purge` to also drop the config).

## Commands

| cmd | what it does |
|---|---|
| `v [N]` | Launch a VS Code Remote Tunnel + Jupyter on a compute node (preset N, default 1) |
| `vclean` | Delete stale VS Code tunnel registrations from your account |
| `p [N]` | Launch a Jupyter session + open an SSH tunnel to it (preset N) |
| `pp [JOB]` | Reconnect SSH tunnel to a running `p` job |
| `interactive` | Drop into an `srun` shell using the `interactive:` block in `config.yaml` |
| `q [SECS]` | Watch `sacct` for your running/pending jobs |
| `s` | `sshare` for your user |
| `n` | `watch nvidia-smi` |
| `c` / `cr` | `claude --dangerously-skip-permissions` (resume with `cr`) |
| `lab` / `scratch` | `cd` to `lab_path` / `scratch_path` from config |
| `blame` | `sshare --account=<blame_account>` |
| `sq`, `njobs`, `myjobs`, `interactive_cpu`, `interactive_gpu` | Plain SLURM aliases |

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

`config.yaml` lives next to this README, gitignored. **Edits are hot** — every
script re-reads it on each invocation. Add or reorder presets freely.

See `config.example.yaml` for the schema.

## Where things go

- SLURM logs and `--keep-rendered` job files: `~/.local/state/richslurmkit/`
- Cached `devtunnel` binary: `~/.local/share/richslurmkit/bin/devtunnel`
- Rendered job templates (per-submit): `/tmp/rsk-*.job` (auto-deleted)
