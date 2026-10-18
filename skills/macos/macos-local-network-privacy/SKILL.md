---
name: macos-local-network-privacy
description: Diagnose and fix macOS Local Network Privacy (LNP) denials, where CLI tools, MCP servers, node or python inside herdr, tmux, a launchd agent or a long-lived terminal multiplexer get EHOSTUNREACH / "No route to host" / errno 65 (sometimes ECONNREFUSED) for LAN IPs while curl, ssh and the same command in a fresh terminal window work. Fix is the Apple TN3179 AllowedEthernetLocalNetworkAddresses / AllowedWiFiLocalNetworkAddresses allowlist. Use when "it used to work", "herdr can't access the network", "can't reach the LAN from herdr", "Home Assistant unreachable", "MCP server can't reach Home Assistant", "homelab hosts unreachable from the Mac", "No route to host but ping works", or when a process's responsible PID is itself.
license: MIT
metadata:
  author: colindomoney
  tags: "macos, local-network-privacy, launchd, herdr, tmux, codesign, tn3179"
  version: "0.1.0"
  last-verified: "2026-10-18"
  status: live
---

# macOS Local Network Privacy denials

macOS (15+) charges every LAN `connect()` to the process's **responsible process**. That's fixed at spawn and inherited across fork/exec/setsid, and reparenting to launchd doesn't change it. A long-lived server (herdr, tmux, a daemon) that outlives the terminal that spawned it, or was started by launchd, becomes its own responsible process. If it is an ad hoc, linker-signed binary with no bundle ID, it can't be listed, prompted or granted, so every non-platform binary under it gets a silent `EHOSTUNREACH`. Apple binaries (`/usr/bin/curl`, `nc`, `ssh`) are exempt, so it looks like a partial network fault. The fix is the Apple-documented, identity-independent address allowlist, not re-signing.

## When to use / when not to

- Use when: LAN connects fail from inside a multiplexer, agent or daemon but work from a fresh terminal window; the failure started after the terminal app was restarted or the server was upgraded or handed off.
- Don't use when: connects also fail from a fresh Terminal.app window (real network fault), or the target is a tailnet `100.x` address (outside LNP by definition: utun is not a local network). For the Hermes tmux stack specifically see `hermes-tmux-stack`.

## Scripts

- `scripts/lnp-responsible.sh [pid...]`: responsible PID and start time for each PID (default: this shell's ancestry).
- `scripts/lnp-test.sh <ipv4> <port>`: builds an **ad hoc** probe (`scripts/lnp-probe.c`) into `~/.cache/lnp-probe` and connects twice: from the current shell, then as a self-responsible `launchctl submit` job. The second run is the control for the failing case.

## Steps

1. **Confirm it's LNP, not networking.** From a fresh terminal-app window (not inside the multiplexer):
   ```sh
   scripts/lnp-test.sh 192.168.16.7 8123
   ```
   Denial signature: `current shell ... connect ok` and `self-responsible launchd job ... connect No route to host`.
2. **Find who the server is charged to.**
   ```sh
   scripts/lnp-responsible.sh $(pgrep -f 'herdr server')   # or tmux server, etc.
   ps -o pid,lstart,command -p "$(pgrep -f '/Applications/kitty.app' | paste -sd, -)"
   codesign -dvvv "$(command -v herdr)" 2>&1 | egrep 'Identifier|Signature|flags'
   ```
   Server `resp` == its own PID, `Signature=adhoc`, and a start time earlier than every running terminal-app process confirms it: the spawning terminal is gone and the server can't be granted.
3. **Get the real subnet.** Don't guess a /24:
   ```sh
   ipconfig getsummary en0 | grep subnet_mask; ifconfig | grep 'inet .*netmask'
   ```
4. **Write the allowlist** (TN3179, macOS 15.5+). The user must run it in their own terminal window: sudo needs a TTY. One line, so a wrapped paste can't split it:
   ```sh
   sudo sh -c 'for k in AllowedEthernetLocalNetworkAddresses AllowedWiFiLocalNetworkAddresses; do defaults write com.apple.network.local-network $k -array "192.168.16.0/22"; done && defaults read com.apple.network.local-network'
   ```
   The values are CIDR strings, and you can pass several to `-array`. Every process on the Mac can then reach those networks without consent.
5. **Reboot.** It's required; the keys aren't read live.
6. **Verify** (below), then check the real tool from inside the multiplexer, then quit and reopen the terminal app and check again.

Undo: `sudo defaults delete com.apple.network.local-network AllowedEthernetLocalNetworkAddresses` (and the `WiFi` key), then reboot.

Stopgap with no sudo or reboot: stop the server and restart it from a live terminal-app window (`herdr server stop; herdr`). This kills every pane and remote session, and it breaks again when the terminal app quits.

## Gotchas

- **The control must be ad hoc.** python.org's Python is Developer ID-signed and can hold its own grant, so as a self-responsible launchd job it *connects* and proves nothing. Use the compiled probe.
- **Testing from a multiplexer pane after the reboot proves nothing.** The reboot means the terminal app respawns the server, so panes work for a while with or without the fix. Only the launchd-job probe isolates the allowlist.
- **`!` / non-interactive shells can't run sudo** ("a terminal is required to read the password"). Hand the command to the user to run in a real terminal window.
- **Line-wrapped pastes split the command.** The quoted CIDR ended up as a separate command (`no such file or directory: 192.168.16.7/32`). Keep it to one line.
- **Check what the address is, and the scope the user needs, before writing it.** A single `/32` from an error message only fixes that one host. Every other LAN host the tools use stays blocked. Resolve it (`dscacheutil -q host -a ip_address <ip>`) and ask whether the whole subnet is wanted.
- **Read the netmask.** Here the LAN was `255.255.252.0` (`/22`, .16–.19) with en0 and en1 on different /24s. Two /24s would have missed half of it.
- **Don't keep test artefacts under `/private/tmp`** if they must survive the reboot. The scripts cache to `~/.cache/lnp-probe`.
- **`resp == own PID` is normal for GUI apps** (kitty, Terminal). It only means "ungrantable" for a bare CLI binary.
- **Node may report `ECONNREFUSED`** rather than `EHOSTUNREACH` for the same denial. Trust the probe, not the client's error text.
- herdr ≥ 0.9.4 deliberately survives its launching shell and terminal (ignores SIGHUP; #5236 on master leaves the terminal's launchd job). That makes the server outliving its terminal the normal case. `herdr update --handoff` and incoming `herdr --remote` attaches also restart the server outside a terminal.

## Verify

```sh
defaults read com.apple.network.local-network   # both keys list the CIDR(s)
sysctl -n kern.boottime                         # rebooted after writing them
scripts/lnp-test.sh <lan-ip> <port>              # BOTH lines: connect ok
```

## References

- Apple TN3179, Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy (the page is JS-rendered; its JSON is at `https://developer.apple.com/tutorials/data/documentation/technotes/tn3179-understanding-local-network-privacy.json`).
- herdr issue #808 (LNP inside herdr panes), #391 (ad hoc signing), #4920/#4965 (server survives terminal quit).
- Grantable-parent alternative: drod3763/herdr-server-app (signed `.app` wrapper that spawns `herdr server` from a LaunchAgent).
