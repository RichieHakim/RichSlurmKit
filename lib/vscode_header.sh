#!/bin/bash
# Render a compact, always-visible header for the `v` viewer.
#
# bin/v runs `watch "<this> ...; echo; tail -n N <log>"`, so this prints once per
# refresh ABOVE the scrolling tail. It surfaces the fields that otherwise scroll
# off the top of the slurm log (Jupyter URL, GitHub device-login code) plus live
# session facts (state, elapsed, node) pulled from squeue.
#
# Usage: vscode_header.sh <slurm_log_file> <job_id> <preset> <partition>
#
# Robustness: this runs every couple seconds and must never error out or the
# viewer flickers/breaks, so every lookup is best-effort with a graceful
# placeholder when a field is not in the log yet (e.g. URL before Jupyter starts,
# device code when a cached token made login a no-op). No `set -e`; no secrets
# beyond what the log already prints (the loopback Jupyter token and the short
# device code are already in the log; the persisted auth token.json is not read).

log="${1:-}"
job_id="${2:-}"
preset="${3:-?}"
partition="${4:-?}"

## --- Live SLURM facts (empty/absent once the job leaves the queue) ---
state="?"; elapsed="-"; node="-"
if [[ -n "$job_id" ]]; then
    squeue_line=$(squeue -h -j "$job_id" -o '%T|%M|%N|%R' 2>/dev/null | head -n1)
    if [[ -n "$squeue_line" ]]; then
        IFS='|' read -r state elapsed node reason <<< "$squeue_line"
        ## PENDING jobs have no node; show the scheduler reason instead.
        [[ -z "$node" ]] && node="${reason:-pending}"
    fi
fi

## --- Fields grepped from the log (present once the job writes them) ---
url="(starting...)"
env="(starting...)"
if [[ -n "$log" && -f "$log" ]]; then
    hit=$(grep -m1 -oE 'http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9]+' "$log" 2>/dev/null)
    [[ -n "$hit" ]] && url="$hit"
    hit=$(grep -m1 'Conda env' "$log" 2>/dev/null | sed -E 's/.*: //')
    [[ -n "$hit" ]] && env="$hit"
fi

## --- Tunnel login status ---
## The device code stays in the log after use, so once the tunnel is actually
## created the printed code is historical: show status, not a stale "paste this".
auth="waiting..."
if [[ -n "$log" && -f "$log" ]]; then
    if grep -q 'Creating tunnel with the name' "$log" 2>/dev/null; then
        auth="authenticated (tunnel up)"
    else
        code=$(grep -m1 -oE 'use code [A-Z0-9-]+' "$log" 2>/dev/null | awk '{print $NF}')
        if [[ -n "$code" ]]; then
            auth="ACTION: paste ${code} at https://github.com/login/device"
        else
            auth="waiting (no code yet; cached token or still starting)"
        fi
    fi
fi

## --- Render (ASCII only, compact) ---
printf '=== v session =================================================\n'
printf '  job %s   state %s   elapsed %s\n' "${job_id:-?}" "$state" "$elapsed"
printf '  preset %s   partition %s   env %s\n' "$preset" "$partition" "$env"
printf '  node %s   session jupyter-%s / tunnel-%s\n' "$node" "${job_id:-?}" "${job_id:-?}"
printf '  Jupyter URL   %s\n' "$url"
printf '  Tunnel login  %s\n' "$auth"
printf '===============================================================\n'
