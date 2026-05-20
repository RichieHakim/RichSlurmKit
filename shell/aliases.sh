# Aliases and shell functions. Path-using ones re-read config on each call so
# `lab_path` / `scratch_path` edits in config.yaml take effect immediately.

# cd shortcuts (hot: re-source config each call).
lab() {
    source "$RSK_ROOT/lib/config.sh" >/dev/null 2>&1 || return 1
    cd "${RSK_LAB_PATH:-$HOME}"
}
scratch() {
    source "$RSK_ROOT/lib/config.sh" >/dev/null 2>&1 || return 1
    cd "${RSK_SCRATCH_PATH:-$HOME}"
}
blame() {
    source "$RSK_ROOT/lib/config.sh" >/dev/null 2>&1 || return 1
    if [[ -z "${RSK_BLAME_ACCOUNT:-}" ]]; then
        echo "Set blame_account in config.yaml" >&2
        return 1
    fi
    sshare --account="$RSK_BLAME_ACCOUNT" -a
}

# SLURM queue / scheduling shortcuts (USER-aware, no config needed).
alias sq='squeue -a -u "$USER"'
alias njobs='squeue -u "$USER" | wc -l'
alias myjobs='watch -n 0.1 squeue -u "$USER" --Format=JobId,Name,State,Partition,SubmitTime,TimeLeft,TimeLimit,ReasonList,MinMemory,NumNodes,NumCPUs,Priority'

# Quick interactive allocations (CPU/GPU) -- separate from the `interactive`
# command in bin/, which sources config. These two are intentionally minimal
# so they can be tweaked inline.
alias interactive_cpu='salloc -p shared --mem=2G -c 2 -N 1 -t 0-02:00:00'
alias interactive_gpu='salloc -p kempner,kempner_requeue --mem=8G --gres=gpu:1 -c 2 -N 1 -t 0-02:00:00'

# Misc.
alias rl='readlink -f ~/.bashrc'
rlf() { readlink -f "$1"; }
