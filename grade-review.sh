#!/bin/bash
# mr-watch — auto-évaluation : compare MA review (section 4 d'un rapport) aux commentaires des
# vrais reviewers humains sur la MÊME MR, via claude. Produit un score « attrapé / manqué » qui
# dit, dans le temps, si l'outil attrape vraiment ce que l'équipe attrape.
# Compatible bash 3.2 (macOS).
#
# Usage:
#   grade-review.sh <iid> [chemin_rapport]
set -uo pipefail

DIR="/Users/bryan.mevo/mr-watch"
CONFIG="$DIR/config.json"
LOG="$DIR/logs/grade.log"
GRADES_DIR="$DIR/grades"
SUMMARY="$GRADES_DIR/summary.tsv"
GRADE_PROMPT="$DIR/prompts/grade-prompt.md"
mkdir -p "$DIR/logs" "$GRADES_DIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

IID="${1:-}"
[ -z "$IID" ] && { echo "usage: grade-review.sh <iid> [rapport]"; exit 2; }

PROJECT=$(jq -r '.project' "$CONFIG")
ENC=$(printf '%s' "$PROJECT" | sed 's#/#%2F#g')
MODEL=$(jq -r '.grade_model // .review_model // "sonnet"' "$CONFIG")
EXCLUDE_JSON=$(jq -c '.learn_exclude_authors // []' "$CONFIG")
RDIR=$(jq -r '.reviews_dir // ""' "$CONFIG"); [ -z "$RDIR" ] && RDIR="$DIR/reviews"

REPORT="${2:-$(ls -t "$RDIR"/*-mr"$IID"-*.md 2>/dev/null | head -1)}"
if [ -z "$REPORT" ] || [ ! -f "$REPORT" ]; then
  log "SKIP !$IID — aucun rapport à évaluer"; exit 0
fi
log "START grade !$IID (rapport=$(basename "$REPORT"))"

# --- auteur de la MR (pour exclure ses propres réponses) ---
mr=$(glab api "projects/$ENC/merge_requests/$IID" 2>>"$LOG")
mr_author=$(printf '%s' "$mr" | jq -r '.author.username // ""')

# --- commentaires humains réels (tous reviewers sauf l'auteur et les bots exclus) ---
humans=$(glab api "projects/$ENC/merge_requests/$IID/discussions?per_page=100" 2>>"$LOG" \
  | jq -r --arg ma "$mr_author" --argjson excl "$EXCLUDE_JSON" '
      [ .[]?.notes[]?
        | select(.system == false)
        | select(.body != null and (.body | gsub("\\s";"") | length) > 3)
        | select(.author.username != $ma)
        | select(.author.username as $a | ($excl | index($a)) == null)
        | { file:(.position.new_path // .position.old_path // null),
            line:(.position.new_line // .position.old_line // null),
            body:.body } ]
    ' 2>>"$LOG")
hcount=$(printf '%s' "$humans" | jq 'length' 2>/dev/null); [ -z "$hcount" ] && hcount=0
log "commentaires humains bruts: $hcount"

# --- mes constats : section 4 du rapport ---
mine=$(awk '
  /^## 4\./ { insec=1; next }
  insec && /^## / { insec=0 }
  !insec { next }
  /^- \*\*`/ {
    s=index($0,"`"); rest=substr($0,s+1); e=index(rest,"`"); tok=substr(rest,1,e-1)
    after=substr(rest,e+1); sub(/^\*\*[ \t]*/,"",after); sub(/^[^[:alnum:]`([]+/,"",after)
    print "- " tok " — " after
  }' "$REPORT")

# --- assemble le prompt et appelle claude ---
tmp=$(mktemp)
{
  cat "$GRADE_PROMPT"
  echo; echo "=== (A) MES CONSTATS (review auto) ==="
  [ -n "$mine" ] && printf '%s\n' "$mine" || echo "(aucun constat)"
  echo; echo "=== (B) COMMENTAIRES HUMAINS ($hcount bruts) ==="
  printf '%s' "$humans" | jq -r '.[] | "- " + ((.file // "?")|tostring) + ":" + ((.line // "?")|tostring) + " — " + .body'
} > "$tmp"

verdict=$(claude -p --model "$MODEL" \
  --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" "Bash" \
  < "$tmp" 2>>"$LOG")
rm -f "$tmp"

# extraction tolérante du 1er objet JSON
obj=$(printf '%s' "$verdict" | tr -d '\r' | sed -n '/{/,/}/p' | head -c 4000)
if [ -z "$obj" ] || ! printf '%s' "$obj" | jq -e 'type=="object" and has("caught")' >/dev/null 2>&1; then
  log "ERROR !$IID — sortie claude non exploitable, note NON écrite"
  exit 1
fi

hp=$(printf '%s' "$obj" | jq -r '.humanPoints // 0')
caught=$(printf '%s' "$obj" | jq -r '.caught // 0')
missed=$(printf '%s' "$obj" | jq -r '.missed // 0')
extra=$(printf '%s' "$obj" | jq -r '.extra // 0')
summary=$(printf '%s' "$obj" | jq -r '.summary // ""')

# --- écrit le rapport de note + une ligne de synthèse ---
gfile="$GRADES_DIR/mr${IID}-$(date +%Y%m%d-%H%M).md"
{
  echo "# Auto-évaluation MR !$IID — $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "- Rapport évalué : \`$(basename "$REPORT")\`"
  echo "- Points de review humains : **$hp** · attrapés par la review auto : **$caught** · manqués : **$missed** · constats en plus : **$extra**"
  echo
  echo "## Résumé"; echo "$summary"
  echo
  echo "## Points humains manqués par la review auto"
  printf '%s' "$obj" | jq -r '.missedList[]? | "- " + .' 2>/dev/null || echo "(aucun)"
} > "$gfile"

printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d')" "$IID" "$hp" "$caught" "$missed" "$extra" >> "$SUMMARY"
log "DONE !$IID — humains=$hp attrapés=$caught manqués=$missed extra=$extra -> $(basename "$gfile")"
echo "note !$IID : $caught/$hp attrapés, $missed manqués, $extra en plus"
exit 0
