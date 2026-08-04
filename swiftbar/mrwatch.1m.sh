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

# Seuil de nag (>Nh sans mon approbation), configurable
NAG_HOURS=$(jq -r '.approval_nag_hours // 2' "$CONFIG" 2>/dev/null); NAG_HOURS=${NAG_HOURS:-2}
NAG_SECS=$((NAG_HOURS * 3600))
now=$(date +%s)

# Santé (health.json écrit par check.sh à chaque passage).
#   health_warn = 1 si les appels GitLab échouent en série, OU si aucun passage réussi depuis >25min
#   (heartbeat périmé = check.sh ne tourne plus). N'alerte qu'en heures actives.
HEALTH="$DIR/health.json"
HALERT_AFTER=$(jq -r '.health_alert_after // 3' "$CONFIG" 2>/dev/null); HALERT_AFTER=${HALERT_AFTER:-3}
health_warn=0; health_msg=""
if [ "$loaded" -eq 1 ] && [ "$inhours" -eq 1 ]; then
  if [ -f "$HEALTH" ]; then
    cf=$(jq -r '.consecutiveFailures // 0' "$HEALTH" 2>/dev/null); [ -z "$cf" ] && cf=0
    ls=$(jq -r '.lastSuccess // 0' "$HEALTH" 2>/dev/null); [ -z "$ls" ] && ls=0
    if [ "$cf" -ge "$HALERT_AFTER" ]; then
      health_warn=1; health_msg="Appels GitLab en échec ($cf passages) — vérifier glab/réseau"
    elif [ "$ls" -gt 0 ] && [ "$((now - ls))" -gt 1500 ]; then
      health_warn=1; health_msg="Aucun passage réussi depuis $(((now - ls) / 60))min — bot bloqué ?"
    fi
  else
    health_warn=1; health_msg="Jamais exécuté (health.json absent)"
  fi
fi

# Compteurs depuis le snapshot écrit par check.sh
#   total      = MR ouvertes non-draft
#   unapproved = celles que JE n'ai pas encore approuvées (approved != true)
#   overdue    = unapproved dont le délai d'attente dépasse le seuil
total=0; unapproved=0; overdue=0; lastapprover=0
if [ -f "$OPENJSON" ]; then
  total=$(jq 'length' "$OPENJSON" 2>/dev/null); [ -z "$total" ] && total=0
  unapproved=$(jq '[.[] | select(.approved != true)] | length' "$OPENJSON" 2>/dev/null); [ -z "$unapproved" ] && unapproved=0
  overdue=$(jq --argjson now "$now" --argjson t "$NAG_SECS" \
    '[.[] | select(.approved != true and .firstSeen != null and ($now - .firstSeen) >= $t)] | length' \
    "$OPENJSON" 2>/dev/null); [ -z "$overdue" ] && overdue=0
  # MR dont je suis le DERNIER approbateur requis (n'attend plus qu'une approbation, pas la mienne)
  lastapprover=$(jq '[.[] | select(.approved != true and .approvalsLeft == 1)] | length' "$OPENJSON" 2>/dev/null); [ -z "$lastapprover" ] && lastapprover=0
fi

# --- Titre dans la barre de menu ---
if [ "$loaded" -ne 1 ]; then
  echo "🔍⏹"
elif [ "$health_warn" -eq 1 ]; then
  echo "🔍⚠️"                                  # bot en peine : API en échec ou plus de passage récent
elif [ "$lastapprover" -gt 0 ]; then
  echo "🎯 $lastapprover"                      # tu es le dernier approbateur requis : ton aval débloque le merge
elif [ "$overdue" -gt 0 ]; then
  echo "🔴 $unapproved"                       # pastille rouge : au moins une MR >${NAG_HOURS}h sans mon aval
elif [ "$inhours" -eq 1 ]; then
  if [ "$unapproved" -gt 0 ]; then echo "🔍 $unapproved"; else echo "🔍✓"; fi
else
  echo "🔍💤"
fi
echo "---"

# --- Statut ---
[ "$health_warn" -eq 1 ] && echo "⚠️ $health_msg | color=red"
if [ "$loaded" -eq 1 ]; then echo "Bot chargé | color=green"; else echo "Bot arrêté | color=red"; fi
if [ "$inhours" -eq 1 ]; then echo "Heures actives (${WS}h-${WE}h) | color=green"; else echo "Hors heures (${WS}h-${WE}h, lun-ven) | color=gray"; fi
lastts=$(tail -n 1 "$DIR/logs/check.log" 2>/dev/null | cut -c1-19)
[ -n "$lastts" ] && echo "Dernier passage: $lastts | size=11 color=gray"
if [ "$total" -gt 0 ]; then
  extra=""; [ "$lastapprover" -gt 0 ] && extra=" · 🎯 $lastapprover dont tu es le dernier"
  echo "$unapproved à approuver · $overdue en retard (>${NAG_HOURS}h)$extra | size=11 color=gray"
fi
echo "---"

# --- MR ouvertes (depuis open.json) ---
if [ "${total:-0}" -eq 0 ]; then
  echo "Aucune MR ouverte"
else
  j=0
  while [ "$j" -lt "$total" ]; do
    iid=$(jq -r ".[$j].iid" "$OPENJSON" 2>/dev/null)
    author=$(jq -r ".[$j].author" "$OPENJSON" 2>/dev/null | tr -d '|')
    title=$(jq -r ".[$j].title" "$OPENJSON" 2>/dev/null | tr -d '|')
    url=$(jq -r ".[$j].url" "$OPENJSON" 2>/dev/null)
    approved=$(jq -r ".[$j].approved // false" "$OPENJSON" 2>/dev/null)
    firstSeen=$(jq -r ".[$j].firstSeen // empty" "$OPENJSON" 2>/dev/null)
    approvalsLeft=$(jq -r ".[$j].approvalsLeft // -1" "$OPENJSON" 2>/dev/null)
    trivial=$(jq -r ".[$j].trivial // false" "$OPENJSON" 2>/dev/null)
    j=$((j + 1))
    report=$(ls -t "$RDIR"/*-mr"$iid"-*.md 2>/dev/null | head -1)

    # délai d'attente lisible (pour les MR non approuvées)
    wait_txt=""
    if [ -n "$firstSeen" ]; then
      age=$((now - firstSeen)); [ "$age" -lt 0 ] && age=0
      h=$((age / 3600)); m=$(((age % 3600) / 60))
      if [ "$h" -gt 0 ]; then wait_txt="${h}h${m}m"; else wait_txt="${m}m"; fi
    fi

    # Ligne parente = toggle (pas de href) : un clic déplie le sous-menu, n'ouvre pas la MR.
    # Seul le bouton « 🌐 Ouvrir la MR » ci-dessous ouvre le navigateur.
    if [ "$approved" = "true" ]; then
      echo "✅ !$iid · ${author:-?} | color=gray"
      status="Déjà approuvée par toi"
    elif [ "$approvalsLeft" = "1" ]; then
      echo "🎯 !$iid · ${author:-?} | color=orange"
      status="Tu es le dernier à approuver${wait_txt:+ (depuis $wait_txt)} — ton aval débloque le merge"
    elif [ -n "$firstSeen" ] && [ "$((now - firstSeen))" -ge "$NAG_SECS" ]; then
      echo "🔴 !$iid · ${author:-?} | color=red"
      status="⏰ En attente de ton approbation depuis ${wait_txt}"
    else
      echo "🟡 !$iid · ${author:-?}"
      status="À approuver${wait_txt:+ (depuis $wait_txt)}"
    fi

    echo "-- ${title:-(sans titre)} | color=gray"
    echo "-- $status | color=gray"
    echo "-- 🌐 Ouvrir la MR | href=$url"
    if [ -n "$report" ]; then
      echo "-- 📄 Ouvrir le rapport | bash=/usr/bin/open param1=-a param2=\"$APP\" param3=$report terminal=false"
    elif [ "$trivial" = "true" ]; then
      echo "-- 🔧 Review sautée (bump / petit changement) — à reviewer toi-même | color=gray"
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

# --- Logs (sous-menu) ---
LOGDIR="$DIR/logs"
echo "📜 Voir les logs"
echo "-- 📁 Dossier des logs | bash=/usr/bin/open param1=$LOGDIR terminal=false"
[ -f "$LOGDIR/check.log" ] && echo "-- 📄 check.log (surveillance) | bash=/usr/bin/open param1=-a param2=\"$APP\" param3=$LOGDIR/check.log terminal=false"
[ -f "$LOGDIR/learn.log" ] && echo "-- 🧠 learn.log (apprentissage) | bash=/usr/bin/open param1=-a param2=\"$APP\" param3=$LOGDIR/learn.log terminal=false"
latest_post=$(ls -t "$LOGDIR"/post-*.log 2>/dev/null | head -1)
[ -n "$latest_post" ] && echo "-- 📮 $(basename "$latest_post") (dernier post) | bash=/usr/bin/open param1=-a param2=\"$APP\" param3=$latest_post terminal=false"
# Aperçu rapide des 5 dernières lignes de check.log (lecture seule, dans le menu)
if [ -f "$LOGDIR/check.log" ]; then
  echo "-----"
  echo "-- Dernières lignes (check.log) | size=11 color=gray"
  tail -n 5 "$LOGDIR/check.log" 2>/dev/null | while IFS= read -r l; do
    echo "-- ${l//|/¦} | font=Menlo size=10 color=gray"
  done
fi

# --- Notes d'auto-évaluation (sous-menu) ---
GRADESDIR="$DIR/grades"
GSUMMARY="$GRADESDIR/summary.tsv"
if [ -f "$GSUMMARY" ]; then
  # agrégat sur toutes les MR notées : attrapés / total de points humains
  agg=$(awk -F'\t' 'NF>=6{hp+=$3; c+=$4; m+=$5; e+=$6; n++} END{ pct=(hp>0)?int(c*100/hp):0; printf "%d\t%d\t%d\t%d\t%d\t%d", n, hp, c, m, e, pct }' "$GSUMMARY")
  n_g=$(printf '%s' "$agg" | cut -f1); g_hp=$(printf '%s' "$agg" | cut -f2)
  g_c=$(printf '%s' "$agg" | cut -f3); g_m=$(printf '%s' "$agg" | cut -f4)
  g_e=$(printf '%s' "$agg" | cut -f5); g_pct=$(printf '%s' "$agg" | cut -f6)
  echo "📊 Qualité review (auto-éval) — $g_c/$g_hp · ${g_pct}%"
  echo "-- Attrapé $g_c/$g_hp points humains (${g_pct}%) sur $n_g MR · $g_m manqués · $g_e en plus | size=11 color=gray"
  echo "-- 📁 Dossier des notes | bash=/usr/bin/open param1=$GRADESDIR terminal=false"
  echo "-----"
  echo "-- Dernières MR notées | size=11 color=gray"
  ls -t "$GRADESDIR"/mr*.md 2>/dev/null | head -5 | while IFS= read -r gf; do
    giid=$(basename "$gf" | sed -E 's/^mr([0-9]+)-.*/\1/')
    line=$(awk -F'\t' -v id="$giid" '$2==id{r=$0} END{print r}' "$GSUMMARY")
    hpp=$(printf '%s' "$line" | cut -f3); cc=$(printf '%s' "$line" | cut -f4)
    echo "-- !$giid : $cc/$hpp attrapés | bash=/usr/bin/open param1=-a param2=\"$APP\" param3=$gf terminal=false"
  done
else
  echo "📊 Qualité review (auto-éval)"
  echo "-- (aucune note encore — activer auto_grade_reviews) | color=gray"
fi

echo "↻ Rafraîchir l'affichage | refresh=true"
