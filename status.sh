#!/bin/bash
# Affiche l'état du bot mr-watch.
set -uo pipefail
DIR="/Users/bryan.mevo/mr-watch"
LABEL="com.bryan.mevo.mrwatch"
UID_=$(id -u)

echo "=== launchd ==="
if launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
  launchctl print "gui/$UID_/$LABEL" | grep -E "state =|last exit code =|runs =" | sed 's/^/  /'
else
  echo "  (non chargé — lance bash $DIR/install.sh)"
fi

echo "=== MR suivies (state.tsv) ==="
[ -f "$DIR/state.tsv" ] && sed 's/^/  !/' "$DIR/state.tsv" || echo "  (aucune encore)"

echo "=== derniers logs check ==="
[ -f "$DIR/logs/check.log" ] && tail -n 8 "$DIR/logs/check.log" | sed 's/^/  /' || echo "  (vide)"

echo "=== derniers rapports ==="
ls -t "$DIR/reviews"/*.md 2>/dev/null | head -n 5 | sed 's/^/  /' || echo "  (aucun)"
