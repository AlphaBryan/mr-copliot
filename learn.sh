#!/bin/bash
# mr-watch — boucle d'apprentissage. Lit les commentaires des reviewers seniors sur les MR
# (ouvertes + mergées récentes), les distille via claude en un guide de style, et met à jour
# prompts/learned-style.md (injecté ensuite dans chaque review). Compatible bash 3.2.
#
# Lancé 2x/jour par launchd (8h05 / 13h05). À la main :
#   bash learn.sh                 # passage normal (n'apprend que des NOUVEAUX commentaires)
#   MRWATCH_LEARN_RESET=1 bash learn.sh   # ré-apprend TOUT (vide learn-state.tsv d'abord)
set -uo pipefail

DIR="/Users/bryan.mevo/mr-watch"
CONFIG="$DIR/config.json"
LOG="$DIR/logs/learn.log"
STATE="$DIR/learn-state.tsv"          # note_id déjà distillés (1 par ligne)
GUIDE="$DIR/prompts/learned-style.md" # sortie : le guide appris
LEARN_PROMPT="$DIR/prompts/learn-prompt.md"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
mkdir -p "$DIR/logs"

PROJECT=$(jq -r '.project' "$CONFIG")
ENC=$(printf '%s' "$PROJECT" | sed 's#/#%2F#g')
MODEL=$(jq -r '.learn_model // .review_model // "sonnet"' "$CONFIG")
WINDOW=$(jq -r '.learn_window_days // 30' "$CONFIG")
REVIEWERS_JSON=$(jq -c '.learn_from_reviewers // []' "$CONFIG")
# Anti « IA qui entraîne l'IA » :
#  Couche 1 (déterministe) : comptes à exclure + sous-chaînes-signatures d'IA.
#  Couche 2 (garde LLM)     : classifieur humain-vs-IA sur les nouveaux commentaires.
EXCLUDE_JSON=$(jq -c '.learn_exclude_authors // []' "$CONFIG")
MARKERS_JSON=$(jq -c '.learn_ai_markers // []' "$CONFIG")
AI_FILTER=$(jq -r '.learn_ai_filter // true' "$CONFIG")
AI_MODEL=$(jq -r '.learn_ai_filter_model // .learn_model // "sonnet"' "$CONFIG")
AI_PROMPT="$DIR/prompts/ai-filter-prompt.md"
NTFY_ENABLED=$(jq -r '.ntfy.enabled // false' "$CONFIG")
NTFY_URL="$(jq -r '.ntfy.server // ""' "$CONFIG")/$(jq -r '.ntfy.topic // ""' "$CONFIG")"
NTFY_TOKEN=$(jq -r '.ntfy.token // ""' "$CONFIG")
ntfy_send() { # $1 titre  $2 corps  $3 tags
  [ "$NTFY_ENABLED" = "true" ] || return 0
  if [ -n "$NTFY_TOKEN" ]; then
    curl -s -m 10 -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $1" -H "Tags: $3" -d "$2" "$NTFY_URL" >/dev/null 2>&1 || true
  else
    curl -s -m 10 -H "Title: $1" -H "Tags: $3" -d "$2" "$NTFY_URL" >/dev/null 2>&1 || true
  fi
}

if [ "$REVIEWERS_JSON" = "[]" ] || [ -z "$REVIEWERS_JSON" ]; then
  log "ERROR: learn_from_reviewers vide dans config.json — rien à apprendre."
  exit 1
fi

[ "${MRWATCH_LEARN_RESET:-0}" = "1" ] && { : > "$STATE"; log "RESET: learn-state.tsv vidé, ré-apprentissage complet."; }
touch "$STATE"

log "START learn (model=$MODEL, fenêtre=${WINDOW}j, reviewers=$REVIEWERS_JSON)"

# Date de coupure ISO8601 (macOS date). Repli sans filtre si la commande échoue.
CUTOFF=$(date -u -v-"${WINDOW}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

# --- 1. Lister les MR : ouvertes (toutes) + mergées récentes ---
mrs=$(mktemp)
glab api "projects/$ENC/merge_requests?scope=all&state=opened&order_by=updated_at&per_page=50" 2>>"$LOG" \
  | jq -r '.[] | "\(.iid)\t\(.author.username)"' >> "$mrs" 2>>"$LOG"
if [ -n "$CUTOFF" ]; then
  glab api "projects/$ENC/merge_requests?scope=all&state=merged&updated_after=$CUTOFF&order_by=updated_at&per_page=50" 2>>"$LOG" \
    | jq -r '.[] | "\(.iid)\t\(.author.username)"' >> "$mrs" 2>>"$LOG"
else
  glab api "projects/$ENC/merge_requests?scope=all&state=merged&order_by=updated_at&per_page=30" 2>>"$LOG" \
    | jq -r '.[] | "\(.iid)\t\(.author.username)"' >> "$mrs" 2>>"$LOG"
fi
mr_count=$(sort -u "$mrs" | grep -c . || true)
log "MR à scanner: $mr_count"

# --- 2. Collecter les commentaires des reviewers seniors (sauf réponses de l'auteur de la MR) ---
corpus=$(mktemp)   # 1 objet JSON par ligne
while IFS="$(printf '\t')" read -r iid mr_author; do
  [ -z "$iid" ] && continue
  glab api "projects/$ENC/merge_requests/$iid/discussions?per_page=100" 2>>"$LOG" \
    | jq -c --argjson rev "$REVIEWERS_JSON" --arg ma "$mr_author" --arg iid "$iid" \
           --argjson excl "$EXCLUDE_JSON" --argjson markers "$MARKERS_JSON" '
        .[]? | .notes[]?
        | select(.system == false)
        | select(.body != null and (.body | gsub("\\s";"") | length) > 3)
        | select(.author.username as $a | ($rev | index($a)) != null)
        | select(.author.username != $ma)
        # Couche 1a — écarte les comptes explicitement exclus (bots, comptes IA dédiés)
        | select(.author.username as $a | ($excl | index($a)) == null)
        # Couche 1b — écarte tout commentaire portant un marqueur IA (sous-chaine, insensible casse)
        | select( (.body | ascii_downcase) as $b
                  | any($markers[]; . as $m | ($b | contains($m | ascii_downcase))) | not )
        | { id: (.id|tostring), iid: $iid, author: .author.username,
            resolved: (.resolved // false),
            file: (.position.new_path // .position.old_path // null),
            line: (.position.new_line // .position.old_line // null),
            body: .body }
      ' >> "$corpus" 2>>"$LOG"
done < <(sort -u "$mrs")
rm -f "$mrs"

total_found=$(grep -c . "$corpus" || true)
log "Commentaires de reviewers trouvés (toutes MR): $total_found"

# --- 3. Dédup : ne garder que les note_id PAS encore appris ---
fresh=$(mktemp)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  nid=$(printf '%s' "$line" | jq -r '.id')
  if ! grep -qxF "$nid" "$STATE"; then
    printf '%s\n' "$line" >> "$fresh"
  fi
done < "$corpus"
rm -f "$corpus"

new_count=$(grep -c . "$fresh" || true)
log "Nouveaux commentaires (non encore appris): $new_count"

if [ "${new_count:-0}" -eq 0 ]; then
  log "Rien de neuf à apprendre — guide inchangé. DONE."
  rm -f "$fresh"
  exit 0
fi

# --- 3b. Couche 2 : garde LLM anti « IA qui entraîne l'IA » ---
# claude classe chaque nouveau commentaire humain-vs-IA. On retire les IA du lot avant
# distillation. Dans le doute, le prompt tranche « humain » (on préfère garder un vrai
# commentaire que jeter à tort). Les IA écartées sont marquées traitées (pas de re-classement).
# Échec/illisible => on SAUTE ce tour (rien appris, rien marqué) et on réessaiera : on ne
# contamine jamais le guide avec un lot non filtré.
AI_LINES=""   # fichier des lignes IA à marquer traitées (renseigné si le filtre s'active)
if [ "$AI_FILTER" = "true" ]; then
  if [ ! -f "$AI_PROMPT" ]; then
    log "WARN filtre IA activé mais prompt absent ($AI_PROMPT) — couche 2 sautée."
  else
    classify_in=$(mktemp)
    n=0
    while IFS= read -r cline; do
      [ -z "$cline" ] && continue
      n=$((n + 1))
      body=$(printf '%s' "$cline" | jq -r '.body')
      printf '### Commentaire [%s]\n%s\n\n' "$n" "$body" >> "$classify_in"
    done < "$fresh"

    cin=$(mktemp)
    { cat "$AI_PROMPT"; echo; echo "=== COMMENTAIRES À CLASSER ($n) ==="; cat "$classify_in"; } > "$cin"
    log "Filtre IA: classification de $n commentaires (model=$AI_MODEL)…"
    verdict=$(claude -p --model "$AI_MODEL" \
      --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" "Bash" \
      < "$cin" 2>>"$LOG")
    rm -f "$cin" "$classify_in"

    # Réponse attendue : un tableau JSON des indices IA, ex [2,5] (ou [] si aucun).
    # Extraction tolérante : on isole le 1er bloc [chiffres/virgules/espaces].
    arr=$(printf '%s' "$verdict" | tr -d '\r' | sed -n 's/.*\(\[[0-9, ]*\]\).*/\1/p' | head -1)
    if [ -z "$arr" ] || ! printf '%s' "$arr" | jq -e 'type=="array"' >/dev/null 2>&1; then
      log "ERROR filtre IA: sortie non exploitable — lot NON appris, réessai au prochain passage."
      ntfy_send "Filtre IA KO" "Classifieur illisible — apprentissage sauté ce tour." "warning"
      rm -f "$fresh"
      exit 1
    fi
    ai_list=$(printf '%s' "$arr" | jq -r '.[] | select(type=="number")' | tr '\n' ' ')

    ai_lines=$(mktemp); fresh_h=$(mktemp)
    awk -v ai="$ai_list" 'BEGIN{split(ai,a," ");for(i in a)S[a[i]]=1} NF{k++; if(S[k])print}'  "$fresh" > "$ai_lines"
    awk -v ai="$ai_list" 'BEGIN{split(ai,a," ");for(i in a)S[a[i]]=1} NF{k++; if(!S[k])print}' "$fresh" > "$fresh_h"
    ai_n=$(grep -c . "$ai_lines" || true)
    mv "$fresh_h" "$fresh"
    AI_LINES="$ai_lines"
    log "Filtre IA: $ai_n commentaire(s) IA écarté(s) sur $n."

    human_n=$(grep -c . "$fresh" || true)
    if [ "${human_n:-0}" -eq 0 ]; then
      log "Filtre IA: les $n nouveaux commentaires sont tous IA — rien d'humain à apprendre. DONE."
      [ "${ai_n:-0}" -gt 0 ] && jq -r '.id' "$AI_LINES" >> "$STATE"
      rm -f "$fresh" "$AI_LINES"
      exit 0
    fi
    new_count="$human_n"
  fi
fi

# --- 4. Mettre en forme le lot pour le prompt ---
batch=$(mktemp)
jq -r '
  "### Commentaire (id \(.id))"
  + " — " + (if .resolved then "[RÉSOLU ✓]" else "[non résolu]" end) + "\n"
  + (if .file then "Emplacement: \(.file):\(.line // "?")\n" else "(commentaire général, pas attaché à une ligne précise)\n" end)
  + "Texte: \(.body)\n"
' "$fresh" > "$batch" 2>>"$LOG"

# --- 5. Assembler le prompt complet et appeler claude ---
tmp=$(mktemp)
{
  cat "$LEARN_PROMPT"
  echo
  echo "=== LE GUIDE ACTUEL ==="
  if [ -f "$GUIDE" ]; then cat "$GUIDE"; else echo "(vide — première fois)"; fi
  echo
  echo "=== NOUVEAUX COMMENTAIRES RÉELS ($new_count) ==="
  cat "$batch"
} > "$tmp"

log "Appel claude pour distiller ($new_count commentaires)…"
# Pure transformation texte→texte : on INTERDIT les outils d'écriture/exécution pour que claude
# renvoie le guide SUR STDOUT (sinon il écrit un fichier lui-même et stdout n'est qu'un résumé).
new_guide=$(claude -p --model "$MODEL" \
  --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" "Bash" \
  < "$tmp" 2>>"$LOG")
rm -f "$tmp" "$batch"

# --- 6. Écrire le guide seulement si la sortie est plausible (ne JAMAIS écraser par du vide) ---
if [ -z "$new_guide" ] || [ "$(printf '%s' "$new_guide" | wc -c | tr -d ' ')" -lt 80 ]; then
  log "ERROR: sortie claude vide/trop courte — guide CONSERVÉ, état NON marqué (on réessaiera)."
  rm -f "$fresh" ${AI_LINES:+"$AI_LINES"}
  ntfy_send "Apprentissage KO" "Distillation vide — guide inchangé. Voir learn.log" "warning"
  exit 1
fi

printf '%s\n' "$new_guide" > "$GUIDE"
log "Guide mis à jour: $GUIDE"

# --- 7. Marquer ces note_id comme appris (après succès seulement) ---
# On marque les commentaires humains distillés ET les IA écartées par la couche 2,
# pour ne jamais les re-traiter/re-classer.
jq -r '.id' "$fresh" >> "$STATE"
[ -n "${AI_LINES:-}" ] && [ -f "$AI_LINES" ] && jq -r '.id' "$AI_LINES" >> "$STATE"
rm -f "$fresh" ${AI_LINES:+"$AI_LINES"}

learned_total=$(grep -c . "$STATE" || true)
log "DONE — +$new_count commentaires appris (total cumulé: $learned_total)."
ntfy_send "Style de review mis à jour" "+$new_count commentaires appris des reviewers" "brain"
exit 0
