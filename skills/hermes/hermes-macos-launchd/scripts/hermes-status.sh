#!/usr/bin/env bash
# Read-only status of a launchd-managed Hermes Agent install on macOS.
# Shows launchd jobs, real gateway/dashboard PIDs, listeners, version,
# toolchain drift in the plists, and platform entries in gateway_state.json.
set -uo pipefail
H="${HERMES_HOME:-$HOME/.hermes}"; LA="${HERMES_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"; uid=$(id -u)
HERMES="$H/hermes-agent/.hermes/bin/hermes"

echo "== host: $(hostname)"
[ -x "$HOME/Deployments/tmux/tmux-respawn-all.sh" ] && echo "!! tmux stack present: this is the central host, use hermes-tmux-stack"

echo "== version"; "$HERMES" --version 2>&1 | head -1

echo "== launchd"
launchctl list | awk 'NR==1 || /ai\.hermes|nousresearch\.hermes/'
for j in dashboard gateway; do
  launchctl print "gui/$uid/ai.hermes.$j" 2>/dev/null | awk -v j=$j '/^\tstate =|^\truns =|^\tlast exit code/{gsub(/^\t/,""); printf "%s: %s\n", j, $0}'
done

echo "== gateway_state.json"
python3 -I - "$H/gateway_state.json" <<'EOF'
import json, sys, os
try: d = json.load(open(sys.argv[1]))
except Exception as e: print("unreadable:", e); sys.exit()
pid = d.get("pid"); alive = False
try: os.kill(pid, 0); alive = True
except Exception: pass
print(f"pid {pid} ({'alive' if alive else 'DEAD'}) state={d.get('gateway_state')} version={d.get('code_version')} updated={d.get('updated_at')}")
for k, v in (d.get("platforms") or {}).items():
    print(f"  platform {k}: {v.get('state')} {v.get('error_code') or ''} since={v.get('retrying_since') or v.get('updated_at')}")
if not d.get("platforms"): print("  no platforms (gateway runs cron/kanban only; no :8642)")
EOF

echo "== listeners (hermes python)"
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1 ~ /^python/ {print $2, $9}' | while read -r pid addr; do
  printf '%-7s %-22s %s\n' "$pid" "$addr" "$(ps -ww -o command= -p "$pid" | grep -oE '(gateway run|dashboard|serve)( .*)?$' | cut -c1-70)"
done

echo "== toolchain drift (plist PATH entries that no longer exist)"
for p in "$LA"/ai.hermes.*.plist; do
  /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' "$p" 2>/dev/null | tr ':' '\n' | grep "$H/tools/" | while read -r d; do
    [ -d "$d" ] || echo "MISSING $(basename "$p"): $d"
  done
  for t in python node; do
    pinned=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' "$p" 2>/dev/null | tr ':' '\n' | grep -oE "tools/$t-[^/]+" | head -1)
    newest=$(cd "$H/tools" && ls -d $t-* 2>/dev/null | sort -V | tail -1)
    [ -n "$pinned" ] && [ "tools/$newest" != "$pinned" ] && echo "STALE $(basename "$p"): $pinned (newest: $newest)"
  done
done
echo "(no output above = no drift)"
