#!/usr/bin/env bash
# Demo step run by docker compose: syncs the menu twice. The second run must change
# nothing, which proves the sync is idempotent. Exit code 0 only if it does.
set -euo pipefail

echo "== First sync"
python sync_menu.py

echo
echo "== Second sync (must change nothing)"
second=$(python sync_menu.py)
echo "$second"

want="Sync: 0 new, 0 updated, 12 unchanged."
if [[ $(echo "$second" | tail -1) == "$want" ]]; then
  echo
  echo "Demo OK: the second run changed nothing."
else
  echo "FAILED: the second run should end with '$want'" >&2
  exit 1
fi
