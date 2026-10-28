#!/usr/bin/env python3
"""One-off: create the Hermes push monitors in Uptime Kuma and write their push URLs.

Reads the Kuma login from .env next to this file, prompts for the 2FA code, then:
  - finds or creates the group monitor named KUMA_GROUP
  - finds or creates one push monitor per check, inside the group
  - copies notification channels from the existing vault-snapshot monitor and moves it into the group
  - writes the push URLs to ~/.config/hermes-health/push.env (mode 600)

Idempotent: monitors that already exist by name are reused, not duplicated.
"""
import getpass
import os
import pathlib
import sys

from uptime_kuma_api import MonitorType, UptimeKumaApi

HERE = pathlib.Path(__file__).resolve().parent
PUSH_ENV = pathlib.Path.home() / ".config/hermes-health/push.env"
VAULT_SNAPSHOT_ENV = pathlib.Path.home() / ".config/vault-snapshot/env"

# env var suffix -> monitor name
CHECKS = {
    "GATEWAY": "hermes-gateway",
    "CRON": "hermes-cron",
    "DASHBOARD": "hermes-dashboard",
    "PAPERCLIP": "paperclip",
    "OBSYNC": "ob-sync",
}
INTERVAL = 300  # checker pushes every 120s; one missed push is tolerated


def read_env(path):
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def main():
    env = read_env(HERE / ".env")
    url = env["KUMA_URL"].rstrip("/")
    group_name = env.get("KUMA_GROUP") or "Hermes"
    if not env.get("KUMA_USERNAME") or not env.get("KUMA_PASSWORD"):
        sys.exit(".env: KUMA_USERNAME and KUMA_PASSWORD must be set")

    totp = getpass.getpass("Kuma 2FA code (blank if 2FA is off): ").strip()

    with UptimeKumaApi(url) as api:
        api.login(env["KUMA_USERNAME"], env["KUMA_PASSWORD"], totp)
        print(f"logged in to {url} (Kuma {api.version})")
        monitors = api.get_monitors()
        by_name = {m["name"]: m for m in monitors}

        group = by_name.get(group_name)
        if group is None:
            group_id = api.add_monitor(type=MonitorType.GROUP, name=group_name)["monitorID"]
            print(f"created group {group_name} ({group_id})")
        else:
            group_id = group["id"]
            print(f"using group {group_name} ({group_id})")

        # Notifications and grouping follow the existing vault-snapshot push monitor.
        notification_ids = []
        snap_token = read_env(VAULT_SNAPSHOT_ENV).get("KUMA_URL", "").rsplit("/", 1)[-1].split("?")[0]
        snap = next((m for m in monitors if m.get("pushToken") and m["pushToken"] == snap_token), None)
        if snap:
            # The library returns a list of IDs and accepts one in add_monitor.
            ids = snap.get("notificationIDList") or []
            notification_ids = [int(k) for k, v in ids.items() if v] if isinstance(ids, dict) else [int(i) for i in ids]
            if snap.get("parent") != group_id:
                api.edit_monitor(snap["id"], parent=group_id)
                print(f"moved {snap['name']} into {group_name}")
        else:
            print("warning: vault-snapshot monitor not found; new monitors get no notifications")

        lines = ["# Written by setup-kuma.py. Push URLs for hermes-health.sh.\n"]
        for suffix, name in CHECKS.items():
            m = by_name.get(name)
            if m is None:
                mid = api.add_monitor(
                    type=MonitorType.PUSH,
                    name=name,
                    parent=group_id,
                    interval=INTERVAL,
                    maxretries=1,
                    notificationIDList=notification_ids,
                )["monitorID"]
                m = api.get_monitor(mid)
                print(f"created {name} ({mid})")
            else:
                print(f"exists  {name} ({m['id']})")
            lines.append(f"KUMA_PUSH_{suffix}={url}/api/push/{m['pushToken']}\n")

    PUSH_ENV.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(PUSH_ENV, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.writelines(lines)
    print(f"wrote {PUSH_ENV}")


if __name__ == "__main__":
    main()
