#!/bin/bash
#
# tart-common.sh — Shared helpers for the Tart-based ephemeral GitHub Actions
# runners (Ubuntu guests with nested KVM on Apple Silicon).
#
# This file is meant to be *sourced*, not executed directly. It defines the
# default configuration, logging helpers, and SSH/Tart utility functions that
# the bake, loop, and bootstrap scripts share. Keeping these in one place
# avoids duplication and keeps the individual scripts focused.
#
# All defaults can be overridden via environment variables so the scripts can
# be reused across machines and repositories without editing source.

# Guard against direct execution — there is nothing to run here.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "tart-common.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Configuration (override via environment)
# -----------------------------------------------------------------------------

# Directory holding host-side state: the dedicated SSH keypair used to talk to
# the guests. Created on demand by the bake script.
TART_CONFIG_DIR="${TART_RUNNER_CONFIG_DIR:-$HOME/.config/github-runner-tart}"

# Dedicated SSH keypair for reaching the Tart guests. Generated once during the
# bake and reused afterwards. Never reuse a personal key here.
TART_SSH_KEY="${TART_SSH_KEY:-$TART_CONFIG_DIR/id_ed25519}"

# Default login on the cirruslabs Ubuntu image. These well-known credentials are
# only used *once* during the bake to inject our SSH key; password auth is then
# disabled inside the golden image. See the cirruslabs/tart documentation.
TART_GUEST_USER="${TART_GUEST_USER:-admin}"
TART_GUEST_PASSWORD="${TART_GUEST_PASSWORD:-admin}"

# Base OCI image and the name of the golden image we derive from it.
TART_BASE_IMAGE="${TART_BASE_IMAGE:-ghcr.io/cirruslabs/ubuntu:latest}"
TART_GOLDEN_IMAGE="${TART_GOLDEN_IMAGE:-gha-ubuntu-kvm}"

# Guest resources. Defaults are conservative; raise for heavier workloads.
# NOTE: CPUs/RAM default to 2/4096 while we investigate nested-virt VM crashes
# (see INCIDENT-tart-vm-crash.md). These are current operating values under
# investigation, not a confirmed fix — revisit once findings are verified.
TART_GUEST_CPUS="${TART_GUEST_CPUS:-2}"
TART_GUEST_MEMORY_MB="${TART_GUEST_MEMORY_MB:-4096}"
TART_GUEST_DISK_GB="${TART_GUEST_DISK_GB:-50}"

# Where the GitHub Actions runner is installed inside the guest.
TART_GUEST_RUNNER_DIR="${TART_GUEST_RUNNER_DIR:-/opt/actions-runner}"

# Persistent host-side build cache, shared into each ephemeral guest over
# virtio-fs. The throwaway clones are destroyed after every job, but this
# directory lives on the host, so compiler/dependency caches (e.g. sccache)
# stay warm across jobs with zero network round-trips.
#
# CONCURRENCY: each runner index gets its OWN sub-directory (runner-<N>), so
# running multiple concurrent runners never shares one cache dir between two
# writers. This matters because sccache/cargo are not safe when several
# independent writers hit the same directory over virtio-fs at once — you'd risk
# corrupt cache entries. Per-runner dirs trade a little disk + cross-runner hit
# rate for correctness. Set TART_CACHE_DIR to relocate the cache root.
TART_CACHE_DIR="${TART_CACHE_DIR:-$HOME/.cache/github-runner-tart}"
TART_CACHE_TAG="${TART_CACHE_TAG:-ci-cache}"
TART_CACHE_GUEST_MOUNT="${TART_CACHE_GUEST_MOUNT:-/var/cache/ci}"
TART_CACHE_MAX_SIZE="${TART_CACHE_MAX_SIZE:-20G}"
# Apple's Virtualization framework exposes ALL `tart run --dir` shares under one
# fixed virtio-fs "automount" tag; each named share (TART_CACHE_TAG) then appears
# as a sub-directory beneath the mountpoint. So the guest mounts THIS tag, and
# the actual cache lives at <mount>/<TART_CACHE_TAG>/.
TART_VIRTIOFS_AUTOMOUNT_TAG="${TART_VIRTIOFS_AUTOMOUNT_TAG:-com.apple.virtio-fs.automount}"

# Default runner labels. self-hosted is added automatically by GitHub and
# cannot be suppressed. Deliberately no "tart" or "ephemeral" labels.
TART_RUNNER_LABELS="${TART_RUNNER_LABELS:-arm64,kvm,linux,ubuntu-24.04}"

# How long (seconds) to wait for a guest to obtain an IP / accept SSH.
TART_BOOT_TIMEOUT="${TART_BOOT_TIMEOUT:-180}"

# Failure-throttling controls for runner loops. If too many iterations fail in
# a short window, loops can pause before retrying to avoid thrashing the host.
TART_FAILURE_WINDOW_SEC="${TART_FAILURE_WINDOW_SEC:-600}"
TART_FAILURE_THRESHOLD="${TART_FAILURE_THRESHOLD:-3}"
TART_FAILURE_COOLDOWN_SEC="${TART_FAILURE_COOLDOWN_SEC:-180}"

# Optional script-level debug tracing for loop scripts. Disabled by default.
# Set TART_RUNNER_DEBUG=1 to enable shell trace and ERR diagnostics.
TART_RUNNER_DEBUG="${TART_RUNNER_DEBUG:-0}"
TART_DEBUG_LOG_DIR="${TART_DEBUG_LOG_DIR:-$HOME/.github-runner-logs}"
TART_KEEP_FAILED_VM="${TART_KEEP_FAILED_VM:-0}"
TART_VM_LOG_LOOKBACK_MINUTES="${TART_VM_LOG_LOOKBACK_MINUTES:-10}"

# Common SSH options: ephemeral guests have throwaway host keys, so we skip
# host-key verification and never persist known_hosts entries.
TART_SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
)

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

err() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Abort with a message and non-zero status.
die() {
    err "$*"
    exit 1
}

# Ensure a required command is on PATH or abort.
require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

# Enable bash xtrace into a dedicated file descriptor so normal stdout/stderr
# logs remain readable. Caller should pass a short per-runner label.
enable_debug_trace() {
    local trace_name="$1"

    [ "$TART_RUNNER_DEBUG" = "1" ] || return 0

    mkdir -p "$TART_DEBUG_LOG_DIR"
    TART_TRACE_LOG_FILE="${TART_DEBUG_LOG_DIR}/${trace_name}-trace.log"
    # shellcheck disable=SC2034
    PS4='+ [${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]-main}] '
    exec 9>>"$TART_TRACE_LOG_FILE"
    export BASH_XTRACEFD=9
    set -x
    log "Debug tracing enabled: ${TART_TRACE_LOG_FILE}"
}

# Install an ERR trap that records the exact failing command and line.
install_err_diagnostics() {
    local err_name="$1"
    local trap_cmd

    trap_cmd='exit_code=$?; err "['"${err_name}"'] Command failed (exit=${exit_code}) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}"; exit "${exit_code}"'
    trap "$trap_cmd" ERR
}

# Capture host-side diagnostics for Virtualization.framework and Tart around a
# failed iteration. This helps pinpoint VM crashes like VZErrorDomain Code=1.
capture_host_vm_diagnostics() {
    local runner_label="$1"
    local vm_name="$2"

    mkdir -p "$TART_DEBUG_LOG_DIR"
    local diag_file="${TART_DEBUG_LOG_DIR}/${runner_label}-vm-diagnostics.log"

    {
        echo ""
        echo "========== $(date '+%Y-%m-%d %H:%M:%S') =========="
        echo "runner=${runner_label} vm=${vm_name}"
        echo "macOS=$(sw_vers -productVersion 2>/dev/null || true) build=$(sw_vers -buildVersion 2>/dev/null || true)"
        echo "kernel=$(uname -a 2>/dev/null || true)"
        echo ""
        echo "-- tart list --"
        tart list 2>/dev/null || true
        echo ""
        echo "-- recent system log (Virtualization + tart) --"
        log show --style compact --last "${TART_VM_LOG_LOOKBACK_MINUTES}m" \
            --predicate '(process == "tart") || (subsystem BEGINSWITH "com.apple.Virtualization") || (senderImagePath CONTAINS[c] "Virtualization")' \
            2>&1 | tail -n 300 || true
        echo ""
        echo "-- end diagnostics --"

        echo ""
        echo "-- recent DiagnosticReports (tart/virtualization) --"
        find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
            \( -name 'tart*.crash' -o -name 'tart*.ips' -o -name '*Virtualization*.crash' -o -name '*Virtualization*.ips' -o -name 'kernel*.panic' -o -name 'kernel*.ips' \) \
            -print 2>/dev/null | tail -n 6 || true

        echo ""
        echo "-- latest Virtualization crash excerpt --"
        latest_vm_report="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -name 'com.apple.Virtualization.VirtualMachine-*.ips' | sort | tail -n 1)"
        if [ -n "$latest_vm_report" ] && [ -f "$latest_vm_report" ]; then
            echo "$latest_vm_report"
            tail -n 120 "$latest_vm_report" || true
        else
            echo "none"
        fi
    } >> "$diag_file"

    err "[${runner_label}] Host VM diagnostics appended to ${diag_file}"
}

# -----------------------------------------------------------------------------
# Tart / SSH utility functions
# -----------------------------------------------------------------------------

# Resolve a running guest's IP address, waiting up to TART_BOOT_TIMEOUT seconds.
# Echoes the IP on success.
tart_guest_ip() {
    local vm="$1"
    tart ip "$vm" --wait "$TART_BOOT_TIMEOUT"
}

# Block until a TCP port starts accepting connections or the timeout elapses.
wait_for_tcp_port() {
    local host="$1"
    local port="$2"
    local deadline=$(( $(date +%s) + TART_BOOT_TIMEOUT ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ( : >"/dev/tcp/${host}/${port}" ) >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

# Block until the guest accepts a key-based SSH login or the timeout elapses.
wait_for_ssh() {
    local ip="$1"
    local deadline=$(( $(date +%s) + TART_BOOT_TIMEOUT ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ssh -i "$TART_SSH_KEY" "${TART_SSH_OPTS[@]}" -o BatchMode=yes \
            "${TART_GUEST_USER}@${ip}" true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done

    return 1
}

# Run a command in the guest using our dedicated key.
ssh_guest() {
    local ip="$1"
    shift
    ssh -i "$TART_SSH_KEY" "${TART_SSH_OPTS[@]}" -o BatchMode=yes \
        "${TART_GUEST_USER}@${ip}" "$@"
}

# Best-effort cleanup for detached `tart run ... <vm>` host processes.
# If the guest process crashes unexpectedly, these can survive and keep a VM
# appearing "running" even though the job loop has moved on.
kill_tart_run_processes() {
    local vm="$1"
    pkill -f "no-graphics ${vm}$" 2>/dev/null || true
}

# Best-effort graceful shutdown of a guest, falling back to `tart stop`.
stop_guest() {
    local vm="$1"
    local ip="$2"

    if [ -n "$ip" ]; then
        ssh_guest "$ip" "sudo shutdown -h now" 2>/dev/null || true
    fi

    # Give the guest a short grace period to power off on its own, then force.
    local deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! tart list 2>/dev/null | grep -qE "[[:space:]]${vm}[[:space:]].*running"; then
            kill_tart_run_processes "$vm"
            return 0
        fi
        sleep 2
    done

    tart stop "$vm" 2>/dev/null || true
    kill_tart_run_processes "$vm"
}
