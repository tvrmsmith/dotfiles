#!/usr/bin/env bash
set -e -u -o pipefail

TUICR_PANE_DIRECTION="${TUICR_PANE_DIRECTION:-horizontal}"
TUICR_ORCA_TIMEOUT_MS="${TUICR_ORCA_TIMEOUT_MS:-3600000}"
JQ_BIN="${JQ_BIN:-jq}"

# Backward-compat: map tmux/zellij-style positions to Orca split directions
case "$TUICR_PANE_DIRECTION" in
  left|right) TUICR_PANE_DIRECTION="horizontal" ;;
  top|bottom|up|down|stacked) TUICR_PANE_DIRECTION="vertical" ;;
esac

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
  printf "%b[tuicr]%b %s\n" "$GREEN" "$NC" "$*"
}

log_warn() {
  printf "%b[tuicr]%b %s\n" "$YELLOW" "$NC" "$*"
}

log_error() {
  printf "%b[tuicr]%b %s\n" "$RED" "$NC" "$*" >&2
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [directory]

Launch tuicr in an Orca split pane.

Arguments:
  directory    Repository directory to review (default: current directory)

Environment variables:
  TUICR_PANE_DIRECTION   Split direction: horizontal or vertical (default: horizontal)
  TUICR_ORCA_TIMEOUT_MS  Max time to wait for tuicr to exit (default: 3600000)
  ORCA_BIN               Path to the Orca CLI executable (default: auto-detected)
  JQ_BIN                 Path to the jq executable (default: jq)

Examples:
  $(basename "$0")
  $(basename "$0") ~/project
  TUICR_PANE_DIRECTION=vertical $(basename "$0")
EOF
}

# Resolve the Orca CLI the same way the orca-cli skill does: Orca exports
# ORCA_CLI_COMMAND for managed WSL sessions, dev checkouts use orca-dev, and
# bare `orca` on Linux can resolve to the GNOME Orca screen reader.
resolve_orca_bin() {
  if [[ -n "${ORCA_BIN:-}" ]]; then
    printf '%s\n' "$ORCA_BIN"
  elif [[ -n "${ORCA_CLI_COMMAND:-}" ]]; then
    printf '%s\n' "$ORCA_CLI_COMMAND"
  elif [[ -n "${ORCA_DEV_REPO_ROOT:-}" ]]; then
    printf '%s\n' "orca-dev"
  else
    printf '%s\n' "orca"
  fi
}

ORCA_BIN=$(resolve_orca_bin)

require_command() {
  local command_name="$1"
  local display_name="$2"

  if ! command -v "$command_name" &>/dev/null; then
    log_error "$display_name not found on PATH"
    return 1
  fi
}

check_git_repo() {
  local dir="$1"
  if ! git -C "$dir" rev-parse --git-dir &>/dev/null; then
    log_error "Not a git repository: $dir"
    return 1
  fi
  return 0
}

# True only when a tuicr is already reviewing *this* repository. Orca panes do
# not expose a running-command listing, so this is a process check — but a
# machine-wide one would report success because of a tuicr in some unrelated
# repo and send the user hunting for a pane that does not exist here.
check_tuicr_running() {
  local target_dir="$1"
  local pid cwd

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    # The launched pane runs `cd <dir> && tuicr`, so the review's repository is
    # the process's working directory rather than an argument.
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    if [[ -z "$cwd" ]]; then
      # Unreadable working directory means this check cannot tell "elsewhere"
      # from "right here", and answering "not running" would open a second
      # review of the same repository. Say so rather than deciding silently.
      log_warn "Cannot read the working directory of running tuicr $pid; assuming it is elsewhere"
      continue
    fi
    if [[ "$cwd" == "$target_dir" ]]; then
      return 0
    fi
  done < <(pgrep -x tuicr 2>/dev/null)

  return 1
}

check_tuicr_stdout_support() {
  tuicr --help 2>&1 | grep -q -- '--stdout'
}

new_pane_handle=""

cleanup() {
  local status=$?

  if [[ -n "$new_pane_handle" ]]; then
    "$ORCA_BIN" terminal close --terminal "$new_pane_handle" --json >/dev/null 2>&1 || true
  fi

  return "$status"
}

launch_tuicr_pane() {
  local target_dir="$1"

  case "$TUICR_PANE_DIRECTION" in
    horizontal|vertical) ;;
    *)
      log_warn "Unknown TUICR_PANE_DIRECTION '$TUICR_PANE_DIRECTION'; using 'horizontal'"
      TUICR_PANE_DIRECTION="horizontal"
      ;;
  esac

  log_info "Launching tuicr in an Orca pane split $TUICR_PANE_DIRECTION"
  log_info "Directory: $target_dir"

  local output_file=""
  local use_stdout=false
  local tuicr_bin
  tuicr_bin=$(command -v tuicr)

  local quoted_tuicr quoted_dir
  printf -v quoted_tuicr '%q' "$tuicr_bin"
  printf -v quoted_dir '%q' "$target_dir"

  local tuicr_cmd="$quoted_tuicr"
  if check_tuicr_stdout_support; then
    output_file=$(mktemp /tmp/tuicr-output.XXXXXX)
    local quoted_output
    printf -v quoted_output '%q' "$output_file"
    tuicr_cmd="$quoted_tuicr --stdout > $quoted_output"
    use_stdout=true
    log_info "Using --stdout mode (output will be captured)"
  else
    log_warn "tuicr --stdout not supported, output will be copied to clipboard"
  fi

  # Exit the pane shell with tuicr's status so `terminal wait --for exit`
  # reports it back to us.
  local pane_command="cd $quoted_dir && $tuicr_cmd; tuicr_status=\$?; exit \$tuicr_status"

  local split_response
  split_response=$("$ORCA_BIN" terminal split \
    ${ORCA_TERMINAL_HANDLE:+--terminal "$ORCA_TERMINAL_HANDLE"} \
    --direction "$TUICR_PANE_DIRECTION" \
    --command "$pane_command" \
    --json)

  if ! new_pane_handle=$(printf '%s\n' "$split_response" | \
    "$JQ_BIN" -er '.result.split.handle'); then
    new_pane_handle=""
    if [[ -n "$output_file" ]]; then
      rm -f "$output_file"
    fi
    log_error "Could not read the new pane's handle from Orca's split response:"
    log_error "$split_response"
    log_warn "A tuicr pane may be open that this wrapper cannot address or close."
    log_warn "Check your terminal and close it yourself if it is there."
    return 1
  fi

  log_info "tuicr is running in pane $new_pane_handle"
  log_info "Waiting for tuicr to exit..."

  local wait_response
  wait_response=$("$ORCA_BIN" terminal wait \
    --terminal "$new_pane_handle" \
    --for exit \
    --timeout-ms "$TUICR_ORCA_TIMEOUT_MS" \
    --json)

  local satisfied
  satisfied=$(printf '%s\n' "$wait_response" | "$JQ_BIN" -r '.result.wait.satisfied')
  if [[ "$satisfied" != "true" ]]; then
    # A timeout means this wrapper stopped waiting, not that tuicr exited.
    # Dropping the handle keeps the EXIT trap from closing a pane where a review
    # is still open and its unexported instructions still unsaved; the trap still
    # closes the pane on the crash and interrupt paths.
    new_pane_handle=""
    if [[ -n "$output_file" ]]; then
      rm -f "$output_file"
    fi
    log_error "Timed out after ${TUICR_ORCA_TIMEOUT_MS}ms waiting for tuicr to exit"
    log_warn "The tuicr pane is still open and the review is still running."
    log_warn "Finish it there, then read the comments with \`tuicr review comments\`."
    return 1
  fi

  local tuicr_status
  tuicr_status=$(printf '%s\n' "$wait_response" | "$JQ_BIN" -r '.result.wait.exitCode')
  if [[ ! "$tuicr_status" =~ ^[0-9]+$ ]]; then
    log_error "Could not read tuicr exit status from Orca output"
    return 1
  fi

  "$ORCA_BIN" terminal close --terminal "$new_pane_handle" --json >/dev/null 2>&1 || true
  new_pane_handle=""

  if [[ "$tuicr_status" -eq 0 ]]; then
    log_info "tuicr finished"
  else
    log_error "tuicr exited with status $tuicr_status"
  fi

  if [[ "$use_stdout" == true ]] && [[ -f "$output_file" ]]; then
    if [[ -s "$output_file" ]]; then
      echo ""
      echo "=== TUICR INSTRUCTIONS ==="
      cat "$output_file"
      echo "=== END TUICR INSTRUCTIONS ==="
    else
      log_info "No instructions exported from tuicr"
      log_info "If you exported to clipboard, paste the instructions here"
    fi
    rm -f "$output_file"
  else
    log_info "If you exported instructions, they are in your clipboard - paste them here"
  fi

  return "$tuicr_status"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ "${TERM_PROGRAM:-}" != "Orca" && -z "${ORCA_TERMINAL_HANDLE:-}" ]]; then
    log_error "Not running inside an Orca-managed terminal"
    echo ""
    echo "To use tuicr with your coding agent, run that agent inside an Orca terminal."
    echo ""
    echo "1. Exit the current agent session."
    echo ""
    echo "2. Restart the agent in an Orca terminal."
    echo ""
    echo "3. Then run /tuicr again."
    exit 1
  fi

  require_command "$ORCA_BIN" "Orca CLI"
  require_command "$JQ_BIN" "jq"
  require_command "tuicr" "tuicr"
  require_command "lsof" "lsof"

  local target_dir="${1:-.}"
  if [[ ! -d "$target_dir" ]]; then
    log_error "Directory not found: $target_dir"
    exit 1
  fi
  # Physical path: lsof reports a process's working directory with symlinks
  # resolved, so a logical `pwd` through a symlinked checkout would never
  # compare equal and the already-reviewing check would never fire.
  target_dir=$(cd "$target_dir" && pwd -P)

  if ! check_git_repo "$target_dir"; then
    exit 1
  fi

  if check_tuicr_running "$target_dir"; then
    log_error "tuicr is already reviewing $target_dir"
    echo ""
    echo "Switch to its pane by clicking it in the Orca UI, or quit it there and"
    echo "run /tuicr again. To review a different repository, pass its directory:"
    echo ""
    echo "  $(basename "$0") <directory>"
    exit 1
  fi

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  launch_tuicr_pane "$target_dir"
}

main "$@"
