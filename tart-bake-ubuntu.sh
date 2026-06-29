#!/bin/bash
#
# tart-bake-ubuntu.sh — Build a golden Ubuntu 24.04 Tart image with nested KVM
# and the GitHub Actions runner pre-installed.
#
# This runs ONCE (or whenever you want to refresh the image). It produces a
# stopped Tart VM that the ephemeral loop clones for every job. Baking the
# runner binary and dependencies into the image keeps per-job startup fast.
#
# Steps:
#   1. Generate a dedicated host SSH keypair if one does not already exist.
#   2. Clone the cirruslabs Ubuntu base image into the golden image name.
#   3. Boot it with nested virtualization (--nested) enabled.
#   4. Inject our public key (over the image's default password login), then
#      provision over key-based SSH: install runner deps, download the
#      linux-arm64 runner, verify /dev/kvm, and disable password auth.
#   5. Shut the guest down — the image is now ready to clone.
#
# Requirements on the host: tart, ssh, ssh-keygen, sshpass, curl.
# Hardware: Apple Silicon M3/M4 + macOS 15+ (nested virtualization is gated to
# these; see https://tart.run/faq/#nested-virtualization-support).
#
# Usage:
#   tart-bake-ubuntu.sh [--golden-image <name>] [--base-image <ref>]
#                       [--runner-version <x.y.z>] [--cpus <n>]
#                       [--memory-mb <mb>] [--disk-gb <gb>] [--force]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tart-common.sh
source "$SCRIPT_DIR/tart-common.sh"

RUNNER_VERSION=""
FORCE=false
BAKE_STAGE="initializing"

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
}

set_bake_stage() {
    BAKE_STAGE="$1"
}

report_failure() {
    local exit_code="$1"

    err "Bake failed during: ${BAKE_STAGE}"

    case "$BAKE_STAGE" in
        "waiting for guest IP")
            err "The VM booted but Tart did not report an IP address before the timeout (${TART_BOOT_TIMEOUT}s)."
            ;;
        "waiting for SSH port")
            err "The guest obtained an IP address but port 22 never opened before the timeout (${TART_BOOT_TIMEOUT}s)."
            ;;
        "injecting SSH key")
            err "The guest never accepted the default password-based SSH login. Verify the base image still uses ${TART_GUEST_USER}/${TART_GUEST_PASSWORD} and that sshd finished starting."
            ;;
        "waiting for key-based SSH")
            err "The public key injection completed, but the guest never accepted key-based SSH before the timeout (${TART_BOOT_TIMEOUT}s)."
            ;;
        "provisioning guest")
            err "Guest provisioning failed after SSH came up. Review the package installation or KVM verification output above for the first failing command."
            ;;
        "hardening SSH")
            err "The image was provisioned, but disabling password SSH failed. The VM is still being shut down for safety."
            ;;
    esac

    exit "$exit_code"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --golden-image) TART_GOLDEN_IMAGE="${2:-}"; shift 2 ;;
        --base-image) TART_BASE_IMAGE="${2:-}"; shift 2 ;;
        --runner-version) RUNNER_VERSION="${2:-}"; shift 2 ;;
        --cpus) TART_GUEST_CPUS="${2:-}"; shift 2 ;;
        --memory-mb) TART_GUEST_MEMORY_MB="${2:-}"; shift 2 ;;
        --disk-gb) TART_GUEST_DISK_GB="${2:-}"; shift 2 ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

require_cmd tart
require_cmd ssh
require_cmd ssh-keygen
require_cmd sshpass
require_cmd curl

# -----------------------------------------------------------------------------
# 1. Ensure the dedicated SSH keypair exists (generate once, reuse thereafter).
# -----------------------------------------------------------------------------
ensure_ssh_key() {
    if [ -f "$TART_SSH_KEY" ]; then
        log "Reusing existing SSH key: $TART_SSH_KEY"
        return 0
    fi

    log "Generating dedicated SSH key: $TART_SSH_KEY"
    mkdir -p "$TART_CONFIG_DIR"
    chmod 700 "$TART_CONFIG_DIR"
    ssh-keygen -t ed25519 -N "" -C "github-runner-tart" -f "$TART_SSH_KEY"
    chmod 600 "$TART_SSH_KEY"
}

# -----------------------------------------------------------------------------
# 2. Resolve the runner version to install (latest if unspecified).
# -----------------------------------------------------------------------------
resolve_runner_version() {
    if [ -n "$RUNNER_VERSION" ]; then
        return 0
    fi
    RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
        | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$RUNNER_VERSION" ] || die "Could not determine latest runner version."
}

# -----------------------------------------------------------------------------
# 3. Clone the base image into the golden image name.
# -----------------------------------------------------------------------------
clone_base_image() {
    local exists=false

    if tart list --format json 2>/dev/null | grep -q '"Name"[[:space:]]*:[[:space:]]*"'"${TART_GOLDEN_IMAGE}"'"'; then
        exists=true
    fi

    if [ "$exists" = true ]; then
        if [ "$FORCE" = true ]; then
            log "Stopping existing golden image: $TART_GOLDEN_IMAGE"
            tart stop "$TART_GOLDEN_IMAGE" 2>/dev/null || true

            log "Removing existing golden image: $TART_GOLDEN_IMAGE"
            tart delete "$TART_GOLDEN_IMAGE" 2>/dev/null || true

            if tart list --format json 2>/dev/null | grep -q '"Name"[[:space:]]*:[[:space:]]*"'"${TART_GOLDEN_IMAGE}"'"'; then
                die "Failed to remove existing golden image '$TART_GOLDEN_IMAGE'."
            fi
        else
            die "Golden image '$TART_GOLDEN_IMAGE' already exists. Use --force to rebuild."
        fi
    fi

    log "Cloning $TART_BASE_IMAGE -> $TART_GOLDEN_IMAGE"
    tart clone "$TART_BASE_IMAGE" "$TART_GOLDEN_IMAGE"

    log "Configuring guest resources (cpu=${TART_GUEST_CPUS}, mem=${TART_GUEST_MEMORY_MB}MB, disk=${TART_GUEST_DISK_GB}GB)"
    tart set "$TART_GOLDEN_IMAGE" \
        --cpu "$TART_GUEST_CPUS" \
        --memory "$TART_GUEST_MEMORY_MB" \
        --disk-size "$TART_GUEST_DISK_GB"
}

# -----------------------------------------------------------------------------
# 4. Provision the running guest.
# -----------------------------------------------------------------------------

# Inject our public key using the image's default password login (one time).
inject_ssh_key() {
    local ip="$1"
    local pubkey
    local deadline
    pubkey="$(cat "${TART_SSH_KEY}.pub")"
    deadline=$(( $(date +%s) + TART_BOOT_TIMEOUT ))

    log "Waiting for password-based SSH so the public key can be injected"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if SSHPASS="$TART_GUEST_PASSWORD" sshpass -e ssh "${TART_SSH_OPTS[@]}" \
            "${TART_GUEST_USER}@${ip}" \
            "install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$pubkey' ~/.ssh/authorized_keys || printf '%s\n' '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
            return 0
        fi
        sleep 2
    done

    return 1
}

# Run the in-guest provisioning over key-based SSH. The heredoc body executes
# inside the guest; quoting the delimiter keeps host-side expansion out of it,
# except for the values we explicitly interpolate first.
provision_guest() {
    local ip="$1"
    local runner_url runner_archive

    runner_archive="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
    runner_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${runner_archive}"

    log "Provisioning guest: installing runner ${RUNNER_VERSION} and verifying KVM"
    ssh_guest "$ip" \
        "sudo RUNNER_DIR='${TART_GUEST_RUNNER_DIR}' RUNNER_URL='${runner_url}' \
         RUNNER_ARCHIVE='${runner_archive}' GUEST_USER='${TART_GUEST_USER}' bash -s" <<'PROVISION'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Refresh package metadata and install the host-side tooling the runner and the
# token loop need: curl, jq, plus cpu-checker for the kvm-ok verification.
apt-get update -y
apt-get install -y --no-install-recommends curl wget jq cpu-checker qemu-system-arm build-essential

# Install LLVM/Clang 18 via the official llvm.sh helper. This provisioning shell
# already runs as root, so no sudo is needed; wget (installed above) is required
# both to fetch llvm.sh and by llvm.sh itself.
#
# Note: llvm.sh only honours the version argument (and "all") — it ignores any
# trailing package names, so on its own it installs just clang/clangd/lld/lldb.
# The clang-tools-extra tooling (clang-tidy, clang-format, clang-query, …) must
# be installed explicitly from the apt.llvm.org repo that llvm.sh configures.
cd /tmp
wget https://apt.llvm.org/llvm.sh
chmod +x ./llvm.sh
./llvm.sh 18
cd -
apt-get install -y --no-install-recommends \
    clang-tools-18 clang-tidy-18 clang-format-18

# Download and unpack the GitHub Actions runner (linux-arm64).
install -d -m 0755 "$RUNNER_DIR"
curl -fL "$RUNNER_URL" -o "/tmp/$RUNNER_ARCHIVE"
tar xzf "/tmp/$RUNNER_ARCHIVE" -C "$RUNNER_DIR"
rm -f "/tmp/$RUNNER_ARCHIVE"

# The runner must not run as root; hand the directory to the guest user.
chown -R "$GUEST_USER":"$GUEST_USER" "$RUNNER_DIR"

# Install the runner's own OS dependencies.
"$RUNNER_DIR/bin/installdependencies.sh"

# Grant the guest user access to the nested KVM device.
usermod -aG kvm "$GUEST_USER"

# Verify nested virtualization actually surfaced inside the guest. If /dev/kvm
# is missing the host is not M3/M4 (or --nested was not passed) and the image
# is useless for KVM workloads — fail loudly so the bake does not "succeed".
if [ ! -e /dev/kvm ]; then
    echo "FATAL: /dev/kvm not present in guest. Nested virtualization unavailable." >&2
    exit 1
fi
kvm-ok

echo "Provisioning complete: runner installed and KVM verified."
PROVISION
}

# Disable password authentication now that key auth is in place. Done last so a
# provisioning failure still leaves a reachable guest for debugging.
harden_ssh() {
    local ip="$1"
    log "Disabling password SSH authentication in the image"
    ssh_guest "$ip" \
        "echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/10-no-password.conf >/dev/null && sudo systemctl restart ssh"
}

main() {
    set_bake_stage "ensuring SSH key"
    ensure_ssh_key

    set_bake_stage "resolving runner version"
    resolve_runner_version

    set_bake_stage "cloning base image"
    clone_base_image

    set_bake_stage "booting guest"
    log "Booting golden image with nested virtualization for provisioning"
    # Run headless in the background; we drive it entirely over SSH.
    tart run --nested --no-graphics "$TART_GOLDEN_IMAGE" &
    local tart_pid=$!

    # Ensure we always power the guest down, even on error.
    local ip=""
    cleanup() {
        if [ -n "${ip:-}" ]; then
            log "Cleaning up guest after stage: ${BAKE_STAGE}"
            stop_guest "$TART_GOLDEN_IMAGE" "$ip"
        fi
        wait "${tart_pid:-}" 2>/dev/null || true
    }
    trap cleanup EXIT
    trap 'report_failure "$?"' ERR

    set_bake_stage "waiting for guest IP"
    ip="$(tart_guest_ip "$TART_GOLDEN_IMAGE")"
    [ -n "$ip" ] || die "Guest did not obtain an IP address."
    log "Guest IP: $ip"

    set_bake_stage "waiting for SSH port"
    wait_for_tcp_port "$ip" 22 || die "Guest SSH port never opened."

    set_bake_stage "injecting SSH key"
    inject_ssh_key "$ip" || die "Guest did not accept password-based SSH."

    set_bake_stage "waiting for key-based SSH"
    wait_for_ssh "$ip" || die "Guest did not accept key-based SSH."

    set_bake_stage "provisioning guest"
    provision_guest "$ip"

    set_bake_stage "hardening SSH"
    harden_ssh "$ip"

    set_bake_stage "completed"
    log "Golden image '$TART_GOLDEN_IMAGE' baked successfully."
    log "Runner version: $RUNNER_VERSION"
}

main "$@"
