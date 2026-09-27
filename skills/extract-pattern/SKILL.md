---
name: extract-pattern
description: Capture a how-to pattern that was just explained in conversation, or that lives in a repo, as a new reusable Agent Skill in the skills repo. Use when asked to "make this a skill", "capture this pattern" or "extract this", and proactively after the same how-to has been explained twice in one session.
license: MIT
metadata:
  author: colindomoney
  version: "0.1.0"
---

# Extract pattern

The pattern library grows one skill at a time, at the moment the user catches themselves re-explaining something. This skill is that moment.

## Inputs

- The pattern: either the conversation so far, or a repo/file path the user points at, or both.
- The skills repo root: a directory containing `templates/SKILL.md`. Try the current directory, `~/skills`, `$SKILLS_ROOT`. Ask if not found.

## Procedure

1. Name it. Lowercase, hyphens, technology-first, task-second: `traefik-static-ingress`, `mcp-server-scaffold`, `k3s-bootstrap`. Check the name doesn't already exist under `skills/`. If it does, ask whether to update that skill instead.
2. Copy `templates/SKILL.md` to `<name>/SKILL.md`.
3. Fill it from the source material. Rules:
   - The **canonical form** is real config or code, copied from the working repo, not rewritten from memory. Anything over ~60 lines goes in `references/` with the actual filename.
   - **Gotchas** are the most valuable section. Ask the user directly: "what has bitten you doing this?" Write down what they say.
   - **Description** is an activation trigger. It must name the technologies and the phrases the user would actually say. It is the only thing an agent sees before deciding to load the skill.
   - Don't pad. Under 200 lines for SKILL.md.
4. Set `metadata.status: live` and `metadata.last-verified` to today only if the config was copied from something currently running. Otherwise leave `skeleton` and say so.
5. If `uvx` or `npx` is available, run `uvx skillscheck skills/<name>` and fix what it reports.
6. Show the user the finished SKILL.md and the description on its own. Ask: "would you have said any of those trigger phrases?" Adjust.
7. Remind them to run the repo's `just install` (or `npx skills add`) so the new skill is picked up.

## Rules

- Never invent the pattern. If the source material doesn't cover a section, leave `[not covered]` and ask.
- One skill per pattern. If the explanation contains two patterns, say so and do the first.
- The skill must work for a stranger's agent with none of this conversation in context.
