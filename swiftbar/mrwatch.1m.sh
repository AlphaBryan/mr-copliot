#!/bin/bash
# Plugin SwiftBar pour mr-watch — affiche l'état du bot dans la barre de menu.
# Lit uniquement des fichiers locaux (aucun appel réseau). Rafraîchi chaque minute.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DIR="/Users/bryan.mevo/mr-watch"
CONFIG="$DIR/config.json"
OPENJSON="$DIR/open.json"
LABEL="com.bryan.mevo.mrwatch"
UID_=$(id -u)

PROJECT=$(jq -r '.project' "$CONFIG" 2>/dev/null)
RDIR=$(jq -r '.reviews_dir' "$CONFIG" 2>/dev/null)
APP=$(jq -r '.open_report_app' "$CONFIG" 2>/dev/null)
WS=$(jq -r '.work_start_hour' "$CONFIG" 2>/dev/null); WS=${WS:-8}
WE=$(jq -r '.work_end_hour' "$CONFIG" 2>/dev/null); WE=${WE:-17}

# Bot chargé dans launchd ?
if launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then loaded=1; else loaded=0; fi

# Dans les heures de travail ?
HOUR=$((10#$(date +%H))); DOW=$(date +%u); inhours=0
[ "$DOW" -ge 1 ] && [ "$DOW" -le 5 ] && [ "$HOUR" -ge "$WS" ] && [ "$HOUR" -lt "$WE" ] && inhours=1

# Nombre de MR ouvertes (snapshot écrit par check.sh)
count=0; [ -f "$OPENJSON" ] && count=$(jq 'length' "$OPENJSON" 2>/dev/null); [ -z "$count" ] && count=0

# --- Titre dans la barre de menu ---
if [ "$loaded" -ne 1 ]; then
  echo "🔍⏹"
elif [ "$inhours" -eq 1 ]; then
  echo "🔍 $count"
else
  echo "🔍💤"
fi
echo "---"

# --- Statut ---
if [ "$loaded" -eq 1 ]; then echo "Bot chargé | color=green"; else echo "Bot arrêté | color=red"; fi
if [ "$inhours" -eq 1 ]; then echo "Heures actives (${WS}h-${WE}h) | color=green"; else echo "Hors heures (${WS}h-${WE}h, lun-ven) | color=gray"; fi
lastts=$(tail -n 1 "$DIR/logs/check.log" 2>/dev/null | cut -c1-19)
[ -n "$lastts" ] && echo "Dernier passage: $lastts | size=11 color=gray"
echo "---"

# --- MR ouvertes (depuis open.json) ---
if [ "${count:-0}" -eq 0 ]; then
  echo "Aucune MR ouverte"
else
  j=0
  while [ "$j" -lt "$count" ]; do
    iid=$(jq -r ".[$j].iid" "$OPENJSON" 2>/dev/null)
    author=$(jq -r ".[$j].author" "$OPENJSON" 2>/dev/null | tr -d '|')
    title=$(jq -r ".[$j].title" "$OPENJSON" 2>/dev/null | tr -d '|')
    url=$(jq -r ".[$j].url" "$OPENJSON" 2>/dev/null)
    j=$((j + 1))
    report=$(ls -t "$RDIR"/*-mr"$iid"-*.md 2>/dev/null | head -1)
    echo "!$iid · ${author:-?} | href=$url"
    echo "-- ${title:-(sans titre)} | href=$url"
    echo "-- 🌐 Ouvrir la MR | href=$url"
    if [ -n "$report" ]; then
      echo "-- 📄 Ouvrir le rapport | bash=/usr/bin/open param1=-a param2=\"$APP\" param3=$report terminal=false"
    else
      echo "-- (rapport pas encore généré) | color=gray"
    fi
  done
fi
echo "---"

# --- Actions ---
echo "↻ Forcer un check maintenant | bash=$DIR/force-check.sh terminal=false refresh=true"

# Review de ma branche locale courante (avant MR)
LREPO=$(jq -r '.local_repo_dir // ""' "$CONFIG" 2>/dev/null)
lbranch=""; [ -n "$LREPO" ] && lbranch=$(git -C "$LREPO" branch --show-current 2>/dev/null)
if [ -n "$lbranch" ]; then
  echo "🔎 Reviewer ma branche locale ($lbranch) | bash=$DIR/review-local-launch.sh terminal=false refresh=false"
else
  echo "🔎 Reviewer ma branche locale | bash=$DIR/review-local-launch.sh terminal=false refresh=false"
fi

echo "📁 Ouvrir le dossier des rapports | bash=/usr/bin/open param1=$RDIR terminal=false"
echo "↻ Rafraîchir l'affichage | refresh=true"
