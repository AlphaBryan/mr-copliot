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
APIBASE="https://gitlab.com/api/v4"
# Token glab (OAuth) pour poster via curl. `glab api -f position[...]` N'ancre PAS les discussions
# (il n'envoie pas l'objet position imbriqué) -> on poste avec curl + Authorization: Bearer, qui, lui,
# transmet correctement les champs position[...] (ancrage inline vérifié).
GLTOKEN=$(glab auth status --show-token 2>&1 | grep -oE '[0-9a-fA-F]{40,}' | head -1)

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
if [ -z "$GLTOKEN" ] && [ "$DRYRUN" != "1" ]; then
  log "ERROR token glab introuvable — impossible de poster (abandon)"; rm -f "$DIFFS"; exit 1
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

# --- Gate de validation : un 2e agent (contexte réduit = juste le diff + les commentaires) confirme
#     que chaque constat est valide et mérite d'être posté. Écarte les faux / non fondés / bruit. ---
VALIDATE=$(jq -r '.validate_comments // true' "$CONFIG")
VALIDATE_MODEL=$(jq -r '.validate_model // .review_model // "sonnet"' "$CONFIG")
VALIDATE_PROMPT="$DIR/prompts/validate-prompt.md"
MAXDIFF=$(jq -r '.max_diff_lines // 2500' "$CONFIG")
if [ "$VALIDATE" = "true" ] && [ -f "$VALIDATE_PROMPT" ]; then
  vin=$(mktemp)
  {
    cat "$VALIDATE_PROMPT"
    echo; echo "=== DIFF DE LA MR (peut être tronqué) ==="
    jq -r '.[] | "--- " + .new_path + " ---\n" + (.diff // "")' "$DIFFS" 2>/dev/null | head -n "$MAXDIFF"
    echo; echo "=== COMMENTAIRES À VALIDER ==="
    vn=0
    while IFS="$(printf '\t')" read -r vc vt vx; do
      [ -z "$vt" ] && continue
      vn=$((vn + 1)); printf '[%s] %s — %s\n' "$vn" "$vt" "$vx"
    done < "$ITEMS"
  } > "$vin"
  log "validation : appel du 2e agent (model=$VALIDATE_MODEL) sur $n_items commentaire(s)…"
  verdict=$(claude -p --model "$VALIDATE_MODEL" --permission-mode acceptEdits \
    --disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" "Bash" < "$vin" 2>>"$LOG")
  rm -f "$vin"
  # Extraction tolérante du tableau d'index à garder.
  arr=$(printf '%s' "$verdict" | tr -d '\r' | sed -n 's/.*\(\[[0-9, ]*\]\).*/\1/p' | head -1)
  if [ -n "$arr" ] && printf '%s' "$arr" | jq -e 'type=="array"' >/dev/null 2>&1; then
    keep=$(printf '%s' "$arr" | jq -r '.[] | select(type=="number")' | tr '\n' ' ')
    awk -v k="$keep" 'BEGIN{split(k,a," ");for(i in a)S[a[i]]=1} NF{n++; if(S[n]) print}' "$ITEMS" > "$ITEMS.kept" 2>/dev/null && mv "$ITEMS.kept" "$ITEMS"
    kept_n=$(grep -c . "$ITEMS" || true)
    log "validation : $kept_n/$n_items commentaire(s) gardé(s) ($((n_items - kept_n)) écarté(s))"
    if [ "${kept_n:-0}" -eq 0 ]; then
      log "DONE — tous les commentaires écartés par la validation, rien à poster"; rm -f "$DIFFS" "$ITEMS"; exit 0
    fi
  else
    log "WARN validation illisible — on garde TOUS les commentaires (gate best-effort)"
  fi
fi

# --- poste une discussion INLINE (curl + Bearer) ; renvoie 0 si ANCRÉE, 1 sinon (repli) ---
post_inline() { # $1 path  $2 new_line  $3 old_line("" si added)  $4 body
  local path="$1" nl="$2" ol="$3" body="$4" resp
  if [ "$DRYRUN" = "1" ]; then
    log "[DRYRUN] inline $path:$nl (old=${ol:-∅}) :: $(printf '%s' "$body" | head -c 80)"
    return 0
  fi
  local args=(-s -X POST "$APIBASE/projects/$ENC/merge_requests/$IID/discussions"
    -H "Authorization: Bearer $GLTOKEN"
    --data-urlencode "body=$body"
    --data-urlencode "position[position_type]=text"
    --data-urlencode "position[base_sha]=$BASE" --data-urlencode "position[head_sha]=$HEAD" --data-urlencode "position[start_sha]=$START"
    --data-urlencode "position[new_path]=$path" --data-urlencode "position[old_path]=$path"
    --data-urlencode "position[new_line]=$nl")
  [ -n "$ol" ] && args+=(--data-urlencode "position[old_line]=$ol")
  resp=$(curl "${args[@]}" 2>>"$LOG")
  # Succès = la discussion est réellement ANCRÉE (position.new_line non nulle). Sinon -> repli.
  if printf '%s' "$resp" | jq -e '.notes[0].position.new_line != null' >/dev/null 2>&1; then
    return 0
  fi
  log "WARN POST inline KO $path:$nl resp=$(printf '%s' "$resp" | head -c 200)"
  return 1
}

# --- poste un commentaire GÉNÉRAL individuel (curl + Bearer) ; renvoie 0 si ok, 1 sinon ---
post_note() { # $1 body
  local body="$1" resp
  if [ "$DRYRUN" = "1" ]; then
    log "[DRYRUN] note :: $(printf '%s' "$body" | head -c 100)"
    return 0
  fi
  resp=$(curl -s -X POST "$APIBASE/projects/$ENC/merge_requests/$IID/notes" \
    -H "Authorization: Bearer $GLTOKEN" --data-urlencode "body=$body" 2>>"$LOG")
  if printf '%s' "$resp" | jq -e '.id != null' >/dev/null 2>&1; then
    return 0
  fi
  log "WARN POST note KO resp=$(printf '%s' "$resp" | head -c 200)"
  return 1
}

posted=0; fell=0

while IFS="$(printf '\t')" read -r cat tok text; do
  [ -z "$tok" ] && continue
  # On retire les backticks : sinon GitLab rend les identifiants (`ProfileCode`…) en `code` — non voulu.
  text=$(printf '%s' "$text" | tr -d '`')
  path="${tok%:*}"; lineitem="${tok##*:}"
  # Le rapport peut citer un NOM COURT (mode diff) ; on résout vers le new_path complet du diff
  # (si non ambigu) pour permettre l'ancrage inline. Ambigu / introuvable -> on garde tel quel.
  fp=$(jq -r --arg p "$path" '[.[] | select(.new_path==$p or (.new_path|endswith("/"+$p))) | .new_path] | unique | if length==1 then .[0] else "" end' "$DIFFS" 2>/dev/null)
  [ -n "$fp" ] && path="$fp"
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
      # Commentaire INLINE = juste le texte du constat (ancré sur la ligne -> le fichier est implicite).
      if post_inline "$path" "$target" "$kold" "$text"; then
        posted=$((posted+1)); ok=1
      fi
    fi
  fi
  if [ "$ok" -eq 0 ]; then
    # Non ancrable inline (ligne absente du diff) : commentaire INDIVIDUEL, sans texte parasite,
    # préfixé du fichier:ligne (en clair, sans backticks) pour rester lié au code concerné.
    post_note "$tok — $text" && fell=$((fell+1))
  fi
done < "$ITEMS"

log "DONE post !$IID — inline=$posted, individuels=$fell"
rm -f "$DIFFS" "$ITEMS"
exit 0
