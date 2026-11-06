#!/usr/bin/env bash
#
# Copy versioned agent content from the repo into the live Hermes home.
#
#   soul/<p>.md   -> hermes-home/profiles/<p>/SOUL.md
#   skills/<s>/   -> hermes-home/profiles/<p>/skills/<s>/   (see skills_for)
#   scripts/      -> hermes-home/profiles/<p>/scripts/
#
# hermes-home/ is bind-mounted, so changes are visible at once. New sessions
# pick them up: send /new to the bot. Restart after any hook change, because the
# gateway reads the allowlist at start.
#
# Idempotent. Never touches .env, config.yaml, auth.json, state.db or cron/.

set -euo pipefail
cd "$(dirname "$0")"
source ./project.conf
HOME_DIR="hermes-home"

[[ -d "$HOME_DIR" ]] || { echo "error: ${HOME_DIR}/ not found. Run ./bootstrap.sh first." >&2; exit 1; }

# rsync -a keeps mtimes, which the hook allowlist pins. macOS openrsync's
# --chmod differs from GNU rsync's, so modes are set afterwards.
sync_dir() {  # src dest filemode
  mkdir -p "$2"
  rsync -a --delete --exclude '__pycache__' "$1/" "$2/"
  find "$2" -type d -exec chmod 755 {} +
  find "$2" -type f -exec chmod "$3" {} +
}

for p in "${PROFILES[@]}"; do
  pdir="${HOME_DIR}/profiles/${p}"
  [[ -d "$pdir" ]] || { echo "==> ${p}: no profile yet, skipping"; continue; }
  echo "==> ${p}"
  if [[ -f "soul/${p}.md" ]]; then
    install -m 644 "soul/${p}.md" "${pdir}/SOUL.md"; echo "    SOUL.md"
  fi
  for s in $(skills_for "$p"); do
    [[ -d "skills/${s}" ]] || { echo "    skills/${s}/ missing" >&2; continue; }
    sync_dir "skills/${s}" "${pdir}/skills/${s}" 644; echo "    skills/${s}/"
  done
  if [[ -d scripts ]] && compgen -G "scripts/*" >/dev/null; then
    sync_dir scripts "${pdir}/scripts" 755; echo "    scripts/"
  fi
done

# Re-seed the hook allowlist last: entries pin each script's mtime at approval,
# and any later edit makes the hook go silently inert.
if [[ -n "$HOOKS" ]]; then
  python3 - "$HOME_DIR" "$HOOKS" <<'PY'
import json, os, sys
from datetime import datetime, timezone

home, spec = sys.argv[1:3]

def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat().replace("+00:00", "Z")

by_profile = {}
for line in filter(None, (l.strip() for l in spec.splitlines())):
    profile, event, script, _ = (line.split("|") + [""])[:4]
    by_profile.setdefault(profile, []).append((event, script))

for profile, wanted in by_profile.items():
    pdir = os.path.join(home, "profiles", profile)
    path = os.path.join(pdir, "shell-hooks-allowlist.json")
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        data = {}
    cmd = lambda s: f"/opt/hermes/.venv/bin/python /opt/data/profiles/{profile}/scripts/{s}"
    ours = {(e, cmd(s)) for e, s in wanted}
    approvals = [a for a in data.get("approvals", []) if (a.get("event"), a.get("command")) not in ours]
    for event, script in wanted:
        approvals.append({
            "approved_at": iso(datetime.now(timezone.utc).timestamp()),
            "command": cmd(script),
            "event": event,
            "script_mtime_at_approval": iso(os.path.getmtime(os.path.join(pdir, "scripts", script))),
        })
    json.dump({"approvals": approvals}, open(path, "w"), indent=2, sort_keys=True)
    os.chmod(path, 0o600)
PY
  echo "==> hook allowlist re-seeded: docker compose restart to apply"
fi
echo "done."
