#!/bin/sh
# Read-only health probe for a local Hindsight server used by Hermes.
# Usage: hindsight-health.sh [container-name]
# Env: HINDSIGHT_URL (default http://localhost:8888), HINDSIGHT_BANK (default hermes),
#      HERMES_VENV (Hermes venv to compare hindsight_client against; auto-detected if unset)
set -eu
BASE=${HINDSIGHT_URL:-http://localhost:8888}
BANK=${HINDSIGHT_BANK:-hermes}
CONTAINER=${1:-hindsight-hindsight-1}

echo "== server version"
curl -sf "$BASE/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["api_version"])' || echo "server unreachable at $BASE"

echo "== hindsight_client in Hermes venv (must match the server)"
find "${HERMES_VENV:-$HOME/.hermes/installs}" -maxdepth 9 -type d -name 'hindsight_client-*.dist-info' 2>/dev/null \
  | sed 's#.*/hindsight_client-##; s#\.dist-info##' | sort -u | grep . || echo "hindsight_client not found"

echo "== stats ($BANK)"
curl -sf "$BASE/v1/default/banks/$BANK/stats" | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k: d.get(k) for k in ("total_nodes","total_documents","total_observations","last_consolidated_at","pending_consolidation","failed_consolidation","pending_operations","failed_operations")})' || true

for s in pending processing failed; do
  echo "== ops: $s"
  curl -sf "$BASE/v1/default/banks/$BANK/operations?status=$s&limit=20" | python3 -c 'import json,sys; [print(o["id"], o["task_type"], o["created_at"][:19], (o.get("error_message") or "")[:80]) for o in json.load(sys.stdin)["operations"]]' || true
done

echo "== container"
docker inspect "$CONTAINER" --format 'image={{.Config.Image}} shm={{.HostConfig.ShmSize}} restarts={{.RestartCount}} status={{.State.Status}}' || true
docker exec "$CONTAINER" printenv HINDSIGHT_API_WORKER_ID 2>/dev/null || echo "HINDSIGHT_API_WORKER_ID unset (defaults to container hostname)"
