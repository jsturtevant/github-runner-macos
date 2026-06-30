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

set -Eeuo pipefail

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
RUNNER_LABEL="tart-runner-${INDEX}"
# Per-runner persistent host cache dir (see tart-common.sh for the concurrency
# rationale). Shared into the guest read-write over virtio-fs each job.
HOST_CACHE_DIR="${TART_CACHE_DIR}/runner-${INDEX}"

# Per-job context banner. Wired into each guest via ACTIONS_RUNNER_HOOK_JOB_STARTED
# so every job logs which repo / PR / run / actor it is serving. The runner
# streams this to run.sh's stdout, which flows back over SSH into this host's
# launchd stdout log — so with several PRs in flight you can tell exactly which
# one each runner is working on. Encoded to base64 to inject cleanly over SSH.
GUEST_HOOK_PATH="${TART_GUEST_RUNNER_DIR}/job-started-hook.sh"
# Written to a temp file via a plain heredoc redirection (not command
# substitution) so it parses under macOS /bin/bash 3.2, then base64-encoded for
# clean injection over SSH.
_hook_tmp="$(mktemp)"
cat > "$_hook_tmp" <<'HOOK'
#!/usr/bin/env bash
{
  echo "==================== JOB CONTEXT ===================="
  echo "repo:     ${GITHUB_REPOSITORY:-?}"
  echo "workflow: ${GITHUB_WORKFLOW:-?}  |  job: ${GITHUB_JOB:-?}"
  echo "event:    ${GITHUB_EVENT_NAME:-?}"
  case "${GITHUB_REF:-}" in
    refs/pull/*) n="${GITHUB_REF#refs/pull/}"; n="${n%%/*}";
      echo "PR:       #${n}  ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/pull/${n}";;
  esac
  [ -n "${GITHUB_HEAD_REF:-}" ] && echo "branch:   ${GITHUB_HEAD_REF} -> ${GITHUB_BASE_REF:-?}"
  echo "actor:    ${GITHUB_ACTOR:-?} (trigger: ${GITHUB_TRIGGERING_ACTOR:-?})"
  echo "sha:      ${GITHUB_SHA:-?}"
  echo "run:      ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-?} (attempt ${GITHUB_RUN_ATTEMPT:-?})"
  if command -v jq >/dev/null 2>&1 && [ -f "${GITHUB_EVENT_PATH:-/nonexistent}" ]; then
    t="$(jq -r '.pull_request.title // .head_commit.message // empty' "$GITHUB_EVENT_PATH" 2>/dev/null | head -n1)"
    [ -n "$t" ] && echo "title:    $t"
  fi
  echo "===================================================="
} 2>/dev/null
exit 0
HOOK
JOB_STARTED_HOOK_B64="$(base64 < "$_hook_tmp" | tr -d '\n')"
rm -f "$_hook_tmp"

enable_debug_trace "$RUNNER_LABEL"
install_err_diagnostics "runner ${INDEX}"

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

    mkdir -p "$TART_DEBUG_LOG_DIR"
    local iter_ts vm_runtime_log run_failed fail_reason
    iter_ts="$(date '+%Y%m%d-%H%M%S')"
    vm_runtime_log="${TART_DEBUG_LOG_DIR}/${RUNNER_LABEL}-vm-${iter_ts}.log"
    run_failed=0
    fail_reason=""

    log "[runner ${INDEX}] Cloning ${TART_GOLDEN_IMAGE} -> ${CLONE_NAME}"
    tart clone "$TART_GOLDEN_IMAGE" "$CLONE_NAME"

    # Ensure the per-runner host cache dir exists before sharing it in.
    # Non-fatal: caching is an optimization, never a reason to fail a job.
    mkdir -p "${HOST_CACHE_DIR}/sccache" 2>/dev/null || true

    log "[runner ${INDEX}] Booting ephemeral guest with nested virtualization"
    # Only share the cache into the guest if the host dir actually exists, so a
    # cache problem can never block the VM from booting. (Two branches rather
    # than an array, to stay compatible with macOS /bin/bash 3.2 + set -u.)
    if [ -d "$HOST_CACHE_DIR" ]; then
        tart run --nested --no-graphics --dir="${TART_CACHE_TAG}:${HOST_CACHE_DIR}" "$CLONE_NAME" >> "$vm_runtime_log" 2>&1 &
    else
        tart run --nested --no-graphics "$CLONE_NAME" >> "$vm_runtime_log" 2>&1 &
    fi
    local tart_pid=$!
    log "[runner ${INDEX}] Tart runtime log: ${vm_runtime_log}"

    local ip=""
    cleanup_job() {
        if [ "$run_failed" -eq 1 ]; then
            capture_host_vm_diagnostics "$RUNNER_LABEL" "$CLONE_NAME"
            err "[runner ${INDEX}] Failure reason: ${fail_reason}"
            if [ -f "$vm_runtime_log" ]; then
                err "[runner ${INDEX}] Tart runtime log size: $(wc -c < "$vm_runtime_log" | tr -d ' ') bytes"
                err "[runner ${INDEX}] Last Tart runtime output:"
                tail -n 40 "$vm_runtime_log" >&2 || true
            else
                err "[runner ${INDEX}] Tart runtime log missing: ${vm_runtime_log}"
            fi
            err "[runner ${INDEX}] Iteration failed; Tart runtime log: ${vm_runtime_log}"
        fi

        [ -n "$ip" ] && stop_guest "$CLONE_NAME" "$ip"
        wait "$tart_pid" 2>/dev/null || true

        if [ "$run_failed" -eq 1 ] && [ "$TART_KEEP_FAILED_VM" = "1" ]; then
            err "[runner ${INDEX}] Keeping failed VM clone for inspection: ${CLONE_NAME}"
        else
            tart delete "$CLONE_NAME" 2>/dev/null || true
        fi
    }
    trap cleanup_job RETURN

    ip="$(tart_guest_ip "$CLONE_NAME")" || {
        run_failed=1
        fail_reason="guest did not obtain IP"
        err "[runner ${INDEX}] No IP"
        return 1
    }
    log "[runner ${INDEX}] Guest IP: $ip"

    wait_for_ssh "$ip" || {
        run_failed=1
        fail_reason="guest SSH did not become ready"
        err "[runner ${INDEX}] SSH never came up"
        return 1
    }

    log "[runner ${INDEX}] Minting registration token"
    local token
    token="$(mint_registration_token "$APP_ID" "$PRIVATE_KEY" "$REPO" "$ORG")" \
        || {
            run_failed=1
            fail_reason="token minting failed"
            err "[runner ${INDEX}] Token minting failed"
            return 1
        }

    local runner_name
    runner_name="${NAME_PREFIX}-${INDEX}-$(date +%s)"
    log "[runner ${INDEX}] Configuring + running ephemeral runner: $runner_name"

    # Best-effort: mount the shared host cache over virtio-fs and point sccache
    # at it. This is purely an optimization, so a mount failure must never abort
    # the job — hence the `|| echo ... (non-fatal)` guard. SCCACHE_DIR is set
    # unconditionally; it's harmless until the workflow enables sccache, after
    # which the cache is automatically persistent and network-free.
    #
    # Apple shares every --dir under the single automount tag, with our named
    # share (TART_CACHE_TAG) as a sub-directory, so we mount that tag and use the
    # <mount>/<TART_CACHE_TAG> sub-dir. virtio-fs maps host ownership through, so
    # no chown is needed (and chowning the automount root is not permitted).
    local cache_setup cache_subdir
    cache_subdir="${TART_CACHE_GUEST_MOUNT}/${TART_CACHE_TAG}"
    cache_setup="sudo mkdir -p '${TART_CACHE_GUEST_MOUNT}' && (mountpoint -q '${TART_CACHE_GUEST_MOUNT}' || sudo mount -t virtiofs '${TART_VIRTIOFS_AUTOMOUNT_TAG}' '${TART_CACHE_GUEST_MOUNT}')"

    # Install the per-job context hook (base64 to avoid SSH quoting issues).
    local hook_install
    hook_install="echo '${JOB_STARTED_HOOK_B64}' | base64 -d | sudo tee '${GUEST_HOOK_PATH}' >/dev/null && sudo chmod +x '${GUEST_HOOK_PATH}'"

    # Configure as an ephemeral runner and execute a single job. run.sh blocks
    # until the job finishes, after which the ephemeral runner deregisters.
    if ! ssh_guest "$ip" \
        "{ ${cache_setup}; } || echo '[cache] virtio-fs mount failed (non-fatal)'; \
         { ${hook_install}; } || echo '[hook] install failed (non-fatal)'; \
         export SCCACHE_DIR='${cache_subdir}/sccache' SCCACHE_CACHE_SIZE='${TART_CACHE_MAX_SIZE}' ACTIONS_RUNNER_HOOK_JOB_STARTED='${GUEST_HOOK_PATH}'; \
         cd '${TART_GUEST_RUNNER_DIR}' && \
         ./config.sh --unattended --ephemeral --replace \
            --url '${RUNNER_URL}' --token '${token}' \
            --labels '${TART_RUNNER_LABELS}' --name '${runner_name}' && \
         ./run.sh"; then
        run_failed=1
        fail_reason="remote runner command exited non-zero"
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
