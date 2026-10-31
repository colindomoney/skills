---
name: hermes-macos-launchd
description: Install, run, inspect, clean up and debug a local Hermes Agent on a Mac, where the dashboard (127.0.0.1:9119) and gateway run as per-user launchd LaunchAgents (ai.hermes.dashboard, ai.hermes.gateway), not the central hermes host's tmux stack. Use when asked "what's Hermes running", "how is the dashboard/gateway launched", "restart Hermes on my Mac", "make the dashboard start at login", "Hermes is down / won't start", "clean up Hermes config", "remove a platform", "stale gateway state", after `hermes update` leaves plists pointing at old ~/.hermes/tools python/node, or when editing ai.hermes.dashboard.plist or ai.hermes.gateway.plist in ~/Library/LaunchAgents.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, macos, launchd, launchagent, plist, debugging"
  version: "0.2.0"
  last-verified: "2026-10-31"
  status: live
---

# Hermes on a local Mac: launchd install, operations and debugging

A local Mac install of Hermes runs as up to three process trees, all as the logged-in user. The **gateway** and the **dashboard** are separate LaunchAgents in the `gui/<uid>` domain. The **Hermes Desktop app** spawns its own backend. `hermes gateway install` writes the gateway plist. `hermes dashboard` has no installer, so the dashboard plist is written by hand. These are LaunchAgents rather than LaunchDaemons because everything lives in `~/.hermes`.

## When to use / when not to

- Use when: `~/.hermes` is on this Mac and `launchctl list | grep ai.hermes` shows `ai.hermes.dashboard` and/or `ai.hermes.gateway`.
- Don't use when: `~/Deployments/tmux/tmux-respawn-all.sh` exists or `ai.hermes.tmux-stack` is loaded. That is the central host, so use `hermes-tmux-stack`.
- Don't use when: you're on Linux. `hermes gateway install` writes a systemd unit there.
- Don't use when: it's model or provider config. Use `hermes-lmstudio-provider`.

## First: status

Run `scripts/hermes-status.sh`. It is read-only and prints:
- the host, with a warning if this is the tmux host;
- the Hermes version;
- the launchd jobs (state, runs, last exit);
- the gateway PID from `gateway_state.json`, and whether it is alive;
- persisted platform entries;
- Hermes Python listeners, labelled `gateway run`, `dashboard` or `serve`;
- toolchain drift in the plists.

`HERMES_LAUNCHAGENTS=<dir>` checks plists in another directory, for example backups.

A healthy install has both jobs `running`, :9119 answering 200, and no drift lines. The gateway listens on :8642 only if a messaging platform or `api_server` is enabled. With none enabled it logs "No messaging platforms enabled", stays up for cron, the kanban dispatcher and housekeeping, and listens only on a random loopback port.

## Process model

| What | Launched by | Process | Port |
|---|---|---|---|
| Gateway | `ai.hermes.gateway` → `osascript -l JavaScript` → `hermes --run-module hermes_cli.stderr_timestamp -- hermes gateway run --external-supervisor` | `python3 -I -c ... gateway run --external-supervisor` | :8642 if a platform is on, plus a random loopback port |
| Dashboard | `ai.hermes.dashboard` → `hermes dashboard --host 127.0.0.1 --port 9119 --no-open --skip-build` | `python3 -I -c ... dashboard ...` | 9119 |
| Desktop backend | `/Applications/Hermes.app` (launchd label `application.com.nousresearch.hermes.*`) | `python3 -I -c ... serve --host 127.0.0.1 --port 0` | random |

- **Launcher:** `~/.hermes/hermes-agent/.hermes/bin/hermes` is a shim that execs the managed Python in `~/.hermes/tools/python-<ver>/` with an inline `-c` bootstrap. Point launchd at the shim, never at a Python.
- **MCP servers** run as children of the gateway, alongside `tools/mcp_death_supervisor.py`. They use whatever `command:` is set under `mcp_servers` in `config.yaml`. A venv's base Python, for example the Framework 3.12, is set when the venv is created, not by PATH.

## Files

| Path | What |
|---|---|
| `~/.hermes/config.yaml` | Main config. Platform settings appear twice: under `display.platforms.<name>` (display) and under `platforms.<name>` (enable and extras). |
| `~/.hermes/.env` | Secrets and platform env vars, for example `BUZZ_*` and `TELEGRAM_*`. |
| `~/.hermes/gateway_state.json` | The gateway's runtime record: pid, state, version, and a status entry for each platform. |
| `~/.hermes/logs/{gateway,dashboard}{,.error}.log` | launchd stdout and stderr. The gateway stamps its stderr with timestamps. |
| `~/.hermes/tools/{python,node}-<ver>-darwin-arm64/` | Managed toolchains. `hermes update` adds new versions and leaves the old ones in place. |
| `~/Library/LaunchAgents/ai.hermes.{dashboard,gateway}.plist` | The jobs. See `references/`. |

## Install

Ask which to set up: **dashboard**, **gateway** or **both**. Don't assume the gateway.

**Dashboard:**
1. Copy `references/ai.hermes.dashboard.plist` to `~/Library/LaunchAgents/`. Replace `/Users/colind`, and set the PATH tool directories to the newest `~/.hermes/tools/*` versions.
2. `plutil -lint` the plist, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.hermes.dashboard.plist`.
3. To remove it: `launchctl bootout gui/$(id -u)/ai.hermes.dashboard`, then delete the plist.

**Gateway:**
1. Run `hermes gateway install`, then check with `hermes gateway status`.
2. To remove it: `hermes gateway uninstall`.

## Operate

| Task | Command |
|---|---|
| Restart the dashboard | `launchctl kickstart -k gui/$(id -u)/ai.hermes.dashboard` |
| Restart the gateway | `hermes gateway restart` (SIGUSR1 → graceful drain → launchd relaunches on exit 75) |
| Pick up an edited plist | `launchctl bootout gui/$(id -u)/ai.hermes.<job>`, then `launchctl bootstrap gui/$(id -u) <plist>`. `kickstart` does not re-read the plist. |
| Stop the gateway for good | `launchctl bootout gui/$(id -u)/ai.hermes.gateway`. Then wait on the pid from `gateway_state.json` (`kill -0 $pid`) before touching its state. |

### After `hermes update`: toolchain drift

Both plists pin versioned `~/.hermes/tools/python-*` and `node-*` directories in `PATH`. An update installs newer ones and leaves the plists pointing at the old ones. The shim still finds the right Python, so nothing breaks straight away. Anything the services shell out to by PATH gets the old Node or Python, and if the old directory is deleted, those calls fail.

To fix it:
1. Back up the plists.
2. Repoint them:
   ```bash
   sed -i '' -e 's/python-<old>/python-<new>/g' -e 's/node-<old>-darwin-arm64/node-<new>-darwin-arm64/g' \
     ~/Library/LaunchAgents/ai.hermes.{dashboard,gateway}.plist
   ```
3. `plutil -lint` both, then bootout and bootstrap each job.
4. Re-run `hermes-status.sh`. Delete the old `tools/` directories only once nothing references them.

Rerunning `hermes gateway install --force` would also rewrite the gateway plist, but it captures the PATH of the shell it runs in. Run it from a normal Terminal login shell, not from an agent's shell. It wasn't used for this fix.

### Remove a messaging platform (e.g. Buzz)

1. Back up `config.yaml`, `.env` and `gateway_state.json`.
2. Delete `display.platforms.<name>` and `platforms.<name>` from `config.yaml`. If that leaves `platforms:` empty, delete the key too. Check the file still parses with `python3 -c "import yaml; yaml.safe_load(open(...))"`.
3. Delete the platform's lines from `.env`, including commented-out ones, which can still contain keys.
4. Clear its entry from `gateway_state.json` while the gateway is stopped (see Gotchas):
   ```bash
   old=$(python3 -I -c "import json;print(json.load(open('$HOME/.hermes/gateway_state.json'))['pid'])")
   launchctl bootout gui/$(id -u)/ai.hermes.gateway
   while kill -0 $old 2>/dev/null; do sleep 2; done
   python3 -I -c "import json,os;p=os.path.expanduser('~/.hermes/gateway_state.json');d=json.load(open(p));d['platforms'].pop('<name>',None);json.dump(d,open(p+'.tmp','w'));os.replace(p+'.tmp',p)"
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.hermes.gateway.plist
   ```

## Gotchas

- **`pgrep -f 'hermes_cli/main.py gateway'` matches nothing.** The process argv is `python3 -I -c <bootstrap> gateway run ...`. `gateway_state.json` lists `hermes_cli/main.py` in its `argv`, but that is not what `ps` shows. Take the pid from `gateway_state.json`, or the owner of the port.
- **Platform status in `gateway_state.json` persists across restarts and config removal.** At start the gateway loads the existing file and merges into it in memory. If you edit the file while the old gateway is still draining, it writes its copy back on exit. So bootout, wait on the real pid, then edit. A Buzz entry from 5 Sep 2026 kept showing as `retrying` / `needs_attention` for weeks after Buzz was disabled.
- **No :8642 doesn't mean the gateway is down.** With no platforms enabled it doesn't open the API port. Check `gateway_state` and the log line "Gateway will continue running for cron job execution".
- **The Desktop app runs its own `hermes serve` backend**, alongside the gateway. It can also run its own cron scheduler (seen on the central host), so a job may fire from both, and a Desktop rerun can look healthy while the gateway is broken. Desktop launching often coincides with SIGUSR1 gateway restarts in `gateway.log`.
- **launchd doesn't inherit your shell PATH.** Both plists set PATH explicitly. The gateway's is the installing shell's whole PATH, frozen, including nvm, `/Library/Frameworks` Python and so on.
- **The gateway's KeepAlive is `{SuccessfulExit=false}`, not `true`.** A clean exit (0, which includes EX_CONFIG 78 after `stderr_timestamp` maps it) parks the job, while exit 75 and crashes relaunch it. `true` respawned a token collision forever (upstream #89477). The live dashboard plist uses the same form.
- **`ExitTimeOut` is capped at 60s in `gui/<uid>`.** The gateway logs `restart_drain_timeout=180s exceeds the live launchd exit timeout` and drains for 50s at most, so long turns are cut off on stop.
- **Don't stop a supervised gateway and run `gateway run` in the foreground.** It stamps the CLI's PID and wedges later KeepAlive respawns (upstream #110637). Use `hermes gateway restart`.
- **The last exit code in `launchctl list` is often benign.** -15 means it was SIGTERMed (kickstart, bootout, update). 75 means the gateway asked to be relaunched.
- **`--skip-build` serves the existing `hermes_cli/web_dist`.** After an update that changes the web UI, run a dashboard build, or start once without `--skip-build`, or the old UI stays up.
- **A stale process can hold :9119.** The job then crash-loops on bind errors every 30s (`ThrottleInterval`), and kickstart doesn't help. Bootout, check the owner with `lsof -nP -iTCP:9119 -sTCP:LISTEN` and `ps -p <pid> -o command`, kill it if it's a Hermes `dashboard`, then bootstrap.

## Verify

```bash
scripts/hermes-status.sh                                        # both jobs running, gateway pid alive, no drift lines
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9119/ # 200
tail -n 20 ~/.hermes/logs/gateway.error.log ~/.hermes/logs/dashboard.error.log
```

## References

- `scripts/hermes-status.sh`: read-only status and drift report.
- `references/ai.hermes.dashboard.plist`: the live hand-written dashboard agent (2026-10-31).
- `references/ai.hermes.gateway.plist`: the generated gateway agent, for comparison. Its PATH is the installer's shell PATH, edited for drift.
- Hermes source: `~/.hermes/hermes-agent/hermes_cli/gateway_launchd.py` (install and reload), `gateway/status.py` (`gateway_state.json` merge logic) and `hermes_cli/AGENTS.md` (supervised-restart rules).
- Related: [[hermes-tmux-stack]] (central host), [[hermes-lmstudio-provider]], [[hermes-desktop-mtls-dmg]], [[macos-local-network-privacy]].
