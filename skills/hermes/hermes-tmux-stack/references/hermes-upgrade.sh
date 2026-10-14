#!/bin/zsh
#
# hermes-upgrade.sh — three-phase Hermes upgrade
#
#   1. tmux-respawn-all.sh --kill   (tear the stack down)
#   2. hermes update                (pull latest + reinstall deps)
#   3. tmux-respawn-all.sh          (bring the stack back up)
#
# Any arguments are forwarded to `hermes update`, e.g.:
#   hermes-upgrade.sh            # interactive update (you answer prompts)
#   hermes-upgrade.sh -y         # assume-yes, hands-off
#   hermes-upgrade.sh --check    # just check; nothing is killed/restarted
#
set -u

RESPAWN="/Users/colind/Deployments/tmux/tmux-respawn-all.sh"
HERMES="/Users/colind/.local/bin/hermes"

# --- colors ---------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
  BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi
phase() { print "\n${BOLD}${CYAN}━━ $1 ━━${RESET}"; }
ok()    { print "${GREEN}✓ $1${RESET}"; }
warn()  { print "${YELLOW}⚠ $1${RESET}"; }
fatal() { print "${RED}✗ $1${RESET}" >&2; exit 1; }

# --- preflight ------------------------------------------------------------
[[ -x "$RESPAWN" ]] || fatal "respawn script not found/executable: $RESPAWN"
command -v "$HERMES" &>/dev/null || fatal "hermes not found: $HERMES"

# `--check` is non-destructive: just probe for an update and exit without
# touching the running stack.
if [[ "${1:-}" == "--check" ]]; then
  phase "Checking for updates (stack left running)"
  "$HERMES" update "$@"
  exit $?
fi

# --- phase 1: kill --------------------------------------------------------
phase "Phase 1/3 — stopping the stack"
"$RESPAWN" --kill
sleep 1   # let ports/processes fully release before the update touches the venv

# --- phase 2: update ------------------------------------------------------
phase "Phase 2/3 — hermes update $*"
"$HERMES" update "$@"
update_rc=$?
if (( update_rc == 0 )); then
  ok "update completed"
else
  warn "hermes update exited $update_rc — bringing the stack back up anyway (likely on the previous version)"
fi

# --- phase 3: respawn -----------------------------------------------------
phase "Phase 3/3 — restarting the stack"
# --restart, not a bare ensure: if anything re-bound a service port between
# phase 1 and here (hermes update relaunching the dashboard, a hand-started
# gateway, a launchd orphan), a plain ensure would see "healthy" and leave the
# pre-update build running.
#
# Over SSH, the respawn must NOT run from this shell: a tmux server forked
# from an SSH session has no macOS Local Network permission, so every service
# in it (gateway, snoopd, ...) gets EHOSTUNREACH for all LAN hosts while
# public IPs still work. Confirmed 2026-10-14 (possibly newer since macOS
# 26.7). Instead kill again (keeps --restart semantics, since the bootstrap only
# starts what's missing) and relaunch via the Terminal.app login bootstrap,
# whose children inherit Terminal's Local Network permission.
BOOTSTRAP_AGENT="gui/$(id -u)/ai.hermes.tmux-stack"
BOOTSTRAP_LOG="$HOME/.hermes/logs/tmux-login-bootstrap.log"
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  warn "running over SSH — relaunching via Terminal.app ($BOOTSTRAP_AGENT) for Local Network permission"
  "$RESPAWN" --kill
  sleep 1
  log_lines=$(wc -l < "$BOOTSTRAP_LOG" 2>/dev/null || echo 0)
  if launchctl kickstart "$BOOTSTRAP_AGENT"; then
    respawn_rc=124   # timeout unless the bootstrap reports in
    for _ in {1..90}; do
      finished=$(tail -n +$(( log_lines + 1 )) "$BOOTSTRAP_LOG" 2>/dev/null | grep 'login bootstrap finished' | tail -1)
      if [[ -n "$finished" ]]; then
        respawn_rc=${${finished##*status=}%%\)*}
        break
      fi
      sleep 2
    done
    tail -n +$(( log_lines + 1 )) "$BOOTSTRAP_LOG" 2>/dev/null
    (( respawn_rc == 124 )) && warn "bootstrap did not finish within 180s — check $BOOTSTRAP_LOG"
  else
    warn "kickstart failed (no GUI login session?) — falling back to direct respawn; LAN access WILL be blocked until relaunched from Terminal"
    "$RESPAWN" --restart
    respawn_rc=$?
  fi
else
  "$RESPAWN" --restart
  respawn_rc=$?
fi

print ""
if (( update_rc == 0 && respawn_rc == 0 )); then
  ok "Hermes upgrade complete"
else
  warn "Finished with issues (update=$update_rc respawn=$respawn_rc) — check output above"
fi
exit $(( update_rc != 0 ? update_rc : respawn_rc ))
