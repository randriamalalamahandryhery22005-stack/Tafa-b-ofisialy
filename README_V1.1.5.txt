TAFAß V1.1.5 — RÉPONSES AUX COMMENTAIRES

Ajouts:
- Répondre à un commentaire
- Afficher/masquer les réponses
- Réponses imbriquées
- Modifier/supprimer ses réponses
- Like/unlike des réponses via comment_likes
- Validation SQL: une réponse doit appartenir au même post
- Notification serveur de réponse à l'auteur du commentaire parent
- Realtime comments déjà présent dans l'application

À exécuter dans Supabase SQL Editor:
1) COMMENTS_V1.1.4.sql si ce n'est pas déjà fait
2) COMMENTS_V1.1.5.sql


FIX V1.1.5.1: Si Supabase affiche "null value in column content", exécutez COMMENTS_V1.1.5.sql. Le frontend utilise désormais la colonne content pour créer/modifier les commentaires et réponses.
