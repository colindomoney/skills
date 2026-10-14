#!/bin/zsh
# Local Network privacy probe for a tmux server started over SSH.
#   lnp-test.sh start  -> spawns tmux server, probes now and 15s later
#   lnp-test.sh check  -> prints results and cleans up
TMUX_BIN=/opt/homebrew/bin/tmux
NODE=/Users/colind/.nvm/versions/node/v24.13.0/bin/node

probe() {
  "$NODE" -e '
require("net").connect(22, "192.168.18.6")
  .on("connect", () => { console.log("ok"); process.exit() })
  .on("error",   e  => { console.log(e.message); process.exit() })
' > "$1" 2>&1
}

case "$1" in
  start)
    rm -f /tmp/lnp-live.out /tmp/lnp-after.out
    "$TMUX_BIN" -L lnptest new-session -d "$0 probe /tmp/lnp-live.out; sleep 15; $0 probe /tmp/lnp-after.out; sleep 5"
    echo "started - wait 20s then run: ssh hermes /tmp/lnp-test.sh check"
    ;;
  probe)
    probe "$2"
    ;;
  gateway)
    # probe from inside the live gateway session (inherits its tmux server)
    rm -f /tmp/lnp-gw.out
    "$TMUX_BIN" new-window -d -t gateway: "$0 probe /tmp/lnp-gw.out"
    for _ in {1..10}; do [[ -s /tmp/lnp-gw.out ]] && break; sleep 1; done
    echo "gateway: $(cat /tmp/lnp-gw.out 2>/dev/null || echo missing)"
    rm -f /tmp/lnp-gw.out
    ;;
  check)
    echo "live:  $(cat /tmp/lnp-live.out 2>/dev/null || echo missing)"
    echo "after: $(cat /tmp/lnp-after.out 2>/dev/null || echo missing)"
    "$TMUX_BIN" -L lnptest kill-server 2>/dev/null
    rm -f /tmp/lnp-live.out /tmp/lnp-after.out
    ;;
  *)
    echo "usage: $0 start|check"
    ;;
esac
