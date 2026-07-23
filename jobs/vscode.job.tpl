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
echo "Conda env (resolved from config/preset/--env): ${ENV}"
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

# Disable libsecret/keychain for EVERY `code` call below (login, show, tunnel,
# unregister), not just login: there's no dbus/keyring on a compute node, and a
# consistent setting keeps token.json plaintext and portable across jobs/nodes.
# If a mid-run token refresh ran without this, it could rewrite token.json in a
# host-bound form that the next job can't reuse.
export VSCODE_CLI_DISABLE_KEYCHAIN_ENCRYPT=1

# --- Persist the GitHub tunnel auth token across jobs (one-time device login) --
# The login token is cached as token.json inside the CLI data dir, but that dir
# lives on per-job scratch and is discarded at job end, so each new job would
# otherwise re-prompt for the github.com/login/device code. We keep only the
# small token.json in a stable $HOME store and seed it into each per-job data
# dir; everything else in the data dir stays per-job on scratch, so concurrent
# tunnels keep their independent singleton locks. token.json is a secret and is
# never echoed or printed.
AUTH_STORE="${HOME}/.local/share/richslurmkit/vscode-cli-auth"
mkdir -p "${AUTH_STORE}"
chmod 700 "${AUTH_STORE}"
if [[ -f "${AUTH_STORE}/token.json" ]]; then
    install -m 600 "${AUTH_STORE}/token.json" "${CLI_DATA_DIR}/token.json"
fi

# GitHub device-login -- ONLY when not already authenticated. `tunnel user login`
# is NOT a no-op when a valid token is present: it unconditionally re-runs the
# device-code flow and blocks for a paste, so calling it every job re-prompts
# even though the seeded token.json is valid. `tunnel user show` exits 0
# ("logged in ...") when the seeded token works and 1 ("not logged in")
# otherwise, so it's the correct guard (the `if` also spares us from errexit).
if "${MY_SCRATCH}/code" --cli-data-dir "${CLI_DATA_DIR}" tunnel user show >/dev/null 2>&1; then
    echo "GitHub tunnel auth: reusing persisted login (no device code needed)."
else
    echo "GitHub tunnel auth: no valid token found; starting one-time device login."
    "${MY_SCRATCH}/code" --cli-data-dir "${CLI_DATA_DIR}" \
        tunnel user login --provider github
fi

# Save the token right after login -- NOT only at exit: SLURM time-limit/scancel
# sends SIGKILL, which skips the EXIT trap, so a first login or refresh captured
# only there would be lost. install(1) writes it mode 600 atomically.
if [[ -f "${CLI_DATA_DIR}/token.json" ]]; then
    install -m 600 "${CLI_DATA_DIR}/token.json" "${AUTH_STORE}/token.json"
fi

cd "$HOME"

# On CLEAN exit: capture any token the tunnel refreshed mid-run (refresh-token
# rotation), then unregister so it doesn't linger in the account. SIGKILL skips
# this -- hence the save right after login above, and `vclean` to mop up leaks.
_rsk_on_exit() {
    if [[ -f "${CLI_DATA_DIR}/token.json" ]]; then
        install -m 600 "${CLI_DATA_DIR}/token.json" "${AUTH_STORE}/token.json" 2>/dev/null || true
    fi
    "${MY_SCRATCH}/code" --cli-data-dir "${CLI_DATA_DIR}" tunnel unregister 2>/dev/null || true
}
trap _rsk_on_exit EXIT

echo "Using VS Code tunnel name: ${TUNNEL_NAME}"
"${MY_SCRATCH}/code" --cli-data-dir "${CLI_DATA_DIR}" tunnel \
    --accept-server-license-terms \
    --name "${TUNNEL_NAME}"
