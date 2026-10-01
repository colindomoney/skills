#!/usr/bin/env bash
# Symlink skills into each agent CLI's user-level skills directory found on
# this machine. Symlinks, not copies: edit once, every client sees it.
#
#   install.sh [GROUP...]      install these groups (default: all, minus _archive)
#   install.sh --uninstall     remove every symlink that points into this repo
#   install.sh --list          show what would be installed
#
# Repo layout is skills/<group>/<name>/SKILL.md. Clients only scan one level,
# so every skill is flattened to <client-dir>/<name>. Names are globally
# unique (enforced by `just check`), so groups never collide.
#
# Client dirs:
#   ~/.agents/skills   Codex CLI, Kimi Code CLI (shared cross-vendor location)
#   ~/.claude/skills   Claude Code
#   ~/.gemini/skills   Gemini CLI
#   ~/.codex/skills    older Codex builds
#
# Alternative on a machine without this repo: `npx skills add <owner>/skills`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/scripts/skills.py"

CLIENT_DIRS=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
  "$HOME/.gemini/skills"
  "$HOME/.codex/skills"
)

selected() {
  if (( $# == 0 )); then python3 "$PY" list --paths; return; fi
  for g in "$@"; do python3 "$PY" list --group "$g" --paths; done
}

uninstall() {
  for d in "${CLIENT_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    for l in "$d"/*; do
      # `if`, not `&&`: a false test on the last entry would make the function
      # return 1 and trip `set -e` at the call site.
      if [[ -L "$l" && "$(readlink "$l")" == "$ROOT"/* ]]; then rm "$l"; echo "rm     $l"; fi
    done
  done
}

case "${1:-}" in
  --uninstall|uninstall) uninstall; exit ;;
  --list|list) selected "${@:2}"; exit ;;
  --help|-h) sed -n '2,20p' "$0"; exit ;;
esac

# Re-installing with a different group set should drop what's no longer selected.
uninstall >/dev/null

PATHS=(); while IFS= read -r p; do PATHS+=("$p"); done < <(selected "$@")
(( ${#PATHS[@]} )) || { echo "no skills matched: $*"; exit 1; }

for d in "${CLIENT_DIRS[@]}"; do
  parent="$(dirname "$d")"
  [[ -d "$parent" ]] || { echo "skip   $d  ($parent absent)"; continue; }
  mkdir -p "$d"
  for s in "${PATHS[@]}"; do
    n="$(basename "$s")"
    if [[ -e "$d/$n" && ! -L "$d/$n" ]]; then echo "KEEP   $d/$n  (real dir exists)"; continue; fi
    ln -sfn "$s" "$d/$n"; echo "link   $d/$n"
  done
done
echo "installed ${#PATHS[@]} skill(s)${*:+ from groups: $*}"
