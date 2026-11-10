"""Prove the CSP lets an analytics script AND its event beacon through, without
recording a pageview.

Plausible-style scripts send nothing when navigator.webdriver is true, so a
normal headless crawl never exercises connect-src for them. This spoofs a
normal browser, then intercepts the beacon: Playwright routing runs after the
browser's CSP check, so a request that reaches the route was allowed by CSP.
The beacon is answered locally and never reaches the analytics server.

Usage: python3 beacon_csp.py https://example.com https://analytics.example.net/api/event
"""
import asyncio, sys
from urllib.parse import urlparse
from playwright.async_api import async_playwright
from pwchrome import launch_kwargs

BASE, BEACON = sys.argv[1].rstrip("/"), sys.argv[2]
INIT = """
Object.defineProperty(navigator, 'webdriver', {get: () => false});
window.__csp = [];
document.addEventListener('securitypolicyviolation', e => window.__csp.push([e.effectiveDirective, e.blockedURI, e.disposition]));
"""

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(**launch_kwargs(["--disable-blink-features=AutomationControlled"]))
        ctx = await b.new_context(user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                                             "(KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36")
        await ctx.add_init_script(INIT)
        beacons, scripts = [], []

        async def on_beacon(route):
            beacons.append(route.request.url)
            await route.fulfill(status=202, body="ok")
        await ctx.route(BEACON, on_beacon)
        pg = await ctx.new_page()
        beacon_host = urlparse(BEACON).hostname
        pg.on("response", lambda r: scripts.append((r.status, r.url)) if urlparse(r.url).hostname == beacon_host else None)
        await pg.goto(BASE + "/", wait_until="load")
        await pg.wait_for_timeout(3000)
        csp = await pg.evaluate("window.__csp")
        await b.close()
    print("responses from analytics host:", scripts or "none")
    print("beacons allowed by CSP (intercepted, not recorded):", len(beacons))
    print("CSP violations:", csp or "none")
    sys.exit(0 if beacons and not csp else 1)

asyncio.run(main())
