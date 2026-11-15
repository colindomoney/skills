#!/bin/sh
# Run pg_dump or psql against Hindsight's embedded Postgres (pg0) inside the container,
# reading credentials from pg0's instance.json so nothing is printed.
# Usage:
#   hindsight-pg.sh dump > hindsight-$(date +%F-%H%M%S).dump     # custom-format dump; check it starts with PGDMP
#   hindsight-pg.sh sql < query.sql                              # run SQL from stdin
# Env: HINDSIGHT_CONTAINER (default hindsight-hindsight-1)
set -eu
C=${HINDSIGHT_CONTAINER:-hindsight-hindsight-1}
mode=${1:?usage: hindsight-pg.sh dump|sql}

# shellcheck disable=SC2016  # expanded inside the container
run='
I=/home/hindsight/.pg0/instances/hindsight/instance.json
v=$(ls /home/hindsight/.pg0/installation | sort -V | tail -1); B=/home/hindsight/.pg0/installation/$v/bin
get() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$I" "$1"; }
export PGPASSWORD=$(get password)
conn="-h 127.0.0.1 -p $(get port) -U $(get username) -d $(get database)"
'
case "$mode" in
  dump) docker exec "$C" sh -c "$run"'exec "$B/pg_dump" $conn -Fc' ;;
  sql)  docker exec -i "$C" sh -c "$run"'exec "$B/psql" $conn -X -A -F" | " -f -' ;;
  *) echo "usage: hindsight-pg.sh dump|sql" >&2; exit 2 ;;
esac
