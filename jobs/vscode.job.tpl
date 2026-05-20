#!/bin/bash
# Launch Jupyter Lab + a VS Code Remote Tunnel on a SLURM compute node.
# Rendered by RichSlurmKit from jobs/vscode.job.tpl. Per-job: random tmux session,
# random Jupyter token + port, dedicated VS Code CLI data dir (=> own singleton
# lock + auth state, so multiple jobs don't fight over ~/.vscode-cli).

#SBATCH --account=${RSK_JOB_ACCOUNT}
#SBATCH --time=${RSK_JOB_TIME}
#SBATCH --partition=${RSK_JOB_PARTITION}
${RSK_JOB_GRES_LINE}
#SBATCH -c ${RSK_JOB_CORES}
#SBATCH --mem=${RSK_JOB_MEM}

set -o errexit -o nounset -o pipefail

# VS Code CLI tarball (~60MB) + per-job data dir need a writable scratch path.
# Try $SCRATCH (set on some clusters), then /scratch (Cannon), then /tmp.
MY_SCRATCH=""
for _candidate in "${SCRATCH:-}" /scratch "${TMPDIR:-}" /tmp; do
    if [[ -n "$_candidate" && -d "$_candidate" && -w "$_candidate" ]]; then
        MY_SCRATCH=$(TMPDIR="$_candidate" mktemp -d) && break
    fi
done
if [[ -z "$MY_SCRATCH" ]]; then
    echo "FATAL: no writable scratch dir found (tried \$SCRATCH /scratch \$TMPDIR /tmp)" >&2
    exit 1
fi
echo "Scratch dir: ${MY_SCRATCH}"

ENV="${RSK_JOB_ENV}"
JOBID="${SLURM_JOB_ID:-$RANDOM}"
SESSION="jupyter-${JOBID}"
TUNNEL_NAME="tunnel-${JOBID}"

NOW=$(date +%Y%m%d_%H%M%S)
LOGFILE="${HOME}/jupyter_lab_${NOW}.log"

# -- Jupyter Lab in a per-job tmux session --
if ! tmux has-session -t "${SESSION}" 2>/dev/null; then
    echo "Creating tmux session '${SESSION}' and launching Jupyter"
    source activate "${ENV}"

    TOKEN=$(python -c 'import secrets;print(secrets.token_hex(16))')
    PORT=$(python -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')

    echo "RSK_JOB_PORT: ${PORT}"
    echo "RSK_JOB_TOKEN: ${TOKEN}"
    echo "Jupyter URL (paste into VS Code 'Existing Jupyter Server'):"
    echo "    http://127.0.0.1:${PORT}/?token=${TOKEN}"

    tmux new -s "${SESSION}" -d "
        jupyter lab \
            --no-browser \
            --ip=127.0.0.1 \
            --port=${PORT} \
            --ServerApp.token='${TOKEN}' \
            --ServerApp.websocket_ping_interval=15 \
            --ServerApp.websocket_ping_timeout=60 \
            --ServerApp.log_level='DEBUG' \
            --ServerApp.log_file='${LOGFILE}'
    "
else
    echo "tmux session '${SESSION}' already exists -- skipping Jupyter launch"
fi

# -- VS Code CLI: fresh install per job, dedicated data dir --
curl -Lk 'https://update.code.visualstudio.com/latest/cli-alpine-x64/stable' \
    | tar -C "${MY_SCRATCH}" -xzf -

CLI_DATA_DIR="${MY_SCRATCH}/vscode-cli-data"
mkdir -p "${CLI_DATA_DIR}"

# GitHub device-login (once per data-dir -> once per job).
# KEYCHAIN_ENCRYPT=1 skips libsecret/keychain (no dbus on compute node).
VSCODE_CLI_DISABLE_KEYCHAIN_ENCRYPT=1 \
    "${MY_SCRATCH}/code" --cli-data-dir "${CLI_DATA_DIR}" \
        tunnel user login --provider github

cd "$HOME"

# Unregister on clean exit (SIGKILL won't fire this; run `vclean` to mop up).
trap '"${MY_SCRATCH}/code" --cli-data-dir "${CLI_DATA_DIR}" tunnel unregister 2>/dev/null || true' EXIT

echo "Using VS Code tunnel name: ${TUNNEL_NAME}"
"${MY_SCRATCH}/code" --cli-data-dir "${CLI_DATA_DIR}" tunnel \
    --accept-server-license-terms \
    --name "${TUNNEL_NAME}"
