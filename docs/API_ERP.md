# API Pointeuse pour les ERP — v1

API REST **en lecture seule** qui permet à un ERP ou à un logiciel de paie de récupérer
les employés, les pointages et les feuilles de temps d'**une** entreprise.

- **Adresse de base** : `https://phckoqgkdmruyfifkeat.supabase.co/functions/v1/api/v1`
- **Format** : JSON (UTF-8), méthode `GET` uniquement
- **Accès** : une clé d'API par entreprise, créée par l'administrateur de l'entreprise dans
  *Administration › Réglages › API pour les ERP* (app mobile ou https://pointeuse-da5ec.web.app)

---

## 1. Authentification

Chaque requête doit contenir la clé :

```
Authorization: Bearer ptk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

(ou l'en-tête `X-API-Key: ptk_…`).

- La clé donne accès **uniquement** aux données de l'entreprise qui l'a créée.
- Elle n'est affichée qu'une fois, à sa création : conservez-la dans un coffre à secrets,
  jamais dans le code source ni dans une application mobile ou une page web publique.
- L'administrateur peut la **révoquer** à tout moment : elle cesse de fonctionner immédiatement.

## 2. Dates et fuseau horaire

- Les paramètres `from` et `to` sont des **jours inclus** au format `AAAA-MM-JJ`,
  interprétés dans le **fuseau horaire de l'entreprise** (ex. `Africa/Tunis`).
- Période maximale : **366 jours** par requête.
- Les horodatages (`timestamp`, `first_in`, `last_out`) sont en **UTC, ISO 8601**.
  Les champs `local_date`, `local_time`, `first_in_local`, `last_out_local` donnent l'heure locale de l'entreprise.

## 3. Ressources

### `GET /company` — entreprise et horaires

```bash
curl -H "Authorization: Bearer $CLE" https://phckoqgkdmruyfifkeat.supabase.co/functions/v1/api/v1/company
```

```json
{
  "data": {
    "id": "…", "name": "CSI", "timezone": "Africa/Tunis", "sites_enabled": false,
    "schedule": { "start": "08:00", "end": "17:00", "days": [1,2,3,4,5], "late_tolerance_min": 5 }
  }
}
```

`days` : jours travaillés, 1 = lundi … 7 = dimanche. Utile aussi pour **tester une clé**.

### `GET /employees` — employés

```json
{
  "data": [
    { "id": "…", "matricule": "M001", "full_name": "Ali Ben Salah", "role": "employee",
      "active": true, "face_enrolled": true, "created_at": "2026-11-21T10:12:00Z" }
  ]
}
```

Le **`matricule`** est la clé de rapprochement avec la fiche employé de l'ERP.
`role` : `employee` ou `admin`.

### `GET /timesheets?from=…&to=…` — feuilles de temps (recommandé pour la paie)

Une ligne par **employé et par jour** : jours travaillés (avec ou sans pointage) et jours non
travaillés où l'employé a pointé.

```bash
curl -H "Authorization: Bearer $CLE" \
  "https://phckoqgkdmruyfifkeat.supabase.co/functions/v1/api/v1/timesheets?from=2026-11-01&to=2026-11-30"
```

```json
{
  "data": [
    { "date": "2026-11-17", "employee_id": "…", "matricule": "M001", "full_name": "Ali Ben Salah",
      "first_in": "2026-11-17T07:20:00Z", "last_out": "2026-11-17T16:00:00Z",
      "first_in_local": "08:20", "last_out_local": "17:00",
      "worked_min": 520, "expected_min": 540, "late_min": 20, "overtime_min": 0,
      "punches": 2, "status": "complet", "absence": null, "manual_punches": 0 }
  ]
}
```

| Champ | Signification |
|---|---|
| `worked_min` | minutes travaillées = somme des paires entrée → sortie (pauses pointées déduites) |
| `expected_min` | minutes prévues ce jour (0 si jour non travaillé) |
| `late_min` | retard en minutes, compté seulement au-delà de la tolérance |
| `overtime_min` | minutes au-delà de la journée prévue (tout le temps travaillé si jour non travaillé) |
| `status` | `complet`, `absent` (jour travaillé sans pointage ni absence déclarée), `justifie` (absence justifiée, voir `absence`), `sortie_manquante`, `entree_manquante`, `en_cours` (aujourd'hui, pas encore sorti) |
| `absence` | absence déclarée par l'administrateur ce jour-là : `conge_paye`, `maladie`, `sans_solde`, `mission`, `ferie`, `autre` ; sinon `null`. Un jour `ferie` n'est pas travaillé (`expected_min` = 0). |
| `manual_punches` | nombre de pointages de ce jour saisis à la main par l'administrateur (oubli de pointage) |

Pointages pris en compte : acceptés et « à vérifier » ; un pointage refusé ne compte que s'il a été
**validé** par l'administrateur ; un pointage **rejeté** ne compte jamais.

### `GET /absences?from=…&to=…` — absences justifiées et jours fériés

Absences qui touchent la période (même partiellement).

```json
{
  "data": [
    { "id": "…", "scope": "employee", "employee_id": "…", "matricule": "M001", "full_name": "Ali Ben Salah",
      "kind": "conge_paye", "start_date": "2026-11-17", "end_date": "2026-11-19", "note": null, "created_at": "…" },
    { "id": "…", "scope": "company", "employee_id": null, "matricule": null, "full_name": null,
      "kind": "ferie", "start_date": "2026-12-25", "end_date": "2026-12-25", "note": "Noël", "created_at": "…" }
  ]
}
```

`scope` : `employee` (un employé) ou `company` (toute l'entreprise, ex. jour férié).
`kind` : `conge_paye`, `maladie`, `sans_solde`, `mission`, `ferie`, `autre`.

### `GET /punches?from=…&to=…[&limit=500][&cursor=…]` — pointages bruts

```json
{
  "data": [
    { "id": "…", "employee_id": "…", "matricule": "M001", "full_name": "Ali Ben Salah",
      "type": "in", "timestamp": "2026-11-17T07:20:00Z", "local_date": "2026-11-17", "local_time": "08:20:00",
      "status": "ok", "review": null, "counted": true, "manual": false, "manual_reason": null,
      "site": { "client": "Client X", "name": "Entrepôt Nord" }, "site_distance_m": 35,
      "address": "Rue …, Sfax", "latitude": 34.83, "longitude": 10.75, "accuracy_m": 12 }
  ],
  "next_cursor": "MjAyNi0xMS0xN1Qw…"
}
```

| Champ | Valeurs |
|---|---|
| `type` | `in` (arrivée) / `out` (départ) |
| `status` | `ok` (accepté), `suspect` (à vérifier), `blocked` (refusé) |
| `review` | décision de l'admin : `approved`, `rejected` ou `null` |
| `counted` | `true` si le pointage compte dans les feuilles de temps |
| `manual` | `true` si le pointage a été **saisi par l'administrateur** (oubli), avec son motif dans `manual_reason` ; pas de position GPS dans ce cas |
| `site` | site client rattaché (si l'entreprise utilise les sites), sinon `null` |
| `site_distance_m` | distance en mètres au site le plus proche (hors site si `site` est `null`) ; `null` sans gestion des sites |

**Pagination** : `limit` de 1 à 1000 (500 par défaut). Tant que `next_cursor` n'est pas `null`,
rappelez la même URL avec `&cursor=<next_cursor>`.

Aucune photo, adresse IP ni information sur l'appareil n'est exposée par l'API.

## 4. Erreurs

```json
{ "error": { "code": "auth", "message": "Clé d'API invalide ou révoquée." } }
```

| HTTP | `code` | Cause |
|---|---|---|
| 400 | `period`, `cursor` | paramètres `from`/`to` absents ou invalides, période > 366 jours, curseur invalide |
| 401 | `auth` | clé absente, invalide ou révoquée |
| 403 | `company` | entreprise désactivée |
| 404 | `not_found` | ressource inconnue |
| 405 | `method` | méthode autre que `GET` |
| 500 | `server` | erreur interne : réessayer plus tard |

## 5. Bonnes pratiques d'intégration

- **Paie mensuelle** : appeler `/timesheets` sur le mois, et rapprocher par `matricule`.
- **Synchronisation quotidienne** : appeler `/punches` sur la veille (et l'avant-veille, pour
  récupérer les décisions de l'administrateur prises entre-temps). Le champ `id` permet d'éviter les doublons.
- Les données d'une journée peuvent encore changer tant que l'administrateur vérifie les pointages :
  **re-synchronisez les 2 à 3 derniers jours**.
- Ne pas dépasser **une requête par seconde** environ.

## 6. Webhooks : être prévenu en temps réel

Au lieu d'interroger l'API régulièrement, l'ERP peut recevoir un appel **à chaque pointage**.
L'administrateur ajoute l'adresse de l'ERP dans *Réglages › Webhooks › Nouveau webhook*
(5 adresses au maximum, `https://` obligatoire). Un **secret de signature** (`whsec_…`) est alors
affiché **une seule fois** : transmettez-le au développeur de l'ERP.

### Événements

| `event` | Quand |
|---|---|
| `punch.created` | un employé vient de pointer (y compris un pointage refusé : voir `status` et `counted`) |
| `punch.reviewed` | l'administrateur a validé ou rejeté un pointage (`review`) |
| `absence.created` | l'administrateur a déclaré une absence (congé, maladie, mission…) ou un jour férié |
| `absence.deleted` | l'administrateur a supprimé une absence (`data` décrit l'absence supprimée) |
| `employee.created` | nouvel employé (ou employé rattaché à l'entreprise) |
| `employee.updated` | nom, matricule, rôle ou activation modifiés ; `data.changes` liste les champs modifiés |
| `ping` | bouton « Envoyer un test » dans Réglages |

### Requête reçue par l'ERP

```
POST https://erp.client.tn/pointeuse/webhook
Content-Type: application/json
X-Pointeuse-Event: punch.created
X-Pointeuse-Delivery: 4f6c…            identifiant de l'envoi (le même à chaque relance)
X-Pointeuse-Timestamp: 1795430400      secondes Unix
X-Pointeuse-Signature: sha256=9a1e…
```

```json
{
  "id": "4f6c…", "event": "punch.created", "created_at": "2026-11-23T07:58:12Z",
  "company": { "id": "…", "name": "CSI" },
  "data": { …même format qu'un élément de GET /punches… }
}
```

Contenu de `data` selon l'événement :

| Événement | `data` |
|---|---|
| `punch.*` | un pointage, même format que `GET /punches` |
| `absence.*` | une absence, même format que `GET /absences` |
| `employee.*` | un employé, même format que `GET /employees` (+ `changes` pour `employee.updated`) |

```json
{ "event": "absence.created", "data": {
    "id": "…", "scope": "employee", "employee_id": "…", "matricule": "M001", "full_name": "Ali Ben Salah",
    "kind": "maladie", "start_date": "2026-11-23", "end_date": "2026-11-24", "note": "certificat reçu" } }

{ "event": "employee.updated", "data": {
    "id": "…", "matricule": "M002", "full_name": "Ali Ben Salah", "role": "employee", "active": true,
    "created_at": "…", "face_enrolled": true, "changes": ["matricule"] } }
```

### Ce que l'ERP doit faire

1. **Vérifier la signature** : `HMAC-SHA256(secret, "<X-Pointeuse-Timestamp>.<corps brut>")` en hexadécimal
   doit être égal à la valeur après `sha256=`. Refuser aussi un horodatage vieux de plus de 5 minutes.
2. **Répondre vite** (moins de 10 s) avec un code **2xx**, puis traiter le pointage en arrière-plan.
3. **Ignorer les doublons** grâce à `X-Pointeuse-Delivery` (ou `data.id` + `event`).

Tout autre code, ou pas de réponse en 10 s, déclenche une **relance** : après 1, 5, 15 min, 1 h, 3 h, 6 h
et 12 h (8 tentatives, environ 24 h). L'état du dernier appel est affiché dans Réglages.
En cas de panne prolongée, rattrapez les données avec `GET /punches`, `GET /absences` et `GET /employees`.

```python
import hmac, hashlib, time

def verifier(secret: str, headers, corps_brut: bytes) -> bool:
    ts = headers["X-Pointeuse-Timestamp"]
    if abs(time.time() - int(ts)) > 300:
        return False
    attendu = hmac.new(secret.encode(), f"{ts}.".encode() + corps_brut, hashlib.sha256).hexdigest()
    return hmac.compare_digest("sha256=" + attendu, headers["X-Pointeuse-Signature"])
```

```php
$ts = $_SERVER['HTTP_X_POINTEUSE_TIMESTAMP'];
$corps = file_get_contents('php://input');
$ok = abs(time() - (int)$ts) <= 300 && hash_equals(
  'sha256=' . hash_hmac('sha256', $ts . '.' . $corps, $secret), $_SERVER['HTTP_X_POINTEUSE_SIGNATURE']);
```

## 7. Exemple (Python)

```python
import os, requests

BASE = "https://phckoqgkdmruyfifkeat.supabase.co/functions/v1/api/v1"
H = {"Authorization": f"Bearer {os.environ['POINTEUSE_API_KEY']}"}

def punches(day_from, day_to):
    params, out = {"from": day_from, "to": day_to, "limit": 1000}, []
    while True:
        r = requests.get(f"{BASE}/punches", headers=H, params=params, timeout=30)
        r.raise_for_status()
        body = r.json()
        out += body["data"]
        if not body["next_cursor"]:
            return out
        params["cursor"] = body["next_cursor"]

sheet = requests.get(f"{BASE}/timesheets", headers=H,
                     params={"from": "2026-11-01", "to": "2026-11-30"}, timeout=60).json()["data"]
```
