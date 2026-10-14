# Hermes on hermes (the Mac): operations notes

These notes are meant to grow: add each incident as it happens. SKILL.md holds the stack-launch gotchas. This file holds everything else learned while running Hermes on this host. Dates are when each fact was last seen true.

## Where things live

| What | Path |
|---|---|
| Hermes home, config, secrets | `~/.hermes/`, `~/.hermes/config.yaml`, `~/.hermes/.env` |
| Hermes code checkout (updated by `hermes update`) | `~/.hermes/hermes-agent/` |
| Logs | `~/.hermes/logs/`: `agent.log` (gateway/cron/agent), `mcp-stderr.log` (all MCP server stderr, large), `errors.log`, `gui.log`, `tmux-login-bootstrap.log` |
| Cron jobs and state | `~/.hermes/cron/jobs.json`, `executions.db`, `ticker_heartbeat`, `ticker_last_success` |
| Cron run output | `~/.hermes/cron/output/<job-id>/<YYYY-MM-DD_HH-MM-SS>.md` |
| Host-side cron scripts | `~/.hermes/scripts/` (for example `snoopd_health_report.py`) |
| Stack scripts (git: `~/Deployments`) | `~/Deployments/tmux/` |
| TLS front end | `~/Deployments/Caddy/Caddyfile` (client-cert mTLS against its own CA in `Caddy/pki/`) |

## Process model

- **Each Hermes process spawns its own MCP servers.** The gateway, the TUI (`hermes --tui`), the dashboard and Desktop-over-SSH `hermes serve` each start their own set, each under an `mcp_death_supervisor.py` with its own copies of servers such as `~/mcp/snoopd/dist/index.js`. They inherit their parent's environment and Local Network permission, so one copy can be broken while another works. To test what a cron job sees, test from inside the gateway session.
- **Two cron schedulers can exist.**
  - The gateway runs one.
  - The Hermes Desktop app starts an in-process one too: `hermes_cli.web_server: Desktop cron scheduler started` in `agent.log`.
  - On 2026-10-14 the Desktop scheduler ran the snoopd job at 12:04:38, just after the gateway's 12:01 run. That rerun was clean (Desktop has Local Network permission), which hid the broken gateway run.
- **Cron log lines:**
  - `agent.log` shows `cron.scheduler: Running job '<name>' (ID: <id>)` and `Job '<id>': delivered to telegram:...`.
  - `Mode: no_agent (script)` jobs run a script and stay silent when the output is empty. Silent means healthy, but also looks the same as a dead scheduler.

## Upgrades (`hermes update`)

- Before updating, it takes a snapshot of the config (`Pre-update snapshot: <ts>-pre-update`).
- **Stale autostashes:** it warns about old `hermes-update-autostash-*` git stashes in `~/.hermes/hermes-agent`. Those are local changes an earlier update stashed and never restored. Review them with `git stash show -p stash@{n}`.
- **Desktop-over-SSH stays on old code:** a `hermes serve` started by the Desktop app over SSH keeps running the pre-update code until the Desktop reconnects. The update lists it as "Left to the Desktop app".
- **Gateway LaunchAgent comes back:** the update re-registers the `ai.hermes.gateway` LaunchAgent. `tmux-respawn-all.sh` boots it out again (see SKILL.md).
- **Dates of past runs:** `git -C ~/.hermes/hermes-agent reflog --date=iso` shows when each update ran (`merge origin/main: Fast-forward`).

## Remote access (2026-10-14)

- **Dashboard:** binds `127.0.0.1:9119`. Caddy fronts it as `hermes.domoney.online`, requiring client-cert mTLS against `Caddy/pki/ca/client-ca.cert.pem`, with allowed leaf certs in `Caddy/pki/clients/allowed`. Caddy rewrites `Host` and `Origin` to `127.0.0.1:9119` because Hermes validates both against its bind address. Without the rewrite you get WebSocket and Origin rejections.
- **Paperclip:** binds the Tailscale IP `100.111.59.2:3100` and is fronted by Caddy as `paperclip.domoney.online` with the same mTLS.
- **Public URL changes:** `hermes dashboard register --redirect-uri <url>` updates the Nous OAuth redirect and writes `HERMES_DASHBOARD_PUBLIC_URL` to `.env`. Respawn the dashboard pane afterwards.

## Tools and MCP

- **Tool-count cap:**
  - Grok rejects requests with more than 200 tools, and built-in toolsets plus all MCP servers came to about 210.
  - The fix is deferred tool loading via `tools.tool_search` in `config.yaml`. It is currently `enabled: auto` with `threshold_pct: 5`. Quote `"on"` if you force it, or YAML parses it as `true`.
  - After changing it, run `/reload-mcp` or start a new session.
- **Expired MCP credentials cause auth-failure storms:** each Hermes process retries on its own, so a revoked token multiplies.
  - For Home Assistant the token is stored twice in `.env` (`HASS_TOKEN` and `API_ACCESS_TOKEN`). Update both, then `/reload-mcp`.
  - Diagnose with `grep 'HTTP/1.1' ~/.hermes/logs/mcp-stderr.log | tail`.
- **snoopd reports failures as successes:** it returns `isError: false` with `{"error": true, "code": ...}` in the body. Consumers must check `data.error`, and `snoopd_health_report.py` does. It also resolves the nvm `node` path explicitly, because cron's minimal PATH has no node.

## Networking on macOS 26

- **Local Network Privacy:**
  - Symptom: a process sees `connect EHOSTUNREACH <lan-ip>` (Node) or `No route to host` for every LAN address while public IPs work.
  - Cause: the process tree was started from a context without the permission. The confirmed case is a tmux server started over SSH.
  - Fix: relaunch from Terminal.app (see SKILL.md).
- **`ssh` "Undefined error: 0":** the blocking `connect()` returns -1 with errno 0 for some LAN hosts on hermes, and any `ConnectTimeout` fixes it. A global `Host *` / `ConnectTimeout 10` is in the chezmoi ssh template. It may or may not share a cause with the Local Network issue; that's unproven.

## Working on hermes remotely

- **Non-interactive ssh has a minimal PATH:** `ssh hermes 'cmd'` doesn't load your login PATH, so `tmux`, `hermes`, `npx` and `ob` are not found. Use full paths (`/opt/homebrew/bin/tmux`) or `zsh -ilc '...'`. The respawn preflight's "not found on PATH" warnings over SSH come from this. They don't matter for `--kill`.
- **Interactive prompts:** use `ssh -t` for anything that prompts, such as `hermes update`.
- **Long one-liners get mangled:** chat and terminal line-wrapping breaks long quoted commands. Put the logic in a script file on hermes and call it with short commands (`ssh hermes /path/script.sh start`, then `... check`). `scripts/lnp-test.sh` is an example.
- **Restarting the whole stack:** `--kill` followed by `launchctl kickstart`, as in SKILL.md, is the only safe way over SSH. Starting individual sessions on an already-good tmux server is fine, because new panes inherit the server's permission.
