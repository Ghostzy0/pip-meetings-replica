#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -gt 1 ]; then echo 'Usage: test-native.sh [baseline|pip|baseline-enhanced|pip-enhanced|upstream]' >&2; exit 2; fi
if [ "$#" -gt 0 ]; then
    EDITION="$1"
elif [ -f "$APP_ROOT/distribution.json" ]; then
    EDITION="$(python3 "$APP_ROOT/scripts/release_integrity.py" distribution-default "$APP_ROOT")"
else
    EDITION='pip'
fi
python3 "$APP_ROOT/scripts/release_integrity.py" distribution-check "$APP_ROOT" "$EDITION"
unset PIP_EDITION PIP_NEUTRAL MEETINGS_ENHANCEMENTS MEETINGS_REPLICA
case "$EDITION" in
    pip|pip-enhanced|baseline|baseline-enhanced) export PIP_EDITION=1; TEST_FILTER='Pip|PipelineJobTests|PipelineSnapshotTests|TranscriptNoteTests|AudioPersistencePolicyTests|WavHeaderRepairTests|RecordingSidecarTests|DualSourceRecorderCrashRecoveryTests|LiveCaptureSessionTests|WhisperKitModelFolderArgumentTests' ;;
    upstream) TEST_FILTER='PipelineQueueTests|PipelineSnapshotTests|PipelineJobTests|TranscriptNoteTests|DualSourceRecorderCrashRecoveryTests|StagedRecoveryFolderTests|AudioPersistencePolicyTests|TerminalJobStoreTests|LocalVQESelftestTests' ;;
    *) echo 'Usage: test-native.sh baseline|pip|baseline-enhanced|pip-enhanced|upstream' >&2; exit 2 ;;
esac
case "$EDITION" in baseline*) export PIP_NEUTRAL=1 ;; esac
if [ "$EDITION" = baseline ]; then export MEETINGS_REPLICA=1; fi
case "$EDITION" in *-enhanced) export MEETINGS_ENHANCEMENTS=1 ;; esac
# All tests and their shared bridge stay inside a fresh synthetic data root.
export PIP_TEST_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meetings-native-tests.XXXXXX")"
trap 'rm -rf "$PIP_TEST_DATA_DIR"' EXIT
# Upstream release tests reference DEBUG-only seams. Use its documented debug route.
CI=1 swift test --package-path "$APP_ROOT/native/app/MeetingTranscriber" \
    --scratch-path "$APP_ROOT/native/.test-$EDITION" -c debug --jobs 2 --filter "$TEST_FILTER"
