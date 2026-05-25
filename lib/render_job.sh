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
    printf "%-3s %-24s %-10s %-22s %-10s %-6s %-8s %s\n" \
        "#" "NAME" "ACCOUNT" "PARTITION" "GRES" "CORES" "MEM" "TIME"
    local i
    for ((i = 1; i <= RSK_PRESET_COUNT; i++)); do
        local n a p g c m t
        n=$(rsk_preset_field "$i" NAME)
        a=$(rsk_preset_field "$i" ACCOUNT)
        p=$(rsk_preset_field "$i" PARTITION)
        g=$(rsk_preset_field "$i" GRES)
        c=$(rsk_preset_field "$i" CORES)
        m=$(rsk_preset_field "$i" MEM)
        t=$(rsk_preset_field "$i" TIME)
        printf "%-3s %-24s %-10s %-22s %-10s %-6s %-8s %s\n" \
            "$i" "$n" "$a" "$p" "${g:-}" "$c" "$m" "$t"
    done
}

# Indirect lookup of RSK_PRESET_<n>_<field>.
rsk_preset_field() {
    local n="$1" field="$2"
    local var="RSK_PRESET_${n}_${field}"
    printf '%s' "${!var:-}"
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

# Render template by allow-listing only RSK_JOB_* vars (protects $SLURM_JOB_ID etc.).
rsk_render_template() {
    local tpl="$1"
    local out="$2"
    local allow='${RSK_JOB_ACCOUNT} ${RSK_JOB_TIME} ${RSK_JOB_PARTITION} ${RSK_JOB_GRES} ${RSK_JOB_GRES_LINE} ${RSK_JOB_CORES} ${RSK_JOB_MEM} ${RSK_JOB_ENV} ${RSK_JOB_USER} ${RSK_JOB_LOGIN_HOST}'
    envsubst "$allow" < "$tpl" > "$out"
}
