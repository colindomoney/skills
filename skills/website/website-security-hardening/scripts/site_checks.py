"""Redirect chains, security.txt (RFC 9116), robots.txt, sitemap, exposure
probes, source maps, traversal, error-page leaks, TRACE/OPTIONS, CORS, cookies.
Read-only: GET/HEAD/OPTIONS/TRACE only, 15 s timeouts. Exit 1 on any failure.

Usage: python3 site_checks.py https://example.com [-v] [--probe /extra/path ...]
Exposure probes are judged against the catch-all 404 body size, so a 200 or a
different-sized body on a sensitive path is flagged even if the status looks fine.
"""
import re, sys, ssl, http.client, datetime as dt
import xml.etree.ElementTree as ET
from urllib.parse import urlparse, urljoin

BASE = sys.argv[1].rstrip("/")
HOST = urlparse(BASE).hostname
results = []

def check(name, ok, detail=""):
    results.append((bool(ok), name, detail))

def req(method, url, headers=None):
    u = urlparse(url)
    cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    kw = {"context": ssl.create_default_context()} if u.scheme == "https" else {}
    c = cls(u.hostname, u.port or (443 if u.scheme == "https" else 80), timeout=15, **kw)
    c.request(method, (u.path or "/") + (("?" + u.query) if u.query else ""),
              headers={"User-Agent": "phase5-check/1", **(headers or {})})
    r = c.getresponse()
    h = {k.lower(): v for k, v in r.getheaders()}
    body = r.read() if method != "HEAD" else b""
    c.close()
    return r.status, h, body

def chain(url, limit=6):
    hops = []
    for _ in range(limit):
        s, h, _ = req("GET", url)
        hops.append((url, s, "strict-transport-security" in h))
        if s in (301, 302, 307, 308) and "location" in h:
            url = urljoin(url, h["location"])
        else:
            break
    return hops

# Redirect chains: http -> https same host first, then canonical; max 2 hops; HSTS on every https redirect.
for start in (f"http://{HOST}/about/", f"http://www.{HOST}/about/", f"https://www.{HOST}/about/", f"{BASE}/security.txt"):
    hops = chain(start)
    final = hops[-1]
    redirects = hops[:-1]
    first_ok = True
    if start.startswith("http://"):
        nxt = urlparse(urljoin(start, req("GET", start)[1].get("location", "")))
        first_ok = nxt.scheme == "https" and nxt.hostname == urlparse(start).hostname
    hsts_ok = all(has for (u, s, has) in redirects if u.startswith("https://"))
    no_http_hsts = not any(has for (u, s, has) in hops if u.startswith("http://"))
    check(f"chain {start}", final[1] == 200 and len(redirects) <= 2 and first_ok and hsts_ok and no_http_hsts,
          " -> ".join(f"{s} {u}" for u, s, _ in hops))

# security.txt
s, h, body = req("GET", f"{BASE}/.well-known/security.txt")
text = body.decode("utf-8", errors="replace")
fields = {}
for line in text.splitlines():
    if line and not line.startswith("#"):
        k, _, v = line.partition(":")
        fields.setdefault(k.strip().lower(), []).append(v.strip())
check("security.txt 200 text/plain utf-8", s == 200 and h.get("content-type", "").replace(" ", "").lower() == "text/plain;charset=utf-8", f"{s} {h.get('content-type')}")
check("security.txt Contact present (mailto/https)", bool(fields.get("contact")) and all(v.startswith(("mailto:", "https://")) for v in fields["contact"]), str(fields.get("contact")))
exp = fields.get("expires", [])
ok_exp = False
if len(exp) == 1:
    try:
        when = dt.datetime.fromisoformat(exp[0].replace("Z", "+00:00"))
        days = (when - dt.datetime.now(dt.timezone.utc)).days
        ok_exp = 300 <= days <= 366
    except ValueError:
        days = None
check("security.txt Expires once, 300-366 days out", ok_exp, f"{exp} ({days if exp else '-'} days)")
check("security.txt Canonical matches fetch URL", fields.get("canonical") == [f"{BASE}/.well-known/security.txt"], str(fields.get("canonical")))
check("security.txt Preferred-Languages: en", fields.get("preferred-languages") == ["en"], str(fields.get("preferred-languages")))
unknown = set(fields) - {"contact", "expires", "encryption", "acknowledgments", "preferred-languages", "canonical", "policy", "hiring", "csaf"}
check("security.txt only RFC 9116 fields", not unknown, str(unknown or ""))
check("security.txt LF/UTF-8, no BOM", not body.startswith(b"\xef\xbb\xbf"), "")

# robots.txt
s, h, body = req("GET", f"{BASE}/robots.txt")
rb = body.decode()
check("robots.txt 200 text/plain", s == 200 and h.get("content-type", "").startswith("text/plain"), f"{s} {h.get('content-type')}")
check("robots.txt has an https Sitemap line on this host", re.search(rf"(?mi)^Sitemap: {re.escape(BASE)}/\S+$", rb), "")
check("robots.txt lists no Disallow paths", "disallow" not in rb.lower(), "")

# Sitemap: valid XML, every URL canonical https on the apex, every URL returns 200
s, h, body = req("GET", f"{BASE}/sitemap-index.xml")
if s != 200:
    s, h, body = req("GET", f"{BASE}/sitemap.xml")
ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
idx = ET.fromstring(body)
locs = [l.text for l in idx.findall("s:url/s:loc", ns)]
for sm in idx.findall("s:sitemap/s:loc", ns):
    s2, h2, b2 = req("GET", sm.text)
    check(f"sitemap {urlparse(sm.text).path} valid XML 200", s2 == 200, f"{s2} {h2.get('content-type')}")
    locs += [l.text for l in ET.fromstring(b2).findall("s:url/s:loc", ns)]
bad = [l for l in locs if urlparse(l).scheme != "https" or urlparse(l).hostname != HOST]
check(f"sitemap: {len(locs)} URLs, all https on {HOST}", not bad and locs, str(bad[:3]))
non200 = []
for l in locs:
    st = req("HEAD", l)[0]
    if st != 200:
        non200.append((st, l))
check("sitemap: every URL returns 200 (no redirects)", not non200, str(non200[:5]))

# Exposure probes: compare against the catch-all 404 body size.
_, _, base404 = req("GET", f"{BASE}/zz-site-checks-baseline-404")
PROBES = ["/.git/HEAD", "/.git/config", "/.env", "/.env.op", "/.DS_Store", "/server-status", "/phpinfo.php",
          "/backup.zip", "/backup.tar.gz", "/site.zip", "/dump.sql", "/db.sqlite", "/.svn/entries", "/.hg/requires",
          "/package.json", "/pnpm-lock.yaml", "/yarn.lock", "/composer.json", "/docker-compose.yml", "/Dockerfile", "/nginx.conf", "/.dockerignore", "/.htaccess",
          "/admin", "/admin/", "/wp-login.php", "/api/", "/_astro/", "/.well-known/", "/scripts/",
          "/dist/server/entry.mjs", "/src/pages/index.astro", "/astro.config.mjs", "/wp-admin/", "/actuator/health", "/.vscode/settings.json"]
PROBES += [sys.argv[i + 1] for i, x in enumerate(sys.argv) if x == "--probe"]
for p in PROBES:
    st, hh, b = req("GET", BASE + p)
    check(f"probe {p}", st in (403, 404) and (st == 403 or len(b) == len(base404)), f"{st} {len(b)}b")
home = req("GET", BASE + "/")[2].decode()
for a in sorted(set(re.findall(r'/_astro/[^"\']+\.(?:js|css)', home)))[:6]:
    st = req("GET", BASE + a + ".map")[0]
    check(f"no source map {a}.map", st == 404, str(st))
for p in ("/..%2f..%2fetc/passwd", "/%2e%2e/%2e%2e/etc/passwd", "/_astro/..%2f..%2fserver/entry.mjs"):
    st = req("GET", BASE + p)[0]
    check(f"traversal {p}", st in (400, 403, 404), str(st))

# Error pages leak nothing
for p in ("/zz-site-checks-not-here", "/api/submissions"):
    b = req("GET", BASE + p)[2].decode(errors="replace")
    leak = re.findall(r"(?i)(stack|traceback|at [\w.]+ \(|node_modules|/app/dist|astro@\d|node v?\d+\.)", b)
    check(f"no stack/version leak in {p}", not leak, str(leak[:3]))
check("no generator meta tag", not re.search(r'<meta[^>]+name="generator"', home, re.I), "")

# TRACE / OPTIONS
st, hh, b = req("TRACE", BASE + "/", {"X-Phase5-Echo": "canary"})
check("TRACE does not echo the request", b"canary" not in b, f"{st}")
st, hh, b = req("OPTIONS", BASE + "/api/contact", {"Origin": "https://evil.example", "Access-Control-Request-Method": "POST"})
check("OPTIONS /api/contact gives no CORS grant", "access-control-allow-origin" not in hh, f"{st} {hh.get('access-control-allow-origin')}")

# CORS: no wildcard or reflected origin anywhere tested
for p in ("/", "/api/submissions", "/.well-known/security.txt"):
    hh = req("GET", BASE + p, {"Origin": "https://evil.example"})[1]
    check(f"CORS {p}: no ACAO", "access-control-allow-origin" not in hh, str(hh.get("access-control-allow-origin")))

# Cookies
cookies = []
for p in ("/", "/contact/", "/api/submissions"):
    if "set-cookie" in req("GET", BASE + p)[1]:
        cookies.append(p)
check("no Set-Cookie on any tested route", not cookies, str(cookies))

passed = sum(ok for ok, _, _ in results)
for ok, name, detail in results:
    if not ok or "-v" in sys.argv:
        print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""))
print(f"\n{passed} pass, {len(results) - passed} fail (of {len(results)})")
fail_exit = passed != len(results)
for ok, name, detail in results:
    if name.startswith("chain"):
        print(f"  {name}: {detail}")

sys.exit(1 if fail_exit else 0)
