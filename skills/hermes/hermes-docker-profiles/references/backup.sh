#!/usr/bin/env bash
#
# Back up DATA_DIRS only. hermes-home/ holds credentials you can reissue and
# state.db, so it isn't here, which keeps the tarball safe for a synced folder.
# Deliberately not `hermes backup`, which bundles secrets.
#
#   ./backup.sh /path/to/dest      # or set BACKUP_DIR

set -euo pipefail
cd "$(dirname "$0")"
source ./project.conf

KEEP="${BACKUP_KEEP:-30}"
DEST="${1:-${BACKUP_DIR:-}}"
[[ -n "$DEST" ]] || { echo "usage: ./backup.sh /path/to/dest" >&2; exit 1; }

for d in "${DATA_DIRS[@]}"; do
  [[ -d "$d" ]] || { echo "error: ${d}/ not found" >&2; exit 1; }
done
mkdir -p "$DEST"

out="${DEST}/${PROJECT}-data-$(date +%Y%m%d-%H%M%S).tgz"
tar czf "$out" --exclude='*/logs/*' "${DATA_DIRS[@]}"

if ! tar tzf "$out" >/dev/null 2>&1; then
  echo "error: archive failed verification, removing: $out" >&2
  rm -f "$out"; exit 1
fi
if tar tzf "$out" | grep -qE '(^|/)(\.env|auth\.json|mcp-tokens)'; then
  echo "error: archive contains a secret-shaped path, removing: $out" >&2
  rm -f "$out"; exit 1
fi
echo "backed up $(du -h "$out" | cut -f1 | tr -d ' ') -> ${out}"

# Keep the newest $KEEP. No mapfile: macOS ships bash 3.2.
old=$(ls -1t "${DEST}/${PROJECT}"-data-*.tgz 2>/dev/null | tail -n +$((KEEP + 1)) || true)
if [[ -n "$old" ]]; then
  echo "$old" | xargs rm -f
  echo "pruned $(echo "$old" | wc -l | tr -d ' ') old backup(s), keeping ${KEEP}"
fi
