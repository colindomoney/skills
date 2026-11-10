#!/usr/bin/env bash
# Local proof stack: the site's own docker-compose.yml (with its Traefik labels)
# behind a throwaway Traefik container on 127.0.0.1:18080 (web) / :18443 (websecure).
#
#   local-traefik.sh up   <repo-dir>   build + start site and Traefik, wait for health
#   local-traefik.sh down <repo-dir>   remove both and the project's volumes
#
# Then test with the production Host header and NO port, or redirectregex rules
# that match on the hostname will not fire:
#   curl -sk --resolve example.com:18443:127.0.0.1 -H 'Host: example.com' https://example.com:18443/
#   python3 crawl.py https://example.com --map 18443 --stub analytics.example.net
#
# Uses traefik:v3.6 (latest 3.6 patch). traefik:v3.6.0 cannot talk to Docker
# Desktop 29's API from a container (provider error "400 Bad Request").
# "Router uses a nonexistent certificate resolver" errors are expected: ACME
# does not run locally and Traefik serves its default cert instead.
set -euo pipefail
cmd=${1:?up|down}; dir=${2:?repo dir}
project=${PROJECT:-hardening-proof}
traefik_image=${TRAEFIK_IMAGE:-traefik:v3.6}
cd "$dir"

case "$cmd" in
up)
  docker compose -p "$project" build -q
  docker compose -p "$project" up -d
  docker run -d --name "$project-traefik" --network "${project}_default" \
    -p 127.0.0.1:18080:80 -p 127.0.0.1:18443:443 \
    -v /var/run/docker.sock:/var/run/docker.sock:ro "$traefik_image" \
    --providers.docker=true --providers.docker.exposedbydefault=false \
    --entrypoints.web.address=:80 --entrypoints.websecure.address=:443 --log.level=INFO >/dev/null
  for _ in $(seq 1 30); do
    ids=$(docker compose -p "$project" ps -q)
    states=$(for i in $ids; do docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$i"; done | sort -u)
    [ "$states" = healthy ] || [ "$states" = running ] && break
    sleep 2
  done
  echo "site: $states"
  echo "Traefik errors other than the expected resolver ones:"
  docker logs "$project-traefik" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E ' (ERR|WRN) ' | grep -v 'nonexistent certificate resolver' || echo "  none"
  ;;
down)
  docker rm -f "$project-traefik" >/dev/null 2>&1 || true
  docker compose -p "$project" down -v
  ;;
*) echo "usage: $0 up|down <repo-dir>" >&2; exit 2 ;;
esac
