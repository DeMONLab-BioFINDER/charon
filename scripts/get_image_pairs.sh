#!/bin/bash
# get_image_pairs.sh
# Either validates a user-provided image pairs TSV (removing rows with missing files),
# or auto-discovers paired T1w and PET scans within a day range.
#
# Usage — auto-discover:
#   bash get_image_pairs.sh --dataset_dir /path/to/dir --dataset ADNI \
#                       --tracer ftp --mri_pet_daydiff 365 \
#                       --scan_selection earliest|latest \
#                       --outfile /path/to/pairs.tsv
#
# Usage — validate provided:
#   bash get_image_pairs.sh --image_pairs /path/to/pairs.tsv \
#                       --outfile /path/to/validated_pairs.tsv

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"

# ============================================================
# ARGUMENT PARSING
# ============================================================

usage() {
    echo "Usage (auto-discover):"
    echo "  $0 --dataset_dir <path> --dataset <name> --tracer <name>"
    echo "     --mri_pet_daydiff <days> --scan_selection earliest|latest"
    echo "     --outfile <path/to/pairs.tsv>"
    echo ""
    echo "Usage (validate provided):"
    echo "  $0 --image_pairs <path/to/pairs.tsv> --outfile <path/to/pairs.tsv>"
    exit 1
}

IMAGE_PAIRS=""
NO_SESSION=false
SES_FORMAT="date"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dataset_dir)     DATASET_DIR=$2;     shift 2;;
        --dataset)         DATASET=$2;         shift 2;;
        --tracer)          TRACER=$2;          shift 2;;
        --mri_pet_daydiff) MRI_PET_DAYDIFF=$2; shift 2;;
        --scan_selection)  SCAN_SELECTION=$2;  shift 2;;
        --ses_format)      SES_FORMAT=$2;      shift 2;;
        --image_pairs)     IMAGE_PAIRS=$2;     shift 2;;
        --no_session)      NO_SESSION=true;    shift;;
        --outfile)         OUTFILE=$2;         shift 2;;
        --help|-h)         usage;;
        *) log_error "Unknown argument: $1"; usage;;
    esac
done

log_section "$(basename "${BASH_SOURCE[0]}")"

# ============================================================
# BRANCH: VALIDATE PROVIDED vs AUTO-DISCOVER
# ============================================================

if [[ -n "$IMAGE_PAIRS" ]]; then

    log_info "Validating image pairs: $IMAGE_PAIRS"

    TOTAL=0
    MISSING=0
    > "$OUTFILE"

    while IFS= read -r line; do
        IFS=$'\t' read -r subject pet_path t1_path _ <<< "$line"

        if [[ "$subject" == "subject" ]]; then
            echo "$line" >> "$OUTFILE"
            continue
        fi

        if [[ ! -f "$pet_path" ]]; then
            log_warn "$subject: PET file not found: $pet_path"
            MISSING=$((MISSING + 1))
        fi
        if [[ ! -f "$t1_path" ]]; then
            log_warn "$subject: T1w file not found: $t1_path"
            MISSING=$((MISSING + 1))
        fi

        echo "$line" >> "$OUTFILE"
        TOTAL=$((TOTAL + 1))
    done < "$IMAGE_PAIRS"

    log_info "Pairs written: $TOTAL"
    [[ $MISSING -gt 0 ]] && log_warn "$MISSING file(s) not found — affected subjects will appear as file_not_found in the status report"

    if [[ $TOTAL -eq 0 ]]; then
        log_error "No image pairs found in provided file."
        exit 1
    fi

    log_success "Image pair validation complete. Written to: $OUTFILE"
    exit 0

fi

# ============================================================
# BRANCH: NO-SESSION (pair by subject only, no date required)
# ============================================================

if [[ "$NO_SESSION" == true ]]; then

    RAW_DIR="$DATASET_DIR/$DATASET/raw"
    log_info "No-session mode — pairing by subject only"
    log_info "Searching in: $RAW_DIR"

    ERRORS=0
    NS_T1_ENTRIES=()
    NS_PET_ENTRIES=()

    while IFS= read -r f; do
        fname="$(basename "$f")"
        sub=""
        [[ "$fname" =~ (sub-[^_]+) ]] && sub="${BASH_REMATCH[1]}"
        if [[ -z "$sub" ]]; then
            log_error "Could not extract subject ID from: $f"
            ERRORS=$((ERRORS + 1)); continue
        fi
        NS_T1_ENTRIES+=("${sub}|${f}")
    done < <(find "$RAW_DIR" -type f -path "*/anat/*" \
        \( -name "*_T1w.nii.gz" -o -name "*_T1w.nii" \) | sort)

    while IFS= read -r f; do
        fname="$(basename "$f")"
        sub=""
        [[ "$fname" =~ (sub-[^_]+) ]] && sub="${BASH_REMATCH[1]}"
        if [[ -z "$sub" ]]; then
            log_error "Could not extract subject ID from: $f"
            ERRORS=$((ERRORS + 1)); continue
        fi
        NS_PET_ENTRIES+=("${sub}|${f}")
    done < <(find "$RAW_DIR" -type f -path "*/pet/*" \
        \( -name "*trc-${TRACER}*pet.nii.gz" -o -name "*trc-${TRACER}*pet.nii" \) | sort)

    log_info "Found ${#NS_T1_ENTRIES[@]} T1w file(s)"
    log_info "Found ${#NS_PET_ENTRIES[@]} PET file(s) for tracer: $TRACER"

    if [[ $ERRORS -gt 0 ]]; then
        log_error "$ERRORS error(s) found while parsing filenames. Aborting."
        exit 1
    fi

    > "$OUTFILE"
    printf "subject\tpet_path\tt1_path\tday_diff\n" >> "$OUTFILE"
    PAIR_COUNT=0

    for t1_entry in "${NS_T1_ENTRIES[@]}"; do
        t1_sub="${t1_entry%%|*}"; t1_path="${t1_entry#*|}"
        for pet_entry in "${NS_PET_ENTRIES[@]}"; do
            pet_sub="${pet_entry%%|*}"
            [[ "$pet_sub" != "$t1_sub" ]] && continue
            pet_path="${pet_entry#*|}"
            printf "%s\t%s\t%s\t%s\n" "$t1_sub" "$pet_path" "$t1_path" "0" >> "$OUTFILE"
            PAIR_COUNT=$((PAIR_COUNT + 1))
        done
    done

    # Warn about subjects that have only one modality
    for t1_entry in "${NS_T1_ENTRIES[@]}"; do
        t1_sub="${t1_entry%%|*}"
        found=false
        for pet_entry in "${NS_PET_ENTRIES[@]}"; do
            [[ "${pet_entry%%|*}" == "$t1_sub" ]] && found=true && break
        done
        $found || log_warn "No PET found for: $t1_sub — skipping"
    done
    for pet_entry in "${NS_PET_ENTRIES[@]}"; do
        pet_sub="${pet_entry%%|*}"
        found=false
        for t1_entry in "${NS_T1_ENTRIES[@]}"; do
            [[ "${t1_entry%%|*}" == "$pet_sub" ]] && found=true && break
        done
        $found || log_warn "No T1w found for: $pet_sub — skipping"
    done

    if [[ $PAIR_COUNT -eq 0 ]]; then
        log_error "No image pairs found. Check dataset structure and --tracer."
        exit 1
    fi

    log_success "Found $PAIR_COUNT image pair(s). Written to: $OUTFILE"
    exit 0

fi

# ============================================================
# BRANCH: LABEL-SESSION (pair by subject + session label, no dates)
# ============================================================

if [[ "$SES_FORMAT" == "label" ]]; then

    RAW_DIR="$DATASET_DIR/$DATASET/raw"
    log_info "Label-session mode — pairing by subject and session label"
    log_info "Searching in: $RAW_DIR"

    ERRORS=0
    LS_T1_ENTRIES=()
    LS_PET_ENTRIES=()

    while IFS= read -r f; do
        fname="$(basename "$f")"
        sub=""; ses_label=""
        [[ "$fname" =~ (sub-[^_]+) ]] && sub="${BASH_REMATCH[1]}"
        [[ "$fname" =~ (ses-[^_]+) ]] && ses_label="${BASH_REMATCH[1]}"
        if [[ -z "$sub" ]]; then
            log_error "Could not extract subject ID from: $f"; ERRORS=$((ERRORS+1)); continue
        fi
        if [[ -z "$ses_label" ]]; then
            log_error "No session label found in filename: $f"; ERRORS=$((ERRORS+1)); continue
        fi
        LS_T1_ENTRIES+=("${sub}|${ses_label}|${f}")
    done < <(find "$RAW_DIR" -type f -path "*/anat/*" \
        \( -name "*_T1w.nii.gz" -o -name "*_T1w.nii" \) | sort)

    while IFS= read -r f; do
        fname="$(basename "$f")"
        sub=""; ses_label=""
        [[ "$fname" =~ (sub-[^_]+) ]] && sub="${BASH_REMATCH[1]}"
        [[ "$fname" =~ (ses-[^_]+) ]] && ses_label="${BASH_REMATCH[1]}"
        if [[ -z "$sub" ]]; then
            log_error "Could not extract subject ID from: $f"; ERRORS=$((ERRORS+1)); continue
        fi
        if [[ -z "$ses_label" ]]; then
            log_error "No session label found in filename: $f"; ERRORS=$((ERRORS+1)); continue
        fi
        LS_PET_ENTRIES+=("${sub}|${ses_label}|${f}")
    done < <(find "$RAW_DIR" -type f -path "*/pet/*" \
        \( -name "*trc-${TRACER}*pet.nii.gz" -o -name "*trc-${TRACER}*pet.nii" \) | sort)

    log_info "Found ${#LS_T1_ENTRIES[@]} T1w file(s)"
    log_info "Found ${#LS_PET_ENTRIES[@]} PET file(s) for tracer: $TRACER"

    if [[ $ERRORS -gt 0 ]]; then
        log_error "$ERRORS error(s) found while parsing filenames. Aborting."
        exit 1
    fi

    > "$OUTFILE"
    printf "subject\tpet_path\tt1_path\tday_diff\n" >> "$OUTFILE"
    PAIR_COUNT=0

    for t1_entry in "${LS_T1_ENTRIES[@]}"; do
        t1_sub="${t1_entry%%|*}"; rest="${t1_entry#*|}"
        t1_ses="${rest%%|*}";     t1_path="${rest#*|}"

        for pet_entry in "${LS_PET_ENTRIES[@]}"; do
            pet_sub="${pet_entry%%|*}"; rest2="${pet_entry#*|}"
            pet_ses="${rest2%%|*}";     pet_path="${rest2#*|}"
            [[ "$pet_sub" != "$t1_sub" || "$pet_ses" != "$t1_ses" ]] && continue
            printf "%s\t%s\t%s\t%s\n" "$t1_sub" "$pet_path" "$t1_path" "NA" >> "$OUTFILE"
            PAIR_COUNT=$((PAIR_COUNT + 1))
        done
    done

    # Warn about T1w sessions with no matching PET session
    for t1_entry in "${LS_T1_ENTRIES[@]}"; do
        t1_sub="${t1_entry%%|*}"; rest="${t1_entry#*|}"; t1_ses="${rest%%|*}"
        found=false
        for pet_entry in "${LS_PET_ENTRIES[@]}"; do
            pet_sub="${pet_entry%%|*}"; rest2="${pet_entry#*|}"; pet_ses="${rest2%%|*}"
            [[ "$pet_sub" == "$t1_sub" && "$pet_ses" == "$t1_ses" ]] && found=true && break
        done
        $found || log_warn "No matching PET for: $t1_sub $t1_ses — skipping"
    done
    for pet_entry in "${LS_PET_ENTRIES[@]}"; do
        pet_sub="${pet_entry%%|*}"; rest2="${pet_entry#*|}"; pet_ses="${rest2%%|*}"
        found=false
        for t1_entry in "${LS_T1_ENTRIES[@]}"; do
            t1_sub="${t1_entry%%|*}"; rest="${t1_entry#*|}"; t1_ses="${rest%%|*}"
            [[ "$t1_sub" == "$pet_sub" && "$t1_ses" == "$pet_ses" ]] && found=true && break
        done
        $found || log_warn "No matching T1w for: $pet_sub $pet_ses — skipping"
    done

    if [[ $PAIR_COUNT -eq 0 ]]; then
        log_error "No image pairs found. Check dataset structure and --tracer."
        exit 1
    fi

    log_success "Found $PAIR_COUNT image pair(s). Written to: $OUTFILE"
    exit 0

fi

# ============================================================
# DATE UTILITIES
# ============================================================

if date --version >/dev/null 2>&1; then
    date_to_epoch() { date -d "${1:0:4}-${1:4:2}-${1:6:2}" +%s; }
else
    date_to_epoch() { date -j -f "%Y%m%d" "$1" +%s; }
fi

# ============================================================
# DISCOVER FILES — parse into plain arrays of "sub|date|path"
# ============================================================

RAW_DIR="$DATASET_DIR/$DATASET/raw"
log_info "Searching in: $RAW_DIR"

ERRORS=0
T1W_ENTRIES=()
PET_ENTRIES=()

while IFS= read -r f; do
    fname="$(basename "$f")"
    sub=""; date_str=""
    [[ "$fname" =~ (sub-[^_]+) ]]    && sub="${BASH_REMATCH[1]}"
    [[ "$fname" =~ ses-([0-9]{8}) ]] && date_str="${BASH_REMATCH[1]}"
    if [[ -z "$sub" ]]; then
        log_error "Could not extract subject ID from: $f"; ERRORS=$((ERRORS+1)); continue
    fi
    if [[ -z "$date_str" ]]; then
        log_error "No YYYYMMDD date found in session label: $f"; ERRORS=$((ERRORS+1)); continue
    fi
    T1W_ENTRIES+=("${sub}|${date_str}|${f}")
done < <(find "$RAW_DIR" -type f -path "*/anat/*" \( -name "*_T1w.nii.gz" -o -name "*_T1w.nii" \) | sort)

while IFS= read -r f; do
    fname="$(basename "$f")"
    sub=""; date_str=""
    [[ "$fname" =~ (sub-[^_]+) ]]    && sub="${BASH_REMATCH[1]}"
    [[ "$fname" =~ ses-([0-9]{8}) ]] && date_str="${BASH_REMATCH[1]}"
    if [[ -z "$sub" ]]; then
        log_error "Could not extract subject ID from: $f"; ERRORS=$((ERRORS+1)); continue
    fi
    if [[ -z "$date_str" ]]; then
        log_error "No YYYYMMDD date found in session label: $f"; ERRORS=$((ERRORS+1)); continue
    fi
    PET_ENTRIES+=("${sub}|${date_str}|${f}")
done < <(find "$RAW_DIR" -type f -path "*/pet/*" \( -name "*trc-${TRACER}*pet.nii.gz" -o -name "*trc-${TRACER}*pet.nii" \) | sort)

log_info "Found ${#T1W_ENTRIES[@]} T1w file(s)"
log_info "Found ${#PET_ENTRIES[@]} PET file(s) for tracer: $TRACER"

if [[ $ERRORS -gt 0 ]]; then
    log_error "$ERRORS error(s) found while parsing filenames. Aborting."
    exit 1
fi

# ============================================================
# FIND PAIRS WITHIN DATE RANGE
# ============================================================

SECS_PER_DAY=86400
TMPFILE="$(mktemp)"

for t1_entry in "${T1W_ENTRIES[@]}"; do
    t1_sub="${t1_entry%%|*}"; rest="${t1_entry#*|}"
    t1_date="${rest%%|*}"; t1_path="${rest#*|}"
    t1_epoch="$(date_to_epoch "$t1_date")"

    for pet_entry in "${PET_ENTRIES[@]}"; do
        pet_sub="${pet_entry%%|*}"
        [[ "$pet_sub" != "$t1_sub" ]] && continue
        rest="${pet_entry#*|}"; pet_date="${rest%%|*}"; pet_path="${rest#*|}"
        pet_epoch="$(date_to_epoch "$pet_date")"

        diff=$(( (pet_epoch - t1_epoch) / SECS_PER_DAY ))
        abs_diff="${diff#-}"

        if [[ "$abs_diff" -le "$MRI_PET_DAYDIFF" ]]; then
            printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
                "$t1_sub" "$t1_date" "$pet_date" "$abs_diff" "$t1_path" "$pet_path" \
                >> "$TMPFILE"
        fi
    done
done

# Warn about subjects with only one modality, or both but no pair in range
for t1_entry in "${T1W_ENTRIES[@]}"; do
    t1_sub="${t1_entry%%|*}"
    found=false
    for pet_entry in "${PET_ENTRIES[@]}"; do
        [[ "${pet_entry%%|*}" == "$t1_sub" ]] && found=true && break
    done
    if ! $found; then
        log_warn "No PET found for: $t1_sub — skipping"
    elif ! grep -q $'^'"${t1_sub}"$'\t' "$TMPFILE"; then
        log_warn "No pair within ${MRI_PET_DAYDIFF} days for: $t1_sub"
    fi
done
for pet_entry in "${PET_ENTRIES[@]}"; do
    pet_sub="${pet_entry%%|*}"
    found=false
    for t1_entry in "${T1W_ENTRIES[@]}"; do
        [[ "${t1_entry%%|*}" == "$pet_sub" ]] && found=true && break
    done
    $found || log_warn "No T1w found for: $pet_sub — skipping"
done

# ============================================================
# APPLY SCAN SELECTION AND WRITE OUTPUT
# ============================================================

SUBJECTS=()
while IFS= read -r sub; do
    SUBJECTS+=("$sub")
done < <(cut -f1 "$TMPFILE" | sort -u)

printf "subject\tpet_path\tt1_path\tday_diff\n" > "$OUTFILE"

PAIR_COUNT=0

for sub in "${SUBJECTS[@]}"; do
    if [[ "$SCAN_SELECTION" == "all" ]]; then
        while IFS= read -r row; do
            IFS=$'\t' read -r _ t1_date pet_date day_diff t1_path pet_path <<< "$row"
            printf "%s\t%s\t%s\t%s\n" "$sub" "$pet_path" "$t1_path" "$day_diff" >> "$OUTFILE"
            PAIR_COUNT=$((PAIR_COUNT + 1))
        done < <(grep $'^'"${sub}"$'\t' "$TMPFILE" | sort -k3,3 -k2,2)
    else
        if [[ "$SCAN_SELECTION" == "earliest" ]]; then
            selected="$(grep $'^'"${sub}"$'\t' "$TMPFILE" | sort -k3,3 -k2,2 | head -1)"
        else
            selected="$(grep $'^'"${sub}"$'\t' "$TMPFILE" | sort -k3,3 -k2,2 | tail -1)"
        fi
        IFS=$'\t' read -r _ t1_date pet_date day_diff t1_path pet_path <<< "$selected"
        printf "%s\t%s\t%s\t%s\n" "$sub" "$pet_path" "$t1_path" "$day_diff" >> "$OUTFILE"
        PAIR_COUNT=$((PAIR_COUNT + 1))
    fi
done

rm -f "$TMPFILE"

if [[ $PAIR_COUNT -eq 0 ]]; then
    log_error "No image pairs found. Check --mri_pet_daydiff and --tracer."
    exit 1
fi

log_success "Found $PAIR_COUNT image pair(s). Written to: $OUTFILE"
exit 0
