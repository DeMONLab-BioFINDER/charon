#!/bin/bash
# run_fastsurfer.sh
# Submits FastSurfer segmentation and surface reconstruction as chained SLURM jobs.
# All SBATCH directives are read from the run_config file in the pipeline config.
# Echoes the surface job ID to stdout; all other output goes to stderr.
# Output lives under fastsurfer_dir/<subject>/<t1_session>/, shared across tracer
# runs in the same --workdir. If a completed run (scripts/recon-all.done) already
# exists there, no jobs are submitted and "REUSED" is echoed instead (regardless
# of --reuse). If finalize.sh already compressed that session to <t1_session>.tar.gz
# and removed the live directory, it is transparently re-extracted first. With
# --reuse, an incomplete prior output is removed and reprocessed.
#
# Usage (called by charon.sh):
#   SURF_JOB_ID=$(bash run_fastsurfer.sh --subject <sub> --t1_session <ses> --t1 <path> --config <path> [--reuse])

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"

# ============================================================
# ARGUMENT PARSING
# ============================================================

REUSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --subject)    SUBJECT=$2;    shift 2;;
        --t1_session) T1_SESSION=$2; shift 2;;
        --t1)         T1_FILE=$2;    shift 2;;
        --config)     CONFIG=$2;     shift 2;;
        --reuse)      REUSE=true;    shift;;
        *) shift;;
    esac
done

# ============================================================
# READ CONFIG AND SLURM OPTIONS
# ============================================================

_cfg()   { grep "^${1}:" "$CONFIG"          | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | xargs; }
_slurm() { grep "^${1}:" "$RUN_CONFIG_FILE" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | xargs; }

FASTSURFER_SIF="$(_cfg fastsurfer_sif)"
FS_LICENSE="$(_cfg fs_license)"
FASTSURFER_DIR="$(_cfg fastsurfer_dir)"
OUTDIR="$(_cfg outdir)"
RUN_CONFIG_FILE="$(_cfg run_config)"
PILOT="$(_cfg pilot)"

if [[ "$PILOT" != "true" && ( -z "$RUN_CONFIG_FILE" || ! -f "$RUN_CONFIG_FILE" ) ]]; then
    log_error "SLURM options file not found in config. Pass --run_config to charon.sh." >&2
    exit 1
fi

# Segmentation SLURM settings
SEG_ACCOUNT="$(_slurm fastsurfer_seg_account)"
SEG_PARTITION="$(_slurm fastsurfer_seg_partition)"
SEG_CPUS="$(_slurm fastsurfer_seg_cpus_per_task)"
SEG_MEM="$(_slurm fastsurfer_seg_mem)"
SEG_CONSTRAINT="$(_slurm fastsurfer_seg_constraint)"
SEG_TIME="$(_slurm fastsurfer_seg_time)"

# Surface SLURM settings
SURF_ACCOUNT="$(_slurm fastsurfer_surf_account)"
SURF_PARTITION="$(_slurm fastsurfer_surf_partition)"
SURF_CPUS="$(_slurm fastsurfer_surf_cpus_per_task)"
SURF_MEM="$(_slurm fastsurfer_surf_mem)"
SURF_TIME="$(_slurm fastsurfer_surf_time)"

# FastSurfer tool options
FS_THREADS="$(_slurm fastsurfer_threads)"

if [[ "$PILOT" != "true" && ( -z "$SEG_ACCOUNT" || -z "$SURF_ACCOUNT" ) ]]; then
    log_error "fastsurfer_seg_account / fastsurfer_surf_account not set in: $RUN_CONFIG_FILE" >&2
    exit 1
fi

# ============================================================
# PATHS
# ============================================================

FS_OUTDIR="$FASTSURFER_DIR/$SUBJECT${T1_SESSION:+/$T1_SESSION}"
LOG_DIR="$FS_OUTDIR/logs"

T1_DIR="$(dirname "$T1_FILE")"
T1_FNAME="$(basename "$T1_FILE")"
LICENSE_DIR="$(dirname "$FS_LICENSE")"
LICENSE_FNAME="$(basename "$FS_LICENSE")"

# ============================================================
# FIELD STRENGTH DETECTION
# ============================================================

T1_JSON="${T1_FILE%.nii.gz}"
T1_JSON="${T1_JSON%.nii}.json"

IS_3T=false
if [[ -f "$T1_JSON" ]]; then
    FIELD_STRENGTH=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('MagneticFieldStrength', ''))
except Exception:
    pass
" "$T1_JSON" 2>/dev/null)
    case "$FIELD_STRENGTH" in
        3|3.0) IS_3T=true;  log_info "Detected 3T scanner for $SUBJECT — passing --3T to FastSurfer" >&2 ;;
        "")    log_warn "MagneticFieldStrength not found in $T1_JSON — not passing --3T" >&2 ;;
        *)     log_info "Detected ${FIELD_STRENGTH}T scanner for $SUBJECT — not passing --3T" >&2 ;;
    esac
else
    log_warn "No T1 sidecar JSON found at $T1_JSON — not passing --3T" >&2
fi

# ============================================================
# REUSE CHECK
# ============================================================

RECON_DONE="${FS_OUTDIR}/${SUBJECT}/scripts/recon-all.done"
FS_ARCHIVE="${FS_OUTDIR}.tar.gz"

# Fall back to the cumulative outdir archive if this session isn't available locally
# at all (e.g. --workdir was wiped, or this session was never copied back from outdir).
# setup.sh already restores the whole fastsurfer_crosssectional/ tree up front when
# --workdir is missing entirely; this covers the case where --workdir has *some*
# sessions (e.g. from another tracer run) but not this particular one.
FASTSURFER_OUTDIR_ARCHIVE="${OUTDIR}/fastsurfer_crosssectional.tar.gz"
if [[ ! -f "$RECON_DONE" && ! -f "$FS_ARCHIVE" && -f "$FASTSURFER_OUTDIR_ARCHIVE" ]]; then
    ARCHIVE_MEMBER="$(basename "$FASTSURFER_DIR")${FS_ARCHIVE#"$FASTSURFER_DIR"}"
    log_info "No local FastSurfer output for $SUBJECT — checking outdir archive: $FASTSURFER_OUTDIR_ARCHIVE" >&2
    mkdir -p "$FASTSURFER_DIR"
    if tar -xzf "$FASTSURFER_OUTDIR_ARCHIVE" -C "$FASTSURFER_DIR" --strip-components=1 "$ARCHIVE_MEMBER" 2>/dev/null; then
        log_info "Recovered FastSurfer session for $SUBJECT from outdir archive" >&2
    else
        log_warn "Session not found in outdir archive — will reprocess $SUBJECT" >&2
    fi
fi

# finalize.sh compresses completed sessions in place and removes the live directory to
# save disk space. If that happened, transparently re-extract it before checking for reuse.
if [[ ! -f "$RECON_DONE" && -f "$FS_ARCHIVE" ]]; then
    log_info "Found archived FastSurfer output for $SUBJECT — extracting $FS_ARCHIVE" >&2
    mkdir -p "$(dirname "$FS_OUTDIR")"
    tar -xzf "$FS_ARCHIVE" -C "$(dirname "$FS_OUTDIR")" \
        || log_warn "Failed to extract $FS_ARCHIVE — will reprocess $SUBJECT" >&2
fi

# FastSurfer output is keyed by (subject, T1 session) and shared across tracer runs in
# this --workdir, so a complete recon is always reused regardless of --reuse — rerunning
# it would just recompute an identical result (or race with the run that produced it).
if [[ -f "$RECON_DONE" ]]; then
    log_info "FastSurfer output already complete for $SUBJECT (found $RECON_DONE) — reusing" >&2
    echo "REUSED"
    exit 0
fi

if [[ "$REUSE" == true && -d "${FS_OUTDIR}/${SUBJECT}" ]]; then
    log_warn "Incomplete FastSurfer output found for $SUBJECT (no recon-all.done) — removing ${FS_OUTDIR}/${SUBJECT} and reprocessing" >&2
    rm -rf "${FS_OUTDIR}/${SUBJECT}"
fi

# ============================================================
# SUBMIT SEGMENTATION JOB
# ============================================================

SEG_SCRIPT="${LOG_DIR}/seg_${SUBJECT#sub-}.sh"
{
    echo "#!/bin/bash"
    echo "#SBATCH --job-name=seg_${SUBJECT#sub-}"
    echo "#SBATCH --account=${SEG_ACCOUNT}"
    [[ -n "$SEG_PARTITION"  ]] && echo "#SBATCH -p ${SEG_PARTITION}"
    [[ -n "$SEG_CPUS"       ]] && echo "#SBATCH --cpus-per-task=${SEG_CPUS}"
    [[ -n "$SEG_MEM"        ]] && echo "#SBATCH --mem=${SEG_MEM}"
    [[ -n "$SEG_CONSTRAINT" ]] && echo "#SBATCH -C ${SEG_CONSTRAINT}"
    [[ -n "$SEG_TIME"       ]] && echo "#SBATCH --time=${SEG_TIME}"
    echo "#SBATCH --output=${LOG_DIR}/seg_${SUBJECT#sub-}_%j.log"
    echo ""
    echo "module load singularity"
    echo ""
    echo "singularity exec --nv --no-mount home,cwd -e \\"
    echo "  -B ${T1_DIR}:/data \\"
    echo "  -B ${FS_OUTDIR}:/output \\"
    echo "  -B ${LICENSE_DIR}:/fs_license \\"
    echo "  ${FASTSURFER_SIF} \\"
    echo "  /fastsurfer/run_fastsurfer.sh \\"
    echo "  --fs_license /fs_license/${LICENSE_FNAME} \\"
    echo "  --t1 /data/${T1_FNAME} \\"
    echo "  --sid ${SUBJECT} --sd /output \\"
    [[ "$IS_3T" == "true" ]] && echo "  --3T \\"
    echo "  --threads ${FS_THREADS:-${SEG_CPUS:-4}} --seg_only"
} > "$SEG_SCRIPT"

if [[ "$PILOT" == "true" ]]; then
    log_info "DRY RUN — FastSurfer seg job for $SUBJECT:" >&2
    cat "$SEG_SCRIPT" >&2
    SEG_JOB_ID="DRY_RUN"
else
    SEG_JOB_ID=$(sbatch --parsable "$SEG_SCRIPT")
    if [[ -z "$SEG_JOB_ID" ]]; then
        log_error "Failed to submit FastSurfer seg job for $SUBJECT" >&2
        exit 1
    fi
    log_info "Submitted seg job $SEG_JOB_ID for $SUBJECT" >&2
fi

# ============================================================
# SUBMIT SURFACE JOB (depends on seg)
# ============================================================

SURF_SCRIPT="${LOG_DIR}/surf_${SUBJECT#sub-}.sh"
{
    echo "#!/bin/bash"
    echo "#SBATCH --job-name=surf_${SUBJECT#sub-}"
    echo "#SBATCH --account=${SURF_ACCOUNT}"
    [[ -n "$SURF_PARTITION" ]] && echo "#SBATCH -p ${SURF_PARTITION}"
    [[ -n "$SURF_CPUS" ]] && echo "#SBATCH --cpus-per-task=${SURF_CPUS}"
    [[ -n "$SURF_MEM"  ]] && echo "#SBATCH --mem=${SURF_MEM}"
    [[ -n "$SURF_TIME" ]] && echo "#SBATCH --time=${SURF_TIME}"
    echo "#SBATCH --output=${LOG_DIR}/surf_${SUBJECT#sub-}_%j.log"
    echo "#SBATCH --dependency=afterok:${SEG_JOB_ID}"
    echo ""
    echo "module load singularity"
    echo ""
    echo "singularity exec --no-mount home,cwd -e \\"
    echo "  -B ${T1_DIR}:/data \\"
    echo "  -B ${FS_OUTDIR}:/output \\"
    echo "  -B ${LICENSE_DIR}:/fs_license \\"
    echo "  ${FASTSURFER_SIF} \\"
    echo "  /fastsurfer/run_fastsurfer.sh \\"
    echo "  --fs_license /fs_license/${LICENSE_FNAME} \\"
    echo "  --t1 /data/${T1_FNAME} \\"
    echo "  --sid ${SUBJECT} --sd /output \\"
    [[ "$IS_3T" == "true" ]] && echo "  --3T \\"
    echo "  --threads ${FS_THREADS:-${SURF_CPUS:-4}} --surf_only"
} > "$SURF_SCRIPT"

if [[ "$PILOT" == "true" ]]; then
    log_info "DRY RUN — FastSurfer surf job for $SUBJECT (would depend on $SEG_JOB_ID):" >&2
    cat "$SURF_SCRIPT" >&2
    SURF_JOB_ID="DRY_RUN"
else
    SURF_JOB_ID=$(sbatch --parsable "$SURF_SCRIPT")
    if [[ -z "$SURF_JOB_ID" ]]; then
        log_error "Failed to submit FastSurfer surf job for $SUBJECT" >&2
        exit 1
    fi
    log_info "Submitted surf job $SURF_JOB_ID for $SUBJECT (depends on $SEG_JOB_ID)" >&2
fi

echo "$SURF_JOB_ID"
exit 0
