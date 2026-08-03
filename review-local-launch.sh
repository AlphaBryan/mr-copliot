#!/bin/bash
# Lance review-local.sh en arrière-plan détaché (utilisé par le bouton du widget SwiftBar).
# Détaché => le clic du widget rend la main tout de suite ; review-local.sh notifie à la fin.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/bryan.mevo/mr-watch || exit 1
nohup /bin/bash review-local.sh >/dev/null 2>&1 &
exit 0
