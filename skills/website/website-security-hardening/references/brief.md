# Web hardening brief (the phased procedure, as given)

Harden the HTTP responses, well-known files, TLS and privacy posture of a website. Work in phases. Each phase ends with a report and a hard stop until the owner replies.

## Ground rules

- Read-only until the owner approves a plan. No SSH, no DNS or Cloudflare changes, no deploys, no pushes to a default branch, no service restarts. Hand over the exact commands for anything needing sudo, a restart or a deploy.
- Never guess how a site is deployed from its IP, headers or name. Find the evidence (repo, compose file, proxy config, CI workflow, DNS record) and cite the file and line. If you cannot find it, say so and ask.
- Every change lives in a repo or deploy config so a redeploy keeps it. No hand edits on a box. One branch and one PR per repo, small commits, each PR description listing what changed, how to verify and how to roll back.
- One site at a time through implement and verify. Do not batch a shared reverse-proxy change across all vhosts until it has been proven on one.
- Do not add `preload` to HSTS anywhere. Do not submit anything to hstspreload.org.
- Do not invent contact addresses, policy URLs or PGP keys. Ask.
- Do not add third-party services (report collectors, analytics, CDNs) without asking. Prefer self-hosted or none.
- If something found is worse than a missing header (exposed `.git`, `.env`, admin panel, open directory listing, expired cert), stop and report immediately rather than waiting for the phase report.

## Phase 0: inventory

Build the list of sites from zoned (`uv run zoned show <domain>`, `zoned lint`), not from memory.

- For each domain, list every hostname that resolves (apex, www, every other subdomain in DNS). For each: A/AAAA/CNAME target, proxied or DNS-only in Cloudflare, whether ports 80 and 443 answer, final URL after redirects, and whether it serves HTML, an API, a redirect only, or nothing.
- Group hostnames by what serves them (same IP, same proxy, same platform).
- Flag hostnames that resolve but serve nothing, and CNAMEs pointing at unclaimed third-party targets (check DKIM CNAME targets too).

Output a table. Stop.

## Phase 1: deployment discovery

For each serving group, establish and cite evidence for:

- Host and platform; TLS terminator and reverse proxy and where its config lives.
- Container or process serving the site, and the framework or static generator behind it.
- Repo, branch, build command, deploy path and deploy mechanism.
- Everything else served by the same proxy or IP, including the default vhost: what answers on the bare IP and on an unknown `Host`, and which names appear in the default certificate's SANs.
- The right layer for headers: the layer closest to the origin that is under version control and covers every response including errors and redirects. Shared baseline headers in one shared snippet at the proxy; CSP per site. If the platform cannot set response headers, say so and propose the smallest change that fixes it.

Output one section per group. Stop.

## Phase 2: baseline audit

For every hostname, GET and HEAD for: home 200, a deep page, a static asset, a 404, the http->https redirect, the www/apex redirect, any API route. Record:

- All response headers per class; which target headers are missing or wrong.
- Redirect chain: http must go to https on the same host first, then to the canonical host. Flag chains longer than two hops and any redirect without HSTS.
- TLS: versions (1.2 and 1.3 only), ciphers, chain, expiry, SAN coverage of apex and www, renewal mechanism, OCSP.
- DNS: CAA, DNSSEC, AAAA parity (repeat header tests over IPv6 if AAAA exists).
- Exposure probes (expect 404/403): `/.git/HEAD`, `/.env`, `/.DS_Store`, `/server-status`, `/phpinfo.php`, backups, `*.map`, directory listings, framework debug and admin paths. TRACE and OPTIONS. Error pages leak no stack traces or versions.
- Version leaks: `Server`, `X-Powered-By`, `Via`, `X-AspNet-Version`, `X-Generator`, generator meta tags.
- Cookies (Secure, HttpOnly, SameSite, prefix, lifetime). CORS (`*` or reflected origins with credentials).
- Page resource inventory from a headless crawl of every sitemap route: every origin for scripts, styles, fonts, images, frames, XHR/fetch, form actions; every inline script, inline style and inline handler; `eval`; mixed content.
- Privacy: third-party requests before consent, storage set before consent, where forms post, whether a privacy notice is linked from every page.
- Existing `/.well-known/security.txt`, `/security.txt`, `/robots.txt`, `/sitemap.xml`, `/.well-known/change-password`.
- `zoned lint` per domain.

Output a per-site findings table with severity and a list of decisions needed. Stop.

## Phase 3: plan

Per site, the exact config diff and the file it goes in. Wait for approval.

### Target headers on every https response (all status codes, all paths)

- `Strict-Transport-Security`: ramp `max-age=300` -> `604800` -> `2592000` -> `31536000`. `includeSubDomains` only once every subdomain serves valid https (list them in the PR). No `preload`. Never over plain http.
- `X-Content-Type-Options: nosniff` (confirm every asset has a correct `Content-Type`).
- `X-Frame-Options: DENY` plus `frame-ancestors 'none'` (SAMEORIGIN or a list only with evidence of legitimate framing).
- `Referrer-Policy: strict-origin-when-cross-origin`.
- `Permissions-Policy`: deny everything unused, at minimum `accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=(), browsing-topics=(), interest-cohort=()`.
- `Cross-Origin-Opener-Policy: same-origin` (`same-origin-allow-popups` for popup auth/payment).
- `Cross-Origin-Resource-Policy: same-origin` (`same-site` across own subdomains; `cross-origin` only on assets intentionally embedded elsewhere). No COEP unless cross-origin isolation is needed.
- `X-Permitted-Cross-Domain-Policies: none`.
- No `X-XSS-Protection` (or `0`); remove `Expect-CT`, `Public-Key-Pins`, `Feature-Policy`, `Pragma`, `X-Powered-By`; strip `Server` or its version.
- `Cache-Control: no-store` on authenticated or personalised responses.
- Proxy traps: nginx `always` and nested `add_header` inheritance; equivalent for other proxies. No duplicate headers from app and proxy.

### Content Security Policy

- Built from the Phase 2 inventory, starting `default-src 'none'`. Always `base-uri 'none'`, `object-src 'none'`, `form-action` limited to real targets, `frame-ancestors 'none'`, `upgrade-insecure-requests`.
- No `'unsafe-inline'` or `'unsafe-eval'` in `script-src`: hashes for static sites, nonces with `'strict-dynamic'` for server-rendered apps, or move inline code into files.
- Prefer removing a third-party origin (self-host) over allowlisting it. SRI with `crossorigin="anonymous"` on any third-party script or stylesheet that remains.
- Response header, never `<meta>`. Ship as `Content-Security-Policy-Report-Only` first; reporting via a small self-hosted collector or none plus a scripted crawl (owner chooses).
- Enforce only when a crawl of every route (including 404 and interactive flows) shows zero violations, and seven quiet days if a collector exists. Propose the switch; do not switch without go-ahead.
- JSON/API responses: `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` enforced from day one.

### Cookies, CORS, TLS, redirects, DNS

- Cookies: `Secure`, `HttpOnly` unless script reads it, `SameSite=Lax/Strict`, `__Host-` where host-scoped, shortest lifetime.
- No wildcard or reflected `Access-Control-Allow-Origin` with credentials.
- TLS 1.2/1.3 only, modern ciphers, full chain, renewal proven (show the job or log).
- http->https same host as a 301, then one canonical redirect; every redirect carries HSTS.
- Unknown `Host` and bare IP get a closed connection or bare 4xx with a non-revealing certificate.
- Propose (do not apply) CAA for the CAs in use, and DNSSEC.

### Files

- `/.well-known/security.txt` per RFC 9116, `text/plain; charset=utf-8`: `Contact:` (ask), `Expires:` ~11 months out generated at build/deploy/request time or guarded by a CI check, `Preferred-Languages: en`, one `Canonical:` per URL it is reachable at; ask about `Policy:`, `Encryption:`, signature. `/security.txt` 301s to it.
- `/robots.txt` as `text/plain` with a `Sitemap:` line; never list sensitive paths.
- `/sitemap.xml` from the build with canonical https URLs only.
- Well-known and static files carry the security headers too.

### Exposure and privacy

- Block or remove everything the probes found. Dotfiles and VCS denied at the proxy, no production source maps, no directory listing.
- For each third-party request before consent: remove, self-host or gate it; list what personal data each receives. Flag analytics/embeds/non-essential cookies with no consent mechanism or privacy notice; do not write legal text.

## Phase 4: implement

Per site: branch, commits, PR, deploy/restart commands. Wait for the owner to confirm deployment.

## Phase 5: verify from outside

Every hostname, IPv4 and IPv6 where applicable: re-run the Phase 2 matrix as a pass/fail grid; security.txt/robots.txt/sitemap validity; exposure probes; headless crawl (no console errors, no broken assets, CSP violations by directive); TLS re-test; `zoned lint` (explain every remaining finding). External scanners (Mozilla Observatory, securityheaders.com, SSL Labs) only after asking.

## Phase 6: keep it fixed

Propose separately: a CI check asserting headers and well-known files; scheduled `zoned lint` and new zoned web rules (Permissions-Policy, COOP, CORP, security.txt expiry and canonical, headers on 404 and redirects, cookie flags); a tracked list of report-only CSP sites and HSTS ramp stages with advance dates.

## Reporting format

At every stop: what was found or done, evidence (paths, command output), decisions needed, what happens next. No changes are implied by a report.
