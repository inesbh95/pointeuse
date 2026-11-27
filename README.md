# Pointeuse missions — application mobile Flutter + serveur Supabase

Pointage des employés en mission chez les clients. À l'arrivée sur le site, l'employé ouvre l'application, passe la vérification du visage, et le serveur enregistre sa **position exacte**, le **site client**, l'**heure du serveur** et un **verdict de fiabilité** : *Vérifié*, *À vérifier* ou *Refusé*.

## Comment la fiabilité est assurée

```
Téléphone (Flutter)                                Serveur (Supabase)
───────────────────                                ──────────────────
1. Demande un défi à usage unique  ───────────────▶ punch-challenge : crée un nonce (3 min)
2. En parallèle :
   • 4 relevés GPS (+ indicateur « position simulée » du système)
   • VPN actif ? options développeur ?  (code natif)
   • jeton Google Play Integrity lié au nonce
   • visage : clignement + rotation de tête (ordre aléatoire),
     photo, vecteur d'identité (MobileFaceNet)
3. Envoie les données BRUTES  ────────────────────▶ punch : refait TOUS les contrôles
                                                     • défi valide et non réutilisé
                                                     • IP réelle → VPN / proxy / Tor / pays
                                                     • Google confirme : appli officielle,
                                                       téléphone non rooté
                                                     • visage comparé aux gabarits enregistrés
                                                     • position : site client, figée, simulée,
                                                       précision, trajet impossible
                                                     • heure du serveur (celle du téléphone
                                                       est seulement comparée)
                                                   ◀── verdict + enregistrement (même refusé)
```

Le téléphone ne décide de rien : il ne peut ni écrire un pointage, ni modifier son statut (règles d'accès de la base). Un employé qui modifierait l'application serait détecté par Play Integrity.

| Fraude | Détection |
|---|---|
| VPN sur le téléphone | Interface VPN active (Android et iOS) + IP répertoriée + fuseau / pays incohérents |
| Application de fausse localisation | Indicateur système `isMocked` (Android ; iOS 15+) + options développeur + position figée |
| Téléphone rooté, émulateur, appli modifiée | Google Play Integrity (Android) |
| Pointer pour un collègue | Reconnaissance faciale côté serveur + photo archivée |
| Photo ou vidéo devant la caméra | Épreuves de présence aléatoires (clignement, rotation) |
| Rejouer un ancien pointage | Défi à usage unique de 3 minutes |
| Changer l'heure du téléphone | Heure du serveur utilisée ; écart signalé |

## Contenu

```
pointeuse-mobile/
├── setup.sh                      préparation du projet Flutter (une fois)
├── supabase/
│   ├── migrations/…_init.sql     tables, règles d'accès, stockage photos, vue des heures
│   ├── functions/
│   │   ├── punch-challenge/      défi à usage unique
│   │   ├── punch/                contrôles et enregistrement du pointage
│   │   ├── enroll-face/          enregistrement d'un visage (admin)
│   │   ├── create-employee/      création d'un compte (admin)
│   │   ├── _shared/checks.ts     règles de fiabilité (testées)
│   │   ├── _shared/services.ts   réputation IP, Play Integrity, adresse
│   │   └── tests/                12 tests des règles
│   └── .env.example              secrets du serveur
└── app/                          application Flutter
    ├── lib/screens/              connexion, pointage, historique, administration
    ├── lib/services/             API, GPS, visage, épreuves de présence, sécurité appareil
    ├── android/…/MainActivity.kt VPN, options développeur, Play Integrity
    ├── ios/Runner/AppDelegate.swift   VPN
    └── assets/models/            modèle MobileFaceNet (licence BSD-3)
```

## Installation

### 1. Serveur Supabase

1. Créez un projet sur [supabase.com](https://supabase.com) (région Europe, proche de la Tunisie).
2. Installez la CLI Supabase, puis depuis `pointeuse-mobile/` :
   ```bash
   supabase login
   supabase link --project-ref VOTRE_REF_PROJET
   supabase db push                      # crée les tables et règles
   cp supabase/.env.example supabase/.env   # complétez-le
   supabase secrets set --env-file supabase/.env
   supabase functions deploy punch-challenge punch enroll-face create-employee
   ```
3. **Premier administrateur** : dans Authentication › Users, créez votre compte (avec « Auto confirm »), puis dans SQL Editor :
   ```sql
   update profiles set role = 'admin'
   where id = (select id from auth.users where email = 'vous@entreprise.tn');
   ```
4. Les autres comptes se créent ensuite depuis l'application (Administration › Employés).

### 2. Application Flutter

Prérequis : Flutter 3.24 ou plus récent, Android Studio (et Xcode sur Mac pour iOS).

```bash
./setup.sh
# renseignez app/config.json : URL et clé « anon » (Project Settings › API)
cd app
flutter run --dart-define-from-file=config.json
```

Testez sur un **vrai téléphone** : l'émulateur n'a pas de caméra frontale fiable et sera signalé par les contrôles.

### 3. Google Play Integrity (Android, recommandé)

C'est ce qui prouve que l'application n'a pas été modifiée et que le téléphone n'est pas rooté.

1. Publiez l'application dans la Play Console (un **test interne** suffit) avec l'identifiant `com.pointeuse.pointeuse`.
2. Play Console › Intégrité de l'appli : associez un projet Google Cloud et activez l'API Play Integrity.
3. Google Cloud › IAM : créez un compte de service, téléchargez sa clé JSON, collez-la (sur une ligne) dans `GOOGLE_SERVICE_ACCOUNT_JSON`.
4. Mettez le numéro du projet Google Cloud dans `GOOGLE_CLOUD_PROJECT_NUMBER` (config.json).

**Pendant le développement**, laissez `GOOGLE_SERVICE_ACCOUNT_JSON` vide : une appli lancée avec `flutter run` n'est pas reconnue par Google Play et serait refusée. Les pointages sont alors marqués « intégrité non vérifiée » (à vérifier).

### 4. iOS

Sur un Mac, `setup.sh` ajoute les autorisations caméra et localisation et fixe iOS 15.5 minimum (exigé par ML Kit). Ensuite `cd ios && pod install`.

## Modules

Le pointage est toujours inclus. Les autres fonctions sont des **modules** que le super-admin
active par entreprise (administration web › Entreprises › icône *Modules*). Désactiver un module
masque ses écrans et bloque son accès côté serveur ; ses données sont conservées.

| Module | Rôle |
|---|---|
| `tickets` | L'admin crée des tickets dans le backoffice (tableau Kanban) et les assigne ; l'employé les traite dans l'app mobile (*Mes tickets* : démarrer, signaler un blocage, terminer, commenter, joindre des photos), l'admin valide. Import possible depuis Odoo ou un autre système par l'API (`POST /tickets`, voir `docs/API_ERP.md`). |

**Ajouter un module** : une ligne dans la table `modules`, des tables préfixées par le nom du module
dont chaque règle d'accès vérifie `has_module(company_id, '<module>')`, et ses écrans dans `lib/<module>/`
des deux applications, affichés seulement si `profile.hasModule('<module>')`. Les modules ne dépendent
que du cœur (profils, entreprises, absences), jamais les uns des autres.

Après mise à jour du serveur : `supabase db push` puis `supabase functions deploy api webhook-dispatch`.

## Réglages

Les règles se trouvent dans la table `settings` (Supabase › Table Editor). Pour chaque alerte : `block` refuse le pointage, `warn` l'enregistre « à vérifier ».

| Réglage | Par défaut | Rôle |
|---|---|---|
| `vpnPolicy` | block | VPN ou proxy |
| `mockPolicy` | block | Position simulée ou figée |
| `integrityPolicy` | block | Play Integrity négatif |
| `livenessPolicy` | block | Épreuves de présence échouées |
| `offSitePolicy` | warn | Aucun site client dans le rayon |
| `devModePolicy` | warn | Options développeur activées |
| `netUnknownPolicy` | warn | Service de réputation IP indisponible |
| `faceMinSimilarity` | 0.6 | Ressemblance minimale du visage (0,55 souple – 0,70 strict) |
| `maxAccuracy` | 100 | Précision GPS en mètres au-delà de laquelle on signale |
| `maxIpGpsKm` | 300 | Écart toléré entre la ville de l'IP et le GPS |
| `maxSpeedKmh` | 200 | Vitesse au-delà de laquelle un trajet est jugé impossible |

## Ce qui a été vérifié, et ce qui reste à faire

**Vérifié** :
- La migration s'exécute sur PostgreSQL, et les règles d'accès ont été testées : un employé ne voit que ses pointages, ne peut ni en créer ni changer un statut, et ne peut pas déposer de photo dans le dossier d'un autre. Le calcul des heures exclut les tentatives refusées.
- Les 12 tests des règles de fiabilité passent (`deno test supabase/functions/tests/`), et les fonctions serveur sont validées par le vérificateur de types.
- Le modèle de visage a été testé sur 22 visages : la ressemblance reste au moins à 0,60 pour une même personne et au plus à 0,59 entre deux personnes différentes.

**Non vérifié** : l'application Flutter n'a pas pu être compilée dans l'environnement où elle a été écrite. Attendez-vous à quelques corrections lors du premier `flutter run`, notamment si des versions de paquets plus récentes ont changé leur API (`flutter pub outdated` aide à les repérer).

**À compléter avant la production** :
- **iOS App Attest** : l'équivalent iOS de Play Integrity n'est pas branché. Les pointages iPhone sont marqués « intégrité non vérifiée ». Si vos employés ont des iPhone, c'est la prochaine étape.
- **Clé ipapi.is** payante : l'offre gratuite est limitée en nombre de requêtes par jour.
- **Données personnelles** (loi organique n° 2004-63, INPDP) : déclarez le traitement de données biométriques et de localisation, informez les employés et recueillez leur consentement. La position n'est relevée qu'au moment du pointage, jamais en continu.
- **Mode hors connexion** : un pointage exige internet, puisque le serveur fait les contrôles. Une file d'attente locale peut être ajoutée, mais ces pointages seront moins fiables.
