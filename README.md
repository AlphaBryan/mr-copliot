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
5. **Suit mon statut d'approbation** sur chaque MR et me **relance** si j'en laisse une trop longtemps
   (relance immédiate si je suis le **dernier approbateur** requis).
6. **Auto-post (optionnel)** : ~15 min après la création d'une nouvelle MR, poste les commentaires de la
   review directement en **inline** sur la MR.
7. **Saute les MR triviales** (bump de dépendances **ou** petit changement 1-2 fichiers) : pas de review
   ni d'auto-post ; me **relance toutes les 15 min** « à reviewer toi-même » jusqu'à ce que je l'approuve.
8. **Auto-évaluation (optionnel)** : après merge d'une MR reviewée, compare ma review aux commentaires
   humains réels et produit un score « attrapé / manqué ».
9. **Alerte de santé** : me prévient (ntfy + widget) si les appels GitLab échouent en série ou si le bot
   ne tourne plus — un watcher silencieusement cassé est pire que pas de watcher.

L'état est visible en continu dans un **widget SwiftBar** (barre de menu macOS) : voir plus bas.

Les bots (Renovate, Snyk) sont ignorés automatiquement (pas dans la watchlist).

### Suivi de mes approbations (pastille rouge + relance)

Pour chaque MR ouverte, `check.sh` interroge l'API GitLab (`.../approvals`) pour savoir si **moi**
je l'ai déjà approuvée (`user_has_approved`) et l'inscrit dans `open.json` (`approved`, `firstSeen`).

- **Relance ntfy + macOS** : si une MR reste **plus de `approval_nag_hours` heures (défaut 2)** sans
  mon approbation, j'en suis notifié **une seule fois** (dédup via `notified2h`, uniquement en heures
  actives). Le compteur part du 1er passage où la MR m'est montrée sans mon aval.
- **🎯 Dernier approbateur** : si `approvals_left == 1` et que ce n'est pas mon aval, la MR n'attend
  plus que **moi**. Notification **immédiate** (sans attendre le seuil de 2h) puis **relance répétée
  toutes les `last_approver_repeat_minutes` (défaut 15 min)** tant que je ne l'ai pas approuvée. C'est
  le signal le plus actionnable : mon clic débloque le merge, donc on insiste jusqu'à l'approbation.
- **Barre de menu** : `🎯 N` si je suis le dernier approbateur requis ; sinon `🔴 N` (pastille rouge)
  dès qu'une MR dépasse le seuil sans mon aval ; sinon `🔍 N` = MR **restant à approuver** ; `🔍✓`
  quand j'ai tout approuvé.
- **Menu déroulant** : `✅` grisé = déjà approuvée ; `🎯` orange = tu es le dernier ; `🟡` = à approuver
  (< seuil) ; `🔴` rouge = en attente au-delà du seuil (avec le temps écoulé).

### Auto-post de la review sur la MR (inline)

Quand `auto_post_review` est actif, `check.sh` poste la **section 4** du rapport (« Commentaires prêts
à coller ») directement sur la MR, **~`post_delay_minutes` (défaut 15) après la création de la MR**, une
seule fois, en heures actives. `post-review.sh <iid>` fait le travail :

- Chaque `- **\`fichier:ligne\`** — texte` devient une **discussion inline** ancrée sur la ligne du
  diff (positions `base/head/start_sha` de l'API GitLab, ligne ajoutée ou de contexte détectée par un
  parseur de diff).
- **Repli sans perte** : tout commentaire non ancrable (ligne hors diff, SHA au lieu d'un numéro de
  ligne, ou POST rejeté par l'API) est regroupé dans **une seule note générale** — rien n'est perdu.
- **Garde-fous** : ne poste que les MR **détectées neuves depuis l'activation** (les MR déjà ouvertes
  au moment d'activer ne sont jamais rétro-postées, via `postEligible`), **une seule fois**
  (`reviewPosted`), jamais sur une simple mise à jour de commits.

Réglages `config.json` : `auto_post_review` = `false` (off, défaut) | `true` (poste réel) | `"dryrun"`
(journalise dans `logs/post-<iid>.log` sans rien envoyer) ; `post_delay_minutes` (défaut 15).

Test manuel sur une MR précise : `bash post-review.sh <iid>` (poste réel) ou
`POST_DRYRUN=1 bash post-review.sh <iid>` (simulation).

### Saut des MR triviales (bump ou petit changement)

Quand `skip_trivial_reviews` est actif (défaut), `check.sh` regarde le diff d'une **nouvelle** MR et la
juge **triviale** dans deux cas :

- **Petit changement** : ≤ `trivial_small_max_files` fichiers (défaut 2) **et** ≤ `trivial_small_max_lines`
  lignes changées (défaut 30). Un gros remaniement d'un seul fichier n'est donc PAS trivial.
- **Bump de dépendances** : ne touche QUE des manifestes (`trivial_file_patterns` : `Directory.Packages.props`,
  `*.csproj`, `*.props`, `package.json`, lockfiles) et ≤ `trivial_max_files` fichiers (défaut 3).

Pour une MR triviale, la review `claude` **et** l'auto-post sont **sautés** (rien de substantiel à
analyser/commenter). À la place, le bot me **relance toutes les `trivial_reminder_minutes` (défaut 15)**
avec « 🔎 À reviewer toi-même » jusqu'à ce que je l'approuve. La MR est visible dans le widget (marquée
`🔧 Pas de review auto — à reviewer toi-même`). Au moindre doute (fichier de code volumineux, trop de
fichiers, API KO), la review a lieu normalement.

Priorité des relances sur une MR non approuvée : **🎯 dernier approbateur** > **🔎 triviale à reviewer** >
**⏰ en attente > seuil**.

**Review échouée / MR trop grosse** : si une review ne produit pas de rapport (claude coupé par une mise
en veille du Mac, ou MR trop grosse pour finir dans le `timeout` de 10 min), `check.sh` la **re-tente en
silence** jusqu'à `review_max_attempts` (défaut 3). Au-delà, il **abandonne l'auto-review** et bascule la
MR en **« 🔎 à reviewer toi-même »** (mêmes relances que le skip trivial). Ça évite qu'une review coincée
tourne en boucle. Un **verrou** (`.check.lock`) garantit par ailleurs qu'un seul `check.sh` tourne à la
fois (les reviews peuvent dépasser l'intervalle de 15 min) — pas de reviews concurrentes ni de double post.

### Auto-évaluation vs les reviewers (score attrapé / manqué)

Quand `auto_grade_reviews` est actif, dès qu'une MR que j'avais reviewée **passe en `merged`**, `check.sh`
lance `grade-review.sh <iid>` : `claude` compare **mes constats** (section 4 du rapport) aux **commentaires
des vrais reviewers humains** (API `discussions`, hors auteur + bots) et répond en JSON : combien de points
humains ma review a **attrapés**, combien **manqués** (avec la liste), et combien de constats **en plus**.

- Une note lisible est écrite dans `grades/mr<iid>-<date>.md`, et une ligne est ajoutée à
  `grades/summary.tsv` (`date, iid, humainsPoints, attrapés, manqués, extra`) pour suivre la tendance.
- Détection du merge : une MR présente au passage précédent et absente ensuite (confirmée `merged`),
  notée **une fois** (`graded-state.tsv`).
- Manuel : `bash grade-review.sh <iid>`.

### Alerte de santé (dead-man's switch)

`check.sh` écrit `health.json` à **chaque** passage (heartbeat). Si les appels GitLab échouent
**`health_alert_after` passages consécutifs** (défaut 3 ≈ 45 min), une **alerte ntfy** est envoyée (une
fois), puis une notif de **rétablissement** au retour. Le **widget** passe en `🔍⚠️` (avec le détail) quand
l'API échoue en série **ou** qu'aucun passage réussi n'a eu lieu depuis > 25 min (bot bloqué / arrêté).

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

## Widget SwiftBar (barre de menu)

`swiftbar/mrwatch.1m.sh` affiche l'état du bot dans la barre de menu macOS, rafraîchi chaque minute
(lecture seule de fichiers locaux, aucun appel réseau). Nécessite [SwiftBar](https://github.com/swiftbar/SwiftBar).

**Icône de la barre de menu :**

| Icône | Sens |
|---|---|
| `🔍⚠️` | **Alerte de santé** : appels GitLab en échec en série, ou aucun passage réussi récent (bot bloqué) |
| `🎯 N` | Je suis le **dernier approbateur** requis sur `N` MR (mon aval débloque le merge) |
| `🔴 N` | Au moins une MR non approuvée depuis > seuil (`approval_nag_hours`) ; `N` = MR restant à approuver |
| `🔍 N` | `N` MR restent à approuver (aucune en retard) |
| `🔍✓` | Tout est approuvé (plus de chiffre) |
| `🔍💤` | Hors heures actives |
| `🔍⏹` | Bot arrêté (non chargé dans launchd) |

Priorité d'affichage : santé `⚠️` > dernier approbateur `🎯` > en retard `🔴` > compte `🔍`.

**Menu déroulant :**
- État du bot (chargé/arrêté + `⚠️` si souci de santé), heures actives, dernier passage, résumé
  « X à approuver · Y en retard · 🎯 Z dont tu es le dernier ».
- La liste des **MR ouvertes** avec, pour chacune : `✅` grisé (approuvée), `🎯` orange (tu es le dernier),
  `🟡` (à approuver), `🔴` (en attente > seuil). Sous-menu : titre, statut, **🌐 Ouvrir la MR** (seul lien
  qui ouvre la MR), **📄 Ouvrir le rapport** (ou `🔧 Pas de review auto` pour une MR triviale / non auto-reviewée).
- Actions : **↻ Forcer un check**, **🔎 Reviewer ma branche locale**, **📁 Dossier des rapports**,
  **📜 Voir les logs** (dossier des logs + `check.log` / `learn.log` / dernier `post-*.log`, plus un
  aperçu des dernières lignes de `check.log`), **📊 Qualité review (auto-éval)** (tendance : attrapé/total
  + %, et les dernières MR notées, depuis `grades/summary.tsv`), **↻ Rafraîchir**.

## Fichiers

| Fichier | Rôle |
|---|---|
| `config.json` | Watchlist, heures, `approval_nag_hours`, `last_approver_repeat_minutes` (relance dernier approbateur, défaut 15), auto-post (`auto_post_review`, `post_delay_minutes`), santé (`health_alert_after`), skip trivial (`skip_trivial_reviews`, `trivial_max_files`, `trivial_file_patterns`, `trivial_small_max_files`, `trivial_small_max_lines`, `trivial_reminder_minutes`, `review_max_attempts`), auto-éval (`auto_grade_reviews`), modèle, plafond diff, `repo_dir`, `local_repo_dir`, filtre IA (`learn_ai_filter`, `learn_exclude_authors`, `learn_ai_markers`). **À éditer ici.** |
| `config.example.json` | Template de config à copier vers `config.json` (non versionné). |
| `check.sh` | Détection + notif + approbations + reviews + auto-post + skip trivial + santé + auto-éval. Toutes les 15 min (launchd). |
| `force-check.sh` | Force un passage de `check.sh` maintenant (bouton du widget). |
| `review.sh <iid>` | Génère un rapport pour une MR (mode repo via worktree, repli diff). |
| `review-local.sh [repo]` | Review la branche locale courante (commité + non commité). |
| `post-review.sh <iid>` | Poste la section 4 d'un rapport en commentaires inline sur la MR (repli en note générale). `POST_DRYRUN=1` = simulation. |
| `grade-review.sh <iid>` | Auto-évaluation : compare ma review aux commentaires humains → `grades/`. |
| `review-local-launch.sh` | Lance `review-local.sh` détaché (utilisé par le bouton du widget). |
| `learn.sh` | Apprend le style des reviewers seniors → met à jour `prompts/learned-style.md`. 2x/jour (8h05, 13h05). |
| `prompts/review-prompt.md` | Le prompt de review (modifiable pour ajouter des critères). |
| `prompts/learn-prompt.md` | Le prompt de distillation utilisé par `learn.sh`. |
| `prompts/ai-filter-prompt.md` | Le prompt du classifieur humain-vs-IA (couche 2 de l'anti « IA entraîne l'IA »). |
| `prompts/grade-prompt.md` | Le prompt d'auto-évaluation (ma review vs les commentaires humains). |
| `prompts/learned-style.md` | Le guide de style APPRIS (généré/maj auto, injecté dans chaque review). |
| `swiftbar/mrwatch.1m.sh` | Widget barre de menu (SwiftBar) : état, MR + approbations, boutons (logs, check, review locale). |
| `learn-state.tsv` | IDs des commentaires déjà appris (dédup). Supprimer = tout ré-apprendre. |
| `state.tsv` | MR déjà vues (iid + sha). Supprimer = tout re-traiter. |
| `open.json` | Snapshot des MR ouvertes + statut approbation / auto-post / trivial (lu par le widget). |
| `health.json` | Heartbeat + compteur d'échecs GitLab (alerte de santé). |
| `graded-state.tsv` | iids de MR déjà auto-évaluées (dédup). |
| `reviews/` | Rapports générés (`ADF-XXXX-mrIID-date.md`, `LOCAL-<branche>-date.md`). |
| `grades/` | Notes d'auto-évaluation (`mr<iid>-date.md`) + `summary.tsv` (tendance). |
| `worktrees/` | Worktrees git temporaires créés/supprimés par `review.sh` (mode repo). |
| `logs/` | Journaux : `check.log`, `learn.log`, `review-<iid>.log`, `review-local-*.log`, `post-<iid>.log`, `launchd.*.log`. |
| `install.sh` / `uninstall.sh` | Charger / décharger le bot dans launchd. |
| `com.bryan.mevo.mrwatch*.plist` | Agents launchd : `check.sh` (15 min) + `learn.sh` (8h05 / 13h05). |
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
bash post-review.sh 3806   # poster la review d'une MR en inline (POST_DRYRUN=1 = simulation)
bash grade-review.sh 3806  # auto-évaluer une review vs les commentaires humains
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
- **Portée de la review** : le prompt (`prompts/review-prompt.md`) review le **code**, pas les
  métadonnées de la MR — pas de commentaire sur l'écart description ↔ commits, les messages de commit
  ou le découpage. Un `fichier:ligne` est toujours un vrai numéro de ligne (jamais un SHA).
- **Auto-post** : action publique sous ton compte GitLab. Pour couper, mettre `auto_post_review` à
  `false` dans `config.json`. Pour un test contrôlé, `POST_DRYRUN=1 bash post-review.sh <iid>`.
- **Robustesse du widget** : `open.json` est écrit **avant** les reviews (lentes, mises en file et
  lancées ensuite) et **survit à un échec partiel** (fetch d'un collègue KO → on garde ses dernières
  MR connues et on met à jour celles des collègues récupérés). Donc une MR déjà notifiée apparaît
  toujours dans le widget, même si une review est lente/interrompue ou qu'un fetch flanche.
- À la 1re notification, macOS demandera l'autorisation pour `terminal-notifier` (accepter une fois).
