---
name: infrastructure-traefik-stale-acme-certs
description: Diagnose and fix stale or split Let's Encrypt certificates in a host-installed (bare-metal, systemd) Traefik v3 fronting Docker Compose deployments, by inspecting and pruning /var/lib/traefik/acme.json. Use when apex and www serve different certificates, a cert is missing a SAN that the labels declare, a renewal came back with the wrong names, Traefik logs "Error renewing certificate from LE" or "Unable to obtain ACME certificate" for a host you no longer serve, or when asked to "clean up acme.json", "why does www have a different cert", "remove the dead cert entries" or "Traefik keeps renewing an old cert".
license: MIT
metadata:
  author: colindomoney
  tags: "infrastructure, traefik, letsencrypt, acme, docker, tls"
  version: "0.1.0"
  last-verified: "2026-10-16"
  status: live
---

# Traefik: stale and split ACME certificates

Traefik keeps every certificate it has ever obtained in `acme.json`, keyed by the domain list it *requested* (`domain.main` + `domain.sans`), and renews each entry with that stored list. It never prunes an entry and never re-reads router labels when renewing. So any change to a router's hostnames or `tls.domains` leaves the old entry behind, and the leftover keeps renewing and can keep winning SNI selection. The fix is surgical editing of `acme.json` with Traefik stopped, not a redeploy: the labels are usually already right.

## When to use / when not to

- Use when: served cert names differ from the router's labels; apex and www get different certs; renewal errors for hosts that moved or died; after changing a site's hostnames.
- Don't use when: putting a new site behind Traefik or writing labels (use `homelab-traefik-ingress`); the cert is simply absent because HTTP-01 can't reach port 80 (fix DNS/firewall first).

## The canonical form

Two scripts, both run as root on the Traefik host. Hand them to the user as one line each if you lack sudo.

- `scripts/diagnose.sh [hostname ...]`: read-only. Lists each `acme.json` entry with stored names, the names actually in its certificate, expiry and flags (`STORED!=CERT`, `UNROUTED:<name>`, `OVERLAP:<name>`), stopped containers that still carry `Host()` rules, the last 7 days of renewal failures grouped by name, and for each hostname argument its DNS and the served cert fingerprint/SANs.
- `scripts/acme-edit.sh drop <main> ...` removes entries by stored `domain.main`. `scripts/acme-edit.sh rekey <current-main> <new-main> [<san> ...]` rewrites an entry's stored names so the next renewal requests the right set. Both stop Traefik, take a timestamped backup, edit a copy, validate the expected count, write back with `cat >` (keeps owner and mode 600), restart Traefik on any exit, and print the rollback command.

Env overrides for both: `ACME` (default `/var/lib/traefik/acme.json`), `RESOLVER` (default `letsencrypt`, must match `certificatesResolvers.<name>` and the `tls.certresolver` label).

## Steps

1. Check where you are: `hostname`. If you are already on the Traefik host, investigate locally; don't ask to SSH.
2. From outside, record what each hostname serves (fingerprint, notBefore, SANs). See Verify.
3. Find the config: `systemctl cat traefik` (ExecStart `--configFile`), then the `certificatesResolvers` block for the resolver name and `storage:` path.
4. Read the router labels the container is actually running with: `docker inspect <ctr> --format '{{json .Config.Labels}}' | jq 'with_entries(select(.key|test("rule|tls")))'`. Confirm `tls.domains[0].main`/`sans` are what you want. If they're wrong, fix the repo and redeploy first.
5. Run `sudo bash scripts/diagnose.sh <hostnames>` (the user runs it if you have no sudo). Then read the history: `journalctl -u traefik --since <date> | grep -iE 'renew|obtain|certif'`. A line like `Renewing certificate from LE : {Main:example.com SANs:[]}` shows which stored entry was renewed and with what names.
6. Decide per entry:
   - Stored names a subset of a newer combined entry, e.g. apex-only next to apex+www: `drop` it.
   - Entry whose cert is right but whose stored names are wrong (`STORED!=CERT`, e.g. stored `www.example.com []` holding an apex+www cert): `rekey` it to match the labels, otherwise the next renewal shrinks it.
   - `UNROUTED` and failing renewals (DNS moved to another box, NXDOMAIN): `drop` it. If a *running* container still routes that host, also disable its router or stop the container, or Traefik will immediately try to obtain a fresh cert and fail.
7. Run `acme-edit.sh`. Check its output, then Verify.

## Gotchas

- **Renewal uses stored names, not labels.** A 60-day cadence of identical single-name certs in CT logs is Traefik renewing a 90-day cert 30 days early from an old entry, not anything reacting to config.
- **Adding a SAN creates a second entry; it doesn't widen the first.** Observed: adding `sans=www` produced a cert covering apex+www, stored as `main=www.example.com` with empty SANs. That needs `rekey` or its renewal comes back www-only.
- **The single-name leftover wins SNI for its name.** Observed: with an apex-only entry and an apex+www entry both present, the apex served the apex-only cert and www the combined one. Removing the leftover is enough; no reissue needed, and Traefik serves the existing combined cert straight away.
- **Stop Traefik before editing.** It holds `acme.json` in memory and rewrites it.
- **Never `jq ... > acme.json` in place.** The redirect truncates first. If jq fails you have an empty store, and on restart Traefik reissues every site at once and can hit Let's Encrypt rate limits. Write to `.new`, validate, then `cat .new > acme.json`.
- **`acme.json` is root-only (600).** An agent without sudo can't read it. Give the user a script and one short `sudo bash <path>` line. Long pasted one-liners get wrapped by the terminal and break (`sh: Syntax error: newline unexpected`).
- **Removing an entry for a host that a running router still uses triggers an immediate new order.** If DNS points elsewhere it fails with `403 unauthorized` naming the other box's IP. Stopped containers' labels are ignored, but they retry if started.
- **Read the error to classify the dead entry:** `403 ... unauthorized` with a foreign IP means DNS points to another server. `400 ... NXDOMAIN` means the name no longer exists.
- **HTTP-01 doesn't use DNS TXT.** A leftover `_acme-challenge` TXT record is irrelevant and safe to delete.
- **crt.sh quirks:** query each hostname separately (`?q=www.example.com`), because one query only matches that exact identity. Certs from the last few days may not be indexed yet. Google Trust Services and Cloudflare wildcard certs appear for Cloudflare zones even when the records are DNS-only; they're never served. Let's Encrypt backdates `notBefore` by one hour, so issuance time ≈ notBefore + 1h. Use that to correlate with a merge or deploy.
- **The host may bind Traefik to the public IP only,** so `openssl s_client -connect 127.0.0.1:443` can fail. Test by public name.

## Verify

```bash
for h in example.com www.example.com; do echo "== $h"
  echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 -startdate -ext subjectAltName | grep -E 'Fingerprint|notBefore|DNS'
done
# expect identical fingerprints and every name in the SAN list
journalctl -u traefik --since -5min --no-pager | grep ERR   # expect no errors for the edited names
```

Then re-run `diagnose.sh`: no `STORED!=CERT` or `OVERLAP` for the site. Optionally check a CT history: `curl -s 'https://crt.sh/?q=<host>&output=json'`.

## References

- `scripts/diagnose.sh`, `scripts/acme-edit.sh`
- Proxy host layout (homelab): `/etc/traefik/traefik.yml`, `/etc/traefik/dynamic/`, `/var/lib/traefik/acme.json`, `journalctl -u traefik`
- Related skill: `homelab-traefik-ingress` (labels and deploy pattern these certs come from)
