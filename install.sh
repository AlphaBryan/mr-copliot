#!/bin/bash
# Installe (charge) le bot mr-watch dans launchd.
set -uo pipefail
DIR="/Users/bryan.mevo/mr-watch"
LABEL="com.bryan.mevo.mrwatch"
LEARN_LABEL="com.bryan.mevo.mrwatch-learn"
PL="$HOME/Library/LaunchAgents/$LABEL.plist"
LEARN_PL="$HOME/Library/LaunchAgents/$LEARN_LABEL.plist"
UID_=$(id -u)

chmod +x "$DIR/check.sh" "$DIR/review.sh" "$DIR/learn.sh" "$DIR/status.sh" "$DIR/uninstall.sh" 2>/dev/null
mkdir -p "$HOME/Library/LaunchAgents"
cp "$DIR/$LABEL.plist" "$PL"
cp "$DIR/$LEARN_LABEL.plist" "$LEARN_PL"

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PL"
launchctl enable "gui/$UID_/$LABEL"

launchctl bootout "gui/$UID_/$LEARN_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$LEARN_PL"
launchctl enable "gui/$UID_/$LEARN_LABEL"

echo "✅ Bot installé et chargé ($LABEL + $LEARN_LABEL)."
echo "   Surveillance : toutes les 15 min, 8h-17h, du lundi au vendredi."
echo "   Apprentissage : 8h05 et 13h05 (distille le style des reviewers seniors)."
echo "   Logs   : $DIR/logs/"
echo "   Reviews: $DIR/reviews/"
echo
echo "Astuce: pour baseliner les MR DÉJÀ ouvertes sans les reviewer maintenant,"
echo "        lance d'abord:  bash $DIR/check.sh --seed"
