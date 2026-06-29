#!/bin/bash
#
# tart-runner-loop.sh — Run an endless ephemeral GitHub Actions runner loop.
#
# Each iteration spins up a throwaway clone of the golden image, registers it as
# a single-use (ephemeral) runner, lets it execute exactly one job, then
# destroys the VM. This gives every job a pristine, isolated environment with
# nested KVM available — no state leaks between jobs.
#
# One instance of this script == one concurrent runner. The bootstrap script
# launches N of these (typically via launchd) for N-way concurrency.
#
# Loop per job:
#   1. Clone golden image -> unique ephemeral VM.
#   2. Boot with --nested, wait for IP + SSH.
#   3. Mint a fresh registration token from the GitHub App.
#   4. config.sh --ephemeral, then run.sh (blocks until one job completes).
#   5. Stop + delete the clone. Repeat.
#
# Configuration (env or flags):
#   GH_APP_ID / --app-id            GitHub App ID
#   GH_APP_PRIVATE_KEY / --private-key   Path to the App private key (PEM)
#   GH_RUNNER_REPO / --repo         owner/repo   (mutually exclusive with org)
#   GH_RUNNER_ORG  / --org          org
#   --golden-image                  Golden image name (default from common)
#   --index                         Runner index (used in the runner name)
#   --name-prefix                   Runner name prefix (default: tart-ubuntu)
#   --labels                        Comma-separated labels (default from common)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tart-common.sh
source "$SCRIPT_DIR/tart-common.sh"
# shellcheck source=tart-github-app-token.sh
source "$SCRIPT_DIR/tart-github-app-token.sh"

APP_ID="${GH_APP_ID:-}"
PRIVATE_KEY="${GH_APP_PRIVATE_KEY:-}"
REPO="${GH_RUNNER_REPO:-}"
ORG="${GH_RUNNER_ORG:-}"
INDEX="1"
NAME_PREFIX="tart-ubuntu"

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app-id) APP_ID="${2:-}"; shift 2 ;;
        --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
        --repo) REPO="${2:-}"; shift 2 ;;
        --org) ORG="${2:-}"; shift 2 ;;
        --golden-image) TART_GOLDEN_IMAGE="${2:-}"; shift 2 ;;
        --index) INDEX="${2:-}"; shift 2 ;;
        --name-prefix) NAME_PREFIX="${2:-}"; shift 2 ;;
        --labels) TART_RUNNER_LABELS="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

require_cmd tart
require_cmd ssh
require_cmd curl
require_cmd openssl
require_cmd jq

[ -n "$APP_ID" ] || die "--app-id (or GH_APP_ID) is required."
[ -n "$PRIVATE_KEY" ] || die "--private-key (or GH_APP_PRIVATE_KEY) is required."
[ -f "$PRIVATE_KEY" ] || die "Private key file not found: $PRIVATE_KEY"

if { [ -n "$REPO" ] && [ -n "$ORG" ]; } || { [ -z "$REPO" ] && [ -z "$ORG" ]; }; then
    die "Provide exactly one of --repo or --org."
fi

# The GitHub URL a runner registers against differs by scope.
if [ -n "$REPO" ]; then
    RUNNER_URL="https://github.com/${REPO}"
else
    RUNNER_URL="https://github.com/${ORG}"
fi

# Stable per-index clone name. Reused each iteration (deleted at end of loop),
# so leftover clones from a crash are reclaimed on the next pass.
CLONE_NAME="${TART_GOLDEN_IMAGE}-runner-${INDEX}"
FAILURE_STATE_FILE="${TART_CONFIG_DIR}/runner-${INDEX}.failure-epochs"

# Clear failure history after a successful job so only fresh incidents count.
clear_failure_history() {
    rm -f "$FAILURE_STATE_FILE" 2>/dev/null || true
}

# Track recent failures and apply a longer cooldown if they are frequent.
record_failure_and_maybe_cooldown() {
    mkdir -p "$TART_CONFIG_DIR"

    local now cutoff failures
    now="$(date +%s)"
    cutoff=$(( now - TART_FAILURE_WINDOW_SEC ))

    printf '%s\n' "$now" >> "$FAILURE_STATE_FILE"
    awk -v cutoff="$cutoff" '$1 >= cutoff' "$FAILURE_STATE_FILE" > "${FAILURE_STATE_FILE}.tmp" || true
    mv -f "${FAILURE_STATE_FILE}.tmp" "$FAILURE_STATE_FILE"

    failures="$(wc -l < "$FAILURE_STATE_FILE" | tr -d ' ')"
    if [ "$failures" -ge "$TART_FAILURE_THRESHOLD" ]; then
        err "[runner ${INDEX}] ${failures} failures in ${TART_FAILURE_WINDOW_SEC}s; cooling down for ${TART_FAILURE_COOLDOWN_SEC}s"
        sleep "$TART_FAILURE_COOLDOWN_SEC"
        clear_failure_history
    fi
}

# Remove a clone if it exists (handles leftovers from a previous crash).
delete_clone_if_present() {
    if tart list 2>/dev/null | grep -qE "[[:space:]]${CLONE_NAME}[[:space:]]"; then
        stop_guest "$CLONE_NAME" ""
        tart delete "$CLONE_NAME" 2>/dev/null || true
    fi
}

# Run a single ephemeral job, returning when the VM has been cleaned up.
run_one_job() {
    delete_clone_if_present

    log "[runner ${INDEX}] Cloning ${TART_GOLDEN_IMAGE} -> ${CLONE_NAME}"
    tart clone "$TART_GOLDEN_IMAGE" "$CLONE_NAME"

    log "[runner ${INDEX}] Booting ephemeral guest with nested virtualization"
    tart run --nested --no-graphics "$CLONE_NAME" &
    local tart_pid=$!

    local ip=""
    cleanup_job() {
        [ -n "$ip" ] && stop_guest "$CLONE_NAME" "$ip"
        wait "$tart_pid" 2>/dev/null || true
        tart delete "$CLONE_NAME" 2>/dev/null || true
    }
    trap cleanup_job RETURN

    ip="$(tart_guest_ip "$CLONE_NAME")" || { err "[runner ${INDEX}] No IP"; return 1; }
    log "[runner ${INDEX}] Guest IP: $ip"

    wait_for_ssh "$ip" || { err "[runner ${INDEX}] SSH never came up"; return 1; }

    log "[runner ${INDEX}] Minting registration token"
    local token
    token="$(mint_registration_token "$APP_ID" "$PRIVATE_KEY" "$REPO" "$ORG")" \
        || { err "[runner ${INDEX}] Token minting failed"; return 1; }

    local runner_name
    runner_name="${NAME_PREFIX}-${INDEX}-$(date +%s)"
    log "[runner ${INDEX}] Configuring + running ephemeral runner: $runner_name"

    # Configure as an ephemeral runner and execute a single job. run.sh blocks
    # until the job finishes, after which the ephemeral runner deregisters.
    if ! ssh_guest "$ip" \
        "cd '${TART_GUEST_RUNNER_DIR}' && \
         ./config.sh --unattended --ephemeral --replace \
            --url '${RUNNER_URL}' --token '${token}' \
            --labels '${TART_RUNNER_LABELS}' --name '${runner_name}' && \
         ./run.sh"; then
        err "[runner ${INDEX}] Runner exited non-zero (job may have failed)"
        return 1
    fi

    log "[runner ${INDEX}] Job finished; tearing down ${CLONE_NAME}"
    # cleanup_job runs via the RETURN trap.
}

log "[runner ${INDEX}] Starting ephemeral loop for ${RUNNER_URL}"
log "[runner ${INDEX}] Golden image: ${TART_GOLDEN_IMAGE}, labels: ${TART_RUNNER_LABELS}"

# Endless loop. launchd (KeepAlive) restarts us if the process itself dies; the
# short sleep on failure avoids hammering GitHub/Tart in a tight crash loop.
while true; do
    if run_one_job; then
        clear_failure_history
    else
        err "[runner ${INDEX}] Iteration failed; backing off before retry"
        record_failure_and_maybe_cooldown
        sleep 10
    fi
done
