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
TART_GUEST_CPUS="${TART_GUEST_CPUS:-4}"
TART_GUEST_MEMORY_MB="${TART_GUEST_MEMORY_MB:-8192}"
TART_GUEST_DISK_GB="${TART_GUEST_DISK_GB:-50}"

# Where the GitHub Actions runner is installed inside the guest.
TART_GUEST_RUNNER_DIR="${TART_GUEST_RUNNER_DIR:-/opt/actions-runner}"

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
