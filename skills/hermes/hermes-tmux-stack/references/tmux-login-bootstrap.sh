#!/bin/zsh
set -u

# Login bootstrap for the user-owned tmux service stack. This script is
# intentionally launched by Terminal.app: its children inherit Terminal's
# macOS Local Network Privacy attribution, while tmux keeps the services
# detached after this short-lived shell exits.

readonly RESPAWN_SCRIPT="/Users/colind/Deployments/tmux/tmux-respawn-all.sh"
readonly LOG_DIR="/Users/colind/.hermes/logs"
readonly LOG_FILE="${LOG_DIR}/tmux-login-bootstrap.log"

mkdir -p "${LOG_DIR}"

{
  print -- "[$(date '+%Y-%m-%d %H:%M:%S %z')] login bootstrap starting"

  if [[ ! -x "${RESPAWN_SCRIPT}" ]]; then
    print -- "ERROR: missing or non-executable supervisor: ${RESPAWN_SCRIPT}"
    exit 1
  fi

  "${RESPAWN_SCRIPT}"
  exit_code=$?

  print -- "[$(date '+%Y-%m-%d %H:%M:%S %z')] login bootstrap finished (status=${exit_code})"
  exit "${exit_code}"
} >> "${LOG_FILE}" 2>&1
