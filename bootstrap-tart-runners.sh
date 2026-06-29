#!/bin/bash
#
# bootstrap-tart-runners.sh — Provision N ephemeral Tart/Ubuntu runners.
#
# This is the entry point that ties everything together. It (optionally) bakes
# the golden Ubuntu 24.04 + KVM image, then installs one launchd service per
# runner. Each service runs tart-runner-loop.sh, which continuously serves
# single-use ephemeral runners.
#
# These runners coexist with the existing persistent macOS host runners — they
# are a separate fleet, not a replacement.
#
# Examples:
#   bash bootstrap-tart-runners.sh \
#     --count 2 \
#     --repo owner/repo \
#     --app-id 123456 \
#     --private-key "$HOME/.config/github-runner-tart/app.private-key.pem" \
#     --install-launchd
#
#   bash bootstrap-tart-runners.sh \
#     --count 4 --org my-org \
#     --app-id 123456 --private-key ./app.pem \
#     --labels "arm64,kvm,linux,ubuntu-24.04" --install-launchd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tart-common.sh
source "$SCRIPT_DIR/tart-common.sh"

usage() {
    cat <<'EOF'
Usage:
  bootstrap-tart-runners.sh --count <N> (--repo <owner/repo> | --org <org>) \
      --app-id <id> --private-key <pem> [options]

Required:
  --count <N>              Number of concurrent ephemeral runners.
  --app-id <id>            GitHub App ID used to mint registration tokens.
  --private-key <pem>      Path to the GitHub App private key (PEM).
  One of:
    --repo <owner/repo>    Repository runner target.
    --org <org>            Organization runner target.

Optional:
  --golden-image <name>    Golden image name. Default: gha-ubuntu-kvm.
  --base-image <ref>       Base OCI image. Default: ghcr.io/cirruslabs/ubuntu:latest.
  --runner-version <x.y.z> Actions runner version baked in. Default: latest.
    --cpus <n>               Guest vCPUs in the baked image. Default: 4.
    --memory-mb <mb>         Guest RAM in MB in the baked image. Default: 8192.
    --disk-gb <gb>           Guest disk size in GB in the baked image. Default: 50.
  --labels <csv>           Runner labels. Default: arm64,kvm,linux,ubuntu-24.04.
  --name-prefix <prefix>   Runner name prefix. Default: tart-ubuntu.
  --rebuild-image          Force a rebuild of the golden image even if it exists.
  --install-launchd        Install/reload a launchd service per runner.
    --launchd-scope <scope>  launchd scope: agent|daemon. Default: agent.
    --launchd-user <user>    User account for daemon scope. Default: current user.
    --launchd-dir <dir>      Directory for plist files.
                                                        Defaults: ~/Library/LaunchAgents (agent),
                                                                            /Library/LaunchDaemons (daemon).
  --launchd-label-prefix <p>  launchd label prefix. Default: com.github.tart-runner.
    --launch-agents-dir <dir>   Back-compat alias for --launchd-dir.
  -h, --help               Show this help.
EOF
}

COUNT=""
REPO=""
ORG=""
APP_ID=""
PRIVATE_KEY=""
NAME_PREFIX="tart-ubuntu"
RUNNER_VERSION=""
REBUILD_IMAGE=false
INSTALL_LAUNCHD=false
LAUNCHD_LABEL_PREFIX="com.github.tart-runner"
LAUNCHD_SCOPE="agent"
LAUNCHD_USER="${SUDO_USER:-$USER}"
LAUNCHD_DIR=""
RUNNER_HOME=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --count) COUNT="${2:-}"; shift 2 ;;
        --repo) REPO="${2:-}"; shift 2 ;;
        --org) ORG="${2:-}"; shift 2 ;;
        --app-id) APP_ID="${2:-}"; shift 2 ;;
        --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
        --golden-image) TART_GOLDEN_IMAGE="${2:-}"; shift 2 ;;
        --base-image) TART_BASE_IMAGE="${2:-}"; shift 2 ;;
        --runner-version) RUNNER_VERSION="${2:-}"; shift 2 ;;
        --cpus) TART_GUEST_CPUS="${2:-}"; shift 2 ;;
        --memory-mb) TART_GUEST_MEMORY_MB="${2:-}"; shift 2 ;;
        --disk-gb) TART_GUEST_DISK_GB="${2:-}"; shift 2 ;;
        --labels) TART_RUNNER_LABELS="${2:-}"; shift 2 ;;
        --name-prefix) NAME_PREFIX="${2:-}"; shift 2 ;;
        --rebuild-image) REBUILD_IMAGE=true; shift ;;
        --install-launchd) INSTALL_LAUNCHD=true; shift ;;
        --launchd-scope) LAUNCHD_SCOPE="${2:-}"; shift 2 ;;
        --launchd-user) LAUNCHD_USER="${2:-}"; shift 2 ;;
        --launchd-dir) LAUNCHD_DIR="${2:-}"; shift 2 ;;
        --launchd-label-prefix) LAUNCHD_LABEL_PREFIX="${2:-}"; shift 2 ;;
        --launch-agents-dir) LAUNCHD_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# ---- Validation -------------------------------------------------------------
require_cmd tart
require_cmd curl
require_cmd openssl
require_cmd jq

[ -n "$COUNT" ] || die "--count is required."
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    die "--count must be a positive integer."
fi
[ -n "$APP_ID" ] || die "--app-id is required."
[ -n "$PRIVATE_KEY" ] || die "--private-key is required."
[ -f "$PRIVATE_KEY" ] || die "Private key file not found: $PRIVATE_KEY"

if { [ -n "$REPO" ] && [ -n "$ORG" ]; } || { [ -z "$REPO" ] && [ -z "$ORG" ]; }; then
    die "Provide exactly one of --repo or --org."
fi

# Normalise the private key path to an absolute path — launchd services run
# with a different working directory, so relative paths would break.
PRIVATE_KEY="$(cd "$(dirname "$PRIVATE_KEY")" && pwd)/$(basename "$PRIVATE_KEY")"

resolve_launchd_layout() {
    case "$LAUNCHD_SCOPE" in
        agent)
            RUNNER_HOME="$HOME"
            [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="$HOME/Library/LaunchAgents"
            ;;
        daemon)
            [ "$(id -u)" -eq 0 ] || die "--launchd-scope daemon requires root. Re-run with sudo."
            [ -n "$LAUNCHD_USER" ] || die "--launchd-user is required for daemon scope."
            RUNNER_HOME="$(dscl . -read "/Users/${LAUNCHD_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
            [ -n "$RUNNER_HOME" ] || RUNNER_HOME="/Users/${LAUNCHD_USER}"
            [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="/Library/LaunchDaemons"
            ;;
        *)
            die "--launchd-scope must be one of: agent, daemon"
            ;;
    esac
}

resolve_launchd_layout

# ---- Golden image -----------------------------------------------------------
ensure_golden_image() {
    local exists=false
    tart list 2>/dev/null | grep -qE "[[:space:]]${TART_GOLDEN_IMAGE}[[:space:]]" && exists=true

    if [ "$exists" = true ] && [ "$REBUILD_IMAGE" = false ]; then
        log "Golden image '$TART_GOLDEN_IMAGE' already exists (use --rebuild-image to refresh)."
        return 0
    fi

    log "Baking golden image '$TART_GOLDEN_IMAGE'..."
    local bake_args=(
        --golden-image "$TART_GOLDEN_IMAGE"
        --base-image "$TART_BASE_IMAGE"
    )
    [ -n "$RUNNER_VERSION" ] && bake_args+=(--runner-version "$RUNNER_VERSION")
    [ "$REBUILD_IMAGE" = true ] && bake_args+=(--force)
    [ -n "$TART_GUEST_CPUS" ] && bake_args+=(--cpus "$TART_GUEST_CPUS")
    [ -n "$TART_GUEST_MEMORY_MB" ] && bake_args+=(--memory-mb "$TART_GUEST_MEMORY_MB")
    [ -n "$TART_GUEST_DISK_GB" ] && bake_args+=(--disk-gb "$TART_GUEST_DISK_GB")

    bash "$SCRIPT_DIR/tart-bake-ubuntu.sh" "${bake_args[@]}"
}

# ---- launchd service per runner --------------------------------------------
install_launchd_service() {
    local index="$1"
    local label="${LAUNCHD_LABEL_PREFIX}-${index}"
    local plist_dest="${LAUNCHD_DIR}/${label}.plist"
    local log_base="${RUNNER_HOME}/.github-runner-logs/tart-runner-${index}"
    local user_block=""

    if [ "$LAUNCHD_SCOPE" = "daemon" ]; then
        user_block=$(cat <<EOF
    <key>UserName</key>
    <string>${LAUNCHD_USER}</string>
EOF
)
    fi

    mkdir -p "$LAUNCHD_DIR" "${RUNNER_HOME}/.github-runner-logs"
    chmod +x "$SCRIPT_DIR/tart-runner-loop.sh"

    # Scope flag (repo or org) passed through to the loop.
    local scope_key scope_value
    if [ -n "$REPO" ]; then
        scope_key="--repo"; scope_value="$REPO"
    else
        scope_key="--org"; scope_value="$ORG"
    fi

    cat > "$plist_dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>

${user_block}

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/tart-runner-loop.sh</string>
        <string>--app-id</string>
        <string>${APP_ID}</string>
        <string>--private-key</string>
        <string>${PRIVATE_KEY}</string>
        <string>${scope_key}</string>
        <string>${scope_value}</string>
        <string>--golden-image</string>
        <string>${TART_GOLDEN_IMAGE}</string>
        <string>--index</string>
        <string>${index}</string>
        <string>--name-prefix</string>
        <string>${NAME_PREFIX}</string>
        <string>--labels</string>
        <string>${TART_RUNNER_LABELS}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>StandardOutPath</key>
    <string>${log_base}-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${log_base}-stderr.log</string>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>${RUNNER_HOME}</string>
    </dict>
</dict>
</plist>
EOF

    chmod 644 "$plist_dest"

    if [ "$LAUNCHD_SCOPE" = "daemon" ]; then
        launchctl bootout "system/${label}" >/dev/null 2>&1 || true
        launchctl bootstrap system "$plist_dest"
        launchctl enable "system/${label}" >/dev/null 2>&1 || true
    else
        if launchctl list "$label" >/dev/null 2>&1; then
            launchctl unload "$plist_dest" || true
        fi
        launchctl load "$plist_dest"
    fi

    log "launchd service ready: $label"
}

# ---- Main -------------------------------------------------------------------
if [ -n "$REPO" ]; then
    log "Target: repository $REPO"
else
    log "Target: organization $ORG"
fi
log "Runners: $COUNT, labels: $TART_RUNNER_LABELS, golden image: $TART_GOLDEN_IMAGE"
log "Guest sizing: cpu=${TART_GUEST_CPUS}, mem=${TART_GUEST_MEMORY_MB}MB, disk=${TART_GUEST_DISK_GB}GB"
log "launchd: scope=${LAUNCHD_SCOPE}, dir=${LAUNCHD_DIR}, user=${LAUNCHD_USER}"

ensure_golden_image

for i in $(seq 1 "$COUNT"); do
    echo ""
    log "==> Configuring ephemeral runner $i of $COUNT"
    if [ "$INSTALL_LAUNCHD" = true ]; then
        install_launchd_service "$i"
    fi
done
echo ""
log "Provisioning complete."
if [ "$INSTALL_LAUNCHD" = true ]; then
    log "launchd services installed/reloaded for tart runners 1..$COUNT"
else
    log "No services installed. Re-run with --install-launchd, or start a loop manually:"
    log "  bash tart-runner-loop.sh --app-id $APP_ID --private-key $PRIVATE_KEY \\"
    if [ -n "$REPO" ]; then
        log "    --repo $REPO --golden-image $TART_GOLDEN_IMAGE --index 1"
    else
        log "    --org $ORG --golden-image $TART_GOLDEN_IMAGE --index 1"
    fi
fi
