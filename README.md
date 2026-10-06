# skills

How I do things, as [Agent Skills](https://agentskills.io). One directory per pattern, one `SKILL.md` each. Works in Claude Code, Codex CLI, Kimi Code CLI, Gemini CLI and anything else that reads the spec.

This is the pattern-library half of a two-repo setup. The private `context` repo holds who I am; this public repo holds how I do things. They're separate because the trust boundary is different.

## Install

```sh
git clone https://github.com/colindomoney/skills ~/skills
cd ~/skills
just install                 # everything
just install homelab mcp     # only these groups — per-machine install sets
```

Symlinks into `~/.agents/skills` (Codex, Kimi), `~/.claude/skills`, `~/.gemini/skills`. `git pull` is the update. Re-running `just install` with a different group set replaces the previous set.

On a machine without `just`: `npx skills add colindomoney/skills`.

## Skills

<!-- skills-table -->
| Skill | Group | Status | Tags | What it does |
|---|---|---|---|---|
| `homelab-nm-source-routing` | homelab | live | homelab, networkmanager, iproute2, tailscale, linux | Set up source-based routing (SBR, policy routing) on a dual-homed Linux host with a public wired uplink and a WiFi/home uplink, using a NetworkManager dispatcher script with per-interface ip rules and routing tables, rolled out safely over Tailscale SSH |
| `homelab-traefik-ingress` | homelab | live | homelab, traefik, docker, compose, letsencrypt, forgejo | Put a website or container on the public internet behind the homelab Traefik (host-installed Traefik v3, Docker provider, Let's Encrypt HTTP-01) using Compose labels, with HTTP→HTTPS and www→apex redirects, and deploy it via a Forgejo Actions runner on the Docker host |
| `context-portfolio-interview` | meta | live | meta, context, nlw | Interview the user to build one file of their personal context portfolio (identity, role-and-responsibilities, current-projects, team-and-relationships, tools-and-systems, communication-style, goals-and-priorities, preferences-and-constraints, domain-knowledge or decision-log) following the NLW protocol, then write portfolio/<name>.md |
| `extract-pattern` | meta | live | meta, authoring | Capture a how-to pattern that was just explained in conversation, or that lives in a repo, as a new reusable Agent Skill in the skills repo |
<!-- /skills-table -->

`just list --tag traefik`, `just list --group homelab`, `just skeletons`. This table is generated: `just readme`.

## Layout and hierarchy

```
skills/<group>/<group>-<name>/SKILL.md    the pattern; references/ and scripts/ beside it
skills/_archive/                          dormant skills, out of the install path, still in git
templates/SKILL.md                        starting point for a new pattern
scripts/install.sh                        flattening symlink installer with group selection
scripts/skills.py                         inventory, checks, README generation
.claude-plugin/                           plugin + marketplace manifests (one plugin per group)
```

The spec gives you no hierarchy: names must be globally unique and clients scan one flat directory. So hierarchy lives in three places that survive flattening:

1. **Name prefix** = group. `homelab-traefik-ingress`, `mcp-server-scaffold`, `hw-kicad-tamper-mesh`. This is the only taxonomy an agent sees. Prefixes are decided once and never renamed.
2. **Group directory** = install set. Which skills load on which machine. Nothing else.
3. **`metadata.tags`** = for humans and `just list`. Agents never read tags during activation; don't expect them to help triggering.

Current groups: `meta` (tooling for this repo and the context portfolio; exempt from the prefix rule), `homelab`. Add groups by making the directory.

## Adding a pattern

In any agent CLI, right after you've explained the thing:

```
/extract-pattern
```

Or by hand: `just new homelab k3s-bootstrap`, fill in the template, `just check`, `just readme`.

## Conventions

- Description is an activation trigger, not a summary. Name the technologies and the phrases you'd actually say. It is the only thing the agent sees before deciding to load the skill.
- Canonical form is real config copied from a working repo, in `references/` if long. Never prose describing config.
- `metadata.status`: `skeleton` means an agent must not trust it and should say so; `live` means verified against something running; `dormant` means archived.
- `metadata.last-verified` gets bumped when the pattern is confirmed against something running, not when the file is touched.
- Under 200 lines per `SKILL.md`. Reference material in `references/`, deterministic steps in `scripts/`.
- Every installed skill costs ~50 tokens of context per turn in every client (name + description). Past ~100 skills, use install sets or push project-specific patterns into that repo's own `.agents/skills/`.
- A skill nobody has invoked in six months gets `just archive <name>`.
- Nothing private. No hostnames you wouldn't put on a slide, no tokens, no internal IPs. Those belong in the `context` repo or in secrets management.
