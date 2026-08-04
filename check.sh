#!/bin/bash
# mr-watch — détecte les MR non-draft des personnes surveillées, notifie, déclenche la review.
# Compatible bash 3.2 (macOS). Lancé toutes les 15 min par launchd.
# Usage:
#   check.sh            -> run normal (respecte les heures de travail)
#   check.sh --seed     -> enregistre les MR actuelles SANS notifier ni reviewer (baseline)
#   MRWATCH_FORCE=1 check.sh  -> ignore le filtre heures de travail (pour tester)
set -uo pipefail

DIR="/Users/bryan.mevo/mr-watch"
CONFIG="$DIR/config.json"
STATE="$DIR/state.tsv"
LOG="$DIR/logs/check.log"
mkdir -p "$DIR/logs"

SEED=0
[ "${1:-}" = "--seed" ] && SEED=1

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# --- config ---
PROJECT=$(jq -r '.project' "$CONFIG")
ENC=$(printf '%s' "$PROJECT" | sed 's#/#%2F#g')
WS=$(jq -r '.work_start_hour' "$CONFIG")
WE=$(jq -r '.work_end_hour' "$CONFIG")
NAG_HOURS=$(jq -r '.approval_nag_hours // 2' "$CONFIG")
NAG_SECS=$((NAG_HOURS * 3600))
# Quand je suis le DERNIER approbateur requis : relance répétée toutes les N minutes (défaut 15),
# tant que je ne l'ai pas approuvée — au lieu d'une seule notif.
LAST_REPEAT_MIN=$(jq -r '.last_approver_repeat_minutes // 15' "$CONFIG")
LAST_REPEAT_SECS=$((LAST_REPEAT_MIN * 60))
# Auto-post de la review (inline) ~post_delay_minutes après la création de la MR.
# Valeurs possibles de auto_post_review : false (défaut, off) | true (poste réel) | "dryrun" (journalise sans envoyer).
AUTO_POST=$(jq -r '.auto_post_review // false' "$CONFIG")
POST_DELAY_MIN=$(jq -r '.post_delay_minutes // 15' "$CONFIG")
POST_DELAY_SECS=$((POST_DELAY_MIN * 60))
REVIEWS_DIR=$(jq -r '.reviews_dir // ""' "$CONFIG"); [ -z "$REVIEWS_DIR" ] && REVIEWS_DIR="$DIR/reviews"
# Santé : alerte après N passages consécutifs où les appels GitLab échouent (dead-man's switch).
HEALTH="$DIR/health.json"
HALERT_AFTER=$(jq -r '.health_alert_after // 3' "$CONFIG")
# Skip des MR triviales : diff ne touchant QUE des manifestes de dépendances (bumps).
SKIP_TRIVIAL=$(jq -r '.skip_trivial_reviews // true' "$CONFIG")
TRIVIAL_MAX_FILES=$(jq -r '.trivial_max_files // 3' "$CONFIG")
TRIVIAL_PATTERNS_JSON=$(jq -c '.trivial_file_patterns // ["Directory.Packages.props","*.csproj","*.props","package.json","package-lock.json","yarn.lock","pnpm-lock.yaml"]' "$CONFIG")
# Auto-évaluation : après merge d'une MR reviewée, comparer ma review aux commentaires humains.
AUTO_GRADE=$(jq -r '.auto_grade_reviews // false' "$CONFIG")
GRADED_STATE="$DIR/graded-state.tsv"; [ "$AUTO_GRADE" = "true" ] && touch "$GRADED_STATE" 2>/dev/null

# Renvoie "true" si la MR ne modifie QUE des fichiers de dépendances (≤ TRIVIAL_MAX_FILES).
# Échec API / doute -> "false" (on fait la review : on ne skippe jamais à tort).
is_trivial_mr() {
  local iid="$1" d n f base match
  d=$(glab api "projects/$ENC/merge_requests/$iid/diffs?per_page=50" 2>>"$LOG")
  printf '%s' "$d" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo false; return; }
  n=$(printf '%s' "$d" | jq 'length'); [ -z "$n" ] && n=0
  { [ "$n" -eq 0 ] || [ "$n" -gt "$TRIVIAL_MAX_FILES" ]; } && { echo false; return; }
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base=$(basename "$f"); match=0
    while IFS= read -r pat; do
      case "$base" in $pat) match=1; break;; esac
    done < <(printf '%s' "$TRIVIAL_PATTERNS_JSON" | jq -r '.[]')
    [ "$match" -eq 0 ] && { echo false; return; }
  done < <(printf '%s' "$d" | jq -r '.[].new_path')
  echo true
}

USERS=()
while IFS= read -r u; do [ -n "$u" ] && USERS+=("$u"); done < <(jq -r '.watch_users[]' "$CONFIG")
WDAYS=" $(jq -r '.work_days[]' "$CONFIG" | tr '\n' ' ')"

# --- ntfy (notifications téléphone) ---
NTFY_ENABLED=$(jq -r '.ntfy.enabled // false' "$CONFIG")
NTFY_URL="$(jq -r '.ntfy.server // ""' "$CONFIG")/$(jq -r '.ntfy.topic // ""' "$CONFIG")"
NTFY_TOKEN=$(jq -r '.ntfy.token // ""' "$CONFIG")
ntfy_send() { # $1 titre  $2 corps  $3 url_clic  $4 tags
  [ "$NTFY_ENABLED" = "true" ] || return 0
  if [ -n "$NTFY_TOKEN" ]; then
    curl -s -m 10 -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $1" -H "Click: $3" -H "Tags: $4" -d "$2" "$NTFY_URL" >/dev/null 2>&1 || log "WARN ntfy échec"
  else
    curl -s -m 10 -H "Title: $1" -H "Click: $3" -H "Tags: $4" -d "$2" "$NTFY_URL" >/dev/null 2>&1 || log "WARN ntfy échec"
  fi
}

# --- dans les heures de travail ? ---
# On ne s'arrête PLUS tôt hors heures : le snapshot des MR ouvertes (open.json) est
# rafraîchi à chaque passage. Seuls les NOTIFS + REVIEWS sont réservés aux heures actives.
HOUR=$((10#$(date +%H)))
DOW=$(date +%u)
INHOURS=0
case "$WDAYS" in *" $DOW "*) [ "$HOUR" -ge "$WS" ] && [ "$HOUR" -lt "$WE" ] && INHOURS=1 ;; esac
[ "${MRWATCH_FORCE:-0}" = "1" ] && INHOURS=1

# --- lecture de l'état précédent (le fichier n'est réécrit qu'à la fin) ---
get_sha() { [ -f "$STATE" ] && awk -F'\t' -v k="$1" '$1==k{print $2}' "$STATE" || true; }

# Valeur d'un champ dans l'ancien snapshot open.json (reporte firstSeen / notified2h / approved).
# NB: on n'utilise pas `// empty` car `false // empty` renverrait empty pour un booléen false.
prev_field() {
  [ -f "$DIR/open.json" ] || return 0
  jq -r --arg iid "$1" --arg f "$2" \
    'first(.[] | select(.iid==$iid)) | .[$f] | select(. != null)' \
    "$DIR/open.json" 2>/dev/null
}

NOW=$(date +%s)
# iids ouverts au passage précédent (pour détecter les MR mergées -> auto-évaluation)
OLD_IIDS=$(jq -r '.[].iid' "$DIR/open.json" 2>/dev/null | sort -u)
NEWSTATE=$(mktemp)   # journal anti-doublon reconstruit (uniquement les MR encore ouvertes)
OPENTMP=$(mktemp)    # snapshot des MR ouvertes, pour le widget
FETCH_FAILED=0       # passe à 1 si un appel glab échoue (auth/DNS/réseau)
FAILED_USERS=" "     # liste des users dont le fetch a échoué (pour conserver LEURS MR dans open.json)
REVIEW_QUEUE=" "     # iids à reviewer APRÈS la boucle (la review claude est lente : on persiste d'abord)

for u in "${USERS[@]}"; do
  json=$(glab api "projects/$ENC/merge_requests?state=opened&author_username=$u&wip=no&per_page=50" 2>>"$LOG")
  rc=$?
  # Un échec API (rc≠0, ou sortie qui n'est pas un tableau JSON : 401, message d'erreur, vide)
  # ne doit PAS être traité comme « 0 MR » — sinon on rate les MR et on efface l'état.
  if [ "$rc" -ne 0 ] || ! printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "ERROR appel glab échoué pour $u (rc=$rc) — MR de $u NON vérifiées ce passage, état préservé"
    FETCH_FAILED=1
    FAILED_USERS="$FAILED_USERS$u "
    continue
  fi
  count=$(printf '%s' "$json" | jq 'length' 2>/dev/null || echo 0)
  [ -z "$count" ] && count=0
  i=0
  while [ "$i" -lt "$count" ]; do
    iid=$(printf '%s' "$json"    | jq -r ".[$i].iid")
    sha=$(printf '%s' "$json"    | jq -r ".[$i].sha")
    title=$(printf '%s' "$json"  | jq -r ".[$i].title")
    url=$(printf '%s' "$json"    | jq -r ".[$i].web_url")
    draft=$(printf '%s' "$json"  | jq -r ".[$i].draft")
    author=$(printf '%s' "$json" | jq -r ".[$i].author.username")
    created=$(printf '%s' "$json" | jq -r ".[$i].created_at")
    i=$((i + 1))

    [ "$draft" = "true" ] && continue

    # created_at (UTC, ISO8601 avec fraction+Z) -> epoch, pour le délai d'auto-post
    cbase="${created%.*}"; cbase="${cbase%Z}"
    created_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$cbase" +%s 2>/dev/null); [ -z "$created_epoch" ] && created_epoch=0

    # --- mon statut d'approbation (+ approvals_left pour le nag « dernier approbateur ») ---
    appr=$(glab api "projects/$ENC/merge_requests/$iid/approvals" 2>>"$LOG")
    if printf '%s' "$appr" | jq -e 'has("user_has_approved")' >/dev/null 2>&1; then
      approved=$(printf '%s' "$appr" | jq -r '.user_has_approved')
      approvals_left=$(printf '%s' "$appr" | jq -r '.approvals_left // -1')
    else
      # appel approvals KO : on réutilise la dernière valeur connue plutôt que d'inventer.
      approved=$(prev_field "$iid" approved); [ -z "$approved" ] && approved=false
      approvals_left=$(prev_field "$iid" approvalsLeft); [ -z "$approvals_left" ] && approvals_left=-1
      log "WARN approvals indisponible !$iid — réutilise approved=$approved"
    fi
    # « dernier approbateur » : la MR n'attend plus qu'UNE approbation et ce n'est pas la mienne.
    last_approver=false
    [ "$approved" != "true" ] && [ "$approvals_left" = "1" ] && last_approver=true

    if [ "$approved" = "true" ]; then
      first_seen=""; notified2h=false; last_notif_at=0
    else
      first_seen=$(prev_field "$iid" firstSeen); [ -z "$first_seen" ] && first_seen=$NOW
      notified2h=$(prev_field "$iid" notified2h); [ "$notified2h" = "true" ] || notified2h=false
      last_notif_at=$(prev_field "$iid" lastApproverNotifiedAt); [ -z "$last_notif_at" ] && last_notif_at=0
      age=$((NOW - first_seen))
      if [ "$last_approver" = "true" ]; then
        # « Tu es le dernier » : relance RÉPÉTÉE toutes les LAST_REPEAT_MIN min (immédiate la 1re fois),
        # tant que la MR n'est pas approuvée.
        if [ "$SEED" -ne 1 ] && [ "$INHOURS" -eq 1 ] \
           && { [ "$last_notif_at" -eq 0 ] || [ "$((NOW - last_notif_at))" -ge "$LAST_REPEAT_SECS" ]; }; then
          terminal-notifier -title "🎯 Dernier à approuver ($author)" -subtitle "!$iid n'attend que TON aval" -message "$title" -open "$url" -group "mrwatch-last-$iid" 2>>"$LOG"
          ntfy_send "🎯 Dernier à approuver: $author" "!$iid $title — ton approbation débloque le merge" "$url" "dart"
          last_notif_at=$NOW
          log "NAG-LAST !$iid $author (approvals_left=1, relance ${LAST_REPEAT_MIN}min)"
        fi
      else
        last_notif_at=0   # plus (ou pas) dernier approbateur -> on réarme la relance immédiate
        # Relance temporelle classique après le seuil (une seule fois).
        if [ "$SEED" -ne 1 ] && [ "$INHOURS" -eq 1 ] && [ "$age" -ge "$NAG_SECS" ] && [ "$notified2h" != "true" ]; then
          h=$((age / 3600)); m=$(((age % 3600) / 60))
          terminal-notifier -title "À approuver ($author)" -subtitle "!$iid en attente >${NAG_HOURS}h" -message "$title" -open "$url" -group "mrwatch-nag-$iid" 2>>"$LOG"
          ntfy_send "À approuver: $author" "!$iid $title (en attente ${h}h${m}m)" "$url" "hourglass"
          notified2h=true
          log "NAG !$iid $author age=${age}s"
        fi
      fi
    fi

    prev=$(get_sha "$iid")
    # État d'auto-post reporté du passage précédent (open.json).
    post_eligible=$(prev_field "$iid" postEligible); [ "$post_eligible" = "true" ] || post_eligible=false
    review_posted=$(prev_field "$iid" reviewPosted); [ "$review_posted" = "true" ] || review_posted=false
    trivial=$(prev_field "$iid" trivial); [ "$trivial" = "true" ] || trivial=false

    if [ "$SEED" -eq 1 ]; then
      printf '%s\t%s\n' "$iid" "$sha" >> "$NEWSTATE"
      log "SEED !$iid $u"
      post_eligible=false   # baseline : les MR déjà ouvertes ne s'auto-postent jamais
    elif [ "$INHOURS" -eq 1 ] && [ "$prev" != "$sha" ]; then
      if [ -z "$prev" ]; then kind="Nouvelle MR"; post_eligible=true; else kind="MR mise a jour"; fi
      # MR triviale (bump de dépendances) ? On teste seulement à la 1re détection.
      trivial=false
      [ "$SKIP_TRIVIAL" = "true" ] && [ -z "$prev" ] && trivial=$(is_trivial_mr "$iid")
      sub="!$iid"; [ "$trivial" = "true" ] && sub="!$iid · bump (review sautée)"
      terminal-notifier -title "$kind — $u" -subtitle "$sub" -message "$title" -open "$url" -group "mrwatch-$iid" 2>>"$LOG"
      ntfy_send "$kind: $u" "!$iid $title" "$url" "bell"
      printf '%s\t%s\n' "$iid" "$sha" >> "$NEWSTATE"
      if [ "$trivial" = "true" ]; then
        post_eligible=false   # rien de substantiel à commenter -> pas d'auto-post
        log "SKIP-REVIEW !$iid $u (trivial : dépendances only)"
      else
        log "DETECT $kind !$iid $u sha=$sha"
        # La review claude est LENTE (plusieurs min). On la met en file et on la lance APRÈS avoir
        # écrit open.json/state, pour que le widget reflète la MR même si la review est interrompue.
        REVIEW_QUEUE="$REVIEW_QUEUE$iid "
      fi
    else
      # MR inchangée, ou hors heures : on conserve l'entrée existante si elle existe.
      # (jamais vue + hors heures -> non ajoutée -> sera reviewée au prochain passage en heures actives)
      [ -n "$prev" ] && printf '%s\t%s\n' "$iid" "$prev" >> "$NEWSTATE"
    fi

    # --- Auto-post de la review en commentaires inline, ~POST_DELAY après la création ---
    # Ne concerne QUE les MR éligibles (détectées neuves depuis l'activation), une seule fois,
    # une fois le rapport prêt et le délai écoulé, en heures actives.
    if [ "$SEED" -ne 1 ] && [ "$AUTO_POST" != "false" ] && [ "$post_eligible" = "true" ] \
       && [ "$review_posted" != "true" ] && [ "$INHOURS" -eq 1 ] \
       && [ "$created_epoch" -gt 0 ] && [ "$((NOW - created_epoch))" -ge "$POST_DELAY_SECS" ]; then
      report=$(ls -t "$REVIEWS_DIR"/*-mr"$iid"-*.md 2>/dev/null | head -1)
      if [ -n "$report" ]; then
        [ "$AUTO_POST" = "dryrun" ] && pdry=1 || pdry=0
        if POST_DRYRUN="$pdry" timeout 300 /bin/bash "$DIR/post-review.sh" "$iid" "$report" >> "$DIR/logs/post-$iid.log" 2>&1; then
          review_posted=true
          log "POSTED review !$iid (dryrun=$pdry, auteur=$author)"
        else
          log "WARN post-review !$iid a échoué (rc=$?)"
        fi
      else
        log "post !$iid différé — rapport pas encore prêt"
      fi
    fi

    # snapshot widget : toute MR ouverte non-draft, avec statut d'approbation + auto-post
    jq -nc --arg iid "$iid" --arg author "$author" --arg title "$title" --arg url "$url" \
      --argjson approved "$approved" --arg firstSeen "$first_seen" --argjson notified2h "$notified2h" \
      --argjson postEligible "$post_eligible" --argjson reviewPosted "$review_posted" \
      --argjson approvalsLeft "$approvals_left" --argjson lastApproverNotifiedAt "$last_notif_at" \
      --argjson trivial "$trivial" \
      '{iid:$iid, author:$author, title:$title, url:$url, approved:$approved,
        firstSeen:(if $firstSeen=="" then null else ($firstSeen|tonumber) end), notified2h:$notified2h,
        postEligible:$postEligible, reviewPosted:$reviewPosted,
        approvalsLeft:$approvalsLeft, lastApproverNotifiedAt:$lastApproverNotifiedAt, trivial:$trivial}' >> "$OPENTMP"
  done
done

# --- open.json (widget) : écrit AVANT les reviews lentes, et robuste à un échec partiel ---
# Les notifs sont déjà parties pendant la boucle ; on doit garantir que le widget reflète les MR
# détectées, même si (a) le fetch d'un collègue a échoué, ou (b) une review claude est lente/coupée.
if [ "$FETCH_FAILED" -eq 0 ]; then
  jq -s '.' "$OPENTMP" > "$DIR/open.json" 2>/dev/null || printf '[]\n' > "$DIR/open.json"
else
  # Fusion : MR fraîches des users OK (OPENTMP) + dernières MR connues des users EN ÉCHEC
  # (reprises de l'ancien open.json — leurs MR n'ont pas pu être refetchées ce passage).
  carried=$(jq -c --arg fu "$FAILED_USERS" '[.[] | select(.author as $a | $fu | contains(" " + $a + " "))]' "$DIR/open.json" 2>/dev/null)
  [ -z "$carried" ] && carried="[]"
  if { jq -s '.' "$OPENTMP" 2>/dev/null || echo "[]"; printf '%s\n' "$carried"; } | jq -s 'add' > "$DIR/open.json.tmp" 2>/dev/null; then
    mv "$DIR/open.json.tmp" "$DIR/open.json"
  else
    rm -f "$DIR/open.json.tmp"; log "WARN open.json (fusion) échec — ancien conservé"
  fi
fi
rm -f "$OPENTMP"

# --- Reviews en file (LENTES) : lancées APRÈS l'écriture de open.json ---
# Ainsi le widget montre la MR immédiatement ; une review interrompue ne bloque plus le snapshot.
if [ "$SEED" -ne 1 ]; then
  for rid in $REVIEW_QUEUE; do
    log "REVIEW !$rid (file)"
    timeout 600 /bin/bash "$DIR/review.sh" "$rid" >> "$DIR/logs/review-$rid.log" 2>&1
  done
fi

# --- État (dédup) : écrit APRÈS les reviews, pour qu'une review interrompue soit RETENTÉE au prochain passage. ---
# Sur échec partiel, on reporte les entrées d'état des users non refetchés pour ne pas élaguer à tort.
if [ "$FETCH_FAILED" -eq 1 ] && [ -f "$STATE" ]; then
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    awk -F'\t' -v key="$k" '$1==key{f=1} END{exit !f}' "$NEWSTATE" || printf '%s\t%s\n' "$k" "$v" >> "$NEWSTATE"
  done < "$STATE"
fi
mv "$NEWSTATE" "$STATE"

# --- Auto-évaluation des MR mergées que j'avais reviewées ---
# Une MR présente au passage précédent et absente maintenant a été mergée/fermée. Si j'ai un
# rapport pour elle et qu'elle est mergée, on note la review (comparaison aux commentaires humains).
if [ "$AUTO_GRADE" = "true" ] && [ "$SEED" -ne 1 ] && [ "$FETCH_FAILED" -eq 0 ] && [ -n "$OLD_IIDS" ]; then
  CUR_IIDS=$(jq -r '.[].iid' "$DIR/open.json" 2>/dev/null)
  for oid in $OLD_IIDS; do
    printf '%s\n' "$CUR_IIDS" | grep -qxF "$oid" && continue      # encore ouverte
    grep -qxF "$oid" "$GRADED_STATE" 2>/dev/null && continue      # déjà noté
    if ! ls "$REVIEWS_DIR"/*-mr"$oid"-*.md >/dev/null 2>&1; then
      echo "$oid" >> "$GRADED_STATE"; continue                    # pas de rapport -> rien à noter
    fi
    st=$(glab api "projects/$ENC/merge_requests/$oid" 2>>"$LOG" | jq -r '.state // ""')
    if [ "$st" = "merged" ]; then
      timeout 300 /bin/bash "$DIR/grade-review.sh" "$oid" >> "$DIR/logs/grade-$oid.log" 2>&1
      echo "$oid" >> "$GRADED_STATE"
      log "GRADED !$oid (mergé)"
    elif [ -n "$st" ]; then
      echo "$oid" >> "$GRADED_STATE"                              # fermée non-mergée : ne pas re-checker
      log "grade !$oid ignoré (state=$st)"
    fi
  done
fi

# --- Santé : suivi des échecs GitLab + alerte ntfy si le bot est aveugle trop longtemps ---
# health.json est réécrit à CHAQUE passage → sa présence/fraîcheur sert aussi de heartbeat au widget.
cf=0; alerted=false; prev_ls=0
if [ -f "$HEALTH" ]; then
  cf=$(jq -r '.consecutiveFailures // 0' "$HEALTH" 2>/dev/null); [ -z "$cf" ] && cf=0
  alerted=$(jq -r '.alerted // false' "$HEALTH" 2>/dev/null); [ "$alerted" = "true" ] || alerted=false
  prev_ls=$(jq -r '.lastSuccess // 0' "$HEALTH" 2>/dev/null); [ -z "$prev_ls" ] && prev_ls=0
fi
if [ "$FETCH_FAILED" -eq 1 ]; then
  cf=$((cf + 1))
  if [ "$cf" -ge "$HALERT_AFTER" ] && [ "$alerted" != "true" ]; then
    ntfy_send "mr-watch en panne" "Appels GitLab en échec depuis $cf passages (~$((cf * 15))min). Vérifier glab (token) / réseau." "" "warning,skull"
    log "HEALTH ALERT — $cf échecs consécutifs"
    alerted=true
  fi
  jq -nc --argjson cf "$cf" --argjson alerted "$alerted" --argjson ls "$prev_ls" \
    '{consecutiveFailures:$cf, alerted:$alerted, lastSuccess:$ls}' > "$HEALTH"
else
  if [ "$alerted" = "true" ]; then
    ntfy_send "mr-watch rétabli" "Les appels GitLab refonctionnent." "" "white_check_mark"
    log "HEALTH OK — rétabli après $cf échec(s)"
  fi
  jq -nc --argjson now "$NOW" '{consecutiveFailures:0, alerted:false, lastSuccess:$now}' > "$HEALTH"
fi

exit 0
