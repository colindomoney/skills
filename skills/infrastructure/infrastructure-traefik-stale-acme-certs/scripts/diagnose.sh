#!/bin/bash
# Read-only diagnosis of Traefik's acme.json against live routers and served certs.
# Usage: sudo bash diagnose.sh [hostname ...]
# Env: ACME (default /var/lib/traefik/acme.json), RESOLVER (default letsencrypt), DYNAMIC (default /etc/traefik/dynamic)
set -uo pipefail
ACME=${ACME:-/var/lib/traefik/acme.json}
RESOLVER=${RESOLVER:-letsencrypt}
DYNAMIC=${DYNAMIC:-/etc/traefik/dynamic}

echo "== host: $(hostname)  IPv4: $(ip -4 -o addr show scope global | grep -vE ' (docker|br-|veth)' | awk '{print $2"="$4}' | cut -d/ -f1 | paste -sd' ')"

# Hostnames that a running container or the file provider currently routes.
routed=$( { docker ps -q | xargs -r docker inspect --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}'
            cat "$DYNAMIC"/* 2>/dev/null; } | grep -oE 'Host(SNI)?\(`[^`]+`\)' | sed -E 's/.*`([^`]+)`.*/\1/' | sort -u )
# Hostnames routed only by stopped containers (ignored now, retried if started).
stopped=$( docker ps -aq --filter status=exited --filter status=created | xargs -r docker inspect --format '{{.Name}} {{range $k,$v := .Config.Labels}}{{$v}} {{end}}' \
           | grep -oE '^/[^ ]+|Host\(`[^`]+`\)' | sed -E 's/Host\(`([^`]+)`\)/\1/' | paste -sd' ' | sed 's| /|\n/|g' | grep ' ' )

echo "== acme.json entries ($ACME, resolver $RESOLVER)"
echo "   flags: STORED!=CERT (renewal will change the names), UNROUTED:<name> (no running router), OVERLAP:<name> (name in >1 entry)"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
jq -r --arg r "$RESOLVER" '.[$r].Certificates[] | [.domain.main, ((.domain.sans // []) | join(",")), .certificate] | join("|")' "$ACME" |
while IFS='|' read -r main sans cert; do
  info=$(base64 -d <<<"$cert" | openssl x509 -noout -enddate -ext subjectAltName 2>/dev/null)
  certnames=$(grep -oE 'DNS:[^, ]+' <<<"$info" | sed 's/DNS://' | sort | paste -sd,)
  stored=$(printf '%s\n' "$main" ${sans//,/ } | sort -u | paste -sd,)
  echo "$main|$stored|$certnames|$(sed -n 's/notAfter=//p' <<<"$info")"
done > "$tmp"
dupes=$(cut -d'|' -f3 "$tmp" | tr ',' '\n' | sort | uniq -d)
while IFS='|' read -r main stored certnames end; do
  flags=""
  [ "$stored" != "$certnames" ] && flags+=" STORED!=CERT"
  for n in ${stored//,/ }; do grep -qxF "$n" <<<"$routed" || flags+=" UNROUTED:$n"; done
  for n in ${certnames//,/ }; do grep -qxF "$n" <<<"$dupes" && flags+=" OVERLAP:$n"; done
  printf '%-34s stored=[%s] cert=[%s] expires=%s%s\n' "$main" "$stored" "$certnames" "$end" "$flags"
done < "$tmp"

[ -n "$stopped" ] && { echo "== stopped containers still carrying Host() rules"; echo "$stopped"; }

echo "== renewal/issue failures, last 7 days (count, names)"
journalctl -u traefik --since -7d --no-pager 2>/dev/null | grep -oE 'from LE: \{[^}]*\}|for the domains \[[^]]*\]' | sort | uniq -c

for h in "$@"; do
  echo "== $h  DNS: $(dig +short "$h" | paste -sd' ')"
  echo | timeout 5 openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 -startdate -ext subjectAltName 2>/dev/null | grep -E 'Fingerprint|notBefore|DNS'
done
