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

# --- Pause : si .paused existe (bouton du widget), le bot ne fait RIEN ce passage ---
# launchd continue de tourner ; la reprise (suppression du fichier) est immédiate.
if [ -f "$DIR/.paused" ]; then
  log "PAUSE — .paused présent, passage sauté"
  exit 0
fi

# --- Verrou anti-chevauchement : un seul check.sh à la fois ---
# Les reviews claude peuvent dépasser l'intervalle launchd de 15 min. Sans verrou, deux passages se
# chevaucheraient → doubles notifs/reviews, double auto-post, courses sur state.tsv/open.json.
LOCKDIR="$DIR/.check.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    log "SKIP — un check.sh (pid $oldpid) est déjà en cours, passage sauté"
    exit 0
  fi
  log "WARN verrou périmé (pid ${oldpid:-?} mort) — récupération"
  rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null || { log "ERROR prise du verrou impossible"; exit 0; }
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

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
# Skip des MR triviales : bump de dépendances OU petit changement (peu de fichiers/lignes).
# Dans ces cas : pas de review claude ni d'auto-post, juste une relance « à reviewer toi-même ».
SKIP_TRIVIAL=$(jq -r '.skip_trivial_reviews // true' "$CONFIG")
TRIVIAL_MAX_FILES=$(jq -r '.trivial_max_files // 3' "$CONFIG")
TRIVIAL_PATTERNS_JSON=$(jq -c '.trivial_file_patterns // ["Directory.Packages.props","*.csproj","*.props","package.json","package-lock.json","yarn.lock","pnpm-lock.yaml"]' "$CONFIG")
TRIVIAL_SMALL_MAX_FILES=$(jq -r '.trivial_small_max_files // 2' "$CONFIG")   # petit changement : ≤ N fichiers
TRIVIAL_SMALL_MAX_LINES=$(jq -r '.trivial_small_max_lines // 30' "$CONFIG")  # ET ≤ M lignes changées
TRIVIAL_REMINDER_MIN=$(jq -r '.trivial_reminder_minutes // 15' "$CONFIG")    # relance « à reviewer » toutes les N min
TRIVIAL_REMINDER_SECS=$((TRIVIAL_REMINDER_MIN * 60))
# Retry borné d'une review sans rapport (échec/coupure claude). Au-delà, on abandonne l'auto-review
# et on bascule sur « à reviewer toi-même » (ex. MR trop grosse pour finir dans le timeout).
REVIEW_MAX_ATTEMPTS=$(jq -r '.review_max_attempts // 3' "$CONFIG")
# Auto-évaluation : après merge d'une MR reviewée, comparer ma review aux commentaires humains.
AUTO_GRADE=$(jq -r '.auto_grade_reviews // false' "$CONFIG")
GRADED_STATE="$DIR/graded-state.tsv"; [ "$AUTO_GRADE" = "true" ] && touch "$GRADED_STATE" 2>/dev/null

# Renvoie "true" si la MR est triviale : soit un PETIT changement (≤ N fichiers ET ≤ M lignes),
# soit un bump de DÉPENDANCES (ne touche que des manifestes, ≤ TRIVIAL_MAX_FILES).
# Échec API / doute -> "false" (on fait la review : on ne skippe jamais à tort).
is_trivial_mr() {
  local iid="$1" d n lines f base match
  d=$(glab api "projects/$ENC/merge_requests/$iid/diffs?per_page=50" 2>>"$LOG")
  printf '%s' "$d" | jq -e 'type=="array"' >/dev/null 2>&1 || { echo false; return; }
  n=$(printf '%s' "$d" | jq 'length'); [ -z "$n" ] && n=0
  [ "$n" -eq 0 ] && { echo false; return; }

  # 1) Petit changement : peu de fichiers ET peu de lignes ajoutées/retirées.
  lines=$(printf '%s' "$d" | jq '[.[].diff // "" | split("\n")[] | select(test("^[+-]") and (test("^(\\+\\+\\+|---) ")|not))] | length')
  [ -z "$lines" ] && lines=999999
  if [ "$n" -le "$TRIVIAL_SMALL_MAX_FILES" ] && [ "$lines" -le "$TRIVIAL_SMALL_MAX_LINES" ]; then
    echo true; return
  fi

  # 2) Bump de dépendances : ne touche QUE des manifestes, ≤ TRIVIAL_MAX_FILES.
  [ "$n" -gt "$TRIVIAL_MAX_FILES" ] && { echo false; return; }
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

    # statut « trivial » reporté du passage précédent (fixé à la 1re détection ; sert au nag ci-dessous)
    trivial=$(prev_field "$iid" trivial); [ "$trivial" = "true" ] || trivial=false

    if [ "$approved" = "true" ]; then
      first_seen=""; notified2h=false; last_notif_at=0; trivial_reminded_at=0
    else
      first_seen=$(prev_field "$iid" firstSeen); [ -z "$first_seen" ] && first_seen=$NOW
      notified2h=$(prev_field "$iid" notified2h); [ "$notified2h" = "true" ] || notified2h=false
      last_notif_at=$(prev_field "$iid" lastApproverNotifiedAt); [ -z "$last_notif_at" ] && last_notif_at=0
      trivial_reminded_at=$(prev_field "$iid" trivialRemindedAt); [ -z "$trivial_reminded_at" ] && trivial_reminded_at=0
      age=$((NOW - first_seen))
      # Priorité des relances : (1) tu es le dernier approbateur, (2) MR triviale à reviewer toi-même, (3) >seuil.
      if [ "$last_approver" = "true" ]; then
        trivial_reminded_at=0   # le signal « dernier » prime : on réarme la relance triviale
        # « Tu es le dernier » : relance RÉPÉTÉE toutes les LAST_REPEAT_MIN min (immédiate la 1re fois).
        if [ "$SEED" -ne 1 ] && [ "$INHOURS" -eq 1 ] \
           && { [ "$last_notif_at" -eq 0 ] || [ "$((NOW - last_notif_at))" -ge "$LAST_REPEAT_SECS" ]; }; then
          terminal-notifier -title "🎯 Dernier à approuver ($author)" -subtitle "!$iid n'attend que TON aval" -message "$title" -open "$url" -group "mrwatch-last-$iid" 2>>"$LOG"
          ntfy_send "🎯 Dernier à approuver: $author" "!$iid $title — ton approbation débloque le merge" "$url" "dart"
          last_notif_at=$NOW
          log "NAG-LAST !$iid $author (approvals_left=1, relance ${LAST_REPEAT_MIN}min)"
        fi
      elif [ "$trivial" = "true" ]; then
        last_notif_at=0
        # MR triviale (bump/petit changement) NON reviewée par le bot : relance « à reviewer toi-même »
        # toutes les TRIVIAL_REMINDER_MIN min tant que je ne l'ai pas approuvée.
        if [ "$SEED" -ne 1 ] && [ "$INHOURS" -eq 1 ] \
           && { [ "$trivial_reminded_at" -eq 0 ] || [ "$((NOW - trivial_reminded_at))" -ge "$TRIVIAL_REMINDER_SECS" ]; }; then
          terminal-notifier -title "🔎 À reviewer toi-même ($author)" -subtitle "!$iid — pas de review auto" -message "$title" -open "$url" -group "mrwatch-triv-$iid" 2>>"$LOG"
          ntfy_send "🔎 À reviewer: $author" "!$iid $title — pas de review auto, review manuelle" "$url" "eyes"
          trivial_reminded_at=$NOW
          log "NAG-TRIVIAL !$iid $author (relance ${TRIVIAL_REMINDER_MIN}min)"
        fi
      else
        last_notif_at=0; trivial_reminded_at=0   # réarme les relances répétées
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
    # État d'auto-post reporté du passage précédent (open.json). (trivial + trivial_reminded_at déjà lus plus haut.)
    post_eligible=$(prev_field "$iid" postEligible); [ "$post_eligible" = "true" ] || post_eligible=false
    review_posted=$(prev_field "$iid" reviewPosted); [ "$review_posted" = "true" ] || review_posted=false
    review_retries=$(prev_field "$iid" reviewRetries); case "$review_retries" in ''|*[!0-9]*) review_retries=0;; esac

    if [ "$SEED" -eq 1 ]; then
      printf '%s\t%s\n' "$iid" "$sha" >> "$NEWSTATE"
      log "SEED !$iid $u"
      post_eligible=false   # baseline : les MR déjà ouvertes ne s'auto-postent jamais
    elif [ "$INHOURS" -eq 1 ] && [ "$prev" != "$sha" ]; then
      if [ -z "$prev" ]; then kind="Nouvelle MR"; post_eligible=true; else kind="MR mise a jour"; fi
      review_retries=0   # nouveau code -> compteur de tentatives remis à zéro
      # Triviale (bump OU petit changement) ? On teste seulement à la 1re détection.
      trivial=false
      [ "$SKIP_TRIVIAL" = "true" ] && [ -z "$prev" ] && trivial=$(is_trivial_mr "$iid")
      sub="!$iid"; [ "$trivial" = "true" ] && sub="!$iid · review sautée (à reviewer toi-même)"
      terminal-notifier -title "$kind — $u" -subtitle "$sub" -message "$title" -open "$url" -group "mrwatch-$iid" 2>>"$LOG"
      ntfy_send "$kind: $u" "!$iid $title" "$url" "bell"
      printf '%s\t%s\n' "$iid" "$sha" >> "$NEWSTATE"
      if [ "$trivial" = "true" ]; then
        post_eligible=false          # rien de substantiel à commenter -> pas d'auto-post
        trivial_reminded_at=$NOW     # cette notif compte comme 1re relance ; la suivante dans TRIVIAL_REMINDER_MIN
        log "SKIP-REVIEW !$iid $u (trivial : bump/petit changement)"
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
      # Retry BORNÉ : MR déjà vue, non triviale, mais SANS rapport (review échouée/coupée, ex. Mac en
      # veille pendant l'appel claude). On re-tente en silence jusqu'à REVIEW_MAX_ATTEMPTS ; au-delà on
      # abandonne l'auto-review et on bascule en « à reviewer toi-même » (ex. MR trop grosse).
      if [ "$INHOURS" -eq 1 ] && [ -n "$prev" ] && [ "$trivial" != "true" ] \
         && ! ls "$REVIEWS_DIR"/*-mr"$iid"-*.md >/dev/null 2>&1; then
        if [ "$review_retries" -lt "$REVIEW_MAX_ATTEMPTS" ]; then
          review_retries=$((review_retries + 1))
          log "RETRY-REVIEW !$iid $u (rapport manquant, tentative $review_retries/$REVIEW_MAX_ATTEMPTS)"
          REVIEW_QUEUE="$REVIEW_QUEUE$iid "
        else
          # abandon : plus de review auto, on passe la main. trivial=true -> relance « à reviewer toi-même ».
          trivial=true; post_eligible=false; trivial_reminded_at=$NOW
          terminal-notifier -title "🔎 Review auto impossible ($author)" -subtitle "!$iid — à reviewer toi-même" -message "$title" -open "$url" -group "mrwatch-giveup-$iid" 2>>"$LOG"
          ntfy_send "🔎 Review auto impossible: $author" "!$iid $title — trop long/gros, review manuelle" "$url" "eyes"
          log "REVIEW-GIVEUP !$iid $u (après $REVIEW_MAX_ATTEMPTS tentatives) -> review manuelle"
        fi
      fi
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
      --argjson trivial "$trivial" --argjson trivialRemindedAt "$trivial_reminded_at" \
      --argjson reviewRetries "$review_retries" \
      '{iid:$iid, author:$author, title:$title, url:$url, approved:$approved,
        firstSeen:(if $firstSeen=="" then null else ($firstSeen|tonumber) end), notified2h:$notified2h,
        postEligible:$postEligible, reviewPosted:$reviewPosted,
        approvalsLeft:$approvalsLeft, lastApproverNotifiedAt:$lastApproverNotifiedAt,
        trivial:$trivial, trivialRemindedAt:$trivialRemindedAt, reviewRetries:$reviewRetries}' >> "$OPENTMP"
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

# --- Santé (heartbeat) : évaluée MAINTENANT, après le fetch + open.json, AVANT les reviews/notations. ---
# lastSuccess = « la boucle de surveillance a fetché les MR avec succès ». Les reviews (claude, plusieurs
# min) viennent après : elles ne doivent PAS retarder le heartbeat, sinon le widget croit le bot bloqué
# pendant qu'il review tranquillement.
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

# --- Reviews en file (LENTES) : lancées APRÈS l'écriture de open.json + heartbeat ---
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

exit 0
