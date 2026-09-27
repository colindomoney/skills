---
name: extract-pattern
description: Capture a how-to pattern that was just explained in conversation, or that lives in a repo, as a new reusable Agent Skill in the skills repo. Use when asked to "make this a skill", "capture this pattern" or "extract this", and proactively after the same how-to has been explained twice in one session.
license: MIT
metadata:
  author: colindomoney
  tags: "meta, authoring"
  version: "0.1.0"
  status: live
  last-verified: "2026-09-27"
---

# Extract pattern

The pattern library grows one skill at a time, at the moment the user catches themselves re-explaining something. This skill is that moment.

## Inputs

- The pattern: either the conversation so far, or a repo/file path the user points at, or both.
- The skills repo root: a directory containing `templates/SKILL.md`. Try the current directory, `~/skills`, `$SKILLS_ROOT`. Ask if not found.

## Procedure

1. Pick the group. `ls skills/` shows existing groups (e.g. `homelab`, `mcp`, `hw`, `sec`, `write`). Use an existing one unless the pattern clearly needs a new domain; if new, ask the user to confirm the group name, since prefixes are permanent.
2. Name it `<group>-<thing>`, lowercase, hyphens, technology-first: `homelab-traefik-ingress`, `mcp-server-scaffold`, `hw-kicad-tamper-mesh`. Check it doesn't already exist anywhere under `skills/` (`python3 scripts/skills.py list`). If it does, ask whether to update that skill instead.
3. Run `just new <group> <thing>` (or copy `templates/SKILL.md` to `skills/<group>/<group>-<thing>/SKILL.md` by hand). Set `metadata.tags` with the group first, then the technologies.
4. Fill it from the source material. Rules:
   - The **canonical form** is real config or code, copied from the working repo, not rewritten from memory. Anything over ~60 lines goes in `references/` with the actual filename.
   - **Gotchas** are the most valuable section. Ask the user directly: "what has bitten you doing this?" Write down what they say.
   - **Description** is an activation trigger. It must name the technologies and the phrases the user would actually say. It is the only thing an agent sees before deciding to load the skill.
   - Don't pad. Under 200 lines for SKILL.md.
5. Set `metadata.status: live` and `metadata.last-verified` to today only if the config was copied from something currently running. Otherwise leave `skeleton` and say so.
6. Run `just check` (frontmatter conventions + spec) and `just readme`. Fix what `check` reports.
7. Show the user the finished SKILL.md and the description on its own. Ask: "would you have said any of those trigger phrases?" Adjust.
8. Remind them to run the repo's `just install` (or `npx skills add`) so the new skill is picked up.

## Rules

- Never invent the pattern. If the source material doesn't cover a section, leave `[not covered]` and ask.
- One skill per pattern. If the explanation contains two patterns, say so and do the first.
- The skill must work for a stranger's agent with none of this conversation in context.
