#!/usr/bin/env python3
"""Daily self-test of Hermes's Hindsight memory server. Run as a Hermes no-agent cron job.

Silent (empty stdout) when everything passes, so Hermes delivers nothing. On any failure it
prints one alert, which the cron job delivers to Telegram. --verbose prints the passing checks too.

Checks:
  1. server reachable; api_version == hindsight_client in the Hermes venv (skew = every retain fails)
  2. container running, not crash-looping, shm >= 1g, fixed worker id
  3. live round trip: retain a nonce into a throwaway bank (Groq extraction + embeddings + Postgres),
     recall it, delete the bank
  4. no ops stuck in "processing" > 1 h; failed_consolidation == 0
  5. no plugin retain failures in ~/.hermes/logs/agent.log in the last 24 h
     ("recall failed: Server disconnected" is excluded: it is the plugin's shutdown race on
     one-shot cron sessions, not an outage)

Stdlib only. Runbook: the hermes-hindsight-memory skill.
"""
from __future__ import annotations

import glob
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

BASE = os.environ.get("HINDSIGHT_URL", "http://localhost:8888")
BANK = os.environ.get("HINDSIGHT_BANK", "hermes")
TEST_BANK = "hermes-selftest"
CONTAINER = os.environ.get("HINDSIGHT_CONTAINER", "hindsight-hindsight-1")
HOME = os.path.expanduser("~")
AGENT_LOGS = sorted(glob.glob(f"{HOME}/.hermes/logs/agent.log*"))
VERBOSE = "--verbose" in sys.argv

CONTAINER_STARTED: datetime | None = None
problems: list[str] = []
notes: list[str] = []


def http(method: str, path: str, body: dict | None = None, timeout: float = 30):
    req = urllib.request.Request(
        BASE + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def http_err(e: Exception) -> str:
    if isinstance(e, urllib.error.HTTPError):
        detail = e.read().decode(errors="replace")[:200]
        return f"HTTP {e.code}: {detail}"
    return f"{type(e).__name__}: {e}"


def docker(*args: str) -> str:
    exe = shutil.which("docker") or next(
        (p for p in ("/usr/local/bin/docker", "/opt/homebrew/bin/docker") if os.path.exists(p)), "docker")
    return subprocess.run([exe, *args], capture_output=True, text=True, timeout=30, check=True).stdout.strip()


def check_versions() -> bool:
    try:
        server = http("GET", "/version")["api_version"]
    except Exception as e:
        problems.append(f"Server unreachable at {BASE} ({http_err(e)})")
        return False
    found = glob.glob(f"{HOME}/.hermes/installs/*/environments/*/venv/lib/python3*/site-packages/hindsight_client-*.dist-info")
    clients = sorted({re.sub(r".*hindsight_client-(.+)\.dist-info$", r"\1", p) for p in found})
    if not clients:
        notes.append("hindsight_client not found in any Hermes venv; version check skipped")
    elif server not in clients:
        problems.append(f"Version skew: server {server}, Hermes client {'/'.join(clients)}. "
                        "Retains will fail; bump the image pin in ~/Deployments/Hindsight/docker-compose.yml")
    notes.append(f"server {server}, client {'/'.join(clients) or '?'}")
    return True


def check_container() -> None:
    try:
        info = json.loads(docker("inspect", CONTAINER))[0]
    except Exception as e:
        problems.append(f"Cannot inspect container {CONTAINER} ({type(e).__name__}: {e})")
        return
    state, host = info["State"], info["HostConfig"]
    global CONTAINER_STARTED
    try:  # Docker reports UTC with nanoseconds; agent.log uses local time
        CONTAINER_STARTED = datetime.fromisoformat(state["StartedAt"][:26].rstrip("Z") + "+00:00").astimezone().replace(tzinfo=None)
    except (KeyError, ValueError):
        CONTAINER_STARTED = None
    env = dict(v.split("=", 1) for v in info["Config"].get("Env", []) if "=" in v)
    if state.get("Status") != "running" or state.get("Restarting"):
        problems.append(f"Container {CONTAINER} is {state.get('Status')} (restarting={state.get('Restarting')})")
    if info.get("RestartCount", 0) > 3:
        problems.append(f"Container has restarted {info['RestartCount']} times: crash loop? "
                        "See 'Recover after reboot' in the hermes-hindsight-memory skill")
    if (host.get("ShmSize") or 0) < 1 << 30:
        problems.append(f"shm_size is {(host.get('ShmSize') or 0) >> 20} MB (<1g); Postgres retains will 500")
    if not env.get("HINDSIGHT_API_WORKER_ID"):
        problems.append("HINDSIGHT_API_WORKER_ID unset; recreates will orphan in-flight ops")
    notes.append(f"container {state.get('Status')}, restarts={info.get('RestartCount')}, image={info['Config']['Image']}")


def check_round_trip() -> None:
    nonce = f"zq{secrets.token_hex(4)}"
    fact = f"The Hermes self-test codeword for today is {nonce}; it is stored on shelf {nonce}."
    try:
        with_suppress_delete()
        http("POST", f"/v1/default/banks/{TEST_BANK}/memories", {"items": [{"content": fact}], "async": False}, timeout=240)
    except Exception as e:
        problems.append(f"Retain failed ({http_err(e)})")
        return
    try:
        res = http("POST", f"/v1/default/banks/{TEST_BANK}/memories/recall",
                   {"query": "What is the Hermes self-test codeword?", "budget": "low"}, timeout=120)
        texts = [r.get("text", "") for r in (res or {}).get("results", [])]
        if not any(nonce in t for t in texts):
            problems.append(f"Recall did not return the retained codeword ({len(texts)} results)")
        else:
            notes.append(f"round trip ok ({len(texts)} results)")
    except Exception as e:
        problems.append(f"Recall failed ({http_err(e)})")
    finally:
        with_suppress_delete()


def with_suppress_delete() -> None:
    try:
        http("DELETE", f"/v1/default/banks/{TEST_BANK}", timeout=60)
    except Exception:
        pass


def check_queue() -> None:
    try:
        stats = http("GET", f"/v1/default/banks/{BANK}/stats")
        ops = http("GET", f"/v1/default/banks/{BANK}/operations?status=processing&limit=50")["operations"]
    except Exception as e:
        problems.append(f"Stats/operations query failed ({http_err(e)})")
        return
    cutoff = datetime.now(timezone.utc) - timedelta(hours=1)
    stuck = [o for o in ops if datetime.fromisoformat(o["created_at"]) < cutoff]
    if stuck:
        problems.append(f"{len(stuck)} op(s) stuck in processing >1h: "
                        + ", ".join(f"{o['task_type']} {o['id']}" for o in stuck[:3])
                        + ". Cancel with DELETE /v1/default/banks/hermes/operations/<id>")
    if stats.get("failed_consolidation"):
        problems.append(f"failed_consolidation={stats['failed_consolidation']} memory units")
    notes.append(f"bank {BANK}: {stats.get('total_nodes')} nodes, last consolidated {str(stats.get('last_consolidated_at'))[:16]}")


def check_plugin_log() -> None:
    # Only failures against the current server instance count: anything before the container
    # last started belongs to an incident that a recreate/restart has already dealt with.
    since_dt = datetime.now() - timedelta(hours=24)
    if CONTAINER_STARTED and CONTAINER_STARTED > since_dt:
        since_dt = CONTAINER_STARTED
    since = since_dt.strftime("%Y-%m-%d %H:%M:%S")
    pat = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d).*Hindsight (retain failed|flush-on-shutdown failed|writer did not stop): ?(.*)")
    hits: list[str] = []
    for path in AGENT_LOGS:
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    m = pat.match(line)
                    if m and m.group(1) >= since:
                        hits.append(f"{m.group(1)} {m.group(2)}: {m.group(3)[:80]}")
        except OSError:
            continue
    if hits:
        problems.append(f"{len(hits)} plugin retain failure(s) since {since}, latest: {sorted(hits)[-1]}")
    notes.append(f"plugin retain failures since {since}: {len(hits)}")


def main() -> int:
    if check_versions():
        check_container()
        check_round_trip()
        check_queue()
    else:
        check_container()
    check_plugin_log()
    if problems:
        print("Hindsight memory self-test FAILED\n")
        print("\n".join(f"- {p}" for p in problems))
        print("\n" + "; ".join(notes))
    elif VERBOSE:
        print("Hindsight memory self-test passed\n" + "\n".join(f"- {n}" for n in notes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
