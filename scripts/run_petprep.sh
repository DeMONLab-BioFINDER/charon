#!/bin/bash
# run_petprep.sh
# Submits a PETprep SLURM job depending on a completed FastSurfer surface job.
# All SBATCH directives are read from the run_config file in the pipeline config.
# Echoes the PETprep job ID to stdout; all other output goes to stderr.
#
# Usage (called by charon.sh):
#   PETPREP_JOB_ID=$(bash run_petprep.sh --subject <sub> --pet <path> --t1 <path> \
#                                        --config <path> --dependency <job_id>)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"

# ============================================================
# ARGUMENT PARSING
# ============================================================

REUSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --subject)    SUBJECT=$2;    shift 2;;
        --session)    SESSION=$2;    shift 2;;
        --t1_session) T1_SESSION=$2; shift 2;;
        --pet)        PET_FILE=$2;   shift 2;;
        --t1)         T1_FILE=$2;    shift 2;;
        --config)     CONFIG=$2;     shift 2;;
        --dependency) DEPENDENCY=$2; shift 2;;
        --reuse)      REUSE=true;    shift;;
        *) shift;;
    esac
done

# ============================================================
# READ CONFIG AND SLURM OPTIONS
# ============================================================

_cfg()   { grep "^${1}:" "$CONFIG"          | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | xargs; }
_slurm() { grep "^${1}:" "$RUN_CONFIG_FILE" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | xargs; }

PETPREP_SIF="$(_cfg petprep_sif)"
FS_LICENSE="$(_cfg fs_license)"
OUTDIR="$(_cfg outdir)"
TRACER_DIR="$(_cfg tracer_dir)"
FASTSURFER_DIR="$(_cfg fastsurfer_dir)"
DATASET_DIR="$(_cfg dataset_dir)"
PILOT="$(_cfg pilot)"
DATASET="$(_cfg dataset)"
TEMPLATEFLOW_HOME="$(_cfg templateflow_home)"
RUN_CONFIG_FILE="$(_cfg run_config)"

if [[ "$PILOT" != "true" && ( -z "$RUN_CONFIG_FILE" || ! -f "$RUN_CONFIG_FILE" ) ]]; then
    log_error "SLURM options file not found in config. Pass --run_config to charon.sh." >&2
    exit 1
fi

PP_ACCOUNT="$(_slurm petprep_account)"
PP_PARTITION="$(_slurm petprep_partition)"
PP_NTASKS="$(_slurm petprep_ntasks)"
PP_TIME="$(_slurm petprep_time)"


if [[ "$PILOT" != "true" && -z "$PP_ACCOUNT" ]]; then
    log_error "petprep_account not set in: $RUN_CONFIG_FILE" >&2
    exit 1
fi

# ============================================================
# PATHS
# ============================================================

REAL_BIDS_DIR="${DATASET_DIR}/${DATASET}"
FAKE_BIDS_DIR="${TRACER_DIR}/bids"
SESSION_DIR="$TRACER_DIR/$SUBJECT${SESSION:+/$SESSION}"
FS_OUTDIR="$FASTSURFER_DIR/$SUBJECT${T1_SESSION:+/$T1_SESSION}"
PETPREP_OUTDIR="$SESSION_DIR/petprep"
PETPREP_WORKDIR="$SESSION_DIR/petprep/work"
LOG_DIR="$SESSION_DIR/logs"
LICENSE_DIR="$(dirname "$FS_LICENSE")"
LICENSE_FNAME="$(basename "$FS_LICENSE")"
PARTICIPANT="${SUBJECT#sub-}"

# ============================================================
# REUSE CHECK — skip resubmission entirely if a previous PETprep run for
# this subject/session already completed successfully. PETprep has no
# single sentinel file like FastSurfer's recon-all.done, so completion is
# detected from its own log. Checked regardless of --reuse, consistent
# with FastSurfer's "always reuse what's already done" behavior.
# ============================================================

if grep -q "PETPrep finished successfully!" "${LOG_DIR}"/pp_${PARTICIPANT}_*.log 2>/dev/null; then
    log_info "PETprep already completed successfully for $SUBJECT — reusing" >&2
    echo "REUSED"
    exit 0
fi

# ============================================================
# REUSE: DELETE EXISTING PETPREP OUTPUT
# ============================================================

if [[ "$REUSE" == true && -d "$PETPREP_OUTDIR" ]]; then
    log_warn "Deleting existing PETprep output for $SUBJECT: $PETPREP_OUTDIR" >&2
    rm -rf "$PETPREP_OUTDIR"
fi

# ============================================================
# SUBMIT PETPREP JOB
# ============================================================

NTHREADS="${PP_NTASKS:-16}"
OMP_NTHREADS="${PP_OMP_NTHREADS:-$(( NTHREADS / 2 ))}"

# ============================================================
# READ PETPREP OPTIONS FROM RUN_CONFIG
# ============================================================

_flag() { [[ "$(_slurm "petprep_${1}")" == "true" ]] && PETPREP_EXTRA_ARGS+=" $2"; }
_val()  { local v; v=$(_slurm "petprep_${1}"); [[ -n "$v" ]] && PETPREP_EXTRA_ARGS+=" $2 $v"; }

MEM_MB="$(_slurm petprep_mem_mb)";           MEM_MB="${MEM_MB:-32000}"
v="$(_slurm petprep_omp_nthreads)";          [[ -n "$v" ]] && OMP_NTHREADS="$v"
PP_STOP_ON_CRASH="$(_slurm petprep_stop_on_first_crash)"; PP_STOP_ON_CRASH="${PP_STOP_ON_CRASH:-true}"
PP_NOTRACK="$(_slurm petprep_notrack)";       PP_NOTRACK="${PP_NOTRACK:-true}"
PP_VERBOSE="$(_slurm petprep_verbose)";       PP_VERBOSE="${PP_VERBOSE:-true}"

if [[ "$(_slurm petprep_longitudinal)" == "true" ]]; then
    log_error "petprep_longitudinal is not yet supported by charon." >&2
    exit 1
fi

PETPREP_EXTRA_ARGS=""

# Input / Output
_flag skip_bids_validation          "--skip_bids_validation"
_val  output_spaces                 "--output-spaces"
_val  output_layout                 "--output-layout"
_val  level                         "--level"

# Subject / Session

# Anatomical
_val  anatref                       "--anatref"
_flag longitudinal                  "--longitudinal"
_val  ignore                        "--ignore"
_val  skull_strip_template          "--skull-strip-template"
_val  skull_strip_t1w               "--skull-strip-t1w"
_flag skull_strip_fixed_seed        "--skull-strip-fixed-seed"
FS_NO_RECONALL="$(_slurm petprep_fs_no_reconall)"
_flag fs_no_reconall                "--fs-no-reconall"
_flag fs_no_resume                  "--fs-no-resume"
smr="$(_slurm petprep_submm_recon)"
# --submm-recon is the default; petprep only exposes --no-submm-recon to disable it.
[[ "$smr" == "false" ]] && PETPREP_EXTRA_ARGS+=" --no-submm-recon"

# PET processing
_val  petref                        "--petref"
_val  pet2anat_dof                  "--pet2anat-dof"
_val  pet2anat_method               "--pet2anat-method"
_val  hmc_fwhm                      "--hmc-fwhm"
_val  hmc_start_time                "--hmc-start-time"
_val  hmc_init_frame                "--hmc-init-frame"
_flag hmc_init_frame_fix            "--hmc-init-frame-fix"
_flag hmc_off                       "--hmc-off"

# --force-bbr/--force-no-bbr are deprecated in favour of --force {bbr,no-bbr}
FORCE_OPTS=""
[[ "$(_slurm petprep_force_bbr)"    == "true" ]] && FORCE_OPTS+=" bbr"
[[ "$(_slurm petprep_force_no_bbr)" == "true" ]] && FORCE_OPTS+=" no-bbr"
[[ -n "$FORCE_OPTS" ]] && PETPREP_EXTRA_ARGS+=" --force${FORCE_OPTS}"

# Segmentation & PVC
_val  seg                           "--seg"
_val  ref_mask_name                 "--ref-mask-name"
_val  ref_mask_index                "--ref-mask-index"
_val  pvc_tool                      "--pvc-tool"
_val  pvc_method                    "--pvc-method"
_val  pvc_psf                       "--pvc-psf"

# Surface & parcellation
_val  cifti_output                  "--cifti-output"
_flag no_msm                        "--no-msm"
_flag medial_surface_nan            "--medial-surface-nan"
_flag project_goodvoxels            "--project-goodvoxels"
_flag return_all_components         "--return-all-components"

# Confounds
_val  fd_spike_threshold            "--fd-spike-threshold"
_val  dvars_spike_threshold         "--dvars-spike-threshold"

# Misc
_val  random_seed                   "--random-seed"
_val  aggregate_session_reports     "--aggregate-session-reports"
_flag track_carbon                  "--track-carbon"
_val  country_code                  "--country-code"
_flag write_graph                   "--write-graph"
_flag resource_monitor              "--resource-monitor"
_val  debug                         "--debug"

PETPREP_SCRIPT="${LOG_DIR}/pp_${SUBJECT#sub-}.sh"
{
    echo "#!/bin/bash"
    echo "#SBATCH --job-name=pp_${SUBJECT#sub-}"
    echo "#SBATCH --account=${PP_ACCOUNT}"
    [[ -n "$PP_PARTITION" ]] && echo "#SBATCH -p ${PP_PARTITION}"
    [[ -n "$PP_NTASKS"    ]] && echo "#SBATCH -n ${PP_NTASKS}"
    [[ -n "$PP_TIME"      ]] && echo "#SBATCH --time=${PP_TIME}"
    echo "#SBATCH --mem=${MEM_MB}M"
    echo "#SBATCH --output=${LOG_DIR}/pp_${SUBJECT#sub-}_%j.log"
    [[ -n "$DEPENDENCY"   ]] && echo "#SBATCH --dependency=afterok:${DEPENDENCY}"
    echo ""
    echo "module load singularity"
    echo ""
    echo "mkdir -p ${PETPREP_OUTDIR} ${PETPREP_WORKDIR}"
    echo ""
    echo "export TEMPLATEFLOW_HOME=\"${TEMPLATEFLOW_HOME}\""
    echo "export APPTAINERENV_TEMPLATEFLOW_HOME=\"/templateflow\""
    echo "export FS_LICENSE=\"${FS_LICENSE}\""
    echo "export APPTAINERENV_FS_LICENSE=\"/freesurfer_license/${LICENSE_FNAME}\""
    echo ""
    echo "unset PYTHONPATH"
    echo ""
    echo "singularity run --cleanenv \\"
    echo "    --env TEMPLATEFLOW_HOME=/templateflow \\"
    echo "    -B ${FAKE_BIDS_DIR}:/data \\"
    echo "    -B ${REAL_BIDS_DIR}:${REAL_BIDS_DIR} \\"
    echo "    -B ${PETPREP_OUTDIR}:/out \\"
    echo "    -B ${LICENSE_DIR}:/freesurfer_license \\"
    echo "    -B ${PETPREP_WORKDIR}:/work \\"
    echo "    -B ${TEMPLATEFLOW_HOME}:/templateflow \\"
    echo "    -B ${FS_OUTDIR}:/freesurfer \\"
    echo "    ${PETPREP_SIF} /data /out participant \\"
    echo "    --participant-label ${PARTICIPANT} \\"
    echo "    --fs-license-file /freesurfer_license/${LICENSE_FNAME} \\"
    [[ "$FS_NO_RECONALL" != "true" ]] && echo "    --fs-subjects-dir /freesurfer \\"
    echo "    -w /work \\"
    echo "    --nprocs ${NTHREADS} \\"
    echo "    --omp-nthreads ${OMP_NTHREADS} \\"
    ALL_EXTRA=""
    [[ "$PP_STOP_ON_CRASH" == "true" ]] && ALL_EXTRA+=" --stop-on-first-crash"
    [[ "$PP_NOTRACK"       == "true" ]] && ALL_EXTRA+=" --notrack"
    [[ "$PP_VERBOSE"       == "true" ]] && ALL_EXTRA+=" -v"
    ALL_EXTRA+="$PETPREP_EXTRA_ARGS"
    if [[ -n "$ALL_EXTRA" ]]; then
        echo "    --mem ${MEM_MB} \\"
        echo "    ${ALL_EXTRA# }"
    else
        echo "    --mem ${MEM_MB}"
    fi
} > "$PETPREP_SCRIPT"

if [[ "$PILOT" == "true" ]]; then
    log_info "DRY RUN — PETprep job for $SUBJECT (would depend on ${DEPENDENCY:-none}):" >&2
    cat "$PETPREP_SCRIPT" >&2
    PETPREP_JOB_ID="DRY_RUN"
else
    PETPREP_JOB_ID=$(sbatch --parsable "$PETPREP_SCRIPT")
    if [[ -z "$PETPREP_JOB_ID" ]]; then
        log_error "Failed to submit PETprep job for $SUBJECT" >&2
        exit 1
    fi
    log_info "Submitted pp job $PETPREP_JOB_ID for $SUBJECT (depends on ${DEPENDENCY:-none})" >&2
fi

echo "$PETPREP_JOB_ID"
exit 0
