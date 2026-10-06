#!/bin/sh
# Build, smoke-test, deploy, health-gate, prune. Run from the repo root on
# the Docker host (the Forgejo deploy job calls it on push to main).
#
# 1. Build the image, tagged with the commit SHA.
# 2. Smoke-test it in a throwaway container. Failure stops here; the live
#    container is untouched.
# 3. Swap the live container to the new tag.
# 4. Wait for the healthcheck. If it doesn't go healthy, roll back to the
#    previous tag and fail.
# 5. Keep the newest $KEEP tagged images, drop the rest and dangling layers.
#    Images that fail step 2 or 4 are deleted, so only good deploys are kept.
set -eu

PROJECT=${PROJECT:-site}
IMAGE=${IMAGE:-example.com}
CONTAINER=${CONTAINER:-site}
TAG=${TAG:-$(git rev-parse --short=12 HEAD)}
KEEP=${KEEP:-5}
PORT=${PORT:-4321}
SMOKE_PATHS=${SMOKE_PATHS:-"/ /api/public-config /robots.txt /sitemap-index.xml"}

log() { echo "==> $*"; }
discard() { docker rmi "$IMAGE:$TAG" >/dev/null 2>&1 || true; }

# Build through compose so its build.args (PUBLIC_* from .env) are applied.
log "Building $IMAGE:$TAG"
IMAGE_TAG=$TAG docker compose -p "$PROJECT" build

log "Smoke-testing $IMAGE:$TAG before deploy"
smoke="$CONTAINER-smoke-$$"
# tmpfs /data: the throwaway container never sees the live SQLite volume.
docker run -d --name "$smoke" --tmpfs /data "$IMAGE:$TAG" >/dev/null
trap 'docker rm -f "$smoke" >/dev/null 2>&1 || true' EXIT
# Node needs a moment to start listening.
i=0
until docker exec "$smoke" wget -q -O /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; do
  i=$((i + 1))
  [ $i -ge 20 ] && break
  sleep 1
done
for p in $SMOKE_PATHS; do
  if docker exec "$smoke" wget -q -O /dev/null "http://127.0.0.1:$PORT$p"; then
    echo "  ok   $p"
  else
    echo "  FAIL $p"
    docker rm -f "$smoke" >/dev/null 2>&1 || true
    discard
    exit 1
  fi
done
docker rm -f "$smoke" >/dev/null
trap - EXIT

prev=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)
case "$prev" in
  "") prev_tag= ;;
  *:*) prev_tag=${prev##*:} ;;
  *) prev_tag=latest ;;
esac

log "Deploying $IMAGE:$TAG (previous: ${prev_tag:-none})"
IMAGE_TAG=$TAG docker compose -p "$PROJECT" up -d --no-build

log "Waiting for $CONTAINER to be healthy"
status=missing
i=0
while [ $i -lt 30 ]; do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo missing)
  [ "$status" = healthy ] || [ "$status" = unhealthy ] && break
  i=$((i + 1))
  sleep 2
done

if [ "$status" != healthy ]; then
  echo "  $CONTAINER is $status"
  if [ -n "$prev_tag" ] && [ "$prev_tag" != "$TAG" ]; then
    log "Rolling back to $IMAGE:$prev_tag"
    IMAGE_TAG=$prev_tag docker compose -p "$PROJECT" up -d --no-build
  fi
  discard
  exit 1
fi
docker tag "$IMAGE:$TAG" "$IMAGE:latest"

log "Pruning: keeping the newest $KEEP $IMAGE tags"
docker images "$IMAGE" --format '{{.CreatedAt}}|{{.Tag}}' \
  | awk -F'|' '$2 != "latest" && $2 != "<none>"' \
  | sort -r \
  | tail -n +$((KEEP + 1)) \
  | cut -d'|' -f2 \
  | while read -r t; do
      docker rmi "$IMAGE:$t" >/dev/null 2>&1 && echo "  removed $t" || echo "  kept $t (in use)"
    done
docker image prune -f >/dev/null

log "Live: $IMAGE:$TAG"
