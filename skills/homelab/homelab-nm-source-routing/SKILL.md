---
name: homelab-nm-source-routing
description: Set up source-based routing (SBR, policy routing) on a dual-homed Linux host with a public wired uplink and a WiFi/home uplink, using a NetworkManager dispatcher script with per-interface ip rules and routing tables, rolled out safely over Tailscale SSH. Use when setting up SBR, source-based routing or policy routing, when replies go out the wrong interface, when each uplink must answer for its own address, or when rebuilding a dual-homed homelab gateway host.
license: MIT
metadata:
  author: colindomoney
  tags: "homelab, networkmanager, iproute2, tailscale, linux"
  version: "0.1.0"
  last-verified: "2026-10-06"
  status: live
---

# Homelab: source-based routing via NetworkManager dispatcher

A host with two uplinks (public static wired, plus WiFi on the home LAN) has one main-table default route, so traffic sourced from the non-default interface's address leaves by the wrong link and is dropped upstream. Fix: one routing table and one `ip rule` per interface, keyed on source address, built by a NetworkManager dispatcher script on `up` and torn down on `down`. A dispatcher script rather than a standalone `sbr-setup.sh` or netplan routing-policy, because it re-runs on every link bounce and lease renewal with no extra unit to manage.

## When to use / when not to

- Use when: a host has two IPv4 uplinks, both managed by NetworkManager, and each address must answer via its own gateway.
- Don't use when: the interfaces are rendered by systemd-networkd (put `routing-policy` in netplan instead), or only one uplink carries traffic.

## The canonical form

`references/20-sbr`, copied from a running host with its addresses replaced by RFC 5737 / example values, installed at `/etc/NetworkManager/dispatcher.d/20-sbr`. Only the two variable lines are per-host:

```bash
PUB_IF=eth0;   PUB_SRC=203.0.113.3;  PUB_NET=203.0.113.0/28;  PUB_GW=203.0.113.1
WIFI_IF=wlan0; WIFI_SRC=192.168.1.50; WIFI_NET=192.168.1.0/24; WIFI_GW=192.168.1.1
```

Fixed across hosts: public = table 201, rule pref 110; WiFi = table 200, rule pref 100; `rp_filter=2` (loose).

Real per-host values are not kept in this public repo; derive them from the host's inventory (step 2). WiFi addresses are DHCP reservations on the router; never hardcode them in NM.

## Steps

Each step that touches networking is lockout-capable. Stop and get approval before each one.

1. Confirm the session is over Tailscale: `echo $SSH_CONNECTION` shows a 100.64.0.0/10 address. If not, ask the user to reconnect (`ssh <host>.<tailnet>.ts.net`) before step 4.
2. Inventory, read-only: `ip -br addr`, `ip rule show`, `ip route show table all`, `nmcli device`, `cat /etc/netplan/*.yaml` (renderer must be NetworkManager for both), `tailscale netcheck` (the gateway/self line shows which interface is Tailscale's underlay).
3. Fill the variable lines from the inventory: real interface names, addresses, subnets. Ask the user to confirm the WiFi address is a reservation.
4. Arm a rollback with enough time for the approval round-trip (10 min, not 5):
   ```sh
   sudo systemctl reset-failed sbr-rollback.service 2>/dev/null
   sudo systemd-run --on-active=10min --unit=sbr-rollback \
     /bin/sh -c 'rm -f /etc/NetworkManager/dispatcher.d/20-sbr; ip rule del pref 100; ip rule del pref 110; ip route flush table 200; ip route flush table 201'
   ```
   Cancel: `sudo systemctl stop sbr-rollback.timer`.
5. Install with a quoted heredoc via `sudo tee`, then `sudo chown root:root` and `sudo chmod 0755`, then `sudo bash -n` it.
6. Trigger by invoking it directly, non-underlay interface first: `sudo /etc/NetworkManager/dispatcher.d/20-sbr <iface> up`. Check `ip rule`, the table, `tailscale status` after each.
7. Bounce-test so NM itself is proven to run it. Clear the interface's rule and table first, otherwise a surviving rule looks like success. Bounce the underlay detached so `up` still runs if the session dies:
   ```sh
   sudo systemd-run --unit=sbr-bounce-wlan0 sh -c 'ip rule del pref 100; ip route flush table 200; nmcli connection down <wifi-conn>; sleep 3; nmcli connection up <wifi-conn>'
   ```
8. Once the user confirms, cancel the rollback timer.
9. Optional: make the wired link own the main default (the usual layout: wired metric 100, WiFi 600). Only after step 6 has proven `curl --interface <PUB_SRC>` works, because this moves Tailscale's underlay. Back up the netplan file first; NM writes the change back to `/etc/netplan/90-NM-<uuid>.yaml`.
   ```sh
   sudo nmcli connection modify <wired-conn> ipv4.route-metric 100 && sudo nmcli device reapply <wired-if>
   ```
   Arm a matching rollback (`ipv4.route-metric 700` + reapply) before running it.

## Gotchas

- `nmcli device reapply` does not trigger the script. NM sends dispatcher action `reapply`, not `up`; the script ignores it. Use a direct invocation or `connection down`/`up`. (`reapply` is still right for applying a route-metric change.)
- A 5-minute rollback timer expires during the approval round-trip and silently deletes the script. Use 10 minutes, and check `systemctl list-timers sbr-rollback.timer` before triggering.
- A fired transient unit stays `failed` (the `ip rule del` calls error on absent rules) and blocks reusing the name until `systemctl reset-failed`.
- NM ignores dispatcher scripts that are not root-owned or are group/world-writable.
- `NetworkManager-dispatcher` showing `inactive` is normal; it is D-Bus activated. Check `systemctl is-enabled` instead.
- The script is silent, so the journal only shows the dispatcher starting. Prove it ran by clearing state and watching it come back.
- Instructions copied from another host carry that host's interface names and addresses. Re-derive everything from the inventory.
- Never touch rule prefs 5200-5300 (Tailscale's) or run `tailscale up/down`.
- A WiFi bounce does not drop an SSH session over `tailscale0`; the 100.x address persists and TCP retransmits across the gap. A LAN SSH session would drop.
- `sysctl` is in `/usr/sbin`, often not on a user PATH on Debian. Read `/proc/sys/net/ipv4/conf/*/rp_filter` instead. Effective rp_filter is max(all, iface).

## Verify

```sh
ip rule show | grep -E '^1[01]0:'            # 100: from <WIFI_SRC> lookup 200 / 110: from <PUB_SRC> lookup 201
ip route get 8.8.8.8 from <PUB_SRC>          # via <PUB_GW> dev <PUB_IF> table 201
ip route get 8.8.8.8 from <WIFI_SRC>         # via <WIFI_GW> dev <WIFI_IF> table 200
curl -4 --interface <PUB_SRC>  -sS https://ifconfig.me; echo   # PUB_SRC
curl -4 --interface <WIFI_SRC> -sS https://ifconfig.me; echo   # the home router's WAN address
tailscale status --self --peers=false
```

## References

- `references/20-sbr` — the dispatcher script, example addresses.
