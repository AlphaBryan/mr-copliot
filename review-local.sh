#!/bin/bash
# mr-watch — review de TA branche locale courante (avant d'ouvrir une MR).
# Compatible bash 3.2. Tourne dans le repo de dev EN DIRECT (lecture seule via claude),
# review les changements commités (vs base) ET non commités (staged + working tree).
# Usage: review-local.sh [repo_dir]
#   repo_dir : optionnel, sinon config .local_repo_dir
set -uo pipefail

DIR="/Users/bryan.mevo/mr-watch"
CONFIG="$DIR/config.json"

MODEL=$(jq -r '.review_model' "$CONFIG")
RDIR=$(jq -r '.reviews_dir' "$CONFIG")
APP=$(jq -r '.open_report_app' "$CONFIG")
JIRA=$(jq -r '.jira_extract' "$CONFIG")
REPO="${1:-$(jq -r '.local_repo_dir // ""' "$CONFIG")}"
BASE=$(jq -r '.local_base_branch // "main"' "$CONFIG")
PROMPT_TMPL="$DIR/prompts/review-prompt.md"
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
mkdir -p "$RDIR"

if [ -z "$REPO" ] || ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  osascript -e 'display notification "local_repo_dir invalide dans config.json" with title "Review locale — erreur"' 2>/dev/null
  echo "ERROR: repo invalide: $REPO" >&2; exit 1
fi

branch=$(git -C "$REPO" branch --show-current 2>/dev/null)
[ -z "$branch" ] && branch="(detached)"
ticket=$(printf '%s' "$branch" | grep -oE 'ADF-[0-9]+' | head -1)
safe_branch=$(printf '%s' "$branch" | tr '/' '-' | tr -cd 'A-Za-z0-9._-')
LOG="$DIR/logs/review-local-${safe_branch:-head}.log"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

log "START review locale repo=$REPO branche=$branch"
terminal-notifier -title "Review locale lancée" -subtitle "$branch" \
  -message "Rapport dans ~2-5 min…" -group "mrwatch-local" 2>>"$LOG"
ntfy_send "Review locale lancée: $branch" "Rapport en cours…" "hourglass"

# --- base : freshen best-effort (borné, jamais bloquant) ---
if [ "${MRWATCH_SKIP_FETCH:-0}" != "1" ]; then
  GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$REPO" fetch origin "$BASE" -q 2>>"$LOG" \
    || log "WARN fetch base KO — j'utilise la ref locale"
fi
if git -C "$REPO" rev-parse --verify -q "origin/$BASE" >/dev/null; then base_ref="origin/$BASE"; else base_ref="$BASE"; fi
log "base_ref=$base_ref"

# --- contexte Jira (best-effort) ---
jira_ctx=""
if [ -n "$ticket" ] && [ -x "$JIRA" ]; then
  timeout 60 "$JIRA" "$ticket" >/dev/null 2>&1 || true
  [ -s "/tmp/jira-$ticket.txt" ] && jira_ctx=$(cat "/tmp/jira-$ticket.txt")
fi

# --- prompt ---
GUIDE="$DIR/prompts/learned-style.md"
tmp=$(mktemp)
{
  cat "$PROMPT_TMPL"
  echo
  # Style appris des vrais reviewers (injecté seulement s'il a déjà été appris).
  if [ -f "$GUIDE" ] && ! grep -q "n'a pas encore tourné" "$GUIDE"; then
    echo "=== STYLE APPRIS DES REVIEWERS DE L'ÉQUIPE ==="
    echo "Ce guide est distillé automatiquement des commentaires réels des reviewers seniors."
    echo "Applique ces checks récurrents, ce ton et ce style dans ton rapport (surtout section 4)."
    echo
    cat "$GUIDE"
    echo
  fi
  echo "=== MÉTADONNÉES (review locale, AVANT MR) ==="
  echo "Repo         : $REPO"
  echo "Branche      : $branch"
  echo "Base         : $base_ref"
  echo "Ticket       : ${ticket:-aucun}"
  echo
  echo "=== REQUIS / CONTEXTE ==="
  if [ -n "$jira_ctx" ]; then echo "$jira_ctx"; else echo "(Pas de contexte Jira — déduis le requis du nom de branche et des changements.)"; fi
  echo
  echo "=== ACCÈS AU CODE (mode repo, LOCAL) ==="
  echo "Tu es dans le repo de dev EN DIRECT, sur la branche '$branch'. Outils en lecture seule."
  echo "Tu dois reviewer DEUX ensembles de changements :"
  echo "  1) Commités sur la branche vs la base :"
  echo "       git diff $base_ref...HEAD --stat        (vue d'ensemble)"
  echo "       git diff $base_ref...HEAD -- <fichier>  (détail)"
  echo "  2) NON commités (travail en cours, à inclure dans la review) :"
  echo "       git status --short"
  echo "       git diff            (modifs non indexées)"
  echo "       git diff --staged   (modifs indexées)"
  echo "Lis les fichiers complets pour le contexte, fais 'grep -n' pour les VRAIS numéros de ligne,"
  echo "et cherche les bugs cross-fichiers (changement incomplet ailleurs)."
  echo "Si la branche est identique à la base et qu'il n'y a aucun changement, dis-le simplement."
} > "$tmp"

log "Appel claude (model=$MODEL)"
report_body=$(cd "$REPO" && claude -p --model "$MODEL" \
  --permission-mode acceptEdits \
  --allowedTools "Read" "Grep" "Glob" "Bash(git:*)" "Bash(grep:*)" "Bash(rg:*)" "Bash(cat:*)" "Bash(sed:*)" "Bash(ls:*)" \
  < "$tmp" 2>>"$LOG")
rm -f "$tmp"

if [ -z "$report_body" ]; then
  report_body="⚠️ Génération du rapport échouée (réponse vide). Voir $LOG."
  log "ERROR: réponse claude vide"
fi

stamp=$(date '+%Y%m%d-%H%M')
fname="$RDIR/LOCAL-${safe_branch:-head}-$stamp.md"
{
  echo "# Review locale — ${ticket:-$branch}"
  echo
  echo "- Repo : \`$REPO\`"
  echo "- Branche : \`$branch\` → \`$base_ref\`"
  echo "- Type : review locale (avant MR)"
  echo "- Généré le : $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "---"
  echo
  printf '%s\n' "$report_body"
} > "$fname"

log "Rapport écrit: $fname"
terminal-notifier -title "Review locale prête — ${ticket:-$branch}" -subtitle "$branch" \
  -message "Cliquer pour ouvrir le rapport" \
  -execute "open -a \"$APP\" \"$fname\"" -group "mrwatch-local" 2>>"$LOG"
ntfy_send "Review locale prête: $branch" "Rapport sur ton Mac" "white_check_mark"
log "DONE review locale $branch"
exit 0
