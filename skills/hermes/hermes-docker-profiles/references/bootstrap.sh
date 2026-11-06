#!/usr/bin/env bash
#
# Stand up the agent. Idempotent: re-run it until it stops halting.
# It halts wherever a human is needed: provider login, bot tokens, MCP OAuth.
# Everything goes through `docker exec` into the running container, never
# `docker compose run`, which boots a second s6 tree.
#
#   ./bootstrap.sh             # continue from wherever things are
#   ./bootstrap.sh --verify    # one chat turn per profile, then the evidence
#   REBUILD=1 ./bootstrap.sh   # rebuild the image first

set -euo pipefail
cd "$(dirname "$0")"
source ./project.conf
CONTAINER="$PROJECT"
HOME_DIR="hermes-home"

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    ok   %s\n' "$1"; }
skip() { printf '    skip %s\n' "$1"; }
warn() { printf '    WARN %s\n' "$1"; }

halt_for_human() {
  printf '\n\033[1;33m--- needs you ---\033[0m\n%s\n\nThen run ./bootstrap.sh again.\n\n' "$1"
  exit 2
}

container_up() { docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; }
hermes_in()    { docker exec --user hermes -e HOME=/opt/data "$CONTAINER" hermes "$@" 2>&1; }
python_in()    { docker exec -i --user hermes -e HOME=/opt/data "$CONTAINER" /opt/hermes/.venv/bin/python - "$@"; }

# Lines pasted from indented instructions arrive with spaces; `export KEY=` counts.
has_key() { grep -qE "^[[:space:]]*(export[[:space:]]+)?${2}=.+" "$1" 2>/dev/null; }

# Shape check only: prints length and ok/bad. The value never leaves awk.
key_shape() {  # file key regex
  awk -v k="$2" -v re="$3" '
    { line = $0; sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line) }
    index(line, k "=") == 1 { v = substr(line, length(k) + 2); gsub(/["'"'"' \r]/, "", v); print length(v), (v ~ re) ? "ok" : "bad"; found = 1; exit }
    END { if (!found) print 0, "missing" }' "$1"
}

if [[ "${1:-}" == "--verify" ]]; then
  step "One chat turn per profile"
  for p in "${PROFILES[@]}"; do
    ans=$(hermes_in -p "$p" chat -q "who are you, one line?" -Q \
          | grep -v '^session_id:\|⚠\|^[[:space:]]*$' | tail -1)
    printf '    %-12s %s\n' "$p" "${ans:0:110}"
  done
  step "Who is being served"
  hermes_in profile list | sed 's/^/    /'
  docker logs --tail 300 "$CONTAINER" 2>&1 | grep -i '409 conflict' && warn "409 conflict: two pollers on one token" || ok "no 409 conflict"
  [[ -z "$HOOKS" ]] || for p in "${PROFILES[@]}"; do hermes_in -p "$p" hooks doctor | tail -6 | sed "s/^/    $p: /"; done
  exit 0
fi

step "Preflight"
for tool in docker git python3 rsync; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "error: docker daemon not reachable" >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "error: docker compose v2 required" >&2; exit 1; }
[[ "$PROJECT" != "PROJECT" ]] || { echo "error: edit project.conf first" >&2; exit 1; }
ok "tools present"

step "Image and directories"
if docker image inspect "${PROJECT}:dev" >/dev/null 2>&1 && [[ "${REBUILD:-}" != "1" ]]; then
  skip "image built (REBUILD=1 to force)"
else
  docker compose build 2>&1 | tail -2 | sed 's/^/    /'; ok "built"
fi
mkdir -p "$HOME_DIR" "${DATA_DIRS[@]}"
chmod 700 "$HOME_DIR"

# With no token anywhere the root gateway polls nothing, so it's safe to start
# before any login. The image seeds the home on first boot.
step "Container"
if container_up; then skip "running"; else docker compose up -d >/dev/null 2>&1; ok "started"; fi
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  hermes_in --version >/dev/null 2>&1 && [[ -f "${HOME_DIR}/config.yaml" ]] && break
  sleep 3
done
hermes_in --version | head -1 | sed 's/^/    /'

step "Provider login (root: profiles fall back to it)"
if [[ -f "${HOME_DIR}/auth.json" ]]; then
  chmod 600 "${HOME_DIR}/auth.json"; skip "auth.json present"
else
  halt_for_human "H1. The provider login is interactive. Pick a cheap default model.

  docker exec -it --user hermes -e HOME=/opt/data ${CONTAINER} hermes setup --portal

If it hangs trying to open a browser, use 'hermes model --no-browser' instead.
If it ends with FileExistsError on /opt/data, the token was already saved.
Other providers: put their API key in ${HOME_DIR}/.env by hand."
fi

step "Profiles"
for p in "${PROFILES[@]}"; do
  pdir="${HOME_DIR}/profiles/${p}"
  if [[ -d "$pdir" ]]; then
    skip "$p exists"
  else
    out=$(hermes_in profile create "$p" --no-skills --description "$(description_for "$p")") || {
      echo "$out" | tail -5 >&2; exit 1; }
    ok "created $p"
  fi
  touch "${pdir}/.env"; chmod 600 "${pdir}/.env"
  rm -f "${pdir}/auth.json"   # a stale copy shadows the root login and can revoke it
done

step "Profile settings"
changed=0
for p in "${PROFILES[@]}"; do
  result=$(python_in "$p" "$(cwd_for "$p")" "$(model_for "$p")" "$(disabled_for "$p")" "$HOOKS" <<'PY'
import io, sys
from ruamel.yaml import YAML      # the image has ruamel.yaml, not PyYAML
profile, cwd, model, disabled, hooks = sys.argv[1:6]
path = f"/opt/data/profiles/{profile}/config.yaml"
y = YAML()
def dump(data):
    buf = io.StringIO(); y.dump(data, buf); return buf.getvalue()
c = y.load(open(path)) or {}
before = dump(c)
# A new profile gets its own seeded model block, so it doesn't follow the root
# login. Carry the root's choice across, then apply any per-profile pin.
root = y.load(open("/opt/data/config.yaml")) or {}
if root.get("model") and dict(c.get("model") or {}) != dict(root["model"]):
    c["model"] = dict(root["model"])      # plain dict: drops the root file's comments
if model:
    c.setdefault("model", {})["default"] = model
d = c.setdefault("display", {})
d["tool_progress"] = "off"                # no chat message per tool call
d["interim_assistant_messages"] = "off"
d["show_reasoning"] = False
d["busy_input_mode"] = "queue"            # each message gets its own turn
c.setdefault("telegram", {})["gateway_restart_notification"] = False
t = c.setdefault("terminal", {})
t["cwd"] = cwd
t["home_mode"] = "real"                   # one HOME for gateway, cron and nested chat
c.setdefault("agent", {})["disabled_toolsets"] = sorted(disabled.split())
ours = {}
for line in filter(None, (l.strip() for l in hooks.splitlines())):
    who, event, script, matcher = (line.split("|") + [""])[:4]
    if who == profile:
        entry = {"command": f"/opt/hermes/.venv/bin/python /opt/data/profiles/{profile}/scripts/{script}", "timeout": 60}
        if matcher:
            entry["matcher"] = matcher
        ours.setdefault(event, []).append(entry)
if ours:
    c["hooks"] = ours
    c["hooks_auto_accept"] = True         # no TTY in the gateway for the consent prompt
after = dump(c)
if after != before:
    open(path, "w").write(after)
    print("changed")
PY
  )
  if [[ "$result" == "changed" ]]; then ok "$p updated"; changed=1; else skip "$p unchanged"; fi
done

step "Agent content"
./deploy.sh | sed 's/^/    /'

step "Bot credentials"
for p in "${BOT_PROFILES[@]}"; do
  envf="${HOME_DIR}/profiles/${p}/.env"
  if has_key "$envf" TELEGRAM_BOT_TOKEN && has_key "$envf" TELEGRAM_ALLOWED_USERS; then
    read -r len shape < <(key_shape "$envf" TELEGRAM_BOT_TOKEN '^[0-9]+:[A-Za-z0-9_-]+$')
    [[ "$shape" == ok ]] && ok "$p: token set (${len} chars, shape OK)" || warn "$p: token doesn't look like <digits>:<secret>"
    read -r len shape < <(key_shape "$envf" TELEGRAM_ALLOWED_USERS '^[0-9,]+$')
    [[ "$shape" == ok ]] && ok "$p: allowed users numeric" || warn "$p: TELEGRAM_ALLOWED_USERS should be numeric ids"
  else
    halt_for_human "H2. Secrets never pass through an agent, a transcript or shell history.
Edit the file directly, not with 'echo >>'.

  1. Telegram: @BotFather, /newbot. One new bot per profile: one token, one poller.
  2. Your numeric user id, from @userinfobot.
  3. Add to ${envf}:

       TELEGRAM_BOT_TOKEN=<token>
       TELEGRAM_ALLOWED_USERS=<numeric id>"
  fi
done

step "Dashboard (optional)"
DASH_ENV="${HOME_DIR}/dashboard.env"
if has_key "$DASH_ENV" HERMES_DASHBOARD_BASIC_AUTH_USERNAME && has_key "$DASH_ENV" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD; then
  chmod 600 "$DASH_ENV"
  has_key "$DASH_ENV" HERMES_DASHBOARD || { printf 'HERMES_DASHBOARD=1\n' >> "$DASH_ENV"; changed=1; }
  if ! has_key "$DASH_ENV" HERMES_DASHBOARD_BASIC_AUTH_SECRET; then
    printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' "$(python3 -c 'import secrets; print(secrets.token_hex(32))')" >> "$DASH_ENV"
    changed=1
  fi
  ok "credentials present: http://127.0.0.1:9119"
else
  skip "off. To enable, add HERMES_DASHBOARD_BASIC_AUTH_USERNAME and _PASSWORD to ${DASH_ENV} by hand"
fi

step "Apply"
# `up -d` recreates the container only if compose or env_file changed; restart
# covers config, tokens and hooks, which the gateway reads at start.
docker compose up -d >/dev/null 2>&1
if [[ "$changed" == 1 || "${RESTART:-}" == 1 ]]; then
  docker compose restart >/dev/null 2>&1; ok "restarted"
else
  skip "no settings changed (RESTART=1 after adding tokens)"
fi

printf '\nDone. MCP servers using OAuth: see SKILL.md. Then ./bootstrap.sh --verify\n'
