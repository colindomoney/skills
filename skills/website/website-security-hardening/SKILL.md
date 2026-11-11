---
name: website-security-hardening
description: Harden one public website in phases, from inventory to verification from outside, so it sends a full security header set (HSTS ramp, report-only then enforced CSP, Permissions-Policy, COOP and CORP) and serves security.txt and robots.txt, with no third-party loads before interaction. On the homelab the headers are Traefik middlewares written as Compose labels in the site repo; Astro sites also need their inline scripts and styles removed. Use when asked to "harden the site", "add security headers", "add a CSP", "add security.txt", "audit the headers", "do the web hardening brief" or "verify the hardening", or when a site sends no HSTS or CSP, or loads fonts and scripts from CDNs.
license: MIT
metadata:
  author: colindomoney
  tags: "website, security-headers, csp, hsts, traefik, astro, security.txt, tls, privacy"
  version: "0.1.0"
  last-verified: "2026-11-10"
  status: live
---

# Website security hardening

A phased, read-only-until-approved procedure for bringing one public site up to a fixed header, file, TLS and privacy target, with every change in the site's repo so a redeploy keeps it. Headers go at the layer closest to the origin that is version-controlled and covers redirects and errors: on the homelab that is Traefik `headers` middlewares written as Compose labels in the site repo, not the app (Traefik generates the redirects) and not a shared proxy file (it would not deploy with the site). The full brief, phase by phase, is `references/brief.md`; follow its hard stops.

## When to use / when not to

- Use when: one site at a time needs headers, CSP, security.txt, robots.txt, TLS checks, or a before/after verification.
- Don't use when: putting a new site behind Traefik for the first time (use `homelab-traefik-ingress` first, then this). Stale ACME certificates: `infrastructure-traefik-stale-acme-certs`.

## The canonical form

Real files from colindomoney.com (PR #47, live 2026-11-10), in `references/`:

- `docker-compose.yml`: the full label set. Middlewares: `APP-headers` (HSTS, nosniff, frameDeny, referrer, permissions, COOP, X-Permitted-Cross-Domain-Policies) on every router; `APP-corp-same` / `APP-corp-cross`; `APP-csp` (`contentSecurityPolicyReportOnly`); `APP-api` (enforced `default-src 'none'; frame-ancestors 'none'` + `Cache-Control: no-store`). Routers: pages, `/api/` (priority 100), image files via `PathRegexp` (priority 90), http apex, https www, http www. Every router names `service=APP` explicitly once there is more than one.
- `security.txt.ts`: RFC 9116 endpoint rendered per request so `Expires` (now + 335 days) can never lapse; `/security.txt` is a 301 with a relative `Location`.
- `astro.config.mjs`: `build.inlineStylesheets: 'never'`, `vite.build.assetsInlineLimit: 0`, and a Shiki transformer that turns css-variables `style=` colours into classes.
- `fonts.css`: self-hosted Inter reproducing rsms.me's `inter.css` exactly.
- `turnstile.ts`: load Cloudflare Turnstile on first form focus; wait up to 10 s for the token on submit.

## Steps

1. **Inventory** (zoned, `dig`, curl): every hostname, proxied or not, what answers on 80/443, final URL. Check CNAME targets (incl. DKIM) are claimed. Stop and report.
2. **Discover the deploy** with evidence: compose labels, Dockerfile `CMD`, CI workflow `runs-on`, the host's etckeeper repo for the proxy's static config. **Find where the site runs before touching any host**: runner label (e.g. `um790b-docker`) -> `~/.ssh/config` alias -> snoopd `get_docker_containers` on that host, confirming the container name and that its image tag is the commit on `origin/main`. If any link is missing, ask; never take an address from a skill or reference file (those are scrubbed placeholders). Then read the Traefik API (`/api/http/routers`, `/api/http/middlewares`, `/api/entrypoints`) at `http://<host>:8080`, using the host found above, for neighbours, existing header middlewares and the Traefik version. Probe bare IP, unknown `Host` and unknown SNI. Stop and report.
3. **Baseline** with `scripts/header_grid.py`, `scripts/site_checks.py`, `scripts/crawl.py` and nmap `ssl-enum-ciphers`. Grep the source for every third-party origin the crawl saw and cite file:line. Stop with findings plus the decisions only the owner can make (security.txt contact, CORP for images, SRI exceptions, www hop count, indexing, analytics).
4. **Plan**: one branch, small commits. Remove third parties first (self-host), then remove inline scripts/styles, then add headers. HSTS starts at `max-age=300`; CSP starts report-only. Write the plan, get approval.
5. **Prove locally before the PR**: `scripts/local-traefik.sh up <repo>`, then `header_grid.py`-style curls with `--resolve` + production `Host`, then `crawl.py https://site --map 18443 --stub <analytics-host>`. Fix every violation at source. `local-traefik.sh down <repo>`.
6. **PR** with what changed, verification, rollback (revert the merge commit; an image-only rollback keeps the new labels), the `includeSubDomains` subdomain list, accepted exceptions, merge gates (security.txt mailbox exists), and a first-minute post-merge curl.
7. **Verify live** with all four scripts plus TLS re-test and `zoned lint`; ask before external scanners. Then, in the same session, open **one** follow-up PR that matches colindomoney.com's live values: HSTS `max-age=604800` and the CSP enforced (rename the label to `contentSecurityPolicy`) once the live crawl shows zero violations. Read colindomoney.com's live headers first (`curl -sI`), not this skill. Do not propose a multi-week ramp, later stages, reminders or calendar events: Colin does not track HSTS stages by date. Further increases happen only when he asks.

## Gotchas

- **Traefik version drift.** Local proof can't use `traefik:v3.6.0` on Docker Desktop 29 (provider gets a 400); use `traefik:v3.6`. Before deploying to an older host binary, check the option names exist at that tag (`pkg/config/dynamic/middlewares.go`, `pkg/muxer/http/matcher.go`). If the host rejects a label, the container's routers vanish and the site 404s while `deploy.sh`'s container-level health gate still passes: always run a post-merge curl.
- **Hostnames with ports break redirectregex.** Locally `Host: www.site:18443` doesn't match `^https?://www\.site/`. Send `-H 'Host: www.site'` with `--resolve`.
- **Traefik `stsSeconds` is never sent over http**, so one headers middleware can sit on the http routers too. Headers middleware listed before a redirect middleware does stamp the 301/308.
- **Traefik's own 404 (container down) has no headers.** Labels can't cover it; record it as a known gap.
- **Traefik permanent redirects** are 301 for GET and 308 for HEAD/other methods. Expected.
- **Astro inlines more than you think**: small processed scripts, `type="module"` scripts (treated as `is:inline`), `define:vars` scripts (one per page, different hash each time), small stylesheets, and Shiki's `style=` colours. Grep `dist/client/**/*.html` for `<script>` without `src`, `<style`, ` style="`: target zero of each.
- **Tailwind forms `<select>` arrow is a `data:` SVG** background: `img-src` needs `data:`.
- **Fontsource Inter is a subset** (drops ss07, ss08, zero, dlig, cv01-cv09). A site using rsms.me's `inter.css` renders the static "Inter" family, not InterVariable, because a later `:root { font-family: Inter }` wins. Vendor the official release files and reproduce `inter.css`; confirm with matching loaded faces and a 0-pixel screenshot diff against live.
- **Lazy-loading Turnstile** makes fast submits fail ("Please complete the security check"): wait for the token in the submit handler. Test with Cloudflare's always-pass key `1x00000000000000000000AA` and the POST intercepted.
- **Plausible-style analytics send nothing under automation** (`navigator.webdriver`), so a crawl never tests `connect-src` for them. `scripts/beacon_csp.py` spoofs a normal browser and intercepts the beacon after the CSP check, so no pageview is recorded.
- **Redirect `Location` built from `request.url`** behind a proxy can come out `http://`. Use a relative `Location`.
- **macOS `openssl` is LibreSSL**: no `x509 -ext`, and it prints a `Protocol` line even when the handshake fails. Judge versions by `Cipher is` vs `alert protocol version`, or use nmap.
- **Playwright "Executable doesn't exist"**: the Python package expects a newer browser than is cached. `scripts/pwchrome.py` launches the newest installed headless shell instead.
- **zsh doesn't word-split `$VAR`**: curl flag lists in a variable fail ("option ... is unknown"). Use a bash script with an array.
- **Report-only CSP noise**: every page logs that `upgrade-insecure-requests` is ignored; Turnstile's iframe logs violations of *its own* CSP (`hagen.challenges.cloudflare.com`). Neither is yours.
- **Mozilla Observatory caps report-only sites**: CSP report-only (-25), HSTS under six months (-10), no SRI on remaining third-party scripts (-5). Expect C+ at stage 1; enforcing the CSP lifts it, and the HSTS penalty stays until he chooses to go past one week. SSL Labs shows A until HSTS is at least six months, then A+.
- **securityheaders.com returns 403 to scripted requests.** Open it in a browser if a grade is wanted.

## Verify

```sh
cd scripts
python3 header_grid.py https://example.com                 # every class x GET/HEAD, exit 1 on any FAIL
python3 site_checks.py https://example.com                 # redirects, security.txt, robots, sitemap, probes, CORS, cookies
python3 crawl.py https://example.com --stub analytics.example.net   # 0 CSP violations, lazy third parties, fonts, broken assets
python3 beacon_csp.py https://example.com https://analytics.example.net/api/event
nmap -Pn -p 443 --script ssl-enum-ciphers example.com
```

colindomoney.com on 2026-11-10: header grid 270/0, site checks 71/0, crawl 0 violations over 116 routes, SSL Labs A, Observatory C+ (60) at HSTS stage 1 with report-only CSP.

## References

- `references/brief.md`: the full phased brief with hard stops and the target values
- `references/docker-compose.yml`, `security.txt.ts`, `astro.config.mjs`, `fonts.css`, `turnstile.ts`: the real files
- Site that uses this: `git@git.domoney.online:Websites/colindomoney.com.git` (PR #47)
- Related: `homelab-traefik-ingress`, `infrastructure-traefik-stale-acme-certs`
