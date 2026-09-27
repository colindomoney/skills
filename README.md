# skills

How I do things, as [Agent Skills](https://agentskills.io). One directory per pattern, one `SKILL.md` each. Works in Claude Code, Codex CLI, Kimi Code CLI, Gemini CLI and anything else that reads the spec.

This is the pattern library half of a two-repo setup. The private `context` repo holds who I am; this public repo holds how I do things. They're separate because the trust boundary is different.

## Install

```sh
git clone https://github.com/colindomoney/skills ~/skills
cd ~/skills && just install       # symlinks into ~/.agents/skills, ~/.claude/skills, ~/.gemini/skills
```

or, on a machine without `just`:

```sh
npx skills add colindomoney/skills
```

Symlinks, so `git pull` is the update.

## Skills

| Skill | Status | What it does |
|---|---|---|
| `context-portfolio-interview` | live | Runs one file of NLW's personal-context-portfolio interview and writes the result |
| `extract-pattern` | live | Turns something I've just explained (or a repo) into a new skill here |
| `traefik-static-ingress` | skeleton | Host a service behind Traefik the standard way |

`just skeletons` lists what still needs filling in.

## Adding a pattern

Either `just new <name>` (copies `templates/SKILL.md` into `skills/<name>/`), or, better, in any agent CLI:

```
/extract-pattern
```

right after you've explained the thing. Then `just check` (runs `skillscheck` against the spec and the major clients).

## Conventions

- Names: lowercase, hyphens, technology first: `traefik-static-ingress`, `mcp-server-scaffold`.
- Description is an activation trigger, not a summary. Name the technologies and the phrases you'd actually say.
- Canonical form is real config copied from a working repo, in `references/` if long. Never prose describing config.
- `metadata.last-verified` gets bumped when the pattern is confirmed against something running, not when the file is touched.
- `metadata.status: skeleton` means an agent must not trust it and should say so.
- Under 200 lines per `SKILL.md`. Reference material goes in `references/`, deterministic steps in `scripts/`.
- Nothing private. No hostnames you wouldn't put on a slide, no tokens, no internal IPs. Those belong in the `context` repo or in secrets management.

## Layout

```
skills/<name>/SKILL.md     one per pattern; references/ and scripts/ beside it as needed
templates/SKILL.md         starting point for a new pattern
scripts/install.sh         symlink installer
.claude-plugin/plugin.json makes the repo installable as a Claude Code plugin as well
```
