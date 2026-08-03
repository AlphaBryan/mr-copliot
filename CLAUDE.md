# mr-watch

Bot local (macOS) qui surveille les Merge Requests GitLab de coéquipiers précis, notifie
(macOS + ntfy sur téléphone) quand une MR non-draft apparaît ou reçoit de nouveaux commits,
et génère un rapport de review ciblé en français via `claude` headless.

Outil personnel de Bryan. Vit en dehors du repo DragonEdge, rien n'est committé là-bas.

## À quoi ça sert

Bryan est débutant en programmation. Le but n'est PAS une revue exhaustive, mais un rapport
court et pédagogique en 4 parties (voir `prompts/review-prompt.md`) :
1. Ce que la MR apporte + le requis, expliqué simplement (avec mini-définitions des termes).
2. Spot checks : dead code, over-engineering.
3. Bugs / incohérences C# ou TS, classés par gravité 🔴🟡🟢.
4. Commentaires prêts à coller sur la MR (groupés Bugs / Améliorations / Questions, `fichier:ligne`).

Deux entrées : review d'une **MR** (`review.sh <iid>`, déclenché par `check.sh`) et review de la
**branche locale courante avant MR** (`review-local.sh`, déclenché par le bouton du widget).

## Architecture

```
launchd (toutes les 15 min, plist dans ~/Library/LaunchAgents/)
   └─ check.sh
        ├─ Pour chaque user surveillé : glab api -> MR ouvertes non-draft (wip=no)
        ├─ Réécrit open.json (snapshot pour le widget) à CHAQUE passage, même hors heures
        ├─ Élague state.tsv : ne garde que les MR encore ouvertes (les mergées disparaissent)
        ├─ Notifs + reviews UNIQUEMENT en heures actives (8h-17h lun-ven). Hors heures :
        │   snapshot mis à jour mais ni notif ni review (les nouvelles MR seront reviewées à 8h)
        ├─ MR nouvelle / sha changé (en heures actives) ?
        │    ├─ Notif macOS (terminal-notifier) + ntfy (curl)
        │    └─ review.sh <iid>  (SYNCHRONE, voir gotcha launchd)
        └─ review.sh : worktree git (repo_dir) sur la branche MR -> claude -p EXPLORE le code
                       complet (Read/Grep/git) -> rapport .md + notifs. Repli mode diff si KO.

review-local.sh (bouton widget, hors launchd) : claude -p dans local_repo_dir EN DIRECT,
   review la branche courante (commité vs base + non commité) -> rapport LOCAL-*.md + notifs.

learn.sh (launchd séparé com.bryan.mevo.mrwatch-learn, 8h05 + 13h05) :
   glab discussions sur MR ouvertes + mergées (30j) -> garde les commentaires des
   learn_from_reviewers (sauf réponses de l'auteur de la MR) -> dédup par note_id (learn-state.tsv)
   -> claude -p distille (outils d'écriture INTERDITS) -> prompts/learned-style.md.
   review.sh ET review-local.sh injectent learned-style.md dans le prompt (sauf placeholder).
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `config.json` | Watchlist, heures, modèle, `repo_dir`, `worktrees_dir`, `local_repo_dir`, `local_base_branch`, bloc `ntfy`. Seul fichier à éditer normalement. |
| `check.sh` | Détection + notif + déclenche review. `--seed` = baseline sans review. `MRWATCH_FORCE=1` = ignore l'heure. |
| `review.sh <iid>` | Rapport d'une MR. Mode repo (worktree + exploration) par défaut, repli mode diff. `MRWATCH_SKIP_FETCH=1` saute le fetch. |
| `review-local.sh [repo]` | Rapport de la branche LOCALE courante (commité vs base + non commité). Arg = repo, sinon `local_repo_dir`. |
| `review-local-launch.sh` | Lance `review-local.sh` détaché (`nohup &`). Cible du bouton widget « 🔎 Reviewer ma branche locale ». |
| `learn.sh` | Boucle d'apprentissage (launchd séparé). Distille les commentaires des reviewers seniors -> `learned-style.md`. `MRWATCH_LEARN_RESET=1` ré-apprend tout. |
| `prompts/review-prompt.md` | Le prompt de review (partagé MR + local). Éditer ici pour ajouter des critères. |
| `prompts/learn-prompt.md` | Prompt de distillation pour `learn.sh`. |
| `prompts/learned-style.md` | Guide de style APPRIS, généré par `learn.sh`, injecté dans chaque review. |
| `learn-state.tsv` | `note_id` des commentaires déjà distillés (anti-doublon). |
| `reviews/` | Rapports générés (`ADF-XXXX-mrIID-date.md`, `LOCAL-<branche>-date.md`). |
| `worktrees/` | Worktrees git temporaires (mode repo). Créés/supprimés par `review.sh` (trap EXIT). |
| `logs/` | `check.log`, `review-<iid>.log`, `launchd.*.log`. |
| `state.tsv` | Journal anti-doublon des reviews (`iid<TAB>sha`). Élagué à chaque passage : ne contient que les MR encore ouvertes. Usage interne, PAS pour l'affichage. |
| `open.json` | Snapshot des MR réellement ouvertes (iid, author, title, url), réécrit à chaque passage. C'est ce que le widget affiche. |
| `install.sh` / `uninstall.sh` / `status.sh` | Charger / décharger / état du bot dans launchd. |
| `swiftbar/mrwatch.1m.sh` | Plugin SwiftBar : widget barre de menu (haut droite) qui affiche l'état. Lit que des fichiers locaux. |
| `force-check.sh` | Force un passage de check.sh (utilisé par le bouton du widget). |

## Configuration actuelle

- **Personnes surveillées** : `jean-baptiste.vouma-lekoundji`, `marc-olivier.gagnon` (dans `config.json` -> `watch_users`).
- **Projet GitLab** : `vooban/customers/adf/DragonEdge` (sur gitlab.com).
- **Heures** : 8h-17h, lun-ven.
- **Modèle review** : `sonnet`. Plafond diff (mode diff seulement) : 2500 lignes.
- **Mode repo** : `repo_dir` = `~/Documents/GitHub/DragonEdge-Review` (worktrees dans `~/mr-watch/worktrees`).
- **Review locale** : `local_repo_dir` = `~/Documents/GitHub/DragonEdge`, base `main`.
- **ntfy** : serveur `https://ntfy.sh`, topic `review-bot` (PUBLIC et devinable — à remplacer par un nom long/aléatoire pour le rendre privé).

## Gotchas (appris en construisant l'outil)

- **bash 3.2** : macOS ship bash 3.2. Pas de `declare -A` ni `mapfile`. L'état est un fichier TSV
  manipulé via `awk`. Garder les scripts compatibles 3.2.
- **launchd tue les enfants en arrière-plan** : un `review.sh` lancé via `nohup ... &` est tué quand
  `check.sh` (le job launchd) se termine. C'est pourquoi `review.sh` est appelé en SYNCHRONE
  (`timeout 600 ...`) dans `check.sh`. Ne PAS revenir à `&`.
- **Token glab** : pas de variable d'env ; lu depuis `~/Library/Application Support/glab-cli/config.yml`
  (un fichier, donc accessible depuis launchd). Le plist fixe `PATH` (homebrew) et `HOME`.
- **Filtre draft** : `wip=no` dans l'appel glab exclut les drafts. Vérifié aussi via le champ `draft`.
  Une MR passée en Draft est donc correctement ignorée.
- **Jira (acli)** : best-effort via `.claude/scripts/jira-extract.sh` du repo DragonEdge-Review. Échoue
  souvent en headless -> repli automatique sur la description de la MR pour le requis.
- **Mode repo (worktree + exploration)** : `review.sh` crée un worktree sur `origin/<branche>` dans
  `worktrees/` et lance `claude -p` AVEC le cwd dans le worktree + outils read-only (`--allowedTools
  Read Grep Glob Bash(git/grep/...)`). Claude lit les fichiers complets et confirme les `fichier:ligne`
  au `grep -n` -> trouve les bugs cross-fichiers (le mode diff seul ne les voyait pas).
- **Fetch jamais bloquant** : `GIT_TERMINAL_PROMPT=0 timeout 120 git fetch` en best-effort. Le
  credential helper `osxkeychain` peut HANG sans TTY ; le `timeout` borne ça et on retombe sur les
  refs locales (ou sur le mode diff). `MRWATCH_SKIP_FETCH=1` saute le fetch (re-run / test).
- **Nettoyage worktree** : `trap cleanup_wt EXIT` dans `review.sh` -> `git worktree remove --force`
  même en cas d'erreur. Ne pas laisser de worktree orphelin (`git -C $repo_dir worktree prune`).
- **review-local.sh tourne dans le repo EN DIRECT** (pas de worktree) pour voir les changements non
  commités. Lecture seule (claude n'a pas de tool d'écriture autorisé). Lancé détaché par le bouton.
- **Diff plafonné (mode diff seulement)** : au-delà de `max_diff_lines`, le diff est tronqué et le rapport le signale.
- **`claude -p` = agent avec outils, pas une fonction texte→texte** : pour `learn.sh` (pure
  distillation), si on ne bride pas les outils, claude ÉCRIT le guide lui-même via Write et ne
  renvoie qu'un résumé sur stdout -> le script écrase alors le bon guide par le résumé. Fix :
  `--disallowedTools "Write" "Edit" "MultiEdit" "NotebookEdit" "Bash"` + prompt qui exige que la
  réponse SOIT le guide. (À l'inverse, `review.sh` a BESOIN des outils de lecture pour explorer.)
- **Apprentissage : ne jamais écraser par du vide** : `learn.sh` ne réécrit `learned-style.md` que
  si la sortie claude fait > 80 octets, et ne marque les `note_id` dans `learn-state.tsv` qu'APRÈS
  succès. Une distillation ratée laisse le guide intact et réessaiera les mêmes commentaires.
- **Injection conditionnelle du guide** : review.sh/review-local.sh injectent `learned-style.md`
  seulement s'il existe ET ne contient pas le marqueur placeholder « n'a pas encore tourné ».

## Commandes

```bash
bash status.sh                  # état du bot, MR suivies, derniers rapports
bash install.sh / uninstall.sh  # démarrer / arrêter
bash check.sh --seed            # marquer les MR actuelles comme vues sans les reviewer
MRWATCH_FORCE=1 bash check.sh   # forcer un passage maintenant
bash review.sh <iid>            # (re)générer le rapport d'une MR à la main (mode repo)
MRWATCH_SKIP_FETCH=1 bash review.sh <iid>   # re-run sans refetch (refs déjà locaux)
bash review-local.sh            # reviewer la branche locale courante (local_repo_dir)
bash review-local.sh /chemin/repo   # reviewer la branche courante d'un autre repo
```

launchd relit les scripts et `config.json` à chaque passage : modifier un fichier prend effet au
prochain cycle, sans réinstaller. Réinstaller (`install.sh`) seulement si on change le `.plist`.

## Widget barre de menu (SwiftBar)

App SwiftBar (installée via `brew install --cask swiftbar`) configurée pour lire le dossier
`swiftbar/`. Le titre du menu : `🔍 N` (N MR suivies) en heures actives, `🔍💤` hors heures,
`🔍⏹` si le bot n'est pas chargé. Le plugin se rafraîchit chaque minute et ne fait AUCUN appel
réseau (il lit `state.tsv`, les rapports dans `reviews/`, et `logs/check.log`). Pour reconstruire
les MR sans réseau, les URLs sont dérivées de `project` + iid, et titre/auteur viennent du dernier
rapport `.md` de chaque MR.

Boutons d'action du widget : « ↻ Forcer un check » (`force-check.sh`), « 🔎 Reviewer ma branche
locale (<branche>) » (`review-local-launch.sh`, détaché — le clic rend la main tout de suite, notif
à la fin), « 📁 Ouvrir le dossier des rapports ». Le nom de la branche affiché vient d'un
`git -C local_repo_dir branch --show-current` (local, sans réseau).

Config SwiftBar : `defaults write com.ameba.SwiftBar PluginDirectory "<dir>/swiftbar"`.
Changer l'intervalle = renommer le fichier (`mrwatch.1m.sh` -> `.30s.sh`, etc.).
