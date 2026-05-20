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

set -euo pipefail

# Config
RUNNER_DIR="${1:?Error: runner directory required (e.g., \$HOME/github-runner-1)}"
RESTART_DELAY=5  # seconds to wait between restart attempts
LOG_DIR="${HOME}/.github-runner-logs"
LOG_FILE="${LOG_DIR}/runner-$(basename "$RUNNER_DIR").log"
PID_FILE="${LOG_DIR}/runner-$(basename "$RUNNER_DIR").pid"

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

# Cleanup on exit
cleanup() {
    local exit_code=$?
    log "INFO" "Runner wrapper shutting down (exit code: $exit_code)"
    rm -f "$PID_FILE"
    exit $exit_code
}

trap cleanup EXIT

# Handle SIGTERM (macOS shutdown) — try to stop the runner gracefully
handle_sigterm() {
    log "WARN" "Received SIGTERM, stopping gracefully..."
    # If ./run.sh is running, it should handle SIGTERM itself
    # We'll give it time to clean up, then exit
    sleep 2
    exit 0
}

trap handle_sigterm SIGTERM

log "INFO" "Starting GitHub Actions runner wrapper"
log "INFO" "Runner directory: $RUNNER_DIR"
log "INFO" "Restart delay: ${RESTART_DELAY}s"
log "INFO" "Note: Post-job cleanup is handled via ACTIONS_RUNNER_HOOK_JOB_COMPLETED in .env"

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

    # Change to runner directory and execute run.sh
    # Capture exit code but don't exit on failure — we want to restart
    cd "$RUNNER_DIR"

    # Prevent system sleep while runner is active
    caffeinate -dimsu ./run.sh 2>&1 | tee -a "$LOG_FILE" &
    run_pid=$!

    # Wait for the runner to exit
    set +e
    wait $run_pid
    run_exit_code=$?
    set -e

    log "WARN" "Runner exited with code $run_exit_code"

    # Wait before restarting (but be interruptible)
    log "INFO" "Restarting runner in ${RESTART_DELAY}s (or killed via signal)..."
    sleep $RESTART_DELAY
done
