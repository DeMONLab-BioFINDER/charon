#!/bin/bash
# setup.sh
# Validates arguments, sets up the working environment, and writes the charon config.
#
# Usage:
#   bash setup.sh --dataset dataset_name --dataset_dir /path/to/directory
#                 --tracer tracer_name \
#                 --workdir /path/to/workdir [--outdir /path/to/outdir] \
#                 --fs_license /path/to/license.txt \
#                 --petprep_sif /path/to/petprep.sif \
#                 --fastsurfer_sif /path/to/fastsurfer.sif \
#                 [--mri_pet_daydiff 365] \
#                 [--scan_selection earliest|latest|all] \
#                 [--ses_format date|label] \
#                 [--no_session] \
#                 [--image_pairs /path/to/pairs.tsv] \
#                 [--templateflow_home /path/to/templateflow] \
#                 --run_config /path/to/run_config.yaml \
#                 [--reuse]
#
# --outdir defaults to <dataset_dir>/<dataset>/derivatives if omitted.

# ============================================================
# ENVIRONMENT
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"
source "$SCRIPT_DIR/config/defaults.sh"

# ============================================================
# DEFAULTS
# ============================================================

DATASET="${DEFAULT_DATASET}"
DATASET_DIR="${DEFAULT_DATASET_DIR}"
TRACER="${DEFAULT_TRACER}"
WORKDIR="${DEFAULT_WORKDIR}"
OUTDIR="${DEFAULT_OUTDIR}"
FS_LICENSE="${DEFAULT_FS_LICENSE}"
PETPREP_SIF="${DEFAULT_PETPREP_SIF}"
FASTSURFER_SIF="${DEFAULT_FASTSURFER_SIF}"
MRI_PET_DAYDIFF="${DEFAULT_MRI_PET_DAYDIFF}"
SCAN_SELECTION="${DEFAULT_SCAN_SELECTION}"
IMAGE_PAIRS="${DEFAULT_IMAGE_PAIRS}"
TEMPLATEFLOW_HOME="${DEFAULT_TEMPLATEFLOW_HOME}"
RUN_CONFIG="${DEFAULT_RUN_CONFIG}"
REUSE="${DEFAULT_REUSE}"
PILOT="${DEFAULT_PILOT}"
NO_SESSION="${DEFAULT_NO_SESSION}"
SES_FORMAT="${DEFAULT_SES_FORMAT}"

# ============================================================
# ARGUMENT PARSING
# ============================================================

usage() {
    echo "Usage: $0 --dataset <name> --dataset_dir <path> --tracer <tracer>"
    echo "          --workdir <path> [--outdir <path>]"
    echo "          --fs_license <path/to/license.txt>"
    echo "          --petprep_sif <path/to/petprep.sif>"
    echo "          --fastsurfer_sif <path/to/fastsurfer.sif>"
    echo "          [--mri_pet_daydiff <days>]"
    echo "          [--scan_selection earliest|latest|all]"
    echo "          [--image_pairs <path/to/pairs.tsv>]"
    echo "          [--templateflow_home <path>]"
    echo "          --run_config <path/to/run_config.yaml>"
    echo "          [--ses_format date|label]"
    echo "          [--no_session]"
    echo "          [--reuse]"
    echo "          [--pilot]"
    echo ""
    echo "  --outdir defaults to <dataset_dir>/<dataset>/derivatives if omitted."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dataset)         DATASET=$2;         shift 2;;
        --dataset_dir)     DATASET_DIR=$2;     shift 2;;
        --tracer)          TRACER=$2;          shift 2;;
        --workdir)         WORKDIR=$2;         shift 2;;
        --outdir)          OUTDIR=$2;          shift 2;;
        --fs_license)      FS_LICENSE=$2;      shift 2;;
        --petprep_sif)     PETPREP_SIF=$2;     shift 2;;
        --fastsurfer_sif)  FASTSURFER_SIF=$2;  shift 2;;
        --mri_pet_daydiff) MRI_PET_DAYDIFF=$2; MRI_PET_DAYDIFF_SET=true; shift 2;;
        --scan_selection)  SCAN_SELECTION=$2; SCAN_SELECTION_SET=true;  shift 2;;
        --ses_format)      SES_FORMAT=$2;                               shift 2;;
        --no_session)      NO_SESSION=true;                             shift;;
        --image_pairs)     IMAGE_PAIRS=$2;     shift 2;;
        --templateflow_home) TEMPLATEFLOW_HOME=$2; shift 2;;
        --run_config)   RUN_CONFIG=$2;   shift 2;;
        --reuse)           REUSE=true;         shift;;
        --pilot)           PILOT=true;         shift;;
        --help|-h)         usage;;
        *) log_error "Unknown argument: $1"; usage;;
    esac
done

# Default outdir to <dataset_dir>/<dataset>/derivatives if not explicitly provided.
# Validation below still catches a missing dataset/dataset_dir on its own terms.
if [[ -z "$OUTDIR" && -n "$DATASET_DIR" && -n "$DATASET" ]]; then
    OUTDIR="$DATASET_DIR/$DATASET/derivatives"
fi

if [[ -n "$IMAGE_PAIRS" ]]; then
    [[ "$MRI_PET_DAYDIFF_SET" == true    ]] && log_warn "--mri_pet_daydiff is ignored when --image_pairs is provided"
    [[ "$SCAN_SELECTION_SET"  == true    ]] && log_warn "--scan_selection is ignored when --image_pairs is provided"
    [[ "$NO_SESSION"          == true    ]] && log_warn "--no_session is ignored when --image_pairs is provided"
    [[ "$SES_FORMAT"          != "date"  ]] && log_warn "--ses_format is ignored when --image_pairs is provided"
    MRI_PET_DAYDIFF=NA
elif [[ "$NO_SESSION" == true ]]; then
    [[ "$MRI_PET_DAYDIFF_SET" == true    ]] && log_warn "--mri_pet_daydiff is ignored when --no_session is provided"
    [[ "$SCAN_SELECTION_SET"  == true    ]] && log_warn "--scan_selection is ignored when --no_session is provided"
    [[ "$SES_FORMAT"          != "date"  ]] && log_warn "--ses_format is ignored when --no_session is provided"
    MRI_PET_DAYDIFF=NA
elif [[ "$SES_FORMAT" == "label" ]]; then
    [[ "$MRI_PET_DAYDIFF_SET" == true    ]] && log_warn "--mri_pet_daydiff is ignored when --ses_format label is provided"
    [[ "$SCAN_SELECTION_SET"  == true    ]] && log_warn "--scan_selection is ignored when --ses_format label is provided"
    MRI_PET_DAYDIFF=NA
fi

# ============================================================
# VALIDATION
# ============================================================

ERRORS=0

require_arg() {
    local val=$1
    local name=$2
    if [[ -z "$val" ]]; then
        log_error "--${name} is required"
        ERRORS=$((ERRORS + 1))
    fi
}

require_file() {
    local val=$1
    local name=$2
    if [[ -n "$val" && ! -f "$val" ]]; then
        log_error "--${name}: file not found: $val"
        ERRORS=$((ERRORS + 1))
    fi
}

require_dir() {
    local val=$1
    local name=$2
    if [[ -n "$val" && ! -d "$val" ]]; then
        log_error "--${name}: directory not found: $val"
        ERRORS=$((ERRORS + 1))
    fi
}

require_arg  "$DATASET"         "dataset"
require_arg  "$DATASET_DIR"     "dataset_dir"
require_arg  "$TRACER"          "tracer"
require_arg  "$WORKDIR"         "workdir"
require_arg  "$OUTDIR"          "outdir"   # only unset if dataset/dataset_dir are too, which already error above
require_dir  "$DATASET_DIR"     "dataset_dir"
require_file "$IMAGE_PAIRS"     "image_pairs"

if [[ "$PILOT" != true ]]; then
    require_arg  "$RUN_CONFIG"            "run_config"
    require_file "$RUN_CONFIG"            "run_config"
    require_arg  "$FS_LICENSE"            "fs_license"
    require_arg  "$PETPREP_SIF"           "petprep_sif"
    require_arg  "$FASTSURFER_SIF"        "fastsurfer_sif"
    require_arg  "$TEMPLATEFLOW_HOME"     "templateflow_home"
    require_file "$FS_LICENSE"            "fs_license"
    require_file "$PETPREP_SIF"           "petprep_sif"
    require_file "$FASTSURFER_SIF"        "fastsurfer_sif"
    require_dir  "$TEMPLATEFLOW_HOME"     "templateflow_home"
fi

# check SES_FORMAT is valid
if [[ "$SES_FORMAT" != "date" && "$SES_FORMAT" != "label" ]]; then
    log_error "--ses_format must be 'date' or 'label' (got: $SES_FORMAT)"
    ERRORS=$((ERRORS + 1))
fi

# check SCAN_SELECTION is valid (skipped when IMAGE_PAIRS or --no_session is provided)
if [[ -z "$IMAGE_PAIRS" && "$NO_SESSION" != true && "$SCAN_SELECTION" != "earliest" && "$SCAN_SELECTION" != "latest" && "$SCAN_SELECTION" != "all" ]]; then
    log_error "--scan_selection must be 'earliest', 'latest', or 'all' (got: $SCAN_SELECTION)"
    ERRORS=$((ERRORS + 1))
fi

# check MRI_PET_DAYDIFF is a positive integer (skipped when IMAGE_PAIRS or --no_session overrides it to NA)
if [[ "$MRI_PET_DAYDIFF" != "NA" ]]; then
    if ! [[ "$MRI_PET_DAYDIFF" =~ ^[0-9]+$ ]]; then
        log_error "--mri_pet_daydiff must be a non-negative integer (got: $MRI_PET_DAYDIFF)"
        ERRORS=$((ERRORS + 1))
    fi
fi

# check dataset exists within dataset_dir
if [[ -n "$DATASET" && -n "$DATASET_DIR" ]]; then
    if [[ ! -d "$DATASET_DIR/$DATASET" ]]; then
        log_error "Dataset directory not found: $DATASET_DIR/$DATASET"
        ERRORS=$((ERRORS + 1))
    fi
fi

if [[ $ERRORS -gt 0 ]]; then
    log_error "$ERRORS error(s) found. Aborting."
    exit 1
fi

# ============================================================
# EXISTING RUN CHECK
# ============================================================

# TODO: this only checks for existing config/log files, but we may want to also check for existing output files and warn about potential conflicts

FASTSURFER_DIR="$WORKDIR/fastsurfer_crosssectional"
TRACER_DIR="$WORKDIR/charon_crosssectional_${TRACER}"
CONFIG_FILE="$TRACER_DIR/charon_config.yaml"
LOGFILE="$TRACER_DIR/charon.log"

# ============================================================
# RESTORE FROM OUTDIR
# ============================================================
# --workdir may have been wiped (e.g. to save disk, or by finalize.sh's own workdir
# cleanup) while --outdir still holds the full archives from a previous run. Restore
# them here, before the existing-run check below, so the rest of setup.sh sees the
# same state it would if --workdir had never been touched. The extraction itself can
# be large (the whole cumulative fastsurfer_crosssectional/ tree), so it's submitted
# as a SLURM job and waited on rather than run inline on the login node — except in
# --pilot mode, which has no SLURM access at all.
#
# FastSurfer restore always runs (when the archive exists), regardless of whether
# --workdir already has *some* sessions: because finalize.sh deletes a subject's
# recon from --workdir as soon as it succeeds, "missing locally" is the common case
# for a second-or-later tracer run sharing this --workdir, not a rare one. A gzip-
# compressed tar archive can't be cheaply spot-extracted (decompression is
# sequential regardless of how many members you ask for), so there's no cheaper way
# to fill in just the gaps — tar safely overlays onto existing content either way.

FASTSURFER_OUTDIR_ARCHIVE="$OUTDIR/fastsurfer_crosssectional.tar.gz"
NEED_FASTSURFER_RESTORE=false
[[ -f "$FASTSURFER_OUTDIR_ARCHIVE" ]] && NEED_FASTSURFER_RESTORE=true

CHARON_OUTDIR_ARCHIVE="$OUTDIR/charon_crosssectional_${TRACER}.tar.gz"
NEED_CHARON_RESTORE=false
[[ "$REUSE" == true && ! -f "$CONFIG_FILE" && -f "$CHARON_OUTDIR_ARCHIVE" ]] && NEED_CHARON_RESTORE=true

if [[ "$NEED_FASTSURFER_RESTORE" == true || "$NEED_CHARON_RESTORE" == true ]]; then
    mkdir -p "$WORKDIR" || { log_error "Failed to create workdir: $WORKDIR"; exit 1; }

    if [[ "$PILOT" == true ]]; then
        log_warn "Pilot mode — restoring from outdir inline (no SLURM access in pilot mode)"
        if [[ "$NEED_FASTSURFER_RESTORE" == true ]]; then
            log_info "Restoring fastsurfer_crosssectional/ from outdir archive: $FASTSURFER_OUTDIR_ARCHIVE"
            tar -xzf "$FASTSURFER_OUTDIR_ARCHIVE" -C "$WORKDIR" || { log_error "Failed to extract $FASTSURFER_OUTDIR_ARCHIVE"; exit 1; }
        fi
        if [[ "$NEED_CHARON_RESTORE" == true ]]; then
            log_info "Restoring charon_crosssectional_${TRACER}/ from outdir archive: $CHARON_OUTDIR_ARCHIVE"
            tar -xzf "$CHARON_OUTDIR_ARCHIVE" -C "$WORKDIR" || { log_error "Failed to extract $CHARON_OUTDIR_ARCHIVE"; exit 1; }
        fi
    else
        _rcfg() { grep "^${1}:" "$RUN_CONFIG" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | xargs; }
        RESTORE_ACCOUNT="$(_rcfg restore_account)"
        RESTORE_PARTITION="$(_rcfg restore_partition)"
        RESTORE_CPUS="$(_rcfg restore_cpus_per_task)"
        RESTORE_MEM="$(_rcfg restore_mem)"
        RESTORE_TIME="$(_rcfg restore_time)"

        if [[ -z "$RESTORE_ACCOUNT" ]]; then
            log_error "restore_account not set in run_config — required to restore archives from outdir on a compute node"
            exit 1
        fi

        RESTORE_SCRIPT="$WORKDIR/restore_outdir.sh"
        {
            echo "#!/bin/bash"
            echo "#SBATCH --job-name=restore_outdir"
            echo "#SBATCH --account=${RESTORE_ACCOUNT}"
            [[ -n "$RESTORE_PARTITION" ]] && echo "#SBATCH -p ${RESTORE_PARTITION}"
            [[ -n "$RESTORE_CPUS" ]] && echo "#SBATCH --cpus-per-task=${RESTORE_CPUS}"
            [[ -n "$RESTORE_MEM"  ]] && echo "#SBATCH --mem=${RESTORE_MEM}"
            [[ -n "$RESTORE_TIME" ]] && echo "#SBATCH --time=${RESTORE_TIME}"
            echo "#SBATCH --output=${WORKDIR}/restore_outdir_%j.log"
            echo ""
            [[ "$NEED_FASTSURFER_RESTORE" == true ]] && echo "tar -xzf '${FASTSURFER_OUTDIR_ARCHIVE}' -C '${WORKDIR}' || exit 1"
            [[ "$NEED_CHARON_RESTORE"     == true ]] && echo "tar -xzf '${CHARON_OUTDIR_ARCHIVE}' -C '${WORKDIR}' || exit 1"
        } > "$RESTORE_SCRIPT"

        log_info "Submitting compute-node job to restore archive(s) from outdir (blocking until complete)..."
        if RESTORE_JOB_ID=$(sbatch --wait --parsable "$RESTORE_SCRIPT"); then
            log_success "Restore job $RESTORE_JOB_ID completed — see ${WORKDIR}/restore_outdir_${RESTORE_JOB_ID}.log"
        else
            log_error "Restore-from-outdir job failed — see ${WORKDIR}/restore_outdir_*.log"
            exit 1
        fi
    fi
fi

if [[ -f "$CONFIG_FILE" ]]; then
    if [[ "$REUSE" == true ]]; then
        log_warn "Existing charon run found in: $TRACER_DIR"
        log_info "Reuse mode enabled — existing outputs will be reused where possible"
    else
        log_error "A charon run already exists in: $TRACER_DIR"
        log_error "To reuse existing outputs, pass --reuse"
        log_error "To start fresh, specify a different --workdir or --tracer"
        exit 1
    fi
fi

# ============================================================
# ENVIRONMENT SETUP
# ============================================================

log_section "$(basename "${BASH_SOURCE[0]}")"

log_info "Creating working directory: $WORKDIR"
mkdir -p "$WORKDIR" || { log_error "Failed to create workdir: $WORKDIR"; exit 1; }

log_info "Creating output directory: $OUTDIR"
mkdir -p "$OUTDIR"  || { log_error "Failed to create outdir: $OUTDIR";   exit 1; }

log_info "Creating shared FastSurfer directory: $FASTSURFER_DIR"
mkdir -p "$FASTSURFER_DIR" || { log_error "Failed to create: $FASTSURFER_DIR"; exit 1; }

log_info "Creating tracer working directory: $TRACER_DIR"
mkdir -p "$TRACER_DIR" || { log_error "Failed to create: $TRACER_DIR"; exit 1; }

# build or validate image pairs
if [[ "$REUSE" == true && -f "$TRACER_DIR/image_pairs.tsv" ]]; then
    log_info "Reusing existing image pairs in tracer working directory"
else
    if [[ -n "$IMAGE_PAIRS" ]]; then
        bash "$SCRIPT_DIR/get_image_pairs.sh" \
            --image_pairs    "$IMAGE_PAIRS" \
            --outfile        "$TRACER_DIR/image_pairs.tsv"
    else
        PAIRS_ARGS=(
            --dataset_dir     "$DATASET_DIR"
            --dataset         "$DATASET"
            --tracer          "$TRACER"
            --mri_pet_daydiff "$MRI_PET_DAYDIFF"
            --scan_selection  "$SCAN_SELECTION"
            --ses_format      "$SES_FORMAT"
            --outfile         "$TRACER_DIR/image_pairs.tsv"
        )
        [[ "$NO_SESSION" == true ]] && PAIRS_ARGS+=(--no_session)
        bash "$SCRIPT_DIR/get_image_pairs.sh" "${PAIRS_ARGS[@]}"
    fi
    if [[ $? -ne 0 ]]; then
        log_error "Image pair step failed. Aborting."
        exit 1
    fi
fi

FAKE_BIDS_DIR="$TRACER_DIR/bids"
if [[ "$REUSE" == true && -f "$FAKE_BIDS_DIR/dataset_description.json" ]]; then
    log_info "Reusing existing fake BIDS directory: $FAKE_BIDS_DIR"
else
    bash "$SCRIPT_DIR/build_fake_bids.sh" \
        --pairs  "$TRACER_DIR/image_pairs.tsv" \
        --outdir "$FAKE_BIDS_DIR"
    if [[ $? -ne 0 ]]; then
        log_error "Failed to build fake BIDS directory. Aborting."
        exit 1
    fi
fi

if [[ -n "$RUN_CONFIG" ]]; then
    if [[ "$REUSE" == true && -f "$TRACER_DIR/run_config.yaml" ]]; then
        log_info "Reusing existing SLURM options in tracer working directory"
    else
        cp "$RUN_CONFIG" "$TRACER_DIR/run_config.yaml"
        log_info "Copied SLURM options to tracer working directory"
    fi
fi

# ============================================================
# GET IMAGE VERSIONS
# ============================================================

if [[ "$PILOT" == true ]]; then
    log_warn "Pilot mode — skipping container version checks"
    PETPREP_VERSION="pilot"
    FASTSURFER_VERSION="pilot"
else
    log_info "Retrieving container versions..."
    PETPREP_VERSION=$(singularity run "$PETPREP_SIF" --version 2>/dev/null || echo "unknown")
    FASTSURFER_VERSION=$(singularity run "$FASTSURFER_SIF" --version 2>/dev/null || echo "unknown")
    log_info "PETprep version:    $PETPREP_VERSION"
    log_info "FastSurfer version: $FASTSURFER_VERSION"
fi

# ============================================================
# WRITE CHARON CONFIG
# ============================================================

if [[ "$REUSE" == true && -f "$CONFIG_FILE" ]]; then
    log_info "Reusing existing config: $CONFIG_FILE"
else
    log_info "Writing config to: $CONFIG_FILE"
    cat > "$CONFIG_FILE" << EOF
dataset:              $DATASET
dataset_dir:          $DATASET_DIR
tracer:               $TRACER
mri_pet_daydiff:      $MRI_PET_DAYDIFF
workdir:              $WORKDIR
outdir:               $OUTDIR
fastsurfer_dir:       $FASTSURFER_DIR
tracer_dir:           $TRACER_DIR
fs_license:           $FS_LICENSE
petprep_sif:          $PETPREP_SIF
petprep_version:      $PETPREP_VERSION
fastsurfer_sif:       $FASTSURFER_SIF
fastsurfer_version:   $FASTSURFER_VERSION
templateflow_home:    $TEMPLATEFLOW_HOME
EOF

    [[ "$PILOT" == true ]] && echo "pilot:                true"              >> "$CONFIG_FILE"
    echo "image_pairs:          $TRACER_DIR/image_pairs.tsv" >> "$CONFIG_FILE"
    [[ "$NO_SESSION"  == true  ]]                                              && echo "no_session:           true"              >> "$CONFIG_FILE"
    echo                                                                           "ses_format:           $SES_FORMAT"              >> "$CONFIG_FILE"
    [[ -z "$IMAGE_PAIRS" && "$NO_SESSION" != true && "$SES_FORMAT" != "label" ]] && echo "scan_selection:       $SCAN_SELECTION"   >> "$CONFIG_FILE"
    [[ -n "$RUN_CONFIG"  ]] && echo "run_config:        $TRACER_DIR/run_config.yaml"  >> "$CONFIG_FILE"
fi

# ============================================================
# INIT LOG
# ============================================================

{
    echo "========================================"
    echo "  CHARON LOG"
    echo "  Started: $(date)"
    [[ "$REUSE" == true ]] && echo "  Mode: reuse"
    echo "========================================"
    echo ""
    echo "Config:"
    cat "$CONFIG_FILE"
    echo ""
    echo "----------------------------------------"
} >> "$LOGFILE"

# ============================================================
# DONE
# ============================================================

log_success "Setup completed successfully"
log_info    "Config:             $CONFIG_FILE"
log_info    "Log:                $LOGFILE"
log_info    "PETprep version:    $PETPREP_VERSION"
log_info    "FastSurfer version: $FASTSURFER_VERSION"
echo "Setup completed successfully at $(date)" >> "$LOGFILE"
exit 0