TAFA V1.1.7.10 — SÉCURITÉ & PERMISSIONS

Base: V1.1.7.9 Pages & Groupes avancés.

Cette version ajoute uniquement des garde-fous frontend non destructifs:
- identification de l'utilisateur courant;
- vérification owner-only avant édition/suppression côté UI;
- vérification de membership pour les listes déjà chargées;
- helpers réutilisables pour les actions protégées.

IMPORTANT:
Le vrai contrôle de sécurité doit rester côté Supabase RLS / fonctions
SECURITY DEFINER. Aucun SQL n'a été inventé ici car le schéma complet des
policies et des fonctions n'a pas été fourni. Cette version ne désactive pas
RLS et ne modifie aucune table.

Les permissions frontend ne remplacent donc jamais les policies Supabase.
