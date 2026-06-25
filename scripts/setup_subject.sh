#!/bin/bash
# setup_subject.sh
# Creates the per-subject directory structure inside the working directory.
# Called by charon.sh before any processing jobs are submitted for a subject.
#
# Structure created:
#   $FASTSURFER_DIR/<subject>/<t1_session>/logs/
#   $TRACER_DIR/<subject>/<session>/petprep/
#   $TRACER_DIR/<subject>/<session>/petprep/work/
#   $TRACER_DIR/<subject>/<session>/logs/
#   $TRACER_DIR/<subject>/<session>/fastsurfer -> symlink into $FASTSURFER_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"

while [[ $# -gt 0 ]]; do
    case $1 in
        --subject)    SUBJECT=$2;    shift 2;;
        --session)    SESSION=$2;    shift 2;;
        --t1_session) T1_SESSION=$2; shift 2;;
        --config)     CONFIG=$2;     shift 2;;
        *) shift;;
    esac
done

_cfg() { grep "^${1}:" "$CONFIG" | sed 's/^[^:]*:[[:space:]]*//' | xargs; }

FASTSURFER_DIR="$(_cfg fastsurfer_dir)"
TRACER_DIR="$(_cfg tracer_dir)"

FS_OUTDIR="$FASTSURFER_DIR/$SUBJECT${T1_SESSION:+/$T1_SESSION}"
CHARON_SESSION_DIR="$TRACER_DIR/$SUBJECT${SESSION:+/$SESSION}"

mkdir -p \
    "$FS_OUTDIR/logs" \
    "$CHARON_SESSION_DIR/petprep" \
    "$CHARON_SESSION_DIR/petprep/work" \
    "$CHARON_SESSION_DIR/logs" \
    || { log_error "Failed to create directories for $SUBJECT"; exit 1; }

# Symlink the shared, T1-session-keyed FastSurfer output into this tracer run's
# subject/session directory, so downstream tools see fastsurfer/<subject>/... exactly
# as if it lived here directly.
REL_TARGET="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$FS_OUTDIR" "$CHARON_SESSION_DIR")"
ln -sfn "$REL_TARGET" "$CHARON_SESSION_DIR/fastsurfer" \
    || { log_error "Failed to create fastsurfer symlink in: $CHARON_SESSION_DIR"; exit 1; }

log_info "FastSurfer directory created: $FS_OUTDIR"
log_info "Session directories created: $CHARON_SESSION_DIR"
