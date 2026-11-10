"""Shared helper: find a Chromium build Playwright can launch.

Playwright's Python package often expects a newer browser build than the one
in ~/Library/Caches/ms-playwright, and fails with "Executable doesn't exist".
Use the newest headless shell that is actually installed instead of running
`playwright install`. Override with $PW_CHROMIUM.
"""
import glob, os

def chromium_path():
    if os.environ.get("PW_CHROMIUM"):
        return os.environ["PW_CHROMIUM"]
    pats = ["~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell",
            "~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell"]
    found = []
    for p in pats:
        found += glob.glob(os.path.expanduser(p))
    found.sort(key=lambda s: int(s.split("chromium_headless_shell-")[1].split("/")[0]))
    return found[-1] if found else None

def launch_kwargs(extra_args=None):
    kw = {"headless": True, "args": list(extra_args or [])}
    exe = chromium_path()
    if exe:
        kw["executable_path"] = exe
    return kw
