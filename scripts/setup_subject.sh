#!/bin/bash
# setup_subject.sh
# Creates the per-subject session directory structure inside the working directory.
# Called by charon.sh before any processing jobs are submitted for a subject.
#
# Structure created:
#   $WORKDIR/<subject>/<session>/fastsurfer/
#   $WORKDIR/<subject>/<session>/petprep/
#   $WORKDIR/<subject>/<session>/petprep/work/
#   $WORKDIR/<subject>/<session>/logs/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils/logging.sh"

while [[ $# -gt 0 ]]; do
    case $1 in
        --subject) SUBJECT=$2; shift 2;;
        --session) SESSION=$2; shift 2;;
        --config)  CONFIG=$2;  shift 2;;
        *) shift;;
    esac
done

_cfg() { grep "^${1}:" "$CONFIG" | sed 's/^[^:]*:[[:space:]]*//' | xargs; }

WORKDIR="$(_cfg workdir)"
SESSION_DIR="$WORKDIR/$SUBJECT${SESSION:+/$SESSION}"

mkdir -p \
    "$SESSION_DIR/fastsurfer" \
    "$SESSION_DIR/petprep" \
    "$SESSION_DIR/petprep/work" \
    "$SESSION_DIR/logs" \
    || { log_error "Failed to create session directories: $SESSION_DIR"; exit 1; }

log_info "Session directories created: $SESSION_DIR"
