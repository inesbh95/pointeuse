# Vidéo de démonstration (≈ 1 min 45) et captures d'écran

Prérequis : avoir exécuté `demo/seed_demo.sql` (compte « BatiNova Services (démo) »), et enrôlé
**votre propre visage** sur un compte employé, par exemple Sami Ben Salah (`sami.demo@example.com`),
pour pouvoir pointer en direct.

## Matériel

- **Téléphone** : enregistrement d'écran intégré (Android : volet rapide › « Enregistreur d'écran » ;
  iPhone : Centre de contrôle › Enregistrement de l'écran). Mode Ne pas déranger, batterie et heure propres.
- **PC** : `Win + Alt + R` (Xbox Game Bar) ou Clipchamp (inclus dans Windows 11) pour enregistrer
  l'administration web en plein écran, navigateur en 1920 × 1080, zoom 110 %.
- **Montage** : Clipchamp. Ajoutez la voix off (ou les sous-titres), une musique douce, et
  le logo en fin de vidéo. Export 1080p.

## Script

| # | Durée | À l'écran | Voix off / sous-titre |
|---|---|---|---|
| 1 | 0:00–0:08 | Titre sur fond vert foncé : « Pointeuse — le pointage mobile sans fraude » | « Vos équipes travaillent chez vos clients. Comment savoir qui est vraiment arrivé, et à quelle heure ? » |
| 2 | 0:08–0:20 | Téléphone : l'employé (Sami) ouvre l'appli, écran « Mon pointage », appuie sur **Pointer mon arrivée** | « Avec Pointeuse, l'employé pointe depuis son téléphone, en arrivant sur le site du client. » |
| 3 | 0:20–0:35 | Écran « Vérification du visage » : clignement, rotation de la tête | « Il prouve que c'est bien lui : reconnaissance du visage, avec un clignement et un mouvement de tête demandés au hasard. Une photo ne suffit pas. » |
| 4 | 0:35–0:45 | Résultat **Vérifié** avec le nom du site client et l'heure | « Le serveur vérifie tout : la position GPS, le site du client, le réseau, le téléphone et l'heure. Le téléphone, lui, ne décide de rien. » |
| 5 | 0:45–0:58 | Admin web, onglet des pointages refusés : position simulée, visage non reconnu, VPN | « Fausse localisation, VPN, pointage pour un collègue, heure modifiée : les tentatives sont refusées et archivées. » |
| 6 | 0:58–1:10 | Pointage « À vérifier » (hors site) › Détails › **Valider** avec une note | « Les cas douteux arrivent chez le responsable, qui valide ou rejette en un clic. » |
| 7 | 1:10–1:25 | Feuille de temps de la semaine : retards, heures sup, absences ; clic sur **Export Excel** | « En fin de mois, la feuille de temps est prête : heures travaillées, retards, heures supplémentaires, absences. Export Excel, ou directement vers votre ERP. » |
| 8 | 1:25–1:35 | Sites clients sur la carte, avec leur rayon ; horaires et tolérance de retard | « Vous placez vos sites clients sur la carte, vous fixez vos horaires, et c'est parti. » |
| 9 | 1:35–1:45 | Écran de fin : « Essai gratuit 30 jours » + votre contact | « Pointeuse : aucun matériel, mise en route en une journée. Essayez gratuitement pendant 30 jours. » |

Astuce : pour la scène 5, ne faites pas de vraie fraude en direct, les données de démo contiennent déjà
des tentatives refusées (Youssef Gharbi, Karim Mansouri, Walid Ayari).

## Captures d'écran à faire (12)

Nommez-les dans cet ordre dans `commercial/captures/`.

**Téléphone (compte employé)**
1. `01_connexion.png` — écran de connexion
2. `02_accueil.png` — « Mon pointage » avec le bouton « Pointer mon arrivée »
3. `03_visage.png` — vérification du visage (cercle, consigne « Clignez des yeux »)
4. `04_verifie.png` — résultat « Vérifié » avec le site client
5. `05_historique.png` — « Mes pointages »

**Administration web (`demo.admin@example.com`)**
6. `06_presences.png` — pointages du jour (arrivées en cours)
7. `07_a_verifier.png` — liste « À vérifier » avec un pointage hors site ouvert
8. `08_refuses.png` — onglet « Refusés » (position simulée, visage non reconnu, VPN)
9. `09_feuille_de_temps.png` — feuille de temps de la semaine (retards, heures sup)
10. `10_export_excel.png` — le fichier Excel ouvert
11. `11_sites.png` — sites clients sur la carte
12. `12_horaires.png` — horaires, tolérance de retard et rappels

Les captures de l'administration web peuvent être faites automatiquement une fois la démo installée
et la session ouverte dans le navigateur (voir README).
