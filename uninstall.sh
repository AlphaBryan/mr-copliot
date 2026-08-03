#!/bin/bash
# Décharge (désinstalle) le bot mr-watch de launchd.
set -uo pipefail
LABEL="com.bryan.mevo.mrwatch"
LEARN_LABEL="com.bryan.mevo.mrwatch-learn"
PL="$HOME/Library/LaunchAgents/$LABEL.plist"
LEARN_PL="$HOME/Library/LaunchAgents/$LEARN_LABEL.plist"
UID_=$(id -u)

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$UID_/$LEARN_LABEL" 2>/dev/null || true
rm -f "$PL" "$LEARN_PL"
echo "🛑 Bot déchargé (surveillance + apprentissage). Les scripts et rapports restent dans /Users/bryan.mevo/mr-watch/."
