#!/bin/bash
# mr-watch — poste la section 4 d'un rapport de review en commentaires inline sur la MR.
# Chaque « - **`fichier:ligne`** — texte » devient une discussion ancrée sur la ligne du diff.
# Repli : tout commentaire non ancrable (ligne hors diff, SHA au lieu d'une ligne, POST rejeté)
# est regroupé dans UNE note générale — aucun commentaire n'est perdu.
# Compatible bash 3.2 (macOS).
#
# Usage:
#   post-review.sh <iid> [chemin_rapport]
#   POST_DRYRUN=1 post-review.sh <iid>   -> n'envoie RIEN, journalise ce qui serait posté
set -uo pipefail

DIR="/Users/bryan.mevo/mr-watch"
CONFIG="$DIR/config.json"
LOG="$DIR/logs/post-${1:-x}.log"
mkdir -p "$DIR/logs"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

IID="${1:-}"
[ -z "$IID" ] && { echo "usage: post-review.sh <iid> [rapport]"; exit 2; }
DRYRUN="${POST_DRYRUN:-0}"

PROJECT=$(jq -r '.project' "$CONFIG")
ENC=$(printf '%s' "$PROJECT" | sed 's#/#%2F#g')
RDIR=$(jq -r '.reviews_dir // ""' "$CONFIG"); [ -z "$RDIR" ] && RDIR="$DIR/reviews"

REPORT="${2:-$(ls -t "$RDIR"/*-mr"$IID"-*.md 2>/dev/null | head -1)}"
if [ -z "$REPORT" ] || [ ! -f "$REPORT" ]; then
  log "ERROR rapport introuvable pour !$IID"; exit 1
fi
log "START post !$IID (rapport=$(basename "$REPORT"), dryrun=$DRYRUN)"

# --- diff_refs (base/head/start sha) ---
refs=$(glab api "projects/$ENC/merge_requests/$IID" 2>>"$LOG")
BASE=$(printf '%s' "$refs" | jq -r '.diff_refs.base_sha // ""')
HEAD=$(printf '%s' "$refs" | jq -r '.diff_refs.head_sha // ""')
START=$(printf '%s' "$refs" | jq -r '.diff_refs.start_sha // ""')
if [ -z "$BASE" ] || [ -z "$HEAD" ] || [ -z "$START" ]; then
  log "ERROR diff_refs indisponibles pour !$IID — abandon"; exit 1
fi

# --- diffs de la MR (un objet par fichier) ---
DIFFS=$(mktemp)
glab api "projects/$ENC/merge_requests/$IID/diffs?per_page=100" 2>>"$LOG" > "$DIFFS"
if ! jq -e 'type=="array"' "$DIFFS" >/dev/null 2>&1; then
  log "ERROR diffs indisponibles pour !$IID — abandon"; rm -f "$DIFFS"; exit 1
fi

# --- parseur de ligne : diff unifié sur stdin, TARGET=new_line -> "type<TAB>old<TAB>new" ou rien ---
line_kind() { # $1 = new_path  $2 = new_line ; lit le diff du fichier et localise la ligne
  local path="$1" target="$2" d
  d=$(jq -r --arg p "$path" '.[] | select(.new_path==$p) | .diff' "$DIFFS")
  [ -z "$d" ] && return 0
  printf '%s\n' "$d" | awk -v TARGET="$target" '
    /^@@/ { m=$0; sub(/^@@ -/,"",m); split(m,parts," ");
            split(parts[1],oo,","); o=oo[1]+0;
            np=parts[2]; sub(/^\+/,"",np); split(np,nn,","); n=nn[1]+0; next }
    /^\+\+\+ / || /^--- / { next }
    { c=substr($0,1,1)
      if (c=="+") { if (n==TARGET){print "added\t\t" n; exit} n++ }
      else if (c=="-") { o++ }
      else { if (n==TARGET){print "context\t" o "\t" n; exit} o++; n++ } }'
}

# --- extraction de la section 4 : category<TAB>token<TAB>texte (un par ligne) ---
ITEMS=$(mktemp)
awk '
  /^## 4\./ { insec=1; next }
  insec && /^## / { insec=0 }
  !insec { next }
  # En-tête de catégorie : ligne NON-puce terminée par **…** (avec ou sans emoji devant,
  # ex. "🐞 **Bugs / risques**" ou "**Bugs**"). On retient un libellé court, jamais vide.
  !/^- / && /\*\*[^*]+\*\*[[:space:]]*$/ {
    cat=$0; gsub(/\*/,"",cat); gsub(/^[[:space:]]+|[[:space:]]+$/,"",cat); next
  }
  /^- \*\*`/ {
    s=index($0,"`"); rest=substr($0,s+1)
    e=index(rest,"`"); tok=substr(rest,1,e-1)
    after=substr(rest,e+1)
    sub(/^\*\*[ \t]*/,"",after)          # enlève "**" et espaces
    sub(/^[^[:alnum:]`([]+/,"",after)    # enlève le séparateur (: ou —) + espaces avant le texte
    # cat NON vide obligatoire : une ligne ITEMS avec 1er champ vide ferait décaler read (IFS=tab).
    c = (cat == "" ? "Review" : cat)
    if (tok != "" && after != "") print c "\t" tok "\t" after
  }
' "$REPORT" > "$ITEMS"

n_items=$(grep -c . "$ITEMS" || true)
log "section 4 : $n_items commentaire(s) détecté(s)"
if [ "${n_items:-0}" -eq 0 ]; then
  log "DONE — rien à poster (section 4 vide)"; rm -f "$DIFFS" "$ITEMS"; exit 0
fi

# --- poste une discussion inline ; renvoie 0 si ok, 1 sinon (repli) ---
post_inline() { # $1 path  $2 new_line  $3 old_line("" si added)  $4 body
  local path="$1" nl="$2" ol="$3" body="$4" resp rc
  if [ "$DRYRUN" = "1" ]; then
    log "[DRYRUN] inline $path:$nl (old=${ol:-∅}) :: $(printf '%s' "$body" | head -c 80)"
    return 0
  fi
  local args=(-X POST "projects/$ENC/merge_requests/$IID/discussions"
    -f "body=$body"
    -f "position[position_type]=text"
    -f "position[base_sha]=$BASE" -f "position[head_sha]=$HEAD" -f "position[start_sha]=$START"
    -f "position[new_path]=$path" -f "position[old_path]=$path"
    -f "position[new_line]=$nl")
  [ -n "$ol" ] && args+=(-f "position[old_line]=$ol")
  resp=$(glab api "${args[@]}" 2>>"$LOG"); rc=$?
  if [ "$rc" -ne 0 ] || printf '%s' "$resp" | jq -e 'has("message") or has("error")' >/dev/null 2>&1; then
    log "WARN POST inline KO $path:$nl (rc=$rc) resp=$(printf '%s' "$resp" | head -c 200)"
    return 1
  fi
  return 0
}

LEFTOVERS=$(mktemp)   # commentaires non ancrés -> une note générale
posted=0; fell=0

while IFS="$(printf '\t')" read -r cat tok text; do
  [ -z "$tok" ] && continue
  path="${tok%:*}"; lineitem="${tok##*:}"
  target=""
  case "$lineitem" in
    ''|*[!0-9]*)
      case "$lineitem" in
        [0-9]*-[0-9]*) target="${lineitem%%-*}" ;;   # plage "137-230" -> 1re ligne
        *) target="" ;;                              # SHA / non numérique -> repli
      esac ;;
    *) target="$lineitem" ;;
  esac

  ok=0
  if [ -n "$target" ] && [ -n "$path" ]; then
    kind=$(line_kind "$path" "$target")
    if [ -n "$kind" ]; then
      ktype=$(printf '%s' "$kind" | cut -f1)
      kold=$(printf '%s' "$kind" | cut -f2)
      [ "$ktype" = "added" ] && kold=""
      if post_inline "$path" "$target" "$kold" "$cat : $text"; then
        posted=$((posted+1)); ok=1
      fi
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    printf -- '- **%s** (%s) — %s\n' "$tok" "$cat" "$text" >> "$LEFTOVERS"
    fell=$((fell+1))
  fi
done < "$ITEMS"

# --- note générale de repli (commentaires non ancrables) ---
if [ "$fell" -gt 0 ]; then
  note=$({
    echo "**Review automatique — commentaires non rattachés à une ligne du diff :**"
    echo
    cat "$LEFTOVERS"
    echo
    echo "_(posté automatiquement par mr-watch)_"
  })
  if [ "$DRYRUN" = "1" ]; then
    log "[DRYRUN] note générale ($fell commentaire(s)) :"
    printf '%s\n' "$note" >> "$LOG"
  else
    resp=$(glab api -X POST "projects/$ENC/merge_requests/$IID/notes" -f "body=$note" 2>>"$LOG"); rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$resp" | jq -e 'has("message") or has("error")' >/dev/null 2>&1; then
      log "WARN note générale KO (rc=$rc) resp=$(printf '%s' "$resp" | head -c 200)"
    fi
  fi
fi

log "DONE post !$IID — inline=$posted, repli=$fell"
rm -f "$DIFFS" "$ITEMS" "$LEFTOVERS"
exit 0
