# Pointeuse sur iPhone — mode d'emploi

Le code iPhone est prêt. Il reste les étapes ci-dessous, qui demandent **votre** compte Apple.
Aucun Mac n'est nécessaire : l'app est compilée sur un Mac en ligne (Codemagic).

## Ce qui est déjà fait dans le code

| Élément | Où |
|---|---|
| Vérification Apple **App Attest** (équivalent de Play Integrity) : prouve que le pointage vient de la vraie app, sur un vrai iPhone | `app/ios/Runner/AppDelegate.swift`, serveur `supabase/functions/_shared/appattest.ts` |
| Détection du VPN | `AppDelegate.swift` |
| Rappels de pointage (notifications locales, max 56 programmées : sous la limite iOS de 64) | `reminder_service.dart` + `AppDelegate.swift` |
| Autorisations caméra et position, langue française, déclaration de chiffrement | `app/ios/Runner/Info.plist` |
| Droit App Attest (environnement production) | `app/ios/Runner/Runner.entitlements` |
| Compilation + envoi sur TestFlight | `codemagic.yaml` |

Sans la variable serveur `IOS_APP_ID` (étape 6), les pointages iPhone fonctionnent mais sont
marqués **« intégrité non vérifiée »** (à vérifier par l'admin).

## Étapes (une seule fois)

### 1. Compte Apple Developer — 99 $/an
- developer.apple.com › *Account* › *Join the Apple Developer Program*.
- **Entreprise** (recommandé) : demandez d'abord un numéro **D-U-N-S** (gratuit, 1 à 2 semaines).
- Notez votre **Team ID** (10 caractères, *Membership details*).

### 2. Identifiant de l'app
- *Certificates, Identifiers & Profiles › Identifiers › +* › *App IDs* › *App*.
- Bundle ID **explicite** : `com.pointeuse.pointeuse` (ou un autre, à reporter partout).
- Cochez la capacité **App Attest**.

### 3. Fiche dans App Store Connect
- appstoreconnect.apple.com › *Apps* › *+ Nouvelle app* : nom « Pointeuse », langue français,
  Bundle ID de l'étape 2.
- Notez l'**Apple ID** numérique de l'app (*Informations sur l'app*) → `APP_STORE_APPLE_ID`.

### 4. Clé API pour Codemagic
- App Store Connect › *Utilisateurs et accès › Intégrations › Clés API* › *+*, rôle **App Manager**.
- Téléchargez le fichier `.p8` (une seule fois) et notez *Issuer ID* et *Key ID*.

### 5. Codemagic (gratuit)
1. Le code doit être sur **GitHub, GitLab ou Bitbucket** (dépôt **privé**). Ne jamais y mettre
   `config.json`, les fichiers `.p8` ni de clés : `.gitignore` les exclut déjà pour `config.json`.
2. codemagic.io › connectez le dépôt.
3. *Teams › Integrations › Developer Portal* : ajoutez la clé API de l'étape 4 sous le nom **`pointeuse-asc`**.
4. *Environment variables*, groupe **`pointeuse`** : `SUPABASE_URL`, `SUPABASE_ANON_KEY`
   (valeurs de `app/config.json`), `APP_STORE_APPLE_ID`.
5. *Code signing identities* : laissez Codemagic créer le certificat de distribution et le profil
   App Store pour `com.pointeuse.pointeuse`.

### 6. Activer App Attest sur le serveur
Avec votre Team ID (ex. `AB12CD34EF`) :
```
supabase secrets set IOS_APP_ID=AB12CD34EF.com.pointeuse.pointeuse
```
(ou demandez-le à Claude, en lui donnant le Team ID — ce n'est pas un secret).

### 7. Compiler et tester
- Créez un tag Git commençant par `ios-` (ex. `ios-1.0.0`) et poussez-le : Codemagic compile
  (≈ 15 min) et envoie l'app sur **TestFlight**.
- App Store Connect › *TestFlight* : ajoutez-vous comme testeur interne, installez **TestFlight**
  sur l'iPhone, puis l'app.

### À vérifier sur l'iPhone (premier test)
1. Connexion, enrôlement du visage par l'admin, pointage d'arrivée.
2. Le pointage ne doit **pas** porter « intégrité non vérifiée » (sinon : étape 6, ou capacité App Attest
   absente du profil).
3. Deuxième pointage : toujours sans avertissement (assertion App Attest).
4. Réglages › rappels : la notification arrive à l'heure.
5. Export Excel : « Enregistrer » ouvre l'app Fichiers.

## Ensuite : distribution
- **TestFlight** : jusqu'à 100 testeurs internes (membres de votre équipe Apple), 10 000 externes après
  une vérification rapide d'Apple. Chaque version de test expire après 90 jours.
- **App privée** (Apple Business Manager) : l'app n'est visible que des entreprises clientes choisies.
- **App Store** public : validation Apple (quelques jours), fiche avec captures d'écran et
  politique de confidentialité (photo du visage, position).
