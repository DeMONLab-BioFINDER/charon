#!/bin/bash
# charon.sh
# Master orchestrator for the charon pipeline.
# This is the only script the user calls directly.
#
# Usage:
#   bash charon.sh --dataset <name> --dataset_dir <path> --tracer <tracer> \
#                  --workdir <path> [--outdir <path>] \
#                  --fs_license <path/to/license.txt> \
#                  --petprep_sif <path/to/petprep.sif> \
#                  --fastsurfer_sif <path/to/fastsurfer.sif> \
#                  [--mri_pet_daydiff <days>] \
#                  [--image_pairs <path/to/pairs.tsv>] \
#                  [--run_config <path/to/slurm.yaml>] \
#                  [--reuse]
#
# --outdir defaults to <dataset_dir>/<dataset>/derivatives if omitted.

# ============================================================
# ENVIRONMENT
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"
source "$SCRIPT_DIR/config/defaults.sh"

if [[ -f "$SCRIPT_DIR/config/local.sh" ]]; then
    source "$SCRIPT_DIR/config/local.sh"
fi

# ============================================================
# USAGE
# ============================================================

usage() {
    echo ""
    echo "  CHARON — The DeMON lab PET preprocessing pipeline"
    echo ""
    echo "  Usage:"
    echo "    bash charon.sh [required arguments] [optional arguments]"
    echo ""
    echo "  Required arguments:"
    echo "    --dataset         <name>             Name of the dataset (e.g. ADNI)"
    echo "    --dataset_dir     <path>             Path to the BIDS dataset directory"
    echo "    --tracer          <name>             Tracer name (e.g. ftp, mk)"
    echo "    --workdir         <path>             Path to the working directory"
    echo "    --fs_license      <path>             Path to the FreeSurfer license file"
    echo "    --petprep_sif     <path>             Path to the PETprep Singularity image"
    echo "    --fastsurfer_sif  <path>             Path to the FastSurfer Singularity image"
    echo "    --run_config      <path>             Path to the run configuration file (SLURM + tool options)"
    echo ""
    echo "  Optional arguments:"
    echo "    --outdir          <path>             Path to the output directory (default: <dataset_dir>/<dataset>/derivatives)"
    echo "    --templateflow_home <path>           Path to the TemplateFlow cache directory"
    echo "    --mri_pet_daydiff <days>             Maximum days between MRI and PET (default: 365)"
    echo "    --image_pairs     <path>             Path to a pre-defined image pairs .tsv file"
    echo "    --ses_format    date|label           Session label format: 'date' (YYYYMMDD, default) or 'label' (e.g. bl, fu1)"
    echo "    --no_session                         Dataset has no session level — pair by subject only"
    echo "    --reuse                              Reuse existing outputs in workdir"
    echo "    --pilot                              Pilot mode: skip container checks (for local testing)"
    echo "    --help                               Show this help message"
    echo ""
    echo "  Example:"
    echo "    bash charon.sh \\"
    echo "        --dataset ADNI \\"
    echo "        --dataset_dir /path/to/bids \\"
    echo "        --tracer ftp \\"
    echo "        --workdir /path/to/workdir \\"
    echo "        --fs_license /path/to/license.txt \\"
    echo "        --petprep_sif /path/to/petprep.sif \\"
    echo "        --fastsurfer_sif /path/to/fastsurfer.sif"
    echo ""
    echo "  (omitting --outdir above defaults it to /path/to/bids/ADNI/derivatives)"
    echo ""
    exit 1
}

# show usage if no arguments provided
if [[ $# -eq 0 ]]; then
    usage
fi

# ============================================================
# ARGUMENT PARSING
# ============================================================

# parse --help, --workdir, --tracer and --reuse; pass all original args through to setup.sh
WORKDIR="${DEFAULT_WORKDIR}"
TRACER="${DEFAULT_TRACER}"
REUSE=false
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case $1 in
        --workdir) WORKDIR=$2; shift 2;;
        --tracer)  TRACER=$2;  shift 2;;
        --reuse)   REUSE=true; shift;;
        --help|-h) usage;;
        *) shift;;
    esac
done

# ============================================================
# PASS ALL ARGUMENTS TO SETUP
# ============================================================

log_section "CHARON"

bash "$SCRIPT_DIR/setup.sh" "${ORIGINAL_ARGS[@]}"
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    log_error "Setup failed — aborting pipeline"
    exit $EXIT_CODE
fi

# ============================================================
# READ CONFIG
# ============================================================

TRACER_DIR="$WORKDIR/charon_crosssectional_${TRACER}"
CONFIG_FILE="$TRACER_DIR/charon_config.yaml"
PAIRS_FILE="$TRACER_DIR/image_pairs.tsv"
LOGFILE="$TRACER_DIR/charon.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found after setup: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f "$PAIRS_FILE" ]]; then
    log_error "Image pairs file not found after setup: $PAIRS_FILE"
    exit 1
fi

PILOT_MODE=$(grep "^pilot:" "$CONFIG_FILE" | sed 's/^[^:]*:[[:space:]]*//' | xargs)
[[ "$PILOT_MODE" == "true" ]] && log_warn "Pilot mode — SLURM jobs will not be submitted; commands will be echoed instead"

# ============================================================
# PROCESS SUBJECTS
# ============================================================

log_section "PROCESSING"

N_SUBJECTS=$(tail -n +2 "$PAIRS_FILE" | wc -l | xargs)
log_info "Found $N_SUBJECTS subject(s) to process"

SUBJECT_IDX=0
N_SUCCESS=0
N_FAILED=0
FAILED_SUBJECTS=()
ALL_PETPREP_JOB_IDS=()

# Tracks FastSurfer submissions made so far in this run, as "subject|t1_session=job_id"
# entries (plain array, not an associative array, for bash 3.2 compatibility on macOS).
FS_JOBS=()
_fs_job_lookup() {
    local key="$1" entry
    for entry in "${FS_JOBS[@]}"; do
        [[ "${entry%%=*}" == "$key" ]] && { echo "${entry#*=}"; return 0; }
    done
    return 1
}

# Pre-scan pairs file to find subject+PET-session keys that appear more than once
# (can happen with --scan_selection all). uniq -d outputs only duplicate lines.
_COLLISION_KEYS=$(while IFS=$'\t' read -r _s _pet _t1 _; do
    [[ "$_s" == "subject" ]] && continue
    _pfname="$(basename "$_pet")"
    [[ "$_pfname" =~ ses-([^_]+) ]] && _pses="ses-${BASH_REMATCH[1]}" || _pses="nosession"
    echo "${_s}|${_pses}"
done < "$PAIRS_FILE" | sort | uniq -d)

while IFS=$'\t' read -r SUBJECT PET_FILE T1_FILE DAYDIFF; do

    [[ "$SUBJECT" == "subject" ]] && continue

    SUBJECT_IDX=$((SUBJECT_IDX + 1))

    # Extract session label from PET filename (empty for no-session datasets)
    PET_FNAME="$(basename "$PET_FILE")"
    if [[ "$PET_FNAME" =~ ses-([^_]+) ]]; then
        SESSION="ses-${BASH_REMATCH[1]}"
    else
        SESSION=""
    fi

    # Extract session label from the T1w filename (empty for no-session datasets).
    # FastSurfer output is keyed by this — the T1's own session — not the PET session.
    T1_FNAME="$(basename "$T1_FILE")"
    if [[ "$T1_FNAME" =~ ses-([^_]+) ]]; then
        T1_SESSION="ses-${BASH_REMATCH[1]}"
    else
        T1_SESSION=""
    fi

    # If the same subject+PET session appears more than once, append T1 session
    # to avoid output directory collisions (e.g. with --scan_selection all)
    _pses="${SESSION:-nosession}"
    if echo "$_COLLISION_KEYS" | grep -qF "${SUBJECT}|${_pses}" && [[ -n "$T1_SESSION" ]]; then
        SESSION="${SESSION}_t1-${T1_SESSION#ses-}"
    fi

    log_section "SUBJECT $SUBJECT_IDX / $N_SUBJECTS: $SUBJECT ($SESSION)"

    # --- Set up per-subject directory structure ---
    bash "$SCRIPT_DIR/setup_subject.sh" --subject "$SUBJECT" --session "$SESSION" --t1_session "$T1_SESSION" --config "$CONFIG_FILE"
    if [[ $? -ne 0 ]]; then
        log_error "Subject directory setup failed for $SUBJECT — skipping"
        N_FAILED=$((N_FAILED + 1))
        FAILED_SUBJECTS+=("$SUBJECT (setup)")
        continue
    fi

    # --- FastSurfer (seg + surf, chained internally) ---
    # Dedup within this run: multiple PET pairs for the same subject can resolve
    # to the same T1 session (e.g. --scan_selection all). Only submit FastSurfer
    # once per (subject, T1 session) and reuse the job/status for the rest.
    FS_KEY="${SUBJECT}|${T1_SESSION:-nosession}"
    FS_JOB_ID="$(_fs_job_lookup "$FS_KEY")"
    if [[ -n "$FS_JOB_ID" ]]; then
        log_info "Reusing FastSurfer job for $SUBJECT ($T1_SESSION) already submitted earlier in this run: $FS_JOB_ID"
    else
        FASTSURFER_ARGS=(
            --subject    "$SUBJECT"
            --t1_session "$T1_SESSION"
            --t1         "$T1_FILE"
            --config     "$CONFIG_FILE"
        )
        [[ "$REUSE" == true ]] && FASTSURFER_ARGS+=(--reuse)

        FS_JOB_ID=$(bash "$SCRIPT_DIR/run_fastsurfer.sh" "${FASTSURFER_ARGS[@]}")

        if [[ $? -ne 0 || -z "$FS_JOB_ID" ]]; then
            log_error "FastSurfer submission failed for $SUBJECT — skipping"
            N_FAILED=$((N_FAILED + 1))
            FAILED_SUBJECTS+=("$SUBJECT (FastSurfer)")
            continue
        fi
        FS_JOBS+=("${FS_KEY}=${FS_JOB_ID}")
    fi

    PETPREP_DEPENDENCY="$FS_JOB_ID"
    case "$FS_JOB_ID" in
        DRY_RUN) log_info "FastSurfer dry run complete for $SUBJECT" ;;
        REUSED)  log_info "Reusing existing FastSurfer output for $SUBJECT"; PETPREP_DEPENDENCY="" ;;
        *)       log_info "FastSurfer submitted for $SUBJECT (surf job: $FS_JOB_ID)" ;;
    esac

    # --- PETprep (depends on FastSurfer surf, unless reused) ---
    PETPREP_ARGS=(
        --subject    "$SUBJECT"
        --session    "$SESSION"
        --t1_session "$T1_SESSION"
        --pet        "$PET_FILE"
        --t1         "$T1_FILE"
        --config     "$CONFIG_FILE"
        --dependency "$PETPREP_DEPENDENCY"
    )
    [[ "$REUSE" == true ]] && PETPREP_ARGS+=(--reuse)

    PETPREP_JOB_ID=$(bash "$SCRIPT_DIR/run_petprep.sh" "${PETPREP_ARGS[@]}")

    if [[ $? -ne 0 || -z "$PETPREP_JOB_ID" ]]; then
        log_error "PETprep submission failed for $SUBJECT — skipping"
        N_FAILED=$((N_FAILED + 1))
        FAILED_SUBJECTS+=("$SUBJECT (PETprep)")
        continue
    fi
    case "$PETPREP_JOB_ID" in
        DRY_RUN) log_info "PETprep dry run complete for $SUBJECT" ;;
        REUSED)  log_info "Reusing already-completed PETprep output for $SUBJECT" ;;
        *)       log_info "PETprep submitted for $SUBJECT (job: $PETPREP_JOB_ID)"; ALL_PETPREP_JOB_IDS+=("$PETPREP_JOB_ID") ;;
    esac

    # --- Statistics (stub) ---
    bash "$SCRIPT_DIR/run_statistics.sh" --subject "$SUBJECT" --config "$CONFIG_FILE"

    # --- QC (stub) ---
    bash "$SCRIPT_DIR/run_qc.sh" --subject "$SUBJECT" --config "$CONFIG_FILE"

    log_success "Jobs submitted for $SUBJECT"
    N_SUCCESS=$((N_SUCCESS + 1))

done < "$PAIRS_FILE"

# ============================================================
# SUBMIT FINALIZE JOB
# ============================================================

if [[ "$PILOT_MODE" == "true" ]]; then
    log_info "Pilot mode — skipping finalize job submission"
elif [[ $N_SUCCESS -gt 0 && -f "$TRACER_DIR/run_config.yaml" ]]; then
    _rcfg() { grep "^${1}:" "$TRACER_DIR/run_config.yaml" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | xargs; }
    FINALIZE_ACCOUNT="$(_rcfg finalize_account)"
    if [[ -z "$FINALIZE_ACCOUNT" ]]; then
        log_warn "finalize_account not set in run_config — skipping finalize job submission"
    fi
    FINALIZE_CPUS="$(_rcfg finalize_cpus_per_task)"
    FINALIZE_MEM="$(_rcfg finalize_mem)"
    FINALIZE_TIME="$(_rcfg finalize_time)"

    FINALIZE_SCRIPT="$TRACER_DIR/finalize.sh"
    {
    cat << EOF
#!/bin/bash
#SBATCH --job-name=finalize
#SBATCH --account=${FINALIZE_ACCOUNT}
#SBATCH --output=${TRACER_DIR}/charon.log
#SBATCH --open-mode=append
EOF
    # Only add a dependency if at least one real PETprep job was submitted — if every
    # subject's PETprep was already complete and reused, there's nothing to wait on.
    if [[ ${#ALL_PETPREP_JOB_IDS[@]} -gt 0 ]]; then
        DEPENDENCY_STR="afterany:$(IFS=':'; echo "${ALL_PETPREP_JOB_IDS[*]}")"
        echo "#SBATCH --dependency=${DEPENDENCY_STR}"
    fi
    [[ -n "$FINALIZE_CPUS" ]] && echo "#SBATCH --cpus-per-task=${FINALIZE_CPUS}"
    [[ -n "$FINALIZE_MEM"  ]] && echo "#SBATCH --mem=${FINALIZE_MEM}"
    [[ -n "$FINALIZE_TIME" ]] && echo "#SBATCH --time=${FINALIZE_TIME}"
    cat << EOF

bash "${SCRIPT_DIR}/finalize.sh" --config "${CONFIG_FILE}"
EOF
    } > "$FINALIZE_SCRIPT"

    if [[ -n "$FINALIZE_ACCOUNT" ]]; then
        FINALIZE_JOB_ID=$(sbatch --parsable "$FINALIZE_SCRIPT")
        if [[ -z "$FINALIZE_JOB_ID" ]]; then
            log_error "Failed to submit finalize job — no status TSV or archive will be created"
        else
            log_info "Finalize job submitted: $FINALIZE_JOB_ID (runs after all PETprep jobs)"
        fi
    fi
fi

# ============================================================
# SUMMARY
# ============================================================

log_section "SUMMARY"

log_info    "Total subjects:    $N_SUBJECTS"
log_success "Jobs submitted:    $N_SUCCESS"

if [[ $N_FAILED -gt 0 ]]; then
    log_warn "Submission failed: $N_FAILED"
    for SUBJECT in "${FAILED_SUBJECTS[@]}"; do
        log_warn "  - $SUBJECT"
    done
else
    log_success "No failures"
fi

{
    echo ""
    echo "========================================"
    echo "  CHARON SUMMARY"
    echo "  Completed: $(date)"
    echo "========================================"
    echo "  Total:     $N_SUBJECTS"
    echo "  Success:   $N_SUCCESS"
    echo "  Failed:    $N_FAILED"
    if [[ ${#FAILED_SUBJECTS[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed subjects:"
        for SUBJECT in "${FAILED_SUBJECTS[@]}"; do
            echo "    - $SUBJECT"
        done
    fi
    echo "========================================"
} >> "$LOGFILE"