#!/bin/bash
#
# Bootstrap multiple GitHub Actions runners on macOS.
#
# Creates numbered runner directories from a prefix, downloads the latest
# runner archive once, extracts into each directory, and runs config.sh.
#
# Examples:
#   bash bootstrap-gh-runners.sh \
#     --dir-prefix "$HOME/github-runner" \
#     --count 2 \
#     --repo owner/repo \
#     --token "<registration-token>"
#
#   bash bootstrap-gh-runners.sh \
#     --dir-prefix "$HOME/github-runner" \
#     --count 2 \
#     --org my-org \
#     --token "<registration-token>" \
#     --labels "self-hosted,macos,mini"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  bootstrap-gh-runners.sh --dir-prefix <path-prefix> --count <N> [--repo <owner/repo> | --org <org> | --url <https://github.com/...>] --token <registration-token> [options]

Required:
  --dir-prefix <path-prefix>   Directory prefix. Script creates <prefix>-1 .. <prefix>-N.
  --count <N>                  Number of runners to create.
  Registration token, one of:
    --token <token>            GitHub runner registration token.
    --token-file <path>        Read the token from a file (keeps it out of shell
                               history and argv; recommended).
  One of:
    --repo <owner/repo>        Repository runner target.
    --org <org>                Organization runner target.
    --url <url>                Explicit target URL (repo or org).

Optional:
  --labels <csv>               Labels for all runners (e.g. "self-hosted,macos").
  --runner-group <name>        Runner group name (org/enterprise scopes only).
  --name-prefix <prefix>       Runner name prefix. Default: "$(hostname -s)-runner".
  Existing configured runners are skipped unless --replace or --force-recreate is used.
  --replace                    Pass --replace to config.sh (recommended).
  --force-recreate             Delete existing runner directories before install.
  --install-launchd            Install/reload launchd services for all 1..N runners.
    --launchd-scope <scope>      launchd scope: agent|daemon. Default: agent.
    --launchd-user <user>        User account for daemon scope. Default: current user.
    --launchd-dir <dir>          Directory for plist files.
                                                             Defaults: ~/Library/LaunchAgents (agent),
                                                                                 /Library/LaunchDaemons (daemon).
  --launchd-label-prefix <p>   launchd label prefix. Default: com.github.runner.
    --launch-agents-dir <dir>    Back-compat alias for --launchd-dir.
  --version <x.y.z>            Runner version. Default: latest release.
  -h, --help                   Show this help.
EOF
}

set_or_replace_env_var() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        # NOTE: BSD/macOS sed requires the empty '' argument after -i. This
        # script targets macOS only; GNU sed would drop the ''.
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# Install the canonical post-job cleanup hook into a runner directory and wire
# it up via ACTIONS_RUNNER_HOOK_JOB_COMPLETED. We copy the single source-of-truth
# script (github-runner-cleanup.sh) rather than duplicating its body here.
configure_job_completed_hook() {
    local runner_dir="$1"
    local env_file="$runner_dir/.env"
    local hook_wrapper="$runner_dir/job-completed-hook.sh"

    cp "$SCRIPT_DIR/github-runner-cleanup.sh" "$hook_wrapper"
    chmod +x "$hook_wrapper"
    touch "$env_file"
    set_or_replace_env_var "$env_file" "ACTIONS_RUNNER_HOOK_JOB_COMPLETED" "$hook_wrapper"
}

install_launchd_service() {
    local runner_index="$1"
    local runner_dir="$2"
    local label="${LAUNCHD_LABEL_PREFIX}-${runner_index}"
    local plist_dest="${LAUNCHD_DIR}/${label}.plist"
    local log_base="${RUNNER_HOME}/.github-runner-logs/runner-${runner_index}"
    local user_block=""

    if [ "$LAUNCHD_SCOPE" = "daemon" ]; then
        user_block=$(cat <<EOF
    <key>UserName</key>
    <string>${LAUNCHD_USER}</string>
EOF
)
    fi

    mkdir -p "$LAUNCHD_DIR" "${RUNNER_HOME}/.github-runner-logs"
    chmod +x "$SCRIPT_DIR/github-runner-wrapper.sh"

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
        <string>${SCRIPT_DIR}/github-runner-wrapper.sh</string>
        <string>${runner_dir}</string>
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
    <string>${runner_dir}</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>${RUNNER_HOME}</string>
        <key>GH_WRAPPER_FAILURE_WINDOW_SEC</key>
        <string>600</string>
        <key>GH_WRAPPER_FAILURE_THRESHOLD</key>
        <string>5</string>
        <key>GH_WRAPPER_FAILURE_COOLDOWN_SEC</key>
        <string>180</string>
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

    echo "launchd service ready: $label"
}

DIR_PREFIX=""
COUNT=""
TOKEN=""
TOKEN_FILE=""
TARGET_URL=""
REPO=""
ORG=""
LABELS=""
RUNNER_GROUP=""
NAME_PREFIX="$(hostname -s)-runner"
REPLACE=false
FORCE_RECREATE=false
VERSION=""
INSTALL_LAUNCHD=false
LAUNCHD_LABEL_PREFIX="com.github.runner"
LAUNCHD_SCOPE="agent"
LAUNCHD_USER="${SUDO_USER:-$USER}"
LAUNCHD_DIR=""
RUNNER_HOME=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir-prefix)
            DIR_PREFIX="${2:-}"
            shift 2
            ;;
        --count)
            COUNT="${2:-}"
            shift 2
            ;;
        --token)
            TOKEN="${2:-}"
            shift 2
            ;;
        --token-file)
            TOKEN_FILE="${2:-}"
            shift 2
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --org)
            ORG="${2:-}"
            shift 2
            ;;
        --url)
            TARGET_URL="${2:-}"
            shift 2
            ;;
        --labels)
            LABELS="${2:-}"
            shift 2
            ;;
        --runner-group)
            RUNNER_GROUP="${2:-}"
            shift 2
            ;;
        --name-prefix)
            NAME_PREFIX="${2:-}"
            shift 2
            ;;
        --replace)
            REPLACE=true
            shift
            ;;
        --force-recreate)
            FORCE_RECREATE=true
            shift
            ;;
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --install-launchd)
            INSTALL_LAUNCHD=true
            shift
            ;;
        --launchd-scope)
            LAUNCHD_SCOPE="${2:-}"
            shift 2
            ;;
        --launchd-user)
            LAUNCHD_USER="${2:-}"
            shift 2
            ;;
        --launchd-dir)
            LAUNCHD_DIR="${2:-}"
            shift 2
            ;;
        --launchd-label-prefix)
            LAUNCHD_LABEL_PREFIX="${2:-}"
            shift 2
            ;;
        --launch-agents-dir)
            LAUNCHD_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Resolve the registration token from --token-file if provided. Reading it from
# a file keeps the secret out of shell history and this script's argv.
if [ -n "$TOKEN_FILE" ]; then
    [ -f "$TOKEN_FILE" ] || { echo "ERROR: --token-file not found: $TOKEN_FILE"; exit 1; }
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi

if [ -z "$DIR_PREFIX" ] || [ -z "$COUNT" ]; then
    echo "ERROR: --dir-prefix and --count are required."
    usage
    exit 1
fi

if [ -z "$TOKEN" ]; then
    echo "ERROR: A registration token is required (use --token or --token-file)."
    usage
    exit 1
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    echo "ERROR: --count must be a positive integer."
    exit 1
fi

target_selector_count=0
[ -n "$TARGET_URL" ] && target_selector_count=$((target_selector_count + 1))
[ -n "$REPO" ] && target_selector_count=$((target_selector_count + 1))
[ -n "$ORG" ] && target_selector_count=$((target_selector_count + 1))

if [ "$target_selector_count" -ne 1 ]; then
    echo "ERROR: Provide exactly one of --repo, --org, or --url."
    exit 1
fi

if [ -n "$REPO" ]; then
    TARGET_URL="https://github.com/$REPO"
elif [ -n "$ORG" ]; then
    TARGET_URL="https://github.com/$ORG"
fi

resolve_launchd_layout() {
    case "$LAUNCHD_SCOPE" in
        agent)
            RUNNER_HOME="$HOME"
            [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="$HOME/Library/LaunchAgents"
            ;;
        daemon)
            [ "$(id -u)" -eq 0 ] || { echo "ERROR: --launchd-scope daemon requires root. Re-run with sudo."; exit 1; }
            [ -n "$LAUNCHD_USER" ] || { echo "ERROR: --launchd-user is required for daemon scope."; exit 1; }
            RUNNER_HOME="$(dscl . -read "/Users/${LAUNCHD_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
            [ -n "$RUNNER_HOME" ] || RUNNER_HOME="/Users/${LAUNCHD_USER}"
            [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="/Library/LaunchDaemons"
            ;;
        *)
            echo "ERROR: --launchd-scope must be one of: agent, daemon"
            exit 1
            ;;
    esac
}

if [ "$INSTALL_LAUNCHD" = true ]; then
    resolve_launchd_layout
fi

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) RUNNER_ARCH="x64" ;;
    arm64) RUNNER_ARCH="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | head -n 1)"
fi

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not determine runner version."
    exit 1
fi

ARCHIVE_NAME="actions-runner-osx-${RUNNER_ARCH}-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${VERSION}/${ARCHIVE_NAME}"

TMP_DIR="$(mktemp -d)"
cleanup_tmp() {
    rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

echo "Using target URL: $TARGET_URL"
echo "Using runner version: $VERSION"
if [ "$INSTALL_LAUNCHD" = true ]; then
    echo "launchd: scope=${LAUNCHD_SCOPE}, dir=${LAUNCHD_DIR}, user=${LAUNCHD_USER}"
fi
echo "Downloading: $DOWNLOAD_URL"
curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/$ARCHIVE_NAME"

for i in $(seq 1 "$COUNT"); do
    runner_dir="${DIR_PREFIX}-${i}"
    runner_name="${NAME_PREFIX}-${i}"
    configured_now=false

    echo ""
    echo "==> Provisioning $runner_dir"

    if [ -d "$runner_dir" ] && [ "$FORCE_RECREATE" = true ]; then
        echo "Removing existing directory: $runner_dir"
        rm -rf "$runner_dir"
    fi

    mkdir -p "$runner_dir"

    if [ -f "$runner_dir/config.sh" ]; then
        echo "Runner files already present in $runner_dir"
    else
        tar -xzf "$TMP_DIR/$ARCHIVE_NAME" -C "$runner_dir"
    fi

    if [ -f "$runner_dir/.runner" ] && [ "$REPLACE" = false ] && [ "$FORCE_RECREATE" = false ]; then
        echo "Runner already configured in $runner_dir (skipping; use --replace to reconfigure)"
        configure_job_completed_hook "$runner_dir"
    else
        config_args=(
            --unattended
            --url "$TARGET_URL"
            --token "$TOKEN"
            --name "$runner_name"
        )

        if [ "$REPLACE" = true ]; then
            config_args+=(--replace)
        fi

        if [ -n "$LABELS" ]; then
            config_args+=(--labels "$LABELS")
        fi

        if [ -n "$RUNNER_GROUP" ]; then
            config_args+=(--runnergroup "$RUNNER_GROUP")
        fi

        (
            cd "$runner_dir"
            ./config.sh "${config_args[@]}"
        )

        configure_job_completed_hook "$runner_dir"
        configured_now=true
    fi

    if [ "$INSTALL_LAUNCHD" = true ]; then
        install_launchd_service "$i" "$runner_dir"
    fi

    if [ "$configured_now" = true ]; then
        echo "Configured runner: $runner_name"
    fi
done

echo ""
echo "Provisioning complete."
if [ "$INSTALL_LAUNCHD" = true ]; then
    echo "launchd services installed/reloaded for runners 1..$COUNT"
else
    echo "Next step: re-run with --install-launchd to install the launchd services."
fi
