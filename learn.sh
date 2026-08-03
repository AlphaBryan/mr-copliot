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
    | jq -c --argjson rev "$REVIEWERS_JSON" --arg ma "$mr_author" --arg iid "$iid" '
        .[]? | .notes[]?
        | select(.system == false)
        | select(.body != null and (.body | gsub("\\s";"") | length) > 3)
        | select(.author.username as $a | ($rev | index($a)) != null)
        | select(.author.username != $ma)
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
  rm -f "$fresh"
  ntfy_send "Apprentissage KO" "Distillation vide — guide inchangé. Voir learn.log" "warning"
  exit 1
fi

printf '%s\n' "$new_guide" > "$GUIDE"
log "Guide mis à jour: $GUIDE"

# --- 7. Marquer ces note_id comme appris (après succès seulement) ---
jq -r '.id' "$fresh" >> "$STATE"
rm -f "$fresh"

learned_total=$(grep -c . "$STATE" || true)
log "DONE — +$new_count commentaires appris (total cumulé: $learned_total)."
ntfy_send "Style de review mis à jour" "+$new_count commentaires appris des reviewers" "brain"
exit 0
