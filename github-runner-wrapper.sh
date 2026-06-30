#!/bin/bash
#
# GitHub Actions Runner Wrapper
#
# Purpose: Restart ./run.sh in an infinite loop with backoff, and handle
# graceful shutdown on SIGTERM. This is a crash-recovery wrapper only.
# Post-job cleanup is handled via ACTIONS_RUNNER_HOOK_JOB_COMPLETED in .env.
#
# Usage: github-runner-wrapper.sh <runner-dir>
#
# Example:
#   github-runner-wrapper.sh "$HOME/github-runner-1"
#   github-runner-wrapper.sh "$HOME/github-runner-2"
#
# Install as a launchd service via the corresponding .plist file.

set -Eeuo pipefail

# Config
RUNNER_DIR="${1:?Error: runner directory required (e.g., \$HOME/github-runner-1)}"
RESTART_DELAY=5  # seconds to wait between restart attempts
LOG_DIR="${HOME}/.github-runner-logs"
LOG_FILE="${LOG_DIR}/runner-$(basename "$RUNNER_DIR").log"
PID_FILE="${LOG_DIR}/runner-$(basename "$RUNNER_DIR").pid"
FAILURE_STATE_FILE="${LOG_DIR}/runner-$(basename "$RUNNER_DIR").failure-epochs"
TRACE_FILE="${LOG_DIR}/runner-$(basename "$RUNNER_DIR").trace.log"
DEBUG_MODE="${GH_WRAPPER_DEBUG:-0}"

# Circuit-breaker controls (override via environment in launchd plist if needed).
FAILURE_WINDOW_SEC="${GH_WRAPPER_FAILURE_WINDOW_SEC:-600}"
FAILURE_THRESHOLD="${GH_WRAPPER_FAILURE_THRESHOLD:-5}"
FAILURE_COOLDOWN_SEC="${GH_WRAPPER_FAILURE_COOLDOWN_SEC:-180}"

# Setup logging
mkdir -p "$LOG_DIR"

# Write PID so launchd can track it
echo $$ > "$PID_FILE"

# Logging function
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "$LOG_FILE"
}

enable_debug_trace() {
    [ "$DEBUG_MODE" = "1" ] || return 0

    # Route xtrace output to a dedicated log file, keeping runner output clean.
    # shellcheck disable=SC2034
    PS4='+ [${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]-main}] '
    exec 9>>"$TRACE_FILE"
    export BASH_XTRACEFD=9
    set -x
    log "INFO" "Debug tracing enabled: $TRACE_FILE"
}

handle_err() {
    local exit_code="$1"
    local line_no="$2"
    local cmd="$3"
    log "ERROR" "Command failed (exit=${exit_code}) at line ${line_no}: ${cmd}"
}

# Cleanup on exit
cleanup() {
    local exit_code=$?
    log "INFO" "Runner wrapper shutting down (exit code: $exit_code)"
    rm -f "$PID_FILE"
    exit $exit_code
}

trap cleanup EXIT
trap 'handle_err $? ${LINENO} "${BASH_COMMAND}"' ERR

clear_failure_history() {
    rm -f "$FAILURE_STATE_FILE" 2>/dev/null || true
}

record_failure_and_maybe_cooldown() {
    local now cutoff failures

    now="$(date +%s)"
    cutoff=$(( now - FAILURE_WINDOW_SEC ))

    printf '%s\n' "$now" >> "$FAILURE_STATE_FILE"
    awk -v cutoff="$cutoff" '$1 >= cutoff' "$FAILURE_STATE_FILE" > "${FAILURE_STATE_FILE}.tmp" || true
    mv -f "${FAILURE_STATE_FILE}.tmp" "$FAILURE_STATE_FILE"

    failures="$(wc -l < "$FAILURE_STATE_FILE" | tr -d ' ')"
    if [ "$failures" -ge "$FAILURE_THRESHOLD" ]; then
        log "WARN" "Circuit breaker: ${failures} failures in ${FAILURE_WINDOW_SEC}s; cooling down ${FAILURE_COOLDOWN_SEC}s"
        sleep "$FAILURE_COOLDOWN_SEC"
        clear_failure_history
    fi
}

# Track the current runner child so the SIGTERM handler can stop it cleanly.
run_pid=""

# Handle SIGTERM (macOS shutdown / launchctl unload): forward the signal to the
# running runner so it can deregister and finish its current step, then exit.
handle_sigterm() {
    log "WARN" "Received SIGTERM, stopping runner gracefully..."
    if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then
        kill -TERM "$run_pid" 2>/dev/null || true
        wait "$run_pid" 2>/dev/null || true
    fi
    exit 0
}

trap handle_sigterm SIGTERM

log "INFO" "Starting GitHub Actions runner wrapper"
log "INFO" "Runner directory: $RUNNER_DIR"
log "INFO" "Restart delay: ${RESTART_DELAY}s"
log "INFO" "Failure window/throttle: threshold=${FAILURE_THRESHOLD}, window=${FAILURE_WINDOW_SEC}s, cooldown=${FAILURE_COOLDOWN_SEC}s"
log "INFO" "Note: Post-job cleanup is handled via ACTIONS_RUNNER_HOOK_JOB_COMPLETED in .env"
enable_debug_trace

# Verify runner directory exists
if [ ! -d "$RUNNER_DIR" ]; then
    log "ERROR" "Runner directory not found: $RUNNER_DIR"
    exit 1
fi

if [ ! -f "$RUNNER_DIR/run.sh" ]; then
    log "ERROR" "run.sh not found in $RUNNER_DIR"
    exit 1
fi

# Main loop
restart_count=0
while true; do
    restart_count=$((restart_count + 1))
    log "INFO" "Starting runner (attempt #$restart_count)"

    cd "$RUNNER_DIR"

    # Prevent system sleep while the runner is active. Use a process
    # substitution for the tee so that $! is caffeinate's PID (and therefore
    # reflects ./run.sh's real exit status). A plain pipe would make $! point at
    # tee, masking the runner's exit code.
    caffeinate -dimsu ./run.sh > >(tee -a "$LOG_FILE") 2>&1 &
    run_pid=$!

    # Wait for the runner to exit. Guard with set +e so a non-zero exit (or a
    # signal-interrupted wait) doesn't abort the wrapper — we want to restart.
    set +e
    wait "$run_pid"
    run_exit_code=$?
    set -e
    run_pid=""

    log "WARN" "Runner exited with code $run_exit_code"

    if [ "$run_exit_code" -eq 0 ]; then
        clear_failure_history
    else
        record_failure_and_maybe_cooldown
    fi

    # Interruptible back-off: background the sleep and wait on it so a SIGTERM
    # breaks us out immediately via the trap instead of blocking the delay.
    log "INFO" "Restarting runner in ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY" &
    wait "$!" 2>/dev/null || true
done
