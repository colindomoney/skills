---
name: pattern-name
description: One sentence, written as an activation trigger not a summary. What task, in what context, makes an agent load this. Name the technologies. Example — "Expose a static site or container behind Traefik using file-provider ingress with automatic TLS. Use when adding a new service to the homelab, when the user says 'put X behind Traefik', or when editing dynamic.yml."
license: MIT
metadata:
  author: colindomoney
  version: "0.1.0"
  last-verified: "YYYY-MM-DD"
  status: skeleton   # skeleton | live
---

# Pattern name

One paragraph: what this pattern is for and the one-line reason it's done this way rather than the obvious alternative.

## When to use / when not to

- Use when: ...
- Don't use when: ... (name the alternative pattern)

## The canonical form

The real, tested artefact. Config, code, commands. Not prose describing config. If it's more than ~60 lines, put it in `references/` and link it.

```yaml
# references/example.yml
```

## Steps

1. Numbered, imperative, each one checkable.
2. Prefer a script in `scripts/` over a paragraph for anything deterministic.

## Gotchas

- The things that bit you. This section is why the skill exists.

## Verify

How the agent proves it worked. A curl, a command, an expected output.

## References

- `references/` — full config files, longer examples
- Repo that uses this pattern: `<url>` (the agent can read it directly)
