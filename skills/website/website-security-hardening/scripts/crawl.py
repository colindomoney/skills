"""Headless crawl of every sitemap route: CSP violations, third-party origins,
Turnstile-style lazy loading, font loading, broken assets, console errors.

Usage:
  python3 crawl.py https://example.com
      [--map PORT]               map example.com:443 -> 127.0.0.1:PORT (local proof stack)
      [--stub HOST ...]          answer every request to HOST with 204 (e.g. your analytics,
                                 so a crawl never records pageviews)
      [--font FAMILY]            check this font family loaded on every page (default Inter)
      [--forms SELECTOR]         CSS selector for a form field to focus (default
                                 "#contact-form input, #subscribe-form input")
      [--lazy-origin HOST]       origin that must NOT load before interaction
                                 (default challenges.cloudflare.com)
      [--interact /path ...]     pages on which to focus a form field and wait 6 s

Violations are caught with a securitypolicyviolation listener, so report-only
policies are covered. Expected noise: "upgrade-insecure-requests is ignored
when delivered in a report-only policy" (one per page), and messages from
inside third-party iframes that quote *their* CSP, not yours.
"""
import argparse, asyncio, collections, re, ssl, urllib.request
from urllib.parse import urlparse
from playwright.async_api import async_playwright
from pwchrome import launch_kwargs

ap = argparse.ArgumentParser()
ap.add_argument("base")
ap.add_argument("--map")
ap.add_argument("--stub", nargs="*", default=[])
ap.add_argument("--font", default="Inter")
ap.add_argument("--forms", default="#contact-form input, #subscribe-form input")
ap.add_argument("--lazy-origin", default="challenges.cloudflare.com")
ap.add_argument("--interact", nargs="*", default=["/contact/", "/"])
a = ap.parse_args()
BASE = a.base.rstrip("/")
HOST = urlparse(BASE).hostname

ctx_ssl = ssl.create_default_context()
if a.map:
    ctx_ssl.check_hostname = False
    ctx_ssl.verify_mode = ssl.CERT_NONE

def fetch(path):
    url = BASE + path
    headers = {}
    if a.map:
        url = url.replace(HOST, f"127.0.0.1:{a.map}", 1)
        headers["Host"] = HOST
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20, context=ctx_ssl).read().decode()

urls = []
for sm_path in ("/sitemap-index.xml", "/sitemap.xml"):
    try:
        top = fetch(sm_path)
    except Exception:
        continue
    for loc in re.findall(r"<loc>([^<]+)", top):
        if loc.endswith(".xml"):
            urls += re.findall(r"<loc>([^<]+)", fetch(urlparse(loc).path))
        else:
            urls.append(loc)
    break
urls = sorted({BASE + urlparse(u).path for u in urls}) + [BASE + "/zz-crawl-404"]

INIT = """
window.__csp = [];
document.addEventListener('securitypolicyviolation', e => {
  window.__csp.push([e.effectiveDirective, e.blockedURI || '(inline)', e.disposition, e.sourceFile || '', e.lineNumber || 0]);
});
"""
violations, console, failed, broken = (collections.Counter() for _ in range(4))
origins = collections.defaultdict(set)
font_fail, lazy_early, form_checks = [], [], []

async def visit(ctx, url, interact):
    pg = await ctx.new_page()
    seen = []
    pg.on("request", lambda r: seen.append(r.url))
    pg.on("console", lambda m: console.update([f"{m.type}: {m.text[:150]}"]) if m.type in ("error", "warning") else None)
    pg.on("requestfailed", lambda r: failed.update([f"{r.failure} {r.url[:110]}"]))
    pg.on("response", lambda r: broken.update([f"{r.status} {urlparse(r.url).path[:90]}"])
          if r.status >= 400 and urlparse(r.url).hostname == HOST and r.request.resource_type != "document" else None)
    await pg.goto(url, wait_until="load", timeout=30000)
    await pg.wait_for_timeout(1200)
    path = urlparse(url).path
    if a.lazy_origin and any(a.lazy_origin in u for u in seen):
        lazy_early.append(path)
    for u in seen:
        o = urlparse(u)
        if o.scheme in ("http", "https") and o.hostname != HOST:
            origins[f"{o.scheme}://{o.netloc}"].add(path)
    ok_font = await pg.evaluate("f => [...document.fonts].some(x => x.family.replace(/\"/g,'') === f && x.status === 'loaded')", a.font)
    if a.font and not ok_font:
        font_fail.append(path)
    if interact:
        field = await pg.query_selector(a.forms)
        if field:
            n0 = len(seen)
            await field.focus()
            await pg.wait_for_timeout(6000)
            loaded = any(a.lazy_origin in u for u in seen[n0:])
            form_checks.append((path, f"{a.lazy_origin} loaded after focus: {loaded}"))
    for d, blocked, disp, src, line in await pg.evaluate("window.__csp"):
        violations[(d, blocked[:90], disp, f"{urlparse(src).path}:{line}")] += 1
    await pg.close()

async def main():
    extra = [f"--host-resolver-rules=MAP {HOST}:443 127.0.0.1:{a.map}"] if a.map else []
    async with async_playwright() as p:
        b = await p.chromium.launch(**launch_kwargs(extra))
        ctx = await b.new_context(ignore_https_errors=bool(a.map))
        await ctx.add_init_script(INIT)
        for host in a.stub:
            await ctx.route(f"https://{host}/**", lambda r: r.fulfill(status=204, body=""))
        for u in urls:
            try:
                await visit(ctx, u, False)
            except Exception as e:
                console.update([f"NAVFAIL {u} {str(e)[:80]}"])
        for path in a.interact:
            try:
                await visit(ctx, BASE + path, True)
            except Exception as e:
                console.update([f"NAVFAIL interact {path} {str(e)[:80]}"])
        await b.close()

asyncio.run(main())
print(f"routes crawled: {len(urls)}")
print("\n== third-party origins (pages contacted on)")
for o, pages in sorted(origins.items()):
    print(f"  {o}: {len(pages)}")
print(f"\n== {a.lazy_origin} requested before any interaction on: {len(lazy_early)} pages {lazy_early[:5]}")
for c in form_checks:
    print("  ", c)
print(f"== pages where font {a.font!r} did not load: {len(font_fail)} {font_fail[:5]}")
print("\n== CSP violations (directive, blocked, disposition, source:line) x count")
for k, n in violations.most_common(30):
    print(f"  {n:4d} x {k}")
print("  none" if not violations else "")
print("== broken same-origin assets (status >= 400)")
for k, n in broken.most_common(10):
    print(f"  {n:4d} x {k}")
print("  none" if not broken else "")
print("== console errors/warnings")
for k, n in console.most_common(15):
    print(f"  {n:4d} x {k}")
print("\n== failed requests")
for k, n in failed.most_common(10):
    print(f"  {n:4d} x {k}")
