"""Header grid: every target header x every response class, GET and HEAD.

Usage:
  python3 header_grid.py https://example.com [--www www.example.com]
      [--corp-images cross-origin|same-origin] [--api-path /api/some-route]
      [--csp enforce|report-only]

Response classes: home, deep page (from the sitemap), hashed script, font,
image, 404, 404 on an image path, an API route, security.txt, robots.txt,
/security.txt redirect, http->https apex, http www, https www.
Prints PASS/FAIL per header and lists every failure. Read-only: GET/HEAD
only, no redirects followed, 15 s timeouts. Exit code 1 on any failure.

Expectations follow the hardening target set in SKILL.md. Edit EXPECT_*
below if a site has agreed different values (e.g. SAMEORIGIN framing).
"""
import argparse, re, ssl, sys, http.client
from urllib.parse import urlparse

ap = argparse.ArgumentParser()
ap.add_argument("base")
ap.add_argument("--www")
ap.add_argument("--corp-images", default="cross-origin")
ap.add_argument("--api-path", default="/api/submissions")
ap.add_argument("--csp", default="report-only", choices=["enforce", "report-only"])
a = ap.parse_args()
BASE = a.base.rstrip("/")
HOST = urlparse(BASE).hostname
WWW = a.www or f"www.{HOST}"

EXPECT_PERMISSIONS = ("accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), "
                      "microphone=(), payment=(), usb=(), browsing-topics=(), interest-cohort=()")
LEAKS = ["server", "x-powered-by", "via", "x-aspnet-version", "x-generator", "x-xss-protection",
         "expect-ct", "public-key-pins", "feature-policy", "pragma"]

def request(method, url):
    u = urlparse(url)
    cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    kw = {"context": ssl.create_default_context()} if u.scheme == "https" else {}
    c = cls(u.hostname, u.port or (443 if u.scheme == "https" else 80), timeout=15, **kw)
    c.request(method, (u.path or "/") + (("?" + u.query) if u.query else ""), headers={"User-Agent": "header-grid/1"})
    r = c.getresponse()
    h = {k.lower(): v for k, v in r.getheaders()}
    body = r.read() if method == "GET" else b""
    c.close()
    return r.status, h, body

def find(pattern, text):
    m = re.search(pattern, text)
    return m.group(0) if m else None

home = request("GET", BASE + "/")[2].decode(errors="replace")
script = find(r'/[^"\'\s>]+\.js', home)
css = find(r'/[^"\'\s>]+\.css', home)
font = find(r'/[^)"\'\s]+\.woff2', request("GET", BASE + css)[2].decode(errors="replace")) if css else None
img = find(r'/[^"\'\s>]+\.(?:webp|png|jpe?g|avif)', home)
deep = None
for sm in ("/sitemap-index.xml", "/sitemap.xml"):
    st, _, b = request("GET", BASE + sm)
    if st == 200:
        locs = re.findall(r"<loc>([^<]+)</loc>", b.decode())
        if locs and locs[0].endswith(".xml"):
            locs = re.findall(r"<loc>([^<]+)</loc>", request("GET", BASE + urlparse(locs[0]).path)[2].decode())
        deep = max((urlparse(u).path for u in locs), key=lambda p: p.count("/"), default=None)
        break

CLASSES = [("home", f"{BASE}/", "html"), ("deep page", f"{BASE}{deep}" if deep else None, "html"),
           ("script", f"{BASE}{script}" if script else None, "asset"),
           ("font", f"{BASE}{font}" if font else None, "asset"),
           ("image", f"{BASE}{img}" if img else None, "image"),
           ("404", f"{BASE}/zz-header-grid-404", "html"),
           ("404 image path", f"{BASE}/zz-header-grid-404.png", "image"),
           ("api", f"{BASE}{a.api_path}", "api"),
           ("security.txt", f"{BASE}/.well-known/security.txt", "html"),
           ("robots.txt", f"{BASE}/robots.txt", "html"),
           ("/security.txt", f"{BASE}/security.txt", "html"),
           ("http apex", f"http://{HOST}/", "http"),
           ("http www", f"http://{WWW}/", "http"),
           ("https www", f"https://{WWW}/", "redirect")]

csp_hdr = "content-security-policy" if a.csp == "enforce" else "content-security-policy-report-only"
def expectations(kind):
    https = kind != "http"
    e = {
        "hsts": ("strict-transport-security",
                 (lambda v: bool(v and re.fullmatch(r"max-age=\d+(; includeSubDomains)?", v)))
                 if https else (lambda v: v is None)),          # never over plain http, never preload
        "nosniff": ("x-content-type-options", lambda v: v == "nosniff"),
        "xfo": ("x-frame-options", lambda v: v == "DENY"),
        "referrer": ("referrer-policy", lambda v: v == "strict-origin-when-cross-origin"),
        "permissions": ("permissions-policy", lambda v: v == EXPECT_PERMISSIONS),
        "coop": ("cross-origin-opener-policy", lambda v: v in ("same-origin", "same-origin-allow-popups")),
        "xpcdp": ("x-permitted-cross-domain-policies", lambda v: v == "none"),
    }
    if kind in ("html", "asset", "api"):
        e["corp"] = ("cross-origin-resource-policy", lambda v: v in ("same-origin", "same-site"))
    if kind == "image":
        e["corp"] = ("cross-origin-resource-policy", lambda v: v == a.corp_images)
    if kind in ("html", "asset", "image"):
        e["csp"] = (csp_hdr, lambda v: bool(v and "default-src 'none'" in v and "frame-ancestors 'none'" in v
                                             and "'unsafe-inline'" not in (re.search(r"script-src[^;]*", v) or [""])[0]))
    if kind == "api":
        e["csp"] = ("content-security-policy", lambda v: v == "default-src 'none'; frame-ancestors 'none'")
        e["no-store"] = ("cache-control", lambda v: v == "no-store")
    return e

COLS = ["hsts", "nosniff", "xfo", "referrer", "permissions", "coop", "xpcdp", "corp", "csp", "no-store", "leaks"]
rows, failures, skipped = [], [], []
for name, url, kind in CLASSES:
    if not url:
        skipped.append(name)
        continue
    for method in ("GET", "HEAD"):
        status, h, _ = request(method, url)
        ex, cells = expectations(kind), []
        for col in COLS:
            if col == "leaks":
                leaked = [k for k in LEAKS if k in h]
                ok = not leaked
                if leaked:
                    failures.append(f"{name} {method}: leaks {leaked}")
            elif col not in ex:
                cells.append("  -  ")
                continue
            else:
                hdr, pred = ex[col]
                ok = pred(h.get(hdr))
                if not ok:
                    failures.append(f"{name} {method} {status}: {hdr} = {h.get(hdr)!r}")
            cells.append(" PASS" if ok else " FAIL")
        rows.append((f"{name} [{method} {status}]", cells, h.get("location", "")))

w = max(len(r[0]) for r in rows)
print(f"{'class':<{w}} " + " ".join(f"{c[:5]:>5}" for c in COLS))
for label, cells, loc in rows:
    print(f"{label:<{w}} " + " ".join(cells) + (f"  -> {loc}" if loc else ""))
npass = sum(c.strip() == "PASS" for _, cs, _ in rows for c in cs)
print(f"\n{npass} pass, {len(failures)} fail" + (f"; skipped (not found on page): {skipped}" if skipped else ""))
for f in failures:
    print("FAIL:", f)
sys.exit(1 if failures else 0)
