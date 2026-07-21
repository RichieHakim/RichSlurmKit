# Shared by `v` and `p`. Parses preset + override flags, renders the job
# template via envsubst, and writes a temp file ready for sbatch.
#
# Requires: lib/config.sh already sourced (RSK_PRESET_COUNT + RSK_PRESET_N_* set).

rsk_print_job_usage() {
    cat <<EOF
Usage: ${RSK_CMD_NAME:-v|p} [PRESET] [OPTIONS]

  PRESET                       Numeric preset index (default 1).

Options:
  --account NAME               Override SLURM account.
  --partition NAME             Override partition.
  --gres SPEC                  Override --gres (e.g. gpu:1, or "" for none).
  --cores N                    Override -c (CPU cores).
  --mem SIZE                   Override --mem (e.g. 64G).
  --time D-HH:MM:SS            Override --time.
  --env NAME                   Override conda env activated inside the job.
  --list                       List available presets and exit.
  --keep-rendered              Write rendered .job alongside slurm log.
  -h, --help                   Show this help.
EOF
}

rsk_list_presets() {
    if [[ "${RSK_PRESET_COUNT:-0}" -eq 0 ]]; then
        echo "No presets defined in $RSK_CONFIG."
        return
    fi
    printf "%-3s %-24s %-10s %-22s %-10s %-6s %-8s %-12s %s\n" \
        "#" "NAME" "ACCOUNT" "PARTITION" "GRES" "CORES" "MEM" "TIME" ""
    local i _def
    _def="$(rsk_default_preset_idx)"
    for ((i = 1; i <= RSK_PRESET_COUNT; i++)); do
        local n a p g c m t mark
        n=$(rsk_preset_field "$i" NAME)
        a=$(rsk_preset_field "$i" ACCOUNT)
        p=$(rsk_preset_field "$i" PARTITION)
        g=$(rsk_preset_field "$i" GRES)
        c=$(rsk_preset_field "$i" CORES)
        m=$(rsk_preset_field "$i" MEM)
        t=$(rsk_preset_field "$i" TIME)
        mark=""
        [[ "$i" -eq "$_def" ]] && mark="<- default (bare v)"
        printf "%-3s %-24s %-10s %-22s %-10s %-6s %-8s %-12s %s\n" \
            "$i" "$n" "$a" "$p" "${g:-}" "$c" "$m" "$t" "$mark"
    done
}

# Indirect lookup of RSK_PRESET_<n>_<field>.
rsk_preset_field() {
    local n="$1" field="$2"
    local var="RSK_PRESET_${n}_${field}"
    printf '%s' "${!var:-}"
}

# Resolve the configured default_preset (a preset NAME or a 1-based index) to a
# numeric index. Used for a bare `v`/`p` with no preset argument. Falls back to
# preset 1 if default_preset is unset, empty, or does not match any preset.
rsk_default_preset_idx() {
    local d="${RSK_DEFAULT_PRESET:-}"
    [[ -z "$d" ]] && { echo 1; return; }
    if [[ "$d" =~ ^[0-9]+$ ]]; then
        echo "$d"; return
    fi
    local i
    for ((i = 1; i <= ${RSK_PRESET_COUNT:-0}; i++)); do
        if [[ "$(rsk_preset_field "$i" NAME)" == "$d" ]]; then
            echo "$i"; return
        fi
    done
    echo "Warning: default_preset '$d' not found among presets; using preset 1." >&2
    echo 1
}

# Parse args into RSK_PRESET_IDX, RSK_OVERRIDE_*, RSK_LIST, RSK_HELP, RSK_KEEP_RENDERED.
rsk_parse_args() {
    RSK_PRESET_IDX=1
    RSK_LIST=0
    RSK_HELP=0
    RSK_KEEP_RENDERED=0
    RSK_OVERRIDE_ACCOUNT=""
    RSK_OVERRIDE_PARTITION=""
    RSK_OVERRIDE_GRES=""
    RSK_OVERRIDE_GRES_SET=0
    RSK_OVERRIDE_CORES=""
    RSK_OVERRIDE_MEM=""
    RSK_OVERRIDE_TIME=""
    RSK_OVERRIDE_ENV=""

    local saw_preset=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)           RSK_LIST=1; shift ;;
            -h|--help)        RSK_HELP=1; shift ;;
            --keep-rendered)  RSK_KEEP_RENDERED=1; shift ;;
            --account)        RSK_OVERRIDE_ACCOUNT="$2"; shift 2 ;;
            --partition)      RSK_OVERRIDE_PARTITION="$2"; shift 2 ;;
            --gres)           RSK_OVERRIDE_GRES="$2"; RSK_OVERRIDE_GRES_SET=1; shift 2 ;;
            --cores)          RSK_OVERRIDE_CORES="$2"; shift 2 ;;
            --mem)            RSK_OVERRIDE_MEM="$2"; shift 2 ;;
            --time)           RSK_OVERRIDE_TIME="$2"; shift 2 ;;
            --env)            RSK_OVERRIDE_ENV="$2"; shift 2 ;;
            --)               shift; break ;;
            -*)               echo "Unknown flag: $1" >&2; return 2 ;;
            *)
                if [[ $saw_preset -eq 0 && "$1" =~ ^[0-9]+$ ]]; then
                    RSK_PRESET_IDX="$1"
                    saw_preset=1
                    shift
                else
                    echo "Unexpected argument: $1" >&2
                    return 2
                fi
                ;;
        esac
    done

    # No positional preset given -> fall back to the configured default_preset
    # (name or index; see rsk_default_preset_idx). `v 2` etc. still win because
    # they set saw_preset above.
    if [[ $saw_preset -eq 0 ]]; then
        RSK_PRESET_IDX="$(rsk_default_preset_idx)"
    fi
}

# Resolve preset + overrides into RSK_JOB_* env vars used by templates.
rsk_resolve_job_vars() {
    local n=$RSK_PRESET_IDX
    if [[ $n -lt 1 || $n -gt ${RSK_PRESET_COUNT:-0} ]]; then
        echo "Preset $n out of range (have ${RSK_PRESET_COUNT:-0} presets). Try --list." >&2
        return 1
    fi

    RSK_JOB_NAME=$(rsk_preset_field "$n" NAME)
    RSK_JOB_ACCOUNT="${RSK_OVERRIDE_ACCOUNT:-$(rsk_preset_field "$n" ACCOUNT)}"
    RSK_JOB_PARTITION="${RSK_OVERRIDE_PARTITION:-$(rsk_preset_field "$n" PARTITION)}"
    if [[ $RSK_OVERRIDE_GRES_SET -eq 1 ]]; then
        RSK_JOB_GRES="$RSK_OVERRIDE_GRES"
    else
        RSK_JOB_GRES=$(rsk_preset_field "$n" GRES)
    fi
    RSK_JOB_CORES="${RSK_OVERRIDE_CORES:-$(rsk_preset_field "$n" CORES)}"
    RSK_JOB_MEM="${RSK_OVERRIDE_MEM:-$(rsk_preset_field "$n" MEM)}"
    RSK_JOB_TIME="${RSK_OVERRIDE_TIME:-$(rsk_preset_field "$n" TIME)}"
    local preset_env
    preset_env="$(rsk_preset_field "$n" CONDA_ENV)"
    RSK_JOB_ENV="${RSK_OVERRIDE_ENV:-${preset_env:-${RSK_CONDA_ENV:-base}}}"
    RSK_JOB_USER="$USER"
    RSK_JOB_LOGIN_HOST="${RSK_LOGIN_HOST:-}"

    # --gres is optional; render the whole SBATCH line conditionally.
    if [[ -n "$RSK_JOB_GRES" ]]; then
        RSK_JOB_GRES_LINE="#SBATCH --gres=${RSK_JOB_GRES}"
    else
        RSK_JOB_GRES_LINE=""
    fi

    export RSK_JOB_NAME RSK_JOB_ACCOUNT RSK_JOB_PARTITION RSK_JOB_GRES \
        RSK_JOB_GRES_LINE RSK_JOB_CORES RSK_JOB_MEM RSK_JOB_TIME RSK_JOB_ENV \
        RSK_JOB_USER RSK_JOB_LOGIN_HOST
}

# Human-readable summary of what will be requested from SLURM. Call after
# rsk_resolve_job_vars. Reads the resolved RSK_JOB_* values and the
# RSK_OVERRIDE_* flags (to mark which fields came from CLI flags vs the preset).
# $1 (optional): one-line description of what the job launches.
rsk_print_job_summary() {
    local launches="${1:-}"
    local mk_account="" mk_partition="" mk_gres="" mk_cores="" mk_mem="" mk_time="" mk_env=""
    [[ -n "$RSK_OVERRIDE_ACCOUNT"   ]] && mk_account="  (override)"
    [[ -n "$RSK_OVERRIDE_PARTITION" ]] && mk_partition="  (override)"
    [[ $RSK_OVERRIDE_GRES_SET -eq 1 ]] && mk_gres="  (override)"
    [[ -n "$RSK_OVERRIDE_CORES"     ]] && mk_cores="  (override)"
    [[ -n "$RSK_OVERRIDE_MEM"       ]] && mk_mem="  (override)"
    [[ -n "$RSK_OVERRIDE_TIME"      ]] && mk_time="  (override)"
    [[ -n "$RSK_OVERRIDE_ENV"       ]] && mk_env="  (override)"

    echo "=== Session request (preset ${RSK_PRESET_IDX}: ${RSK_JOB_NAME}) ==="
    printf "  %-13s %s%s\n" "Account:"    "$RSK_JOB_ACCOUNT"        "$mk_account"
    printf "  %-13s %s%s\n" "Partition:"  "$RSK_JOB_PARTITION"      "$mk_partition"
    printf "  %-13s %s%s\n" "GRES:"       "${RSK_JOB_GRES:-none}"   "$mk_gres"
    printf "  %-13s %s%s\n" "CPU cores:"  "$RSK_JOB_CORES"          "$mk_cores"
    printf "  %-13s %s%s\n" "Memory:"     "$RSK_JOB_MEM"            "$mk_mem"
    printf "  %-13s %s%s\n" "Time limit:" "$RSK_JOB_TIME"           "$mk_time"
    printf "  %-13s %s\n"   "Nodes:"      "1 (no --nodes/--ntasks set; SLURM default)"
    printf "  %-13s %s%s\n" "Conda env:"  "$RSK_JOB_ENV"            "$mk_env"
    [[ -n "${RSK_JOB_LOGIN_HOST:-}" ]] && printf "  %-13s %s\n" "Login host:" "$RSK_JOB_LOGIN_HOST"
    [[ -n "$launches" ]] && printf "  %-13s %s\n" "Launches:" "$launches"
    printf "  %-13s %s\n"   "Config:"     "$RSK_CONFIG"
}

# Render template by allow-listing only RSK_JOB_* vars (protects $SLURM_JOB_ID etc.).
rsk_render_template() {
    local tpl="$1"
    local out="$2"
    local allow='${RSK_JOB_ACCOUNT} ${RSK_JOB_TIME} ${RSK_JOB_PARTITION} ${RSK_JOB_GRES} ${RSK_JOB_GRES_LINE} ${RSK_JOB_CORES} ${RSK_JOB_MEM} ${RSK_JOB_ENV} ${RSK_JOB_USER} ${RSK_JOB_LOGIN_HOST}'
    envsubst "$allow" < "$tpl" > "$out"
}
