#!/bin/bash
# Edit Traefik's acme.json safely: stop Traefik, back up, edit a copy, validate, write back keeping owner/mode, always restart.
# Usage: sudo bash acme-edit.sh drop  <main> [<main> ...]           remove entries by stored domain.main
#        sudo bash acme-edit.sh rekey <current-main> <new-main> [<san> ...]   set an entry's stored names (what renewal requests)
# Env: ACME (default /var/lib/traefik/acme.json), RESOLVER (default letsencrypt)
set -euo pipefail
ACME=${ACME:-/var/lib/traefik/acme.json}
RESOLVER=${RESOLVER:-letsencrypt}
op=${1:?usage: drop|rekey ...}; shift
[ $# -ge 1 ] || { echo "missing hostnames"; exit 2; }
BAK="$ACME.bak-$(date +%Y%m%d-%H%M%S)"
count() { jq --arg r "$RESOLVER" '.[$r].Certificates | length' "$1"; }

systemctl stop traefik
trap 'systemctl start traefik' EXIT
cp -a "$ACME" "$BAK"

case "$op" in
  drop)
    jq --arg r "$RESOLVER" '.[$r].Certificates |= map(select(.domain.main as $m | ($ARGS.positional | index($m)) == null))' \
      "$BAK" --args "$@" > "$ACME.new"
    removed=$(( $(count "$BAK") - $(count "$ACME.new") ))
    if [ "$removed" -ne $# ]; then
      echo "Expected to remove $# entries, would remove $removed; acme.json unchanged"; rm -f "$ACME.new"; exit 1
    fi ;;
  rekey)
    cur=$1; new=${2:?new main}; shift 2
    matches=$(jq --arg r "$RESOLVER" --arg c "$cur" '[.[$r].Certificates[] | select(.domain.main == $c)] | length' "$BAK")
    [ "$matches" -eq 1 ] || { echo "Expected 1 entry with main=$cur, found $matches; acme.json unchanged"; exit 1; }
    jq --arg r "$RESOLVER" --arg c "$cur" --arg n "$new" \
      '(.[$r].Certificates[] | select(.domain.main == $c) | .domain) = {main: $n, sans: $ARGS.positional}' \
      "$BAK" --args "$@" > "$ACME.new" ;;
  *) echo "unknown op: $op"; exit 2 ;;
esac

jq -e . "$ACME.new" >/dev/null
cat "$ACME.new" > "$ACME"
rm -f "$ACME.new"
echo "Done ($op). Entries: $(count "$BAK") -> $(count "$ACME"). Backup: $BAK"
echo "Rollback: sudo systemctl stop traefik && sudo cp -a '$BAK' '$ACME' && sudo systemctl start traefik"
