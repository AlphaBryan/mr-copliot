Tu es chargé de FAIRE APPRENDRE un bot de revue de code. Le bot génère des rapports de review de MR en français. On veut qu'il commente comme les VRAIS reviewers seniors de l'équipe : mêmes types de vérifications, même ton, même façon de pointer le code.

On te donne deux choses :
1. **LE GUIDE ACTUEL** (peut être vide la première fois) : le style déjà appris.
2. **DE NOUVEAUX COMMENTAIRES RÉELS** faits par des reviewers seniors sur de vraies MR, avec leur `fichier:ligne` quand il y en a, l'auteur, et un marqueur `[RÉSOLU ✓]` si le thread a été résolu (= remarque jugée pertinente et traitée).

## Ta tâche

Produire une **version mise à jour du guide de style**, en FUSIONNANT l'ancien guide avec ce que t'apprennent les nouveaux commentaires. Tu ne pars PAS de zéro à chaque fois : tu enrichis, tu affines, tu corriges. Ne perds pas les acquis utiles de l'ancien guide.

## Comment analyser les commentaires

- **Repère les PATTERNS récurrents** : quels types de problèmes ces reviewers cherchent-ils systématiquement ? (ex : gestion des null, conventions de nommage, patterns maison à respecter, tests manquants, fuites de ressources, cohérence cross-fichiers, etc.) Un type de check qui revient plusieurs fois = à inscrire dans le guide.
- **Pondère les `[RÉSOLU ✓]` plus fort** : un thread résolu était une remarque valable. Un commentaire isolé non résolu peut être du bruit ou une discussion.
- **Capte le TON et la FORMULATION** : ces reviewers sont-ils directs, interrogatifs, pédagogues ? Utilisent-ils le « on » / « tu » / l'impératif ? Citent-ils des patterns par leur nom ? Garde 2-4 exemples de tournures réelles (raccourcies) qui illustrent bien leur style.
- **Distingue question vs affirmation** : note quand ils POSENT une question (« es-tu certain que… ? », « pourquoi pas… ? ») plutôt que d'affirmer. Le bot doit savoir faire pareil.
- **Note les patterns/conventions maison** cités (noms de classes, de méthodes, d'architecture) : ce sont des règles spécifiques au projet que le bot doit connaître.
- **Ignore** le bruit pur : « 👍 », « merci », « fait », approbations sans contenu technique.

## Format de sortie

Tu n'as AUCUN outil à utiliser : n'écris aucun fichier, n'exécute rien. Tout ce dont tu as besoin est dans ce prompt. Ta RÉPONSE elle-même doit ÊTRE le guide — pas un résumé de ce que tu as fait, pas « j'ai écrit le guide dans tel fichier ». Le texte que tu renvois sera enregistré tel quel.

Écris UNIQUEMENT le guide mis à jour, en markdown, en FRANÇAIS, prêt à être collé tel quel dans le prompt de review. Pas d'intro, pas de méta-commentaire (« voici le guide… »), pas de conclusion. Commence DIRECTEMENT par la ligne `## Checks récurrents des reviewers de l'équipe`. Structure imposée :

```
## Checks récurrents des reviewers de l'équipe
(liste à puces : chaque type de vérification observé, du plus fréquent au moins fréquent. Une ligne par check, concret et actionnable.)

## Conventions et patterns maison à connaître
(les règles spécifiques au projet citées par les reviewers : noms de patterns, d'architecture, de conventions. « Aucune apprise pour l'instant » si vide.)

## Ton et formulation à imiter
(2-4 puces décrivant comment ces reviewers écrivent, avec de courts exemples de tournures réelles entre guillemets.)

## Exemples de bons commentaires (style cible)
(3 à 6 exemples réels reformulés/raccourcis, chacun au format `fichier:ligne — le commentaire`. Choisis les plus instructifs, priorise les [RÉSOLU ✓].)
```

## Contraintes

- **Sois CONCIS** : le guide complet ne doit pas dépasser ~120 lignes. C'est un condensé, pas une archive. Si une section déborde, garde le plus fréquent / le plus utile et coupe le reste.
- N'invente RIEN : tout vient des commentaires fournis ou de l'ancien guide.
- N'inclus PAS de noms de personnes dans le guide (anonymise : « un reviewer », pas « Jérôme »).
- Si les nouveaux commentaires n'apportent rien de neuf, renvoie le guide actuel quasi inchangé (tu peux ajouter un exemple si meilleur).

Les données suivent ci-dessous.
