#!/bin/bash
# finalize.sh
# Runs after all per-subject SLURM jobs complete (submitted with afterany dependency).
# 1. Writes a processing status TSV to the tracer working directory.
# 2. Compresses each subject/session directory in place within --workdir (on both the
#    fastsurfer and charon sides) and removes the live directory, to save disk space.
#    run_fastsurfer.sh re-extracts an archived FastSurfer session on demand if a later
#    run needs to reuse it.
# 3. Compresses fastsurfer_crosssectional/ and charon_crosssectional_<tracer>/ into
#    two separate full archives in OUTDIR. Since step 2 already ran, these archives
#    contain the per-session .tar.gz files rather than raw directories.
# 4. Now that OUTDIR holds the full archives, deletes the per-session .tar.gz from
#    --workdir for every subject/session that succeeded (both sides), leaving failed
#    rows in place for inspection/retry. Removes the whole tracer working directory
#    if every row succeeded.
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
TRACER_DIR="$(_cfg tracer_dir)"
FASTSURFER_DIR="$(_cfg fastsurfer_dir)"
OUTDIR="$(_cfg outdir)"
TRACER="$(_cfg tracer)"
PAIRS_FILE="$TRACER_DIR/image_pairs.tsv"
LOGFILE="$TRACER_DIR/charon.log"

log_section "$(basename "${BASH_SOURCE[0]}")"

# ============================================================
# PROCESSING STATUS TSV
# ============================================================

STATUS_TSV="${TRACER_DIR}/charon_crosssectional_${TRACER}_processing_status.tsv"
log_info "Writing processing status to: $STATUS_TSV"

printf "subject\tt1_path\tpet_path\tday_diff\tfastsurfer_seg\tfastsurfer_surf\tpetprep\n" > "$STATUS_TSV"

while IFS=$'\t' read -r subject pet_path t1_path day_diff; do
    [[ "$subject" == "subject" ]] && continue

    # Extract session label from the PET filename (used for the petprep output path)
    pet_fname="$(basename "$pet_path")"
    if [[ "$pet_fname" =~ ses-([^_]+) ]]; then
        session="ses-${BASH_REMATCH[1]}"
    else
        session=""
    fi

    # Extract session label from the T1w filename (used for the fastsurfer output path)
    t1_fname="$(basename "$t1_path")"
    if [[ "$t1_fname" =~ ses-([^_]+) ]]; then
        t1_session="ses-${BASH_REMATCH[1]}"
    else
        t1_session=""
    fi

    # Check input files first
    if [[ ! -f "$t1_path" || ! -f "$pet_path" ]]; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$subject" "$t1_path" "$pet_path" "$day_diff" \
            "file_not_found" "file_not_found" "file_not_found" >> "$STATUS_TSV"
        log_warn "$subject $session — input file(s) not found"
        continue
    fi

    SUBJECT_FS="$FASTSURFER_DIR/$subject${t1_session:+/$t1_session}/$subject"

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

    # Same completion marker run_petprep.sh's reuse check uses, so a subject can't be
    # "success" here but "not yet done" there (or vice versa).
    participant="${subject#sub-}"
    PP_LOG_DIR="$TRACER_DIR/$subject${session:+/$session}/logs"
    if grep -q "PETPrep finished successfully!" "${PP_LOG_DIR}"/pp_${participant}_*.log 2>/dev/null; then
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
# COMPRESS PER-SESSION OUTPUTS IN PLACE — saves disk space in the workdir itself
# and ensures the full archives below contain compressed sessions rather than raw
# directories. run_fastsurfer.sh transparently re-extracts an archived FastSurfer
# session if a later run needs to reuse it.
# ============================================================

log_info "Compressing per-session outputs in workdir..."

while IFS=$'\t' read -r subject pet_path t1_path day_diff; do
    [[ "$subject" == "subject" ]] && continue

    pet_fname="$(basename "$pet_path")"
    if [[ "$pet_fname" =~ ses-([^_]+) ]]; then
        session="ses-${BASH_REMATCH[1]}"
    else
        session=""
    fi

    t1_fname="$(basename "$t1_path")"
    if [[ "$t1_fname" =~ ses-([^_]+) ]]; then
        t1_session="ses-${BASH_REMATCH[1]}"
    else
        t1_session=""
    fi

    # FastSurfer side: may already be archived by an earlier row sharing the same
    # T1 session (or a previous tracer's finalize run) — -d guard makes this safe to repeat.
    FS_LEAF="$FASTSURFER_DIR/$subject${t1_session:+/$t1_session}"
    if [[ -d "$FS_LEAF" ]]; then
        if tar -czf "${FS_LEAF}.tar.gz" -C "$(dirname "$FS_LEAF")" "$(basename "$FS_LEAF")"; then
            rm -rf "$FS_LEAF"
        else
            log_warn "Failed to compress FastSurfer session: $FS_LEAF"
        fi
    fi

    # Charon side: one row normally maps to one session directory.
    CHARON_LEAF="$TRACER_DIR/$subject${session:+/$session}"
    if [[ -d "$CHARON_LEAF" ]]; then
        if tar -czf "${CHARON_LEAF}.tar.gz" --exclude='*/petprep/work' -C "$(dirname "$CHARON_LEAF")" "$(basename "$CHARON_LEAF")"; then
            rm -rf "$CHARON_LEAF"
        else
            log_warn "Failed to compress charon session: $CHARON_LEAF"
        fi
    fi
done < "$PAIRS_FILE"

log_success "Per-session compression complete"

# ============================================================
# COMPRESS FAKE BIDS DIRECTORY IN PLACE — same rationale as the per-session
# compaction above: saves disk space in --workdir and ensures the full charon
# archive below contains the compressed bids/ rather than the raw symlink tree.
# ============================================================

BIDS_DIR="$TRACER_DIR/bids"
if [[ -d "$BIDS_DIR" ]]; then
    log_info "Compressing fake BIDS directory: $BIDS_DIR"
    if tar -czf "${BIDS_DIR}.tar.gz" -C "$TRACER_DIR" "$(basename "$BIDS_DIR")"; then
        rm -rf "$BIDS_DIR"
        log_success "Fake BIDS directory compressed: ${BIDS_DIR}.tar.gz"
    else
        log_warn "Failed to compress fake BIDS directory: $BIDS_DIR"
    fi
fi

# ============================================================
# COMPRESS OUTPUTS — fastsurfer and charon outputs are archived separately.
# Runs after per-session compression above, so these full archives contain the
# per-session .tar.gz files rather than raw directories.
# ============================================================

FASTSURFER_ARCHIVE="${OUTDIR}/fastsurfer_crosssectional.tar.gz"
log_info "Compressing fastsurfer_crosssectional to: $FASTSURFER_ARCHIVE"

tar -czf "$FASTSURFER_ARCHIVE" -C "$WORKDIR" "$(basename "$FASTSURFER_DIR")"

if [[ $? -eq 0 ]]; then
    log_success "Archive created: $FASTSURFER_ARCHIVE"
else
    log_error "Failed to compress fastsurfer_crosssectional"
    exit 1
fi

CHARON_ARCHIVE="${OUTDIR}/charon_crosssectional_${TRACER}.tar.gz"
log_info "Compressing charon_crosssectional_${TRACER} to: $CHARON_ARCHIVE"

tar -czf "$CHARON_ARCHIVE" --exclude='*/petprep/work' -C "$WORKDIR" "$(basename "$TRACER_DIR")"

if [[ $? -eq 0 ]]; then
    log_success "Archive created: $CHARON_ARCHIVE"
else
    log_error "Failed to compress charon_crosssectional_${TRACER}"
    exit 1
fi

# ============================================================
# WORKDIR CLEANUP — now that the full archives above safely capture everything,
# remove the now-redundant per-session .tar.gz for subjects/sessions that
# succeeded, on both the fastsurfer and charon sides. Failed rows are left in
# place for inspection or a later --reuse retry. If every row succeeded, the
# entire tracer working directory is removed; charon.log and charon_config.yaml
# are copied to OUTDIR first so the run's record survives the deletion.
# ============================================================

log_info "Cleaning up successfully processed subjects/sessions from workdir..."

ALL_SUCCESS=true

while IFS=$'\t' read -r subject t1_path pet_path day_diff seg_status surf_status petprep_status; do
    [[ "$subject" == "subject" ]] && continue

    pet_fname="$(basename "$pet_path")"
    if [[ "$pet_fname" =~ ses-([^_]+) ]]; then
        session="ses-${BASH_REMATCH[1]}"
    else
        session=""
    fi

    t1_fname="$(basename "$t1_path")"
    if [[ "$t1_fname" =~ ses-([^_]+) ]]; then
        t1_session="ses-${BASH_REMATCH[1]}"
    else
        t1_session=""
    fi

    if [[ "$petprep_status" == "success" ]]; then
        CHARON_LEAF="$TRACER_DIR/$subject${session:+/$session}"
        rm -f "${CHARON_LEAF}.tar.gz"
        log_info "Removed charon session from workdir (already archived in outdir): $subject $session"
    else
        ALL_SUCCESS=false
    fi

    # FastSurfer recon is shared across rows of the same (subject, T1 session); deleting
    # it more than once is harmless since rm -f is a no-op on an already-removed file.
    if [[ "$seg_status" == "success" && "$surf_status" == "success" ]]; then
        FS_LEAF="$FASTSURFER_DIR/$subject${t1_session:+/$t1_session}"
        rm -f "${FS_LEAF}.tar.gz"
        log_info "Removed FastSurfer session from workdir (already archived in outdir): $subject $t1_session"
    fi
done < "$STATUS_TSV"

if [[ "$ALL_SUCCESS" == true ]]; then
    log_info "All subjects/sessions processed successfully — removing tracer working directory: $TRACER_DIR"
    cp "$LOGFILE" "$OUTDIR/charon_crosssectional_${TRACER}.log" 2>/dev/null
    cp "$CONFIG"  "$OUTDIR/charon_crosssectional_${TRACER}_config.yaml" 2>/dev/null
    rm -rf "$TRACER_DIR"
    log_success "Tracer working directory removed: $TRACER_DIR"
else
    log_warn "Not all subjects/sessions succeeded — keeping tracer working directory (only failed rows remain): $TRACER_DIR"
fi

exit 0
