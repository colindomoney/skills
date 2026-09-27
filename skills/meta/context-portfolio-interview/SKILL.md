---
name: context-portfolio-interview
description: Interview the user to build one file of their personal context portfolio (identity, role-and-responsibilities, current-projects, team-and-relationships, tools-and-systems, communication-style, goals-and-priorities, preferences-and-constraints, domain-knowledge or decision-log) following the NLW protocol, then write portfolio/<name>.md. Use when building or revising a context portfolio, or when asked to "do identity", "interview me for communication-style" or similar.
license: MIT
metadata:
  author: colindomoney
  tags: "meta, context, nlw"
  version: "0.1.0"
  status: live
  last-verified: "2026-09-27"
  upstream: https://github.com/nlwhittemore/personal-context-portfolio
---

# Context portfolio interview

You are the build partner for one file of the user's personal context portfolio. The protocol is Nathaniel Whittemore's; this skill just makes it runnable from a CLI instead of a paste.

## Inputs

- `NAME`: one of the ten portfolio file names. If the user didn't give one, ask which. Don't guess.
- The context repo root. Look for a directory containing `AGENTS.md` and `portfolio/` and `interview/` — the current working directory, or `~/context`, or `$CONTEXT_ROOT`. If none found, ask for the path and stop.

## Procedure

1. Read `interview/NAME.md`. It has two parts: an interview protocol and an output structure. Follow the protocol exactly — its question list, its "when you have enough" rule, and its "after drafting" step.
2. Read `portfolio/NAME.md` if it exists. If `status: live`, tell the user and ask whether they want to revise or start over. If `status: draft` with placeholder text, start fresh.
3. Read `AGENTS.md` and `portfolio/identity.md` (if live) so you don't re-ask what's already known. Skip questions the existing files already answer; say you're skipping them.
4. Ask the protocol's questions **one at a time**. Short questions. Don't stack them. Don't editorialise between answers.
5. When the protocol's "when you have enough" condition is met, stop asking and draft the file using the output structure from `interview/NAME.md`.
6. Show the draft. Ask what's wrong. Revise until the user says it's right. Corrections are the signal; do not accept a rubber stamp without asking at least once "what doesn't sound like you?"
7. Write to `portfolio/NAME.md` with this frontmatter, then the drafted body:

   ```
   ---
   title: <Title from the template's first heading>
   status: live
   last-verified: <today, YYYY-MM-DD>
   ---
   ```

8. Update the Status column for that file in `INDEX.md` to `live`.
9. For `communication-style.md` only: also ask the user for two or three real writing samples (a Slack message, a commit message, a blog paragraph) and save each verbatim under `portfolio/samples/<channel>.md`. Add a line at the end of the drafted file pointing at `samples/`.

## Rules

- Ground truth, not aspiration. If an answer sounds like how they wish they worked, ask for a recent concrete example.
- One page. Dense. If the draft runs long, cut it before showing it.
- Preserve the user's wording where it's distinctive. Don't smooth it into corporate English.
- Never invent facts to fill a section. Leave a `[not covered]` marker and tell the user.
- Don't run more than one file per invocation. When done, say which file is next in the recommended order (identity, role-and-responsibilities, current-projects, team-and-relationships, tools-and-systems, communication-style, goals-and-priorities, preferences-and-constraints, domain-knowledge, decision-log).
