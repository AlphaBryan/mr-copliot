#!/bin/bash
# mr-watch — génère un rapport de review ciblé pour une MR, puis notifie.
# Compatible bash 3.2. Lancé en arrière-plan par check.sh.
# Usage: review.sh <iid>
#
# Mode "repo" (par défaut si repo_dir est configuré et valide):
#   crée un worktree git isolé sur la branche source de la MR et laisse claude
#   EXPLORER le code complet (Read/Grep/git) -> reviews riches avec fichier:ligne fiables.
# Mode "diff" (repli automatique): pipe seulement le diff (ancien comportement).
set -uo pipefail

DIR="/Users/bryan.mevo/mr-watch"
CONFIG="$DIR/config.json"
IID="${1:?usage: review.sh <iid>}"
LOG="$DIR/logs/review-$IID.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

PROJECT=$(jq -r '.project' "$CONFIG")
ENC=$(printf '%s' "$PROJECT" | sed 's#/#%2F#g')
MODEL=$(jq -r '.review_model' "$CONFIG")
MAXLINES=$(jq -r '.max_diff_lines' "$CONFIG")
RDIR=$(jq -r '.reviews_dir' "$CONFIG")
APP=$(jq -r '.open_report_app' "$CONFIG")
JIRA=$(jq -r '.jira_extract' "$CONFIG")
REPO=$(jq -r '.repo_dir // ""' "$CONFIG")
WT_DIR=$(jq -r '.worktrees_dir // ""' "$CONFIG")
PROMPT_TMPL="$DIR/prompts/review-prompt.md"
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
mkdir -p "$RDIR"

log "START review !$IID"

mr=$(glab api "projects/$ENC/merge_requests/$IID" 2>>"$LOG")
if [ -z "$mr" ]; then log "ERROR: MR introuvable"; exit 1; fi

title=$(printf '%s'  "$mr" | jq -r '.title')
desc=$(printf '%s'   "$mr" | jq -r '.description // ""')
branch=$(printf '%s' "$mr" | jq -r '.source_branch')
base=$(printf '%s'   "$mr" | jq -r '.target_branch')
url=$(printf '%s'    "$mr" | jq -r '.web_url')
author=$(printf '%s' "$mr" | jq -r '.author.username')
ticket=$(printf '%s' "$title" | grep -oE 'ADF-[0-9]+' | head -1)

# --- contexte Jira (best-effort) ---
jira_ctx=""
if [ -n "$ticket" ] && [ -x "$JIRA" ]; then
  timeout 60 "$JIRA" "$ticket" >/dev/null 2>&1 || true
  if [ -f "/tmp/jira-$ticket.txt" ] && [ -s "/tmp/jira-$ticket.txt" ]; then
    jira_ctx=$(cat "/tmp/jira-$ticket.txt")
  fi
fi

# --- Mode diff forcé : override explicite OU MR trop grosse pour une exploration repo ---
# Le mode repo (claude explore tout le code) DÉPASSE le timeout sur les grosses MR -> jamais de rapport
# (cas ADF-3878 / MR 55 fichiers). Au-delà de review_repo_max_files, on bascule en mode diff : borné par
# max_diff_lines, rapide, et il ABOUTIT. MRWATCH_MODE=diff force le mode diff quelle que soit la taille.
REPO_MAX_FILES=$(jq -r '.review_repo_max_files // 40' "$CONFIG")
force_diff=0
if [ "${MRWATCH_MODE:-}" = "diff" ]; then
  force_diff=1; log "MRWATCH_MODE=diff -> mode diff forcé"
else
  nfiles=$(printf '%s' "$mr" | jq -r '.changes_count // empty' | tr -dc '0-9')
  [ -z "$nfiles" ] && nfiles=$(glab api "projects/$ENC/merge_requests/$IID/diffs?per_page=100" 2>>"$LOG" | jq 'length' 2>/dev/null)
  case "$nfiles" in ''|*[!0-9]*) nfiles=0;; esac
  if [ "$nfiles" -gt "$REPO_MAX_FILES" ]; then
    force_diff=1
    log "MR volumineuse ($nfiles fichiers > $REPO_MAX_FILES) -> mode diff forcé (repo dépasserait le timeout)"
  fi
fi

# --- prépare le worktree (mode repo) ---
MODE="diff"
WT=""
cleanup_wt() { [ -n "$WT" ] && [ -n "$REPO" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; }
trap cleanup_wt EXIT

if [ "$force_diff" -eq 0 ] && [ -n "$REPO" ] && git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mkdir -p "$WT_DIR"
  WT="$WT_DIR/mr-$IID"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  # Fetch best-effort et borné dans le temps : un fetch qui hang (creds/réseau) ne doit
  # JAMAIS bloquer le job launchd. GIT_TERMINAL_PROMPT=0 évite tout prompt interactif.
  # MRWATCH_SKIP_FETCH=1 saute le fetch (re-run / test sur refs déjà locales).
  if [ "${MRWATCH_SKIP_FETCH:-0}" != "1" ]; then
    log "fetch origin $branch + $base"
    # Sous launchd, `git` ne peut pas lire le keychain -> "terminal prompts disabled" et le
    # fetch échoue, ce qui faisait silencieusement tomber TOUTE review en mode diff.
    # On injecte le token de glab (rafraîchi par l'appel `glab api` ci-dessus) comme credential
    # helper inline : username=oauth2, password=<token>. On reset d'abord les helpers existants.
    GLAB_TOKEN=$(glab auth status --show-token 2>&1 | sed -n 's/.*Token found: *//p' | head -1 | tr -d '[:space:]')
    GIT_CREDS=()
    if [ -n "$GLAB_TOKEN" ]; then
      GIT_CREDS=(-c "credential.helper=" -c "credential.helper=!f() { echo username=oauth2; echo password=$GLAB_TOKEN; }; f")
    else
      log "WARN token glab introuvable — fetch tenté sans credentials injectés"
    fi
    GIT_TERMINAL_PROMPT=0 timeout 120 git ${GIT_CREDS[@]+"${GIT_CREDS[@]}"} -C "$REPO" fetch origin "$branch" "$base" -q 2>>"$LOG" \
      || log "WARN fetch KO (creds/réseau/timeout) — j'utilise les refs locales si présentes"
  fi
  if git -C "$REPO" worktree add --force "$WT" "origin/$branch" -q 2>>"$LOG"; then
    MODE="repo"
    log "worktree prêt: $WT (mode repo)"
  else
    log "WARN worktree KO -> repli mode diff"
    WT=""
  fi
else
  log "repo_dir absent/invalide -> mode diff"
fi

# --- diff (mode diff seulement, plafonné) ---
diff=""; trunc_note=""
if [ "$MODE" = "diff" ]; then
  diff=$(glab mr diff "$IID" -R "$PROJECT" 2>>"$LOG")
  diff_lines=$(printf '%s\n' "$diff" | wc -l | tr -d ' ')
  if [ "${diff_lines:-0}" -gt "$MAXLINES" ]; then
    diff=$(printf '%s\n' "$diff" | head -n "$MAXLINES")
    trunc_note="⚠️ Diff tronqué à $MAXLINES lignes (total réel: $diff_lines). Revue partielle."
  fi
fi

# --- prompt complet ---
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
  echo "=== MÉTADONNÉES MR ==="
  echo "Titre        : $title"
  echo "Auteur       : $author"
  echo "Ticket       : ${ticket:-aucun}"
  echo "Branche src  : $branch"
  echo "Branche base : $base"
  echo "URL          : $url"
  [ -n "$trunc_note" ] && echo "$trunc_note"
  echo
  echo "=== REQUIS / CONTEXTE ==="
  if [ -n "$jira_ctx" ]; then
    echo "$jira_ctx"
  else
    echo "(Jira indisponible — se fier à la description de la MR ci-dessous.)"
  fi
  echo
  echo "--- Description de la MR ---"
  echo "$desc"
  echo
  if [ "$MODE" = "repo" ]; then
    echo "=== ACCÈS AU CODE ==="
    echo "Tu travailles DANS un worktree git checkout sur la branche source ($branch)."
    echo "HEAD = origin/$branch. La base de comparaison est origin/$base."
    echo "Pour voir l'ensemble des changements de la MR, commence par :"
    echo "    git diff origin/$base...HEAD --stat"
    echo "    git diff origin/$base...HEAD -- <fichier>"
    echo "Tu peux lire n'importe quel fichier complet et faire 'grep -n' pour obtenir les VRAIS numéros de ligne."
  else
    echo "=== DIFF ==="
    echo '```diff'
    printf '%s\n' "$diff"
    echo '```'
  fi
} > "$tmp"

log "Appel claude (model=$MODEL, mode=$MODE)"
if [ "$MODE" = "repo" ]; then
  report_body=$(cd "$WT" && claude -p --model "$MODEL" \
    --permission-mode acceptEdits \
    --allowedTools "Read" "Grep" "Glob" "Bash(git:*)" "Bash(grep:*)" "Bash(rg:*)" "Bash(cat:*)" "Bash(sed:*)" "Bash(ls:*)" "Bash(glab:*)" \
    < "$tmp" 2>>"$LOG")
else
  # Mode diff = transformation texte→texte (le diff est dans le prompt) : aucun outil requis.
  # --permission-mode acceptEdits + --disallowedTools évitent que claude se FIGE en attente d'une
  # permission/trust sur un workspace non trusté (sinon 0% CPU, jamais de rapport, puis timeout).
  report_body=$(claude -p --model "$MODEL" --permission-mode acceptEdits \
    --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" "Bash" \
    < "$tmp" 2>>"$LOG")
fi
rm -f "$tmp"
cleanup_wt; WT=""

if [ -z "$report_body" ]; then
  report_body="⚠️ La génération du rapport a échoué (réponse vide). Voir $LOG."
  log "ERROR: réponse claude vide"
fi

stamp=$(date '+%Y%m%d-%H%M')
fname="$RDIR/${ticket:-NOID}-mr$IID-$stamp.md"
{
  echo "# Review MR !$IID — ${ticket:-sans ticket}"
  echo
  echo "**$title**"
  echo
  echo "- Auteur : $author"
  echo "- Branche : \`$branch\` → \`$base\`"
  echo "- MR : $url"
  echo "- Mode : $MODE"
  echo "- Généré le : $(date '+%Y-%m-%d %H:%M')"
  [ -n "$trunc_note" ] && { echo; echo "> $trunc_note"; }
  echo
  echo "---"
  echo
  printf '%s\n' "$report_body"
} > "$fname"

log "Rapport écrit: $fname"
terminal-notifier -title "Review prête — ${ticket:-!$IID}" -subtitle "$author" -message "$title" \
  -execute "open -a \"$APP\" \"$fname\"" -group "mrwatch-review-$IID" 2>>"$LOG"
ntfy_send "Review prete: ${ticket:-!$IID}" "$title (rapport sur ton Mac)" "$url" "white_check_mark"

log "DONE review !$IID"
exit 0
