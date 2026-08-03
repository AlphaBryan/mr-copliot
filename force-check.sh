#!/bin/bash
# Force un passage de check.sh tout de suite (ignore le filtre horaire).
# Utilisé par le bouton "Forcer un check" du widget SwiftBar.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/bryan.mevo/mr-watch || exit 1
MRWATCH_FORCE=1 /bin/bash check.sh
