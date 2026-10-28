---
name: homelab-uptime-kuma-api
description: Create or update Uptime Kuma 2.x monitors (push, HTTP, groups) from a script with the uptime-kuma-api2 Python library over socket.io, logging in with username, password and a prompted 2FA code from a throwaway .env. Use when asked to "add Kuma monitors", "create push monitors", "set up heartbeats in Uptime Kuma", "script Kuma", "use the Kuma API", when an Uptime Kuma API key is rejected for anything but /metrics, or when wiring a cron job, service or health checker to report into Kuma.
license: MIT
metadata:
  author: colindomoney
  tags: "homelab, uptime-kuma, python, socketio, monitoring"
  version: "0.1.0"
  last-verified: "2026-10-28"
  status: live
---

# Uptime Kuma 2 monitors via uptime-kuma-api2

Uptime Kuma has no REST management API. Monitors, groups and notifications are managed over its socket.io interface, which `uptime-kuma-api2` (PyPI, fork of lucasheld/uptime-kuma-api for Kuma 2.x) wraps. It authenticates with username + password (+ TOTP). The "API key" in Kuma's settings only reads `/metrics` and cannot create anything. So: a one-off, idempotent setup script, credentials in a gitignored `.env` that is deleted afterwards, 2FA typed at run time, and only the resulting push URLs kept on disk for the runtime checker.

## When to use / when not to

- Use when: creating monitors in bulk or repeatably, wiring a script/service into Kuma as push monitors, putting monitors into a group with the same notifications as an existing monitor.
- Don't use when: reading status or uptime (use `/metrics` with an API key as basic-auth password); one or two monitors are quicker in the UI.

## The canonical form

- `references/setup-kuma.py`: logs in (prompts for 2FA), finds or creates a group, creates push monitors by name (reuses existing ones), copies `notificationIDList` from a reference monitor, writes push URLs to a mode-600 env file.
- `references/.env.example`: the login template.

Core calls:

```python
from uptime_kuma_api import MonitorType, UptimeKumaApi

with UptimeKumaApi(url) as api:
    api.login(username, password, totp)          # totp="" if 2FA is off
    by_name = {m["name"]: m for m in api.get_monitors()}
    gid = api.add_monitor(type=MonitorType.GROUP, name="Hermes")["monitorID"]
    mid = api.add_monitor(type=MonitorType.PUSH, name="svc", parent=gid,
                          interval=300, maxretries=1,
                          notificationIDList=[1, 2])["monitorID"]
    token = api.get_monitor(mid)["pushToken"]    # library generates it for PUSH
    api.edit_monitor(other_id, parent=gid)       # move an existing monitor into the group
# push URL: f"{url}/api/push/{token}"
```

Pushing from the checker (no login needed):

```bash
curl -fsS -m 20 -G "$PUSH_URL" --data-urlencode "status=up|down" --data-urlencode "msg=$reason" --data-urlencode "ping="
```

## Steps

1. Project folder (e.g. `~/Deployments/<name>/`): copy `references/.env.example`, add `.env` and `.venv/` to `.gitignore`, commit the example.
2. `uv venv .venv && uv pip install --python .venv/bin/python uptime-kuma-api2`.
3. Copy and adapt `references/setup-kuma.py` (the `CHECKS` map, group name, output path, reference monitor).
4. User: `cp .env.example .env && chmod 600 .env`, fills in username/password.
5. User runs `.venv/bin/python setup-kuma.py` themselves so they can type the TOTP code (via `! ...` in Claude Code).
6. Delete `.env`. Only the push-URL file (outside the repo, mode 600) remains.
7. Start the checker that pushes to those URLs more often than the monitor interval (e.g. every 120s against a 300s interval).

## Gotchas

- **The UI API key is not a credential for this.** It only grants `/metrics`. The library README says so. Don't ask the user for one to create monitors.
- **`notificationIDList` is a list of IDs** in `uptime-kuma-api2` (`get_monitors()` returns `[1, 2]`, `add_monitor` takes a list). Treating it as Kuma's raw `{id: true}` dict crashes with `'list' object has no attribute 'items'`. The reference script accepts both.
- **Make it idempotent by name.** A crash part-way leaves a group created and nothing else. Re-running must reuse the group and existing monitors, not duplicate them.
- **Never store the TOTP or ask for it in chat.** Prompt with `getpass` at run time. It's only needed once; push URLs need no login.
- **Push URLs are secrets.** Anyone with one can mark the monitor up. Keep them in a mode-600 file outside the repo, and mask the token when printing (`sed -E 's#(/api/push/).*#\1<token>#'`).
- **Interval vs push cadence.** Push monitor interval must exceed the checker's loop plus run time, or it flaps. A stopped checker is detected by missed heartbeats, which is the point: one checker dying takes every monitor down.
- **Pin library to server version.** The README maps library releases to Kuma version ranges; `api.version` after login shows the server version. Verified: library 2.9.0 against Kuma 2.5.5.

## Verify

- Setup prints `logged in to <url> (Kuma x.y.z)`, `created`/`exists` per monitor, and `wrote <push file>`.
- `sed -E 's#(/api/push/).*#\1<token>#' <push file>` shows one URL per monitor.
- A manual `curl` with `status=up&msg=test` to one URL returns `{"ok":true}` and the monitor turns green in the group.

## References

- `references/setup-kuma.py`, `references/.env.example`: copied from a running deployment.
- Library: https://github.com/pbarone/uptime-kuma-api2 (`pip install uptime-kuma-api2`).
- Repo using this pattern: `ssh://git@git.domoney.online/Infrastructure/hermes-health.git`.
