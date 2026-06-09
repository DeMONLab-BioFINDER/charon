#!/bin/bash
# finalize.sh
# Runs after all per-subject SLURM jobs complete (submitted with afterany dependency).
# 1. Writes a processing status TSV to OUTDIR.
# 2. Compresses WORKDIR to OUTDIR/<dataset>_<tracer>_<suffix>.tar.gz.
#
# Usage:
#   bash finalize.sh --config <path/to/charon_config.yaml>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) CONFIG=$2; shift 2;;
        *) shift;;
    esac
done

_cfg() { grep "^${1}:" "$CONFIG" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | xargs; }

WORKDIR="$(_cfg workdir)"
OUTDIR="$(_cfg outdir)"
DATASET="$(_cfg dataset)"
TRACER="$(_cfg tracer)"
SUFFIX="$(_cfg suffix)"
PAIRS_FILE="$WORKDIR/image_pairs.tsv"

log_section "$(basename "${BASH_SOURCE[0]}")"

# ============================================================
# PROCESSING STATUS TSV
# ============================================================

STATUS_TSV="${WORKDIR}/${DATASET}_${TRACER}_${SUFFIX}_processing_status.tsv"
log_info "Writing processing status to: $STATUS_TSV"

printf "subject\tt1_path\tpet_path\tday_diff\tfastsurfer_seg\tfastsurfer_surf\tpetprep\n" > "$STATUS_TSV"

while IFS=$'\t' read -r subject pet_path t1_path day_diff; do
    [[ "$subject" == "subject" ]] && continue

    # Extract session label from PET filename
    pet_fname="$(basename "$pet_path")"
    if [[ "$pet_fname" =~ ses-([^_]+) ]]; then
        session="ses-${BASH_REMATCH[1]}"
    else
        session=""
    fi

    # Check input files first
    if [[ ! -f "$t1_path" || ! -f "$pet_path" ]]; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$subject" "$t1_path" "$pet_path" "$day_diff" \
            "file_not_found" "file_not_found" "file_not_found" >> "$STATUS_TSV"
        log_warn "$subject $session — input file(s) not found"
        continue
    fi

    SUBJECT_FS="$WORKDIR/$subject${session:+/$session}/fastsurfer/$subject"

    if [[ -f "$SUBJECT_FS/mri/aparc.DKTatlas+aseg.deep.mgz" ]]; then
        seg_status="success"
    else
        seg_status="failed"
    fi

    if [[ -f "$SUBJECT_FS/surf/lh.pial" ]]; then
        surf_status="success"
    else
        surf_status="failed"
    fi

    participant="${subject#sub-}"
    PP_DIR="$WORKDIR/$subject${session:+/$session}/petprep/sub-${participant}"
    if [[ -d "$PP_DIR" && -n "$(ls -A "$PP_DIR" 2>/dev/null)" ]]; then
        petprep_status="success"
    else
        petprep_status="failed"
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$subject" "$t1_path" "$pet_path" "$day_diff" \
        "$seg_status" "$surf_status" "$petprep_status" >> "$STATUS_TSV"

    log_info "$subject $session — seg: $seg_status  surf: $surf_status  petprep: $petprep_status"
done < "$PAIRS_FILE"

log_success "Status TSV written: $STATUS_TSV"

# ============================================================
# COMPRESS WORKDIR
# ============================================================

ARCHIVE="${OUTDIR}/${DATASET}_${TRACER}_${SUFFIX}.tar.gz"
log_info "Compressing workdir to: $ARCHIVE"

tar -czf "$ARCHIVE" --exclude='*/petprep/work' -C "$WORKDIR" .

if [[ $? -eq 0 ]]; then
    log_success "Archive created: $ARCHIVE"
else
    log_error "Failed to compress workdir"
    exit 1
fi

exit 0
