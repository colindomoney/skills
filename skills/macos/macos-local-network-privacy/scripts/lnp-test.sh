#!/bin/sh
# Local Network privacy probe: connect to <ipv4> <port> twice with an ad hoc binary.
#   1. from the current shell   (inherits this shell's responsible process)
#   2. as a launchd job         (self-responsible, ungrantable: the failing case)
# EHOSTUNREACH ("No route to host") on 2 and ok on 1 = LNP denial, not networking.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <ipv4> <port>" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
C=${XDG_CACHE_HOME:-$HOME/.cache}/lnp-probe; mkdir -p "$C"
[ "$C/lnp-probe" -nt "$HERE/lnp-probe.c" ] || clang -O2 -o "$C/lnp-probe" "$HERE/lnp-probe.c"
echo "== current shell"; "$C/lnp-probe" "$1" "$2" || true
rm -f "$C/out"; launchctl remove lnp-probe 2>/dev/null || true
launchctl submit -l lnp-probe -o "$C/out" -e "$C/out" -- "$C/lnp-probe" "$1" "$2"
i=0; until [ -s "$C/out" ] || [ $i -ge 20 ]; do sleep 1; i=$((i+1)); done
launchctl remove lnp-probe 2>/dev/null || true
echo "== self-responsible launchd job"; cat "$C/out"
