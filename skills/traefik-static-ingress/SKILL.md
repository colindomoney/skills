---
name: traefik-static-ingress
description: Put a static site or container behind Traefik on the homelab using the standard static ingress pattern. Use when adding a new HTTP service to the homelab, editing Traefik routing config, or asked to "put X behind Traefik" or "host this the usual way".
license: MIT
metadata:
  author: colindomoney
  version: "0.0.1"
  last-verified: "unset"
  status: skeleton
---

# Traefik static ingress

**This skill is a skeleton.** The canonical config below is a placeholder. Do not use it as ground truth. If you are an agent and this file still says `status: skeleton`, tell the user and ask them to point you at the repo that actually implements the pattern so it can be filled in (see `extract-pattern`).

<!-- Colin: replace everything below with the real pattern. Copy the actual
     routing config into references/, keep the gotchas section honest. -->

## When to use / when not to

- Use when: a new HTTP service needs a hostname and TLS on the homelab.
- Don't use when: [the case that needs a different pattern — e.g. non-HTTP, k3s IngressRoute, external-only]

## The canonical form

```yaml
# references/dynamic.yml — REPLACE with the real file
http:
  routers:
    example:
      rule: "Host(`example.domoney.online`)"
      entryPoints: [websecure]
      service: example
      tls:
        certResolver: REPLACE
  services:
    example:
      loadBalancer:
        servers:
          - url: "http://REPLACE:8080"
```

## Steps

1. [ ]
2. [ ]
3. [ ]

## Gotchas

- [ ]

## Verify

```sh
curl -sI https://example.domoney.online | head -1
```

## References

- `references/` — real config once filled in
- Implementing repo: `REPLACE`
