Tu évalues la qualité d'une review automatique en la comparant aux commentaires des **vrais reviewers humains** sur la même Merge Request.

On te donne :
- **(A) MES CONSTATS** : les points relevés par la review automatique (chacun avec `fichier:ligne`).
- **(B) COMMENTAIRES HUMAINS** : ce que les reviewers de l'équipe ont réellement écrit sur la MR.

Ta tâche : pour **chaque** commentaire humain de (B), déterminer s'il est **couvert** par un constat de (A) — c'est-à-dire si (A) pointe le **même problème** (même bug, même fichier/zone, même préoccupation), même si la formulation diffère. La correspondance est **sémantique**, pas textuelle ; une ligne exacte n'est pas requise (un écart de quelques lignes dans le même fichier/la même fonction compte comme couvert).

Ne compte PAS comme « humain » les simples acquittements (« LGTM », « 👍 », « merci »), les réponses de discussion sans contenu de review, ni le bruit de process (« rebase stp »). Concentre-toi sur les vrais points de review (bugs, risques, améliorations, questions techniques).

Renvoie **UNIQUEMENT** un objet JSON, rien d'autre (pas de ```fences```, pas de phrase autour) :

{
  "humanPoints": <nombre de vrais points de review humains retenus>,
  "caught": <combien de ces points sont couverts par (A)>,
  "missed": <combien NE sont PAS couverts par (A)>,
  "missedList": ["résumé court de chaque point humain manqué par (A)"],
  "extra": <nombre de constats de (A) qu'aucun humain n'a soulevés>,
  "summary": "1 à 2 phrases : forces/faiblesses de la review auto vs les humains"
}

Règles : `caught + missed == humanPoints`. Si (B) ne contient aucun vrai point de review, mets `humanPoints: 0`, `caught: 0`, `missed: 0`, `missedList: []`, et un `summary` qui le dit.
