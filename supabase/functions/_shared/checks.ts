// Règles de fiabilité d'un pointage. Fonction pure : testable sans réseau ni base de données.
// Chaque contrôle produit un signal ; la règle de l'administrateur décide s'il bloque ou s'il
// marque le pointage « à vérifier ».

export type Policy = 'block' | 'warn';
export type Level = 'block' | 'warn';
export interface Flag { code: string; level: Level; label: string }

export interface Rules {
  vpnPolicy: Policy; offSitePolicy: Policy; mockPolicy: Policy; integrityPolicy: Policy;
  devModePolicy: Policy; netUnknownPolicy: Policy; livenessPolicy: Policy;
  maxAccuracy: number; maxIpGpsKm: number; maxSpeedKmh: number; maxClockDriftSec: number;
  faceMinSimilarity: number;
}

export interface Fix { lat: number; lng: number; acc: number; ts: number; mocked?: boolean }
export interface Site { id: string; client: string; name: string; lat: number; lng: number; radius_m: number }
export interface IpInfo {
  error?: string; ip?: string; vpn?: boolean; proxy?: boolean; tor?: boolean; datacenter?: boolean;
  vpnService?: string | null; operator?: string | null; country?: string | null; city?: string | null;
  lat?: number | null; lng?: number | null; tz?: string | null;
}
export interface Integrity { verdict: 'ok' | 'fail' | 'unverified'; reasons: string[] }
export interface DeviceInfo {
  platform: 'android' | 'ios'; vpnActive?: boolean | null; devMode?: boolean | null; tz?: string | null;
}
export interface Previous { lat: number; lng: number; ts: number }

export interface Input {
  fixes: Fix[]; device: DeviceInfo; ip: IpInfo; integrity: Integrity;
  face: { similarity: number | null; templates: number };
  liveness: { passed: boolean; steps?: string[] };
  sites: Site[] | null; // null : application sans sites clients, pas de contrôle « hors site »
  rules: Rules; previous?: Previous | null;
  now: number; deviceTs?: number | null;
}

export interface Verdict {
  status: 'ok' | 'suspect' | 'blocked'; flags: Flag[];
  best: Fix | null; site: Site | null; siteDistance: number | null; spreadM: number | null;
}

export const DEFAULT_RULES: Rules = {
  vpnPolicy: 'block', offSitePolicy: 'warn', mockPolicy: 'block', integrityPolicy: 'block',
  devModePolicy: 'warn', netUnknownPolicy: 'warn', livenessPolicy: 'block',
  maxAccuracy: 100, maxIpGpsKm: 300, maxSpeedKmh: 200, maxClockDriftSec: 180, faceMinSimilarity: 0.6,
};

export function distanceM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000, r = Math.PI / 180;
  const dLat = (lat2 - lat1) * r, dLng = (lng2 - lng1) * r;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

export function evaluate(i: Input): Verdict {
  const flags: Flag[] = [];
  const r = { ...DEFAULT_RULES, ...i.rules };
  const add = (code: string, level: Level, label: string) => flags.push({ code, level, label });
  const lvl = (p: Policy): Level => (p === 'block' ? 'block' : 'warn');

  // 1. Identité
  if (i.face.templates === 0) add('no_template', 'block', "Visage non enrôlé : demandez à l'administrateur d'enregistrer votre visage.");
  else if (i.face.similarity == null || i.face.similarity < r.faceMinSimilarity) {
    const pct = i.face.similarity == null ? '?' : Math.round(i.face.similarity * 100);
    add('face_mismatch', 'block', `Visage non reconnu (ressemblance ${pct} %, minimum ${Math.round(r.faceMinSimilarity * 100)} %).`);
  }
  if (!i.liveness.passed) add('liveness', lvl(r.livenessPolicy), 'Test de présence (clignement / mouvement de tête) non réussi.');

  // 2. Intégrité de l'appareil et de l'application
  if (i.integrity.verdict === 'fail') add('integrity', lvl(r.integrityPolicy), `Appareil ou application non fiable : ${i.integrity.reasons.join(', ') || 'verdict négatif'}.`);
  else if (i.integrity.verdict === 'unverified') add('integrity_unverified', 'warn', `Intégrité de l'appareil non vérifiée${i.integrity.reasons.length ? ' (' + i.integrity.reasons.join(', ') + ')' : ''}.`);
  if (i.device.devMode) add('dev_mode', lvl(r.devModePolicy), 'Options pour les développeurs activées sur le téléphone (permettent la fausse localisation).');

  // 3. Position
  const fixes = (i.fixes || []).filter((f) => Number.isFinite(f.lat) && Number.isFinite(f.lng) && Math.abs(f.lat) <= 90 && Math.abs(f.lng) <= 180);
  let best: Fix | null = null, site: Site | null = null, siteDistance: number | null = null, spreadM: number | null = null;
  if (!fixes.length) {
    add('no_gps', 'block', 'Position GPS absente.');
  } else {
    best = fixes.reduce((a, b) => (b.acc < a.acc ? b : a));
    spreadM = 0;
    for (const a of fixes) for (const b of fixes) spreadM = Math.max(spreadM, distanceM(a.lat, a.lng, b.lat, b.lng));
    spreadM = Math.round(spreadM * 10) / 10;

    if (fixes.some((f) => f.mocked)) add('mock_location', lvl(r.mockPolicy), 'Position simulée signalée par le téléphone (application de fausse localisation).');
    if (fixes.length >= 3 && fixes.every((f) => f.lat === fixes[0].lat && f.lng === fixes[0].lng && f.acc === fixes[0].acc)) {
      add('frozen_gps', lvl(r.mockPolicy), 'Position figée : relevés GPS strictement identiques.');
    }
    if (best.acc > r.maxAccuracy) add('low_accuracy', 'warn', `Précision GPS faible (± ${Math.round(best.acc)} m).`);
    if (best.acc < 1.5) add('perfect_gps', 'warn', `Précision irréaliste (± ${best.acc} m).`);
    const age = (i.now - best.ts) / 1000;
    if (age > 120) add('stale_gps', 'warn', `Position ancienne (${Math.round(age / 60)} min).`);
    if (age < -120) add('future_gps', 'warn', 'Horodatage GPS dans le futur (horloge du téléphone modifiée ?).');

    if (i.sites) {
      let nearest: { s: Site; d: number } | null = null;
      for (const s of i.sites) {
        const d = distanceM(best.lat, best.lng, s.lat, s.lng);
        if (!nearest || d < nearest.d) nearest = { s, d };
      }
      if (nearest) { siteDistance = Math.round(nearest.d); if (nearest.d <= nearest.s.radius_m) site = nearest.s; }
      if (!site) {
        const where = nearest ? `${siteDistance} m de « ${nearest.s.client} — ${nearest.s.name} »` : 'aucun site client enregistré';
        add('off_site', lvl(r.offSitePolicy), `Hors site client (${where}).`);
      }
    }

    if (i.previous) {
      const d = distanceM(i.previous.lat, i.previous.lng, best.lat, best.lng);
      const h = (i.now - i.previous.ts) / 3600000;
      const kmh = h > 0 ? d / 1000 / h : Infinity;
      if (d > 2000 && kmh > r.maxSpeedKmh) add('impossible_travel', 'warn', `Trajet impossible : ${Math.round(d / 1000)} km depuis le dernier pointage (${Math.round(kmh)} km/h).`);
    }
  }

  // 4. Réseau
  if (i.device.vpnActive) add('vpn_device', lvl(r.vpnPolicy), 'VPN actif sur le téléphone.');
  if (i.ip.error) {
    add('net_unknown', lvl(r.netUnknownPolicy), 'Réseau non vérifié (service de réputation IP indisponible).');
  } else {
    if (i.ip.tor) add('tor', 'block', 'Connexion via le réseau Tor.');
    if (i.ip.vpn && !i.device.vpnActive) add('vpn', lvl(r.vpnPolicy), `VPN détecté par l'adresse IP${i.ip.vpnService ? ' (' + i.ip.vpnService + ')' : ''}.`);
    if (i.ip.proxy) add('proxy', lvl(r.vpnPolicy), 'Proxy détecté.');
    if (i.ip.datacenter && !i.ip.vpn) add('datacenter', 'warn', `Adresse IP d'hébergeur (${i.ip.operator || 'inconnu'}) : VPN non répertorié possible.`);
    if (best && i.ip.lat != null && i.ip.lng != null) {
      const km = distanceM(best.lat, best.lng, i.ip.lat, i.ip.lng) / 1000;
      if (km > r.maxIpGpsKm) add('ip_far', 'warn', `L'adresse IP situe l'appareil à ${Math.round(km)} km de la position GPS (${i.ip.city || i.ip.country || '?'}).`);
    }
    if (i.ip.tz && i.device.tz && i.ip.tz !== i.device.tz) add('tz_mismatch', 'warn', `Fuseau du téléphone (${i.device.tz}) différent de celui du réseau (${i.ip.tz}).`);
  }

  // 5. Horloge du téléphone (l'heure enregistrée est toujours celle du serveur)
  if (i.deviceTs != null) {
    const drift = (i.deviceTs - i.now) / 1000;
    if (Math.abs(drift) > r.maxClockDriftSec) add('clock', 'warn', `Heure du téléphone décalée de ${Math.round(drift / 60)} min.`);
  }

  const status = flags.some((f) => f.level === 'block') ? 'blocked' : flags.length ? 'suspect' : 'ok';
  return { status, flags, best, site, siteDistance, spreadM };
}

/* Similarité cosinus maximale entre un vecteur et des gabarits (tous normalisés ou non). */
export function bestSimilarity(embedding: number[], templates: number[][]): number | null {
  const norm = (v: number[]) => Math.sqrt(v.reduce((s, x) => s + x * x, 0));
  const ne = norm(embedding);
  if (!ne || !templates.length) return null;
  let best = -Infinity;
  for (const t of templates) {
    if (t.length !== embedding.length) continue;
    const nt = norm(t); if (!nt) continue;
    let dot = 0; for (let k = 0; k < t.length; k++) dot += t[k] * embedding[k];
    best = Math.max(best, dot / (ne * nt));
  }
  return Number.isFinite(best) ? Math.round(best * 1000) / 1000 : null;
}
