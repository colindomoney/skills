#!/usr/bin/env bash
# Symlink every skill in this repo into each agent CLI's user-level skills
# directory found on this machine. Symlinks, not copies: edit once, every
# client sees it.
#
#   ~/.agents/skills   Codex CLI, Kimi Code CLI (shared cross-vendor location)
#   ~/.claude/skills   Claude Code
#   ~/.gemini/skills   Gemini CLI
#   ~/.codex/skills    older Codex builds
#

#
# Alternative for a fresh machine: `npx skills add <owner>/skills` detects
# installed clients itself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-install}"

CLIENT_DIRS=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
  "$HOME/.gemini/skills"
  "$HOME/.codex/skills"
)

skills() { find "$ROOT/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -exec dirname {} \; | sort; }

case "$MODE" in
  install|--install)
    for d in "${CLIENT_DIRS[@]}"; do
      parent="$(dirname "$d")"
      [[ -d "$parent" ]] || { echo "skip   $d  ($parent absent)"; continue; }
      mkdir -p "$d"
      while IFS= read -r s; do
        n="$(basename "$s")"
        if [[ -e "$d/$n" && ! -L "$d/$n" ]]; then echo "KEEP   $d/$n  (real dir exists)"; continue; fi
        ln -sfn "$s" "$d/$n"; echo "link   $d/$n"
      done < <(skills)
    done
    ;;
  --uninstall|uninstall)
    for d in "${CLIENT_DIRS[@]}"; do
      [[ -d "$d" ]] || continue
      for l in "$d"/*; do
        [[ -L "$l" && "$(readlink "$l")" == "$ROOT"/* ]] && { rm "$l"; echo "rm     $l"; }
      done
    done
    ;;
  --list|list) skills ;;
  *) echo "usage: $0 [install|--uninstall|--list]"; exit 2 ;;
esac
