#!/bin/sh
# Recover Hindsight from the post-reboot crash loop where pg0 state files come back 0 bytes
# ("JSON error: EOF while parsing", then "lock file ... remnant of a previous server startup crash").
# Takes a cold tarball of the volume first, removes ONLY zero-byte state files, recreates.
# Usage: hindsight-reboot-recover.sh [snapshot-dir]
# Env: HINDSIGHT_CONTAINER, HINDSIGHT_VOLUME, HINDSIGHT_COMPOSE_DIR (default ~/Deployments/Hindsight)
set -eu
C=${HINDSIGHT_CONTAINER:-hindsight-hindsight-1}
VOL=${HINDSIGHT_VOLUME:-hindsight_hindsight_data}
OUT=${1:-$HOME/Backups/hermes/volumes}
IMG=$(docker inspect "$C" --format '{{.Config.Image}}')   # reuse the local image; a pull may need the keychain
SNAP="$OUT/hindsight-pg0-cold-$(date +%F-%H%M%S).tar.gz"
mkdir -p "$OUT"

docker stop "$C" >/dev/null
if ! docker run --rm --entrypoint sh -u 0 -v "$VOL":/v:ro "$IMG" -c 'tar czf - -C /v .' >"$SNAP" || [ ! -s "$SNAP" ]; then
  echo "snapshot failed; nothing changed" >&2; docker start "$C" >/dev/null; exit 1
fi
echo "cold snapshot: $SNAP ($(du -h "$SNAP" | cut -f1))"

docker run --rm --entrypoint sh -u 0 -v "$VOL":/v "$IMG" -c '
  cd /v/instances/hindsight
  for f in instance.json data/postmaster.pid data/postmaster.opts; do
    [ -e "$f" ] && [ ! -s "$f" ] && { echo "removing empty $f"; rm -f "$f"; }
  done; true'
# The stale /tmp/.s.PGSQL.5432.lock lives in the container's writable layer, which survives
# restarts. Recreating discards it. Safe only with a fixed HINDSIGHT_API_WORKER_ID in compose.
docker compose --project-directory "${HINDSIGHT_COMPOSE_DIR:-$HOME/Deployments/Hindsight}" up -d --force-recreate
echo "recreated; watch for 'PostgreSQL started' in: docker logs -f $C"
