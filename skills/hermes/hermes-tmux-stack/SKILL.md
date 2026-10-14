---
name: hermes-tmux-stack
description: Run, restart, upgrade or debug the Hermes Agent service stack on macOS (gateway :8642, dashboard :9119, Paperclip :3100, Obsidian ob sync), with one tmux session per service, launched at login by the ai.hermes.tmux-stack LaunchAgent through Terminal.app, via tmux-respawn-all.sh and hermes-upgrade.sh. Use when asked to "restart Hermes", "upgrade Hermes", "respawn the stack", "the gateway is down", "Chat unavailable", "address already in use on 8642", or when Hermes cron/MCP tools such as snoopd report EHOSTUNREACH for every LAN host while ssh from a shell works.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, tmux, macos, launchd, local-network-privacy, zsh, nvm"
  version: "0.1.0"
  last-verified: "2026-10-14"
  status: live
---

# Hermes tmux stack on macOS

Hermes Agent and its companion services run as long-lived processes in one tmux session per service, on a single user-owned tmux server. They are not run as launchd daemons. On macOS 15+ (Sequoia/Tahoe), Local Network Privacy blocks LAN access for processes not started from an app that holds the permission. Launchd-managed Hermes hit this. A tmux server started from Terminal.app inherits Terminal's permission, and so do all its panes, while keeping a full login shell environment (nvm, PATH) and staying trivially debuggable with `tmux attach`.

## When to use / when not to

- Use when: starting, restarting or upgrading Hermes on the Mac host (hermes), adding a service to the stack, or diagnosing a pane that died, a port conflict, or LAN-only network failures from Hermes tools.
- Don't use when: Hermes runs in a container or on Linux, or for model/provider config (`hermes-lmstudio-provider`).

## The canonical form

Launch chain at GUI login:

```
~/Library/LaunchAgents/ai.hermes.tmux-stack.plist   (RunAtLoad, Aqua only, one-shot)
  -> osascript: tell application "Terminal" to do script ...
    -> zsh -ilc ~/.hermes/scripts/tmux-login-bootstrap.sh   (logs ~/.hermes/logs/tmux-login-bootstrap.log)
      -> ~/Deployments/tmux/tmux-respawn-all.sh             (ensure all sessions)
        -> tmux server, sessions: gateway, dashboard, paperclip, obsidian
```

| Session | Command (each via `zsh -ilc`) | Port | cwd |
|---|---|---|---|
| gateway | `exec hermes gateway run` | 8642 | `~/Documents/Jeffrey_Workspace` |
| dashboard | `exec hermes --tui dashboard --host 127.0.0.1 --port 9119 --no-open` | 9119 | - |
| paperclip | `exec npx paperclipai run` (listen host = Tailscale IP) | 3100 | - |
| obsidian | `ob sync --continuous` in a `while true` retry loop | none | - |

Files (copies in `references/`, live copies in `~/Deployments/tmux/` (git) and `~/.hermes/scripts/`):
- `references/ai.hermes.tmux-stack.plist`: the LaunchAgent.
- `references/tmux-login-bootstrap.sh`: Terminal-hosted bootstrap.
- `references/tmux-respawn-all.sh`: the supervisor. `(none)` ensures, `--restart` recycles everything, `--kill` stops everything, `--status` shows status.
- `references/hermes-upgrade.sh`: kill -> `hermes update` -> respawn. Symlinked as `~/hermes-upgrade.sh`.
- `scripts/lnp-test.sh`: Local Network probe (`gateway` mode tests the live stack).

## Steps

- **Status:** `~/Deployments/tmux/tmux-respawn-all.sh --status` shows versions, pane alive/dead and port liveness.
- **Start or fix missing sessions, from Terminal.app on hermes:** `tmux-respawn-all.sh`.
- **Full restart from anywhere, including over SSH:**
  ```
  ~/Deployments/tmux/tmux-respawn-all.sh --kill
  launchctl kickstart gui/$(id -u)/ai.hermes.tmux-stack
  tail -f ~/.hermes/logs/tmux-login-bootstrap.log   # wait for "login bootstrap finished (status=0)"
  ```
- **Upgrade:** `ssh -t hermes ~/hermes-upgrade.sh` (or run it locally). Over SSH, phase 3 automatically does the kill + kickstart + wait above.
- **Verify LAN access:** `scripts/lnp-test.sh gateway` should print `gateway: ok`.

## Gotchas

- **Never start the tmux server from an SSH shell.** It gets no Local Network permission. Every pane (gateway, its MCP servers such as snoopd) then gets `connect EHOSTUNREACH` for all LAN IPs, including the same subnet. Public IPs still work, and `ssh` from your own shell still works, so it looks like a partial outage. This applies from the start, not only after logout (tested 2026-10-14, macOS 26.7.1). The tmux server keeps the permission of whatever forked it, so restarting individual sessions on an already-good server is fine. Starting a new server over SSH is not. `hermes-upgrade.sh` guards this with `$SSH_CONNECTION`. Running `tmux-respawn-all.sh` directly over SSH after `--kill` does not.
- **A plain `launchctl kickstart` does nothing if sessions exist.** The bootstrap only ensures, so `--kill` first.
- **The bootstrap needs a GUI login.** The plist is `LimitLoadToSessionType: Aqua`, so kickstart fails with no one logged in at the console.
- **`hermes update` re-registers the `ai.hermes.gateway` KeepAlive LaunchAgent.** Its `--replace` kills the pane gateway, and KeepAlive revives it within 30s. The respawn script boots the job out (`launchctl bootout gui/<uid>/ai.hermes.gateway`) before starting the gateway. Killing the process alone is useless. The original plist is parked as `~/Library/LaunchAgents/ai.hermes.gateway.plist.disabled`.
- **Don't `pkill -f "hermes gateway"`.** The tmux server is forked by the first `tmux new-session ... hermes gateway run` and keeps that argv, so the pattern matches the server and kills every session. `kill_matching` filters by executable name.
- **Name patterns miss gateways started other ways.** The dashboard's restart button runs `python -m hermes_cli.main gateway restart`, and launchd runs `python -m hermes_cli.main gateway run`. Match `"gateway run"` and also kill by port owner (`lsof -i :8642 -sTCP:LISTEN -t`).
- **"Port is listening" is not "our service is up".** If the pane is dead but the port is held, another process owns it, often the old build after an upgrade. `wait_for_port` checks both.
- **Use `--restart` after an update.** Plain ensure sees the old build as healthy.
- **Use `zsh -ilc` for every service.** tmux's bare `sh -c` puts Homebrew's node ahead of nvm, which causes:
  - the dashboard Chat tab failing with "Chat unavailable: 1" (npm EBADENGINE);
  - paperclip dying in dyld (`Library not loaded: .../libada.4.dylib`) after brew upgrades;
  - `ob`'s better-sqlite3 failing to load;
  - MCP servers launched by the gateway running on the wrong node.
- **The tmux server's cwd leaks into panes created without `-c`.** The script `cd`s to `~/Documents/Jeffrey_Workspace` before creating any session. It also restarts the gateway if the process on :8642 has the wrong cwd.
- **Startup timeouts are long on purpose.** The gateway gets 120s, because a failing MCP server can stall it before it binds. The dashboard gets 240s, because a cold vite rebuild after an update takes time.
- **The obsidian session has no port.** If `ob sync` exits, tmux removes the session silently and status shows "absent". The retry loop keeps it alive and logs the exit code to the pane.
- **The Hermes Desktop app runs its own in-process cron scheduler** (`Desktop cron scheduler started` in `agent.log`). A job can then run from the gateway and from Desktop. Desktop has Local Network permission, so a rerun from it can look healthy while the gateway is broken.

## Verify

```
~/Deployments/tmux/tmux-respawn-all.sh --status        # 4 sessions alive, :8642 :9119 :3100 listening
tail -3 ~/.hermes/logs/tmux-login-bootstrap.log         # "login bootstrap finished (status=0)" with today's date
scripts/lnp-test.sh gateway                             # gateway: ok   (EHOSTUNREACH = server started outside Terminal)
tmux ls -F '#{session_name} #{t:session_created}'       # creation times match the last bootstrap run
```

## Debug tips

- **A pane died:** run `tmux capture-pane -pt <session>` for its last output, or `tmux attach -t <session>`.
- **Port conflict:** `lsof -nP -i :8642 -sTCP:LISTEN` shows the owner, and `lsof -a -p <pid> -d cwd` shows its cwd.
- **LAN-only failures from Hermes tools:**
  - Compare the probe result inside the gateway session (`lnp-test.sh gateway`) with a fresh Terminal shell.
  - `lnp-test.sh start` / `check` starts a throwaway SSH-launched tmux server (`-L lnptest`), which always fails over SSH. Use it to reproduce the block, not to test the stack.
  - `last` shows whether a respawn coincided with an SSH session.
- **Who restarted things:**
  - The bootstrap log only records Terminal launches.
  - `git -C ~/.hermes/hermes-agent reflog --date=iso` dates `hermes update` runs.
  - `~/.hermes/logs/agent.log` has `Gateway running with N platform(s)` on each gateway start.
- **launchd ghost:** `launchctl list | grep ai.hermes` should show only `ai.hermes.tmux-stack`.

## References

- `references/operations-notes.md`: everything else about running Hermes on this host (file locations, process model, the two cron schedulers, upgrades, remote access through Caddy, tool cap, MCP auth storms, snoopd, macOS 26 networking, working over SSH). Read it when debugging, and append new incidents there.
- `references/`: live copies of the plist, bootstrap, respawn and upgrade scripts (2026-10-14).
- Design note with rationale and the 2026-10-14 Local Network addendum: `~/Deployments/tmux/tmux-respawn-design-note.md`.
