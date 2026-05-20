#!/bin/bash
# Launch Jupyter Lab on a compute node and print the ssh-tunnel command to reach it.
# Rendered by RichSlurmKit from jobs/persistent_ssh.job.tpl. Random token + free
# port per run -- nothing sensitive is hardcoded.

#SBATCH --account=${RSK_JOB_ACCOUNT}
#SBATCH --time=${RSK_JOB_TIME}
#SBATCH --partition=${RSK_JOB_PARTITION}
${RSK_JOB_GRES_LINE}
#SBATCH -c ${RSK_JOB_CORES}
#SBATCH --mem=${RSK_JOB_MEM}
#SBATCH --job-name=jupyter-tunnel
#SBATCH --output=jupyter-tunnel_%j.out

set -o errexit -o nounset -o pipefail

ENV="${RSK_JOB_ENV}"
USERNAME="${RSK_JOB_USER}"
LOGIN_HOST="${RSK_JOB_LOGIN_HOST}"

source activate "${ENV}"

# Random token + free port per run.
TOKEN=$(python -c 'import secrets;print(secrets.token_hex(16))')
PORT=$(python -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')

NODE_HOSTNAME=$(hostname)
SESSION="jupyter_session_${SLURM_JOB_ID}"

# Structured fields scraped by `pp` -- keep these prefixes stable.
echo "RSK_JOB_NODE: ${NODE_HOSTNAME}"
echo "RSK_JOB_PORT: ${PORT}"
echo "RSK_JOB_TOKEN: ${TOKEN}"
echo "------------------------------------------------------------------"
echo "Job running on node: ${NODE_HOSTNAME}"
echo ""
echo "1. From the login node (VS Code terminal):"
echo "   ssh -N -L ${PORT}:localhost:${PORT} ${NODE_HOSTNAME}"
echo ""
echo "2. From a laptop:"
echo "   ssh -N -L ${PORT}:${NODE_HOSTNAME}:${PORT} ${USERNAME}@${LOGIN_HOST}"
echo ""
echo "3. In IDE/Browser:"
echo "   http://127.0.0.1:${PORT}/lab?token=${TOKEN}"
echo "------------------------------------------------------------------"

if ! tmux has-session -t "${SESSION}" 2>/dev/null; then
    echo "Creating new tmux session '${SESSION}'"
    tmux new-session -s "${SESSION}" -d
    tmux send-keys -t "${SESSION}" "source activate ${ENV}" C-m
    tmux send-keys -t "${SESSION}" "jupyter lab --no-browser --ip=0.0.0.0 --port=${PORT} --ServerApp.token='${TOKEN}' --ServerApp.allow_remote_access=True" C-m
else
    echo "tmux session '${SESSION}' already exists."
fi

# Keep the allocation alive until SLURM time limit.
sleep infinity
