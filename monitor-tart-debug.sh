#!/bin/bash
set -euo pipefail
set +m

LOG_DIR="${LOG_DIR:-$HOME/.github-runner-logs}"
MODE="${1:-watch}"
TARGET="${2:-all}"
LINES="${3:-80}"

usage() {
  cat <<EOF
Usage:
  $0 watch [all|N]
  $0 snapshot [all|N] [lines]
  $0 auto [all|N] [lines]

Notes:
  - 'all' = every currently configured runner (from installed launchd plists).
  - watch is live and does not return until Ctrl+C.
  - snapshot is one-shot and returns immediately.
  - auto watches until an error pattern appears, then writes a snapshot and exits.
EOF
}

# Discover configured runner indices from installed launchd plists (daemon or
# agent scope). This reflects the *current* fleet, so removed runners (whose
# plists are gone) are not watched even if their old log files still exist.
discover_runners() {
  local found
  found="$(
    ls /Library/LaunchDaemons/com.github.tart-runner-*.plist \
       "$HOME/Library/LaunchAgents/com.github.tart-runner-"*.plist 2>/dev/null \
      | sed -E 's#.*com\.github\.tart-runner-([0-9]+)\.plist#\1#' \
      | sort -n -u
  )"
  echo "$found"
}

runner_list() {
  case "$TARGET" in
    all)
      local found
      found="$(discover_runners)"
      if [ -z "$found" ]; then
        echo "No configured tart runners found (no launchd plists)." >&2
        exit 1
      fi
      echo $found
      ;;
    ''|*[!0-9]*)
      echo "Invalid runner target: $TARGET" >&2
      usage
      exit 1
      ;;
    *)
      echo "$TARGET"
      ;;
  esac
}

latest_vm_log() {
  local runner="$1"
  find "$LOG_DIR" -maxdepth 1 -type f -name "tart-runner-${runner}-vm-*.log" | sort | tail -n 1
}

snapshot_runner() {
  local runner="$1"
  local vm_log diag

  vm_log="$(latest_vm_log "$runner")"
  diag="$LOG_DIR/tart-runner-${runner}-vm-diagnostics.log"

  echo "=== runner-${runner} snapshot ==="
  if [ -f "$LOG_DIR/tart-runner-${runner}-stderr.log" ]; then
    echo "--- stderr (last ${LINES}) ---"
    tail -n "$LINES" "$LOG_DIR/tart-runner-${runner}-stderr.log" || true
  fi

  if [ -f "$LOG_DIR/tart-runner-${runner}-stdout.log" ]; then
    echo "--- stdout (last ${LINES}) ---"
    tail -n "$LINES" "$LOG_DIR/tart-runner-${runner}-stdout.log" || true
  fi

  echo "--- latest vm log ---"
  if [ -n "$vm_log" ] && [ -f "$vm_log" ]; then
    echo "$vm_log"
    tail -n "$LINES" "$vm_log" || true
  else
    echo "none"
  fi

  echo "--- diagnostics log ---"
  if [ -f "$diag" ]; then
    echo "$diag"
    tail -n "$LINES" "$diag" || true
  else
    echo "none"
  fi
  echo ""
}

watch_runner() {
  local runner="$1"
  echo "Watching runner-${runner} stderr/stdout (Ctrl+C to stop)"
  tail -F \
    "$LOG_DIR/tart-runner-${runner}-stderr.log" \
    "$LOG_DIR/tart-runner-${runner}-stdout.log"
}

watch_all() {
  local runners file_args=() r
  runners="$(runner_list)"
  echo "Watching runners: ${runners} stderr/stdout (Ctrl+C to stop)"
  for r in $runners; do
    file_args+=(
      "$LOG_DIR/tart-runner-${r}-stderr.log"
      "$LOG_DIR/tart-runner-${r}-stdout.log"
    )
  done
  tail -F "${file_args[@]}"
}

auto_capture() {
  local files=()
  local error_re out_file tmp_dir fifo tail_pid line matched_line f r runners

  error_re='VZErrorDomain|virtual machine stopped unexpectedly|Failure reason|Iteration failed|SSH never came up|No IP'

  # runner_list resolves 'all' to the currently configured runners (from
  # launchd plists), so removed runners with stale logs are never watched.
  runners="$(runner_list)"
  for r in $runners; do
    files+=(
      "$LOG_DIR/tart-runner-${r}-stderr.log"
      "$LOG_DIR/tart-runner-${r}-stdout.log"
    )
  done

  # Make sure every target file exists so tail -F has something to follow.
  for f in "${files[@]}"; do
    touch "$f" 2>/dev/null || true
  done

  echo "Watching for crash/error markers on target '${TARGET}'..."

  tmp_dir="$(mktemp -d)"
  fifo="${tmp_dir}/fifo"
  mkfifo "$fifo"

  # Single follower process for all files. disown so the shell never prints
  # job-control noise (e.g. "Terminated: 15") when we stop it after a match.
  tail -n 0 -F "${files[@]}" > "$fifo" 2>/dev/null &
  tail_pid=$!
  disown "$tail_pid" 2>/dev/null || true

  matched_line=""
  while IFS= read -r line; do
    echo "$line"
    if printf '%s\n' "$line" | grep -Eq "$error_re"; then
      matched_line="$line"
      break
    fi
  done < "$fifo"

  kill "$tail_pid" 2>/dev/null || true
  rm -rf "$tmp_dir" 2>/dev/null || true

  echo ""
  echo "Marker detected:"
  echo "$matched_line"

  out_file="/tmp/tart-crash-snapshot-${TARGET}-$(date '+%Y%m%d-%H%M%S').txt"
  "$0" snapshot "$TARGET" "$LINES" > "$out_file"

  echo ""
  echo "Crash marker detected. Snapshot written to: $out_file"
  echo ""
  echo "Summary markers:"
  grep -nE "$error_re" "$out_file" | tail -n 40 || true
}

case "$MODE" in
  watch)
    if [ "$TARGET" = "all" ]; then
      watch_all
    else
      watch_runner "$TARGET"
    fi
    ;;
  snapshot)
    for r in $(runner_list); do
      snapshot_runner "$r"
    done
    ;;
  auto)
    runner_list >/dev/null
    auto_capture
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
