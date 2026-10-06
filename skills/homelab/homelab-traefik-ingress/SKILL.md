---
name: homelab-traefik-ingress
description: Put a website or container on the public internet behind the homelab Traefik (host-installed Traefik v3, Docker provider, Let's Encrypt HTTP-01) using Compose labels, with HTTP→HTTPS and www→apex redirects, and deploy it via a Forgejo Actions runner on the Docker host. Use when adding a new site or service to the homelab, writing or fixing Traefik labels in docker-compose.yml, adding a www redirect, debugging a 404/cert error from Traefik, or asked to "put X behind Traefik", "host this the usual way" or "deploy it like the other sites".
license: MIT
metadata:
  author: colindomoney
  tags: "homelab, traefik, docker, compose, letsencrypt, forgejo"
  version: "0.1.0"
  last-verified: "2026-10-06"
  status: live
---

# Homelab: Traefik ingress for Compose services

One Traefik v3 instance runs as a **systemd host binary, not a Docker container**, on the Docker host, bound to the host's public address. It discovers services from Docker labels (`exposedByDefault: false`) and gets certificates from Let's Encrypt over HTTP-01. Each site is a Compose project in its own repo that carries its own routers and middlewares as labels, and a Forgejo runner on the same host deploys it on push to `main`. Labels rather than file-provider config because the routing then lives in the site's repo and goes live with its deploy; there is no shared proxy config to edit.

## When to use / when not to

- Use when: an HTTP(S) site or API on the Docker host needs a public hostname and TLS.
- Don't use when: the service sits behind Cloudflare Tunnel (`cloudflared` container, no Traefik labels), is not HTTP, or runs on a non-Docker host. For a non-Docker host process, use the file provider (`/etc/traefik/dynamic/*.yml`, watched) and point a `loadBalancer` server at `127.0.0.1:<port>`.

## The canonical form

Real files, copied from the running host and a live site repo, with addresses and names replaced by example values (`203.0.113.10` public, `192.168.1.50` LAN, `example.com`, app `site`):

- `references/traefik.yml`: static config, `/etc/traefik/traefik.yml`
- `references/traefik.service`: systemd unit
- `references/docker-compose.yml`: a site's Compose file with the full label set
- `references/deploy.sh`: build, smoke-test, swap, health-gate, roll back, prune
- `references/deploy.yml`: Forgejo workflow, `.forgejo/workflows/deploy.yml`

Proxy facts every site relies on (from `traefik.yml`): entrypoints `web` (:80) and `websecure` (:443) on the public IP; cert resolver `letsencrypt` (HTTP-01 on `web`); dashboard and `ping` on entrypoint `traefik`, LAN IP `:8080`, unauthenticated.

The per-site label set (`APP` = a name unique on the host, used to prefix every router and middleware):

```yaml
labels:
  - "traefik.enable=true"
  # HTTPS router
  - "traefik.http.routers.APP.rule=Host(`example.com`) || Host(`www.example.com`)"
  - "traefik.http.routers.APP.entrypoints=websecure"
  - "traefik.http.routers.APP.middlewares=APP-www-redirect"
  - "traefik.http.routers.APP.tls.certresolver=letsencrypt"
  - "traefik.http.routers.APP.tls.domains[0].main=example.com"
  - "traefik.http.routers.APP.tls.domains[0].sans=www.example.com"
  - "traefik.http.services.APP.loadbalancer.server.port=4321"
  # HTTP router: www redirect first, so http://www reaches https://apex in one hop
  - "traefik.http.routers.APP-http.rule=Host(`example.com`) || Host(`www.example.com`)"
  - "traefik.http.routers.APP-http.entrypoints=web"
  - "traefik.http.routers.APP-http.middlewares=APP-www-redirect,APP-https-redirect"
  - "traefik.http.middlewares.APP-https-redirect.redirectscheme.scheme=https"
  - "traefik.http.middlewares.APP-https-redirect.redirectscheme.permanent=true"
  - "traefik.http.middlewares.APP-www-redirect.redirectregex.regex=^https?://www\\.example\\.com/(.*)"
  - "traefik.http.middlewares.APP-www-redirect.redirectregex.replacement=https://example.com/$${1}"
  - "traefik.http.middlewares.APP-www-redirect.redirectregex.permanent=true"
```

No `www`: drop the `www` host from both rules, the `sans` line, the `APP-www-redirect` middleware and its references.

## Steps

1. DNS: point the apex (A) and `www` (CNAME to the apex) at the Docker host's public IP. Existing sites use DNS-only records (not Cloudflare-proxied); match that. Check with `dig +short` before deploying, because HTTP-01 fails otherwise.
2. Pick `APP`. Check it is not already used: `docker ps --format '{{.Names}}'` on the host, and no other container uses the same router or middleware names.
3. Add a `healthcheck` and the label set to the service in `docker-compose.yml` (see `references/docker-compose.yml`). Set `loadbalancer.server.port` to the port the app listens on inside the container. Do not publish it with `ports:`.
4. Copy `references/deploy.sh` to `scripts/deploy.sh` and set `PROJECT`, `IMAGE`, `CONTAINER`, `PORT` and `SMOKE_PATHS`. Copy `references/deploy.yml` to `.forgejo/workflows/` and set `runs-on` to the Docker host's runner label (copy it from another site repo).
5. Store the site's `.env` as the repo secret `ENV_FILE`. The workflow writes it out before building.
6. Validate locally: `docker compose config | grep traefik`. The rendered output shows `$${1}`, which is expected.
7. Open a PR (`fj pr create`). Merging to `main` deploys.

## Gotchas

- **Traefik is not in a container. Agents always assume it is.** It is `/usr/local/bin/traefik` under systemd (`traefik.service`). So there is:
  - no `traefik` container: `docker ps`, `docker logs traefik` and `docker restart traefik` find nothing. Use `systemctl status traefik` and `journalctl -u traefik`.
  - no Traefik Compose file to edit. Static config is `/etc/traefik/traefik.yml`, and certificates are in `/var/lib/traefik/acme.json` on the host, not in a volume.
  - no shared `proxy`/`traefik` external network. Do not add `networks:` to join one. The host binary reaches containers on their Compose bridge IPs. Only if a container joins more than one network, set `traefik.docker.network=<project>_default`.
  - no `ports:` needed on the site container, and no labels on any Traefik container.
- **Entrypoints are bound to the public IP, not `:80`/`:443`.** The host is dual-homed (see [[homelab-nm-source-routing]]). They were moved off the wildcard on purpose (`traefik.yml.bak.pre-publicnic` has the old form). A LAN-side request to the LAN IP will not reach the sites.
- **Router and middleware names are global** across every container and the file provider. Always prefix them with `APP`. A generic name such as `redirect-to-https` is already defined by another container.
- **Compose eats `$`.** Write `$${1}` in the replacement and `\\.` in the regex inside a double-quoted YAML label.
- **Permanent redirects are 308, not 301,** in Traefik v3 (`redirectscheme` and `redirectregex`). This is correct, so don't "fix" it or assert 301 in tests.
- **Put the `www` host on both routers and in the SANs.** Missing from a router means no redirect for that scheme. Missing from the SANs means no valid certificate for `https://www…`.
- **HTTP-01 means port 80 must reach Traefik** for every hostname in the cert. One unresolvable SAN fails the whole certificate.
- **Build args vs runtime env.** `PUBLIC_*` values that a static build inlines must be `build.args` in Compose. `env_file` alone only reaches the runtime. `deploy.sh` builds through `docker compose build` for this reason.
- **Rollback workflow needs `.env` too.** Compose refuses to start without `env_file`, so any job that runs `docker compose up` must write it first.

## Verify

```sh
for u in http://www.example.com/about https://www.example.com/about http://example.com/about https://example.com/; do
  echo "== $u"; curl -sI --max-time 10 "$u" | grep -i -E '^(HTTP|location)'
done
# expect 308 -> https://example.com/about for the first three, 200 for the last

echo | openssl s_client -connect example.com:443 -servername www.example.com 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
# expect DNS:example.com, DNS:www.example.com; issuer Let's Encrypt
```

The macOS `openssl` is LibreSSL and has no `x509 -ext`; use `-text | grep`. Failing that, read the Traefik dashboard on the LAN entrypoint (`http://<lan-ip>:8080/dashboard/`), which shows each router's status and errors.

## References

- `references/`: the real files listed above
- Proxy host: `/etc/traefik/traefik.yml`, `/etc/traefik/dynamic/`, `/var/lib/traefik/acme.json`, `journalctl -u traefik`
- Related: [[homelab-nm-source-routing]] (why the entrypoints bind to one address)
