# Kit commercial Pointeuse

| Pièce | Fichier | État |
|---|---|---|
| PDF de présentation (2 pages) | `Pointeuse_Presentation.pdf` | Prêt — remplacer `[Votre nom]`, `[Téléphone]`, `[E-mail]`, `[Site web]` |
| Offre commerciale avec prix | `Pointeuse_Offre_commerciale.pdf` | Prêt — idem + `[Votre société]`, `[Matricule fiscal]` |
| Compte de démonstration | `demo/seed_demo.sql` | À exécuter dans Supabase › SQL Editor |
| Vidéo 1–2 min | `Video_script_et_captures.md` | Script prêt, à tourner (téléphone + PC) |
| Captures d'écran | `captures/` | Après installation de la démo |

## Modifier les PDF

Les sources sont dans `src/` (`presentation.html`, `offre.html`, `style.css`). Après modification,
régénérez le PDF avec Edge :

```powershell
& "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --headless=new --no-pdf-header-footer --print-to-pdf="$PWD\Pointeuse_Presentation.pdf" "file:///$($PWD -replace '\\','/')/src/presentation.html"
```

(ou ouvrez le HTML dans Edge › Imprimer › Enregistrer au format PDF, marges « Aucune », sans en-têtes.)

## Compte de démonstration

Entreprise fictive **BatiNova Services (démo)** : 1 administratrice, 10 employés, 3 sites clients
(Lac 2, Ariana, Sfax), ~3 semaines de pointages réalistes (retards, heures sup, absences,
pointages à vérifier et refusés). Identifiants et mot de passe en tête de `demo/seed_demo.sql`.

- Le script est ré-exécutable : relancez-le la veille d'un rendez-vous pour avoir des données à jour.
- Il ne touche qu'à cette entreprise.
- Aucun visage n'est enrôlé : enrôlez le vôtre sur un compte employé pour pointer en direct.
- Ne donnez pas le compte admin de démo à un prospect pour qu'il le garde : créez-lui plutôt
  une entreprise d'essai.

## Prix proposés (à ajuster)

Essentiel 9 DT, Pro 14 DT, Entreprise 19 DT HT par employé et par mois ; mise en service 490 DT HT
(offerte en annuel) ; 2 mois offerts en annuel ; essai 30 jours. Ce sont des propositions de départ :
comparez avec les offres locales que vos prospects connaissent avant de les envoyer.

## Points à ne pas promettre (encore)

- **iPhone** : le pointage fonctionne, mais la vérification d'intégrité du téléphone (équivalent de
  Play Integrity) n'est pas encore branchée ; les pointages iPhone sont marqués « intégrité non vérifiée ».
- **Hors connexion** : un pointage exige internet.
- **INPDP** : la déclaration du traitement biométrique reste à la charge du client ; l'offre propose
  un accompagnement, pas une prise en charge.
