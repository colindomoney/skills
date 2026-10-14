#!/bin/zsh
set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers (respects NO_COLOR)
# ---------------------------------------------------------------------------
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  RED=$'\e[31m'; YELLOW=$'\e[33m'; GREEN=$'\e[32m'
  CYAN=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

FORCE_RESTART=0

info()    { print -P "${CYAN}${BOLD}[info]${RESET}    $*" }
ok()      { print -P "${GREEN}${BOLD}[ok]${RESET}      $*" }
action()  { print -P "${YELLOW}${BOLD}[action]${RESET}  $*" }
warn()    { print -P "${YELLOW}${BOLD}[warn]${RESET}    $*" >&2 }
fatal()   { print -P "${RED}${BOLD}[fatal]${RESET}   $*" >&2; exit 1 }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  info "Running preflight checks..."

  if ! command -v tmux &>/dev/null; then
    fatal "tmux not found — cannot continue"
  fi

  if ! command -v hermes &>/dev/null; then
    warn "hermes not found on PATH — gateway and dashboard sessions may fail"
  fi

  if ! command -v npx &>/dev/null; then
    warn "npx not found on PATH — paperclip session may fail"
  fi

  if ! command -v ob &>/dev/null; then
    warn "ob not found on PATH — obsidian session may fail"
  fi

  ok "Preflight passed"
}

# ---------------------------------------------------------------------------
# Session bootstrap
# ---------------------------------------------------------------------------
# Kill processes matching $pattern, but NEVER tmux itself.
#
# `pkill -f "hermes gateway"` is a trap here: when tmux isn't already running,
# the server is forked by the first `tmux new-session -d -s gateway ... hermes
# gateway run` and keeps that argv forever. So the tmux *server* matches the
# gateway pattern, and a -9 against it takes down every session on the machine
# (dashboard, paperclip, obsidian, and unrelated ones like garmin) as
# collateral. Filter by executable name instead.
kill_matching() {
  local pattern="$1"
  local -a pids=()
  local pid cmd exe
  for pid in ${(f)"$(pgrep -f "$pattern" 2>/dev/null || true)"}; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ -z "$cmd" ]] && continue
    exe="${${cmd%% *}##*/}"
    [[ "$exe" == tmux ]] && continue
    pids+=("$pid")
  done
  (( ${#pids} == 0 )) && return 1
  kill -9 "${pids[@]}" 2>/dev/null || true
  return 0
}

# Kill whatever holds $port, whatever it happens to be called.
#
# Name patterns are not enough. A gateway started by the dashboard's UI
# "restart" button runs as `python -m hermes_cli.main gateway restart` — no
# "hermes gateway" pattern matches that, so it survived the sweep, kept :8642,
# and the fresh tmux pane died on bind while wait_for_port cheerfully reported
# the survivor's listener as success.
kill_port_owner() {
  local port="$1"
  local -a pids
  pids=(${(f)"$(lsof -nP -i ":$port" -sTCP:LISTEN -t 2>/dev/null || true)"})
  (( ${#pids} == 0 )) && return 1
  kill -9 "${pids[@]}" 2>/dev/null || true
  local waited=0
  while lsof -i ":$port" -sTCP:LISTEN &>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 0
}

# launchd must not co-own the gateway. `hermes update` (re)registers an
# ai.hermes.gateway KeepAlive agent whose `--replace` kills any pane gateway
# moments after it starts — and killing its *process* is useless, KeepAlive
# revives it within 30s. Boot the *job* out before tmux claims :8642.
boot_out_launchd_gateway() {
  local label="ai.hermes.gateway"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl remove "$label" 2>/dev/null || true
  local waited=0
  while launchctl list "$label" &>/dev/null && (( waited < 10 )); do
    sleep 1; waited=$(( waited + 1 ))
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  done
  if launchctl list "$label" &>/dev/null; then
    warn "launchd job $label still loaded — pane gateway may be killed by --replace"
  fi
}

wait_for_port() {
  local session="$1"
  local port="$2"
  local timeout="${3:-60}"
  local elapsed=0
  local pane_dead
  printf "          waiting for :$port "
  while ! lsof -i ":$port" -sTCP:LISTEN &>/dev/null; do
    # A pane that exits before binding (classically "address already in use")
    # used to be invisible here — we'd just keep printing dots until timeout.
    # Bail immediately and point at the pane so the real error is readable.
    pane_dead=$(tmux list-panes -t "$session:0" -F '#{pane_dead}' 2>/dev/null | head -n1)
    if [[ "$pane_dead" != "0" ]]; then
      printf "\n"
      warn "$session exited before binding :$port — output: tmux capture-pane -pt $session"
      return 1
    fi
    if (( elapsed >= timeout )); then
      printf "\n"
      warn "$session did not bind :$port within ${timeout}s"
      return 1
    fi
    printf "."
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done
  printf "\n"
  # "Something is listening" is not "our service is up". If the pane is gone
  # but the port is held, the listener belongs to someone else — reporting
  # [ok] here is how an upgrade could claim success while the old build kept
  # serving.
  pane_dead=$(tmux list-panes -t "$session:0" -F '#{pane_dead}' 2>/dev/null | head -n1)
  if [[ "$pane_dead" != "0" ]]; then
    warn "$session: :$port is listening but its tmux pane is gone — another process owns that port"
    return 1
  fi
  ok "$session up on :$port (${elapsed}s)"
}

# True if a process listening on $port has its cwd at $expected_dir.
# Used to catch a service that some *other* launcher (launchd, a manual
# `hermes gateway run`, or a `--replace` takeover) started in the wrong
# directory — the port is bound, but not where we want it.
port_cwd_matches() {
  local port="$1" expected="$2" pid cwd
  pid=$(lsof -nP -i ":$port" -sTCP:LISTEN -t 2>/dev/null | head -n1)
  [[ -z "$pid" ]] && return 1
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)
  [[ "$cwd" == "$expected" ]]
}

ensure_session() {
  local session="$1"
  local cmd="$2"
  local port="${3:-}"
  local proc_pattern="${4:-}"
  local start_dir="${5:-}"
  local wait_timeout="${6:-60}"

  local dir_flag=()
  [[ -n "$start_dir" ]] && dir_flag=(-c "$start_dir")

  if ! tmux has-session -t "$session" 2>/dev/null; then
    # No session of ours, but the port is taken → a stray owns it (launchd
    # orphan, a hand-run `hermes gateway run`, or one an update spawned).
    # Starting a pane on top of that just dies on bind. Clear it first, so an
    # upgrade actually lands on the new build.
    if [[ -n "$port" ]] && lsof -i ":$port" -sTCP:LISTEN &>/dev/null; then
      action "Clearing   stray listener on :$port before starting $session"
      [[ -n "$proc_pattern" ]] && { kill_matching "$proc_pattern" || true; }
      kill_port_owner "$port" || true
    fi
    action "Starting   $session"
    tmux new-session -d -s "$session" "${dir_flag[@]}" "$cmd"
    [[ -n "$port" ]] && { wait_for_port "$session" "$port" "$wait_timeout" || true; }
    return 0
  fi

  # --restart: unconditionally recycle, even if the service looks healthy.
  # This is what an upgrade needs — "healthy" after `hermes update` just means
  # the *old* code is still serving.
  if (( FORCE_RESTART )); then
    action "Restarting $session (forced)"
    tmux kill-session -t "$session" 2>/dev/null || true
    [[ -n "$proc_pattern" ]] && { kill_matching "$proc_pattern" || true; }
    [[ -n "$port" ]] && { kill_port_owner "$port" || true; }
    sleep 1
    tmux new-session -d -s "$session" "${dir_flag[@]}" "$cmd"
    [[ -n "$port" ]] && { wait_for_port "$session" "$port" "$wait_timeout" || true; }
    return 0
  fi

  local pane_dead
  pane_dead=$(tmux list-panes -t "$session:0" -F '#{pane_dead}' 2>/dev/null | head -n1)

  if [[ "$pane_dead" == "1" ]]; then
    action "Respawning $session (pane dead)"
    tmux kill-session -t "$session" 2>/dev/null || true
    tmux new-session -d -s "$session" "${dir_flag[@]}" "$cmd"
    [[ -n "$port" ]] && { wait_for_port "$session" "$port" "$wait_timeout" || true; }
    return 0
  fi

  # port listening = genuinely healthy, no need to check further
  if [[ -n "$port" ]] && lsof -i ":$port" -sTCP:LISTEN &>/dev/null; then
    # ...unless we require a specific working directory and the live process
    # is running somewhere else (e.g. launchd/manual started it in $HOME or
    # the deploy dir). Relocate it to $start_dir.
    if [[ -n "$start_dir" ]] && ! port_cwd_matches "$port" "$start_dir"; then
      action "Restarting $session (running in wrong directory; want $start_dir)"
      tmux kill-session -t "$session" 2>/dev/null || true
      [[ -n "$proc_pattern" ]] && { kill_matching "$proc_pattern" || true; }
      tmux new-session -d -s "$session" "${dir_flag[@]}" "$cmd"
      [[ -n "$port" ]] && { wait_for_port "$session" "$port" "$wait_timeout" || true; }
      return 0
    fi
    ok "Running    $session"
    return
  fi

  # process alive but port not bound = stale process, restart
  if [[ -n "$port" ]] && ! lsof -i ":$port" -sTCP:LISTEN &>/dev/null; then
    action "Restarting $session (process alive but port not bound)"
    tmux kill-session -t "$session" 2>/dev/null || true
    tmux new-session -d -s "$session" "${dir_flag[@]}" "$cmd"
    [[ -n "$port" ]] && { wait_for_port "$session" "$port" "$wait_timeout" || true; }
    return 0
  fi

  ok "Running    $session"
}

# ---------------------------------------------------------------------------
# Kill all sessions
# ---------------------------------------------------------------------------
kill_all() {
  local -A proc_map
  proc_map=(gateway "gateway run" dashboard "hermes dashboard" paperclip "paperclipai" obsidian "ob sync")
  local sessions=("gateway" "dashboard" "paperclip" "obsidian")
  local any_killed=0

  # Unload the launchd job first or KeepAlive revives the gateway we kill.
  boot_out_launchd_gateway

  for session in "${sessions[@]}"; do
    local pattern="${proc_map[$session]}"

    # Kill tmux session if present
    if tmux has-session -t "$session" 2>/dev/null; then
      action "Killing    $session (tmux session)"
      tmux kill-session -t "$session"
      any_killed=$(( any_killed + 1 ))
    fi

    # Kill any loose service processes (e.g. launchd orphans). kill_matching
    # skips tmux itself — see its comment; a plain pkill here used to SIGKILL
    # the tmux server on the very first iteration.
    if kill_matching "$pattern"; then
      action "Killing    $session (loose process: $pattern)"
      any_killed=$(( any_killed + 1 ))
    fi

    ok "Done       $session"
  done

  if (( any_killed > 0 )); then
    ok "All services terminated"
  else
    info "No active sessions or processes found"
  fi
}

# ---------------------------------------------------------------------------
# Status summary
# ---------------------------------------------------------------------------
show_status() {
  print ""
  print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  print "${BOLD} Installed versions${RESET}"
  print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  printf "  ${BOLD}%-12s  %s${RESET}\n" "TOOL" "VERSION"
  print "  ─────────────────────────────────────────────────"

  local hermes_ver paperclip_ver
  if command -v hermes &>/dev/null; then
    hermes_ver=$(hermes --version 2>&1 | head -n1)
    printf "  ${GREEN}%-12s  %s${RESET}\n" "hermes" "$hermes_ver"
  else
    printf "  ${RED}%-12s  not found${RESET}\n" "hermes"
  fi

  if command -v npx &>/dev/null; then
    paperclip_ver=$(npx paperclipai --version 2>&1 | head -n1)
    printf "  ${GREEN}%-12s  %s${RESET}\n" "paperclipai" "$paperclip_ver"
  else
    printf "  ${RED}%-12s  not found${RESET}\n" "paperclipai"
  fi

  print ""
  print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  print "${BOLD} Session status${RESET}"
  print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  printf "  ${BOLD}%-12s  %-6s  %-6s  %s${RESET}\n" "SESSION" "PANE" "PID" "COMMAND"
  print "  ─────────────────────────────────────────────────"

  local sessions=("gateway" "dashboard" "paperclip" "obsidian")
  local pane_info pane_dead pane_pid proc_cmd child_pid full_cmd exe rest
  for session in "${sessions[@]}"; do
    if ! tmux has-session -t "$session" 2>/dev/null; then
      printf "  ${RED}%-12s  %-6s${RESET}\n" "$session" "absent"
      continue
    fi

    pane_info=$(tmux list-panes -t "$session:0" -F '#{pane_dead} #{pane_pid}' 2>/dev/null | head -n1)
    pane_dead="${pane_info%% *}"
    pane_pid="${pane_info##* }"

    if [[ "$pane_dead" == "1" ]]; then
      printf "  ${RED}%-12s  %-6s  %-6s${RESET}\n" "$session" "dead" "-"
    else
      proc_cmd=""
      if [[ -n "$pane_pid" ]] && kill -0 "$pane_pid" 2>/dev/null; then
        full_cmd=$(ps -o command= -p "$pane_pid" 2>/dev/null || true)
        local exe="${${full_cmd%% *}##*/}"
        # only chase children when the pane process is a shell wrapper
        if [[ "$exe" == (zsh|bash|sh|-zsh|-bash) ]]; then
          child_pid=$(pgrep -P "$pane_pid" 2>/dev/null | head -n1 || true)
          [[ -n "$child_pid" ]] && full_cmd=$(ps -o command= -p "$child_pid" 2>/dev/null || true)
        fi
        proc_cmd=$(print -- "$full_cmd" | awk '{for(i=1;i<=NF;i++){sub(/.*\//,"",$i)}; print}')
        proc_cmd="${proc_cmd[1,80]}"
      fi
      printf "  ${GREEN}%-12s  %-6s  %-6s  %s${RESET}\n" "$session" "alive" "$pane_pid" "$proc_cmd"
    fi
  done

  print ""
  print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  print "${BOLD} Port liveness${RESET}"
  print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  printf "  ${BOLD}%-12s  %-6s  %s${RESET}\n" "SESSION" "PORT" "STATUS"
  print "  ─────────────────────────────────────────────────"

  local -A port_map proc_map
  port_map=(gateway 8642 dashboard 9119 paperclip 3100)
  proc_map=(gateway "gateway run" dashboard "hermes dashboard" paperclip "paperclipai" obsidian "ob sync")

  for session in "${sessions[@]}"; do
    local port="${port_map[$session]:-}"
    local pattern="${proc_map[$session]}"
    if [[ -z "$port" ]]; then
      if pgrep -f "$pattern" &>/dev/null; then
        printf "  ${GREEN}%-12s  %-6s  ✓ running${RESET}\n" "$session" "none"
      else
        printf "  ${RED}%-12s  %-6s  ✗ not running${RESET}\n" "$session" "none"
      fi
    elif lsof -i ":${port}" -sTCP:LISTEN &>/dev/null; then
      printf "  ${GREEN}%-12s  %-6s  ✓ listening${RESET}\n" "$session" ":$port"
    elif pgrep -f "$pattern" &>/dev/null; then
      printf "  ${YELLOW}%-12s  %-6s  ⧖ starting up${RESET}\n" "$session" ":$port"
    else
      printf "  ${RED}%-12s  %-6s  ✗ not listening${RESET}\n" "$session" ":$port"
    fi
  done

  print "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  print ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
print ""
print "${BOLD}${CYAN}tmux-respawn-all${RESET}"
print ""

case "${1:-}" in
  --kill|-k)
    preflight
    print ""
    kill_all
    ;;
  --status|-s)
    preflight
    show_status
    ;;
  --help|-h)
    print "Usage: $(basename $0) [--status|-s] [--kill|-k] [--restart|-r] [--help|-h]"
    print ""
    print "  (no args)    Ensure all sessions are running, then show status"
    print "  --status,-s  Show status only (no changes): installed versions,"
    print "               session state, and port liveness"
    print "  --kill,-k    Kill all sessions (gateway, dashboard, paperclip)"
    print "  --restart,-r Recycle every session even if it looks healthy."
    print "               Use after an upgrade: a healthy service is still"
    print "               serving the old code."
    print "  --help,-h    Show this help"
    ;;
  --restart|-r)
    FORCE_RESTART=1
    ;&              # fall through to the normal ensure path
  "")
    preflight
    print ""
    # Anchor the tmux server to the workspace before creating any session. The
    # server keeps the cwd it was launched from (usually the deploy dir), and
    # every pane created without an explicit -c — including some gateway restart
    # paths — inherits it. That's how `pwd` inside the agent showed the deploy
    # dir. cd'ing here makes the workspace the server-wide default.
    cd /Users/colind/Documents/Jeffrey_Workspace 2>/dev/null \
      || warn "workspace dir missing; tmux server will default to $PWD"
    info "Ensuring sessions..."
    # zsh -ilc for the same nvm/PATH reason as the dashboard: the gateway
    # spawns node-based MCP servers via npx/node, and tmux's bare `sh -c`
    # hands them Homebrew's node instead of nvm's. Explicit cd + exec so the
    # cwd check below still sees the workspace and the pane process is hermes
    # itself, not a wrapper shell.
    # Pattern is "gateway run", not "hermes gateway": the launchd agent runs
    # `python -m hermes_cli.main gateway run` (plus a stderr_timestamp
    # wrapper), which "hermes gateway" never matched — same trap as the
    # dashboard-restart argv documented above kill_port_owner.
    boot_out_launchd_gateway
    # MCP startup can legitimately spend over a minute waiting for a failing
    # server connection to time out before the gateway binds its health port.
    ensure_session "gateway"   "zsh -ilc 'cd /Users/colind/Documents/Jeffrey_Workspace && exec hermes gateway run'"  8642  "gateway run"  "/Users/colind/Documents/Jeffrey_Workspace"  120
    # zsh -ilc, same reason as obsidian below: the dashboard's Chat tab shells
    # out to `npm install` for the TUI workspace, and hermes-agent's
    # package.json pins npm to "<11.10.0 || >=12.0.0". tmux's bare `sh -c`
    # misses the nvm PATH reorder in ~/.zshrc, so npm resolves to Homebrew's
    # (node 26.5.0 / npm 11.17.0 as of 2026-07-31) → EBADENGINE → the Chat tab
    # dies with "Chat unavailable: 1". A login+interactive shell picks up
    # nvm's node instead.
    #
    # The dashboard also rebuilds the web UI (vite) before it binds :9119. On a
    # cold cache — i.e. straight after `hermes update` — that alone can outrun
    # a 60s budget, so the old timeout reported a false failure on a perfectly
    # good start. Give it room.
    # Caddy runs on this host, so keep the dashboard on loopback. Uvicorn trusts
    # loopback proxy headers by default, which preserves HTTPS detection for the
    # OAuth PKCE cookie without broadening FORWARDED_ALLOW_IPS.
    ensure_session "dashboard" "zsh -ilc 'exec hermes --tui dashboard --host 127.0.0.1 --port 9119 --no-open'" 9119  "hermes dashboard" ""  240
    # zsh -ilc for the same nvm/PATH reason as the gateway and dashboard — this
    # was the last service still on tmux's bare `sh -c`. That shell puts
    # /opt/homebrew/bin ahead of nvm, so `npx` ran under Homebrew's node. When a
    # brew upgrade left node 26.5.0_1 linked against a libada.4.dylib that was no
    # longer installed, node died in dyld before executing a single line:
    #   dyld: Library not loaded: /opt/homebrew/opt/ada-url/lib/libada.4.dylib
    # The pane exited in well under a second — no log line, no bind — so the
    # whole session vanished and the failure looked like Paperclip crashing
    # rather than a broken interpreter. A login+interactive shell picks up nvm's
    # node, which is unaffected by Homebrew's dependency graph.
    ensure_session "paperclip" "zsh -ilc 'PAPERCLIP_LISTEN_HOST=100.111.59.2 PAPERCLIP_MIGRATION_AUTO_APPLY=true exec npx paperclipai run'" 3100  "paperclipai"
    # ob's native module (better-sqlite3) only dlopen's under a login+interactive
    # shell that sources nvm; tmux's bare `sh -c` does not, so run it via zsh -ilc.
    #
    # Wrapped in a retry loop: obsidian is the one portless service, so when
    # `ob sync` exits (e.g. a transient connect failure at cold start — its
    # startup path exits where its steady-state loop retries), the pane died
    # and tmux silently removed the whole session, showing "absent" with no
    # evidence. The loop self-heals and keeps the exit status in scrollback.
    ensure_session "obsidian"  "zsh -ilc 'while true; do ob sync --path \"\$HOME/Documents/Jeffrey_Workspace/Obsidian Vault\" --continuous; echo \"[respawn] ob sync exited (\$?); retrying in 10s\"; sleep 10; done'"  ""  "ob sync"
    show_status
    ;;
  *)
    fatal "Unknown argument: $1 (try --help)"
    ;;
esac
