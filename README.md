# mr-watch

Bot local qui surveille les Merge Requests GitLab de coéquipiers précis, notifie sur macOS
quand une MR **non-draft** apparaît (ou reçoit de nouveaux commits), et génère un **rapport de
review ciblé** en français.

## Ce qu'il fait

Toutes les 15 min, **uniquement 8h-17h du lundi au vendredi** (auto-désactivé en dehors) :

1. Liste les MR ouvertes non-draft des personnes dans `config.json` (`watch_users`).
2. Pour chaque MR nouvelle ou mise à jour → **notification macOS** (cliquable, ouvre la MR).
3. Génère en arrière-plan un **rapport de review** via `claude`, en 4 parties :
   - Ce que la MR apporte + le requis, expliqué simplement (niveau débutant).
   - Spot checks : dead code, over-engineering.
   - Bugs / incohérences C# ou TS, classés par gravité.
   - **Commentaires prêts à coller** sur la MR (groupés Bugs / Améliorations / Questions, chacun avec `fichier:ligne`).
4. **Notification cliquable** quand le rapport est prêt → ouvre le `.md` dans VS Code.
5. **Suit mon statut d'approbation** sur chaque MR et me **relance** si j'en laisse une trop longtemps.

Les bots (Renovate, Snyk) sont ignorés automatiquement (pas dans la watchlist).

### Suivi de mes approbations (pastille rouge + relance)

Pour chaque MR ouverte, `check.sh` interroge l'API GitLab (`.../approvals`) pour savoir si **moi**
je l'ai déjà approuvée (`user_has_approved`) et l'inscrit dans `open.json` (`approved`, `firstSeen`).

- **Relance ntfy + macOS** : si une MR reste **plus de `approval_nag_hours` heures (défaut 2)** sans
  mon approbation, j'en suis notifié **une seule fois** (dédup via `notified2h`, uniquement en heures
  actives). Le compteur part du 1er passage où la MR m'est montrée sans mon aval.
- **Barre de menu** : `🔴 N` (pastille rouge) dès qu'une MR dépasse le seuil sans mon aval ; sinon
  `🔍 N` = nombre de MR **restant à approuver** ; `🔍✓` quand j'ai tout approuvé (plus de chiffre).
- **Menu déroulant** : `✅` grisé = déjà approuvée ; `🟡` = à approuver (< seuil, avec délai) ;
  `🔴` rouge = en attente au-delà du seuil (avec le temps écoulé).

### Auto-apprentissage du style des reviewers

2x/jour (8h05 et 13h05), `learn.sh` lit les **commentaires des reviewers seniors** (liste
`learn_from_reviewers`) sur les MR ouvertes + mergées des 30 derniers jours, via l'API GitLab
`discussions` (chaque commentaire porte son `fichier:ligne` et son statut `résolu`). Il **distille**
ces commentaires via `claude` en un guide de style — `prompts/learned-style.md` — qui capture les
**checks récurrents**, les **conventions maison**, le **ton** et des **exemples** de bons commentaires.

Ce guide est ensuite **injecté automatiquement** dans chaque review (MR et locale). Résultat : les
rapports commentent de plus en plus comme un vrai dev de l'équipe. L'apprentissage est **incrémental**
(seuls les nouveaux commentaires sont distillés, dédup par ID dans `learn-state.tsv`) et **idempotent**
(rien de neuf → aucun appel claude). Les noms des personnes sont anonymisés dans le guide.

#### Anti « IA qui entraîne l'IA »

Maintenant que des reviewers collent parfois des commentaires générés par IA, `learn.sh` filtre le
corpus avant distillation pour ne pas apprendre d'une autre IA — en **deux couches** :

1. **Déterministe (gratuit)** : écarte les commentaires des comptes listés dans
   `learn_exclude_authors` (bots, comptes IA dédiés) et ceux contenant une **signature**
   `learn_ai_markers` (sous-chaînes insensibles à la casse, ex. `🤖`, `co-authored-by: claude`).
2. **Garde LLM** (`learn_ai_filter`, activé par défaut) : `claude` classe chaque **nouveau**
   commentaire humain-vs-IA (modèle `learn_ai_filter_model`). Les commentaires jugés IA sont retirés
   du lot mais **marqués traités** (jamais re-classés). Dans le doute, le classifieur tranche
   **humain** (on préfère garder un vrai commentaire que le jeter). Si sa sortie est illisible, le
   passage est **sauté** (rien appris, réessai au prochain tour) — le guide n'est jamais contaminé.

Prompt du classifieur : `prompts/ai-filter-prompt.md`. Mettre `learn_ai_filter` à `false` désactive
la couche 2 (la couche 1 reste active).

### Mode repo (par défaut) vs mode diff

Par défaut, `review.sh` ne se contente PAS du diff : il crée un **worktree git isolé** sur la
branche de la MR (à partir de `repo_dir`) et laisse `claude` **explorer le code complet**
(lecture de fichiers, `grep -n`, `git diff`). Résultat : il trouve les bugs cross-fichiers
(un changement incomplet ailleurs) et les `fichier:ligne` sont **réels** (vérifiés au `grep -n`).

Si le worktree échoue (repo absent, fetch KO), repli automatique sur l'ancien **mode diff**
(on ne pipe que le diff, plafonné par `max_diff_lines`). Le mode utilisé est inscrit dans le rapport.

### Reviewer ma branche locale (avant MR)

Bouton du widget **« 🔎 Reviewer ma branche locale »** (ou `bash review-local.sh`) : review la
branche actuellement checkout dans `local_repo_dir`, vs `local_base_branch`, en incluant les
changements **non commités** (staged + working tree). Pratique pour avoir un rapport avant
d'ouvrir la MR. Notif au lancement, puis notif cliquable quand le rapport est prêt.

## Fichiers

| Fichier | Rôle |
|---|---|
| `config.json` | Watchlist, heures, `approval_nag_hours` (seuil relance, défaut 2), modèle, plafond diff, `repo_dir`, `local_repo_dir`, `learn_from_reviewers`, `learn_window_days`, `learn_model`, filtre IA (`learn_ai_filter`, `learn_exclude_authors`, `learn_ai_markers`). **À éditer ici.** |
| `check.sh` | Détection + notif + déclenche les reviews. |
| `review.sh <iid>` | Génère un rapport pour une MR (mode repo via worktree, repli diff). |
| `review-local.sh [repo]` | Review la branche locale courante (commité + non commité). |
| `review-local-launch.sh` | Lance `review-local.sh` détaché (utilisé par le bouton du widget). |
| `learn.sh` | Apprend le style des reviewers seniors → met à jour `prompts/learned-style.md`. 2x/jour (8h05, 13h05). |
| `prompts/review-prompt.md` | Le prompt de review (modifiable pour ajouter des critères). |
| `prompts/learn-prompt.md` | Le prompt de distillation utilisé par `learn.sh`. |
| `prompts/ai-filter-prompt.md` | Le prompt du classifieur humain-vs-IA (couche 2 de l'anti « IA entraîne l'IA »). |
| `prompts/learned-style.md` | Le guide de style APPRIS (généré/maj auto, injecté dans chaque review). |
| `learn-state.tsv` | IDs des commentaires déjà appris (dédup). Supprimer = tout ré-apprendre. |
| `reviews/` | Rapports générés (`ADF-XXXX-mrIID-date.md`, `LOCAL-<branche>-date.md`). |
| `worktrees/` | Worktrees git temporaires créés/supprimés par `review.sh` (mode repo). |
| `logs/` | Journaux (`check.log`, `review-<iid>.log`, `review-local-*.log`, `launchd.*.log`). |
| `state.tsv` | MR déjà vues (iid + sha). Supprimer = tout re-traiter. |
| `install.sh` / `uninstall.sh` | Charger / décharger le bot dans launchd. |
| `status.sh` | État du bot, MR suivies, derniers logs et rapports. |

## Commandes

```bash
bash install.sh            # démarre le bot en arrière-plan (auto au login)
bash uninstall.sh          # arrête et retire le bot
bash status.sh             # voir l'état

bash check.sh --seed       # marque les MR ACTUELLES comme vues SANS les reviewer (baseline)
MRWATCH_FORCE=1 bash check.sh   # forcer un passage maintenant (ignore le filtre horaire)
bash review.sh 3806        # (re)générer le rapport d'une MR précise à la main
bash review-local.sh       # reviewer la branche locale courante (repo de dev configuré)
bash learn.sh              # apprendre le style des reviewers maintenant (nouveaux commentaires)
MRWATCH_LEARN_RESET=1 bash learn.sh   # tout ré-apprendre depuis zéro
MRWATCH_SKIP_FETCH=1 bash review.sh 3806   # re-run sans refetch (refs déjà locaux)
```

## Modifier la watchlist

Éditer `config.json` → `watch_users`. Aucune autre étape : le prochain passage en tient compte.

## Notes

- `glab` lit son token depuis `~/Library/Application Support/glab-cli/config.yml`.
- L'extraction Jira (`acli`) est best-effort ; si elle échoue, le requis vient de la description de la MR.
- **Mode repo** : `repo_dir` est un clone local de DragonEdge ; `review.sh` y crée un worktree
  temporaire (dans `worktrees/`) puis le supprime. Le `git fetch` est borné (`timeout` +
  `GIT_TERMINAL_PROMPT=0`) pour ne jamais bloquer le job launchd ; en cas d'échec il utilise les
  refs locales, et si le worktree ne peut pas se créer, repli sur le mode diff.
- **Mode diff (repli)** : le diff envoyé à `claude` est plafonné (`max_diff_lines`, défaut 2500) ;
  au-delà, la review est partielle et le rapport le signale.
- À la 1re notification, macOS demandera l'autorisation pour `terminal-notifier` (accepter une fois).
