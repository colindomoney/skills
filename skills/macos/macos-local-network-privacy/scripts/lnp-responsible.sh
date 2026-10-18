#!/bin/sh
# Print the responsible PID for each given PID (default: this shell and its ancestry).
# resp == own PID is normal for a GUI app (kitty, Terminal). For a bare CLI binary
# (herdr, tmux, node) it means no grantable app is behind it: LAN connects are denied.
# resp -1 = not queryable (setuid binaries such as /usr/bin/login).
set -eu
pids=${*:-}
if [ -z "$pids" ]; then p=$$; while [ "$p" -gt 1 ]; do pids="$pids $p"; p=$(ps -o ppid= -p "$p" | tr -d ' '); done; fi
for p in $pids; do
  r=$(python3 -I -c 'import ctypes,sys
f=ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
f.argtypes=[ctypes.c_int]; f.restype=ctypes.c_int; print(f(int(sys.argv[1])))' "$p")
  printf '%-7s resp %-7s %s | started %s\n' "$p" "$r" "$(ps -o comm= -p "$p")" "$(ps -o lstart= -p "$p")"
done
