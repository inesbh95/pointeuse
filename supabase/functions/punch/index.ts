// Étape 2 du pointage : reçoit les données brutes du téléphone, refait TOUS les contrôles
// côté serveur, enregistre le pointage (même refusé, pour l'audit) et renvoie le verdict.
import { adminClient, caller, cors, fail, json } from '../_shared/http.ts';
import { bestSimilarity, DEFAULT_RULES, evaluate, type Fix } from '../_shared/checks.ts';
import { clientIp, lookupIp, reverseGeocode, verifyPlayIntegrity } from '../_shared/services.ts';
import { verifyIos, type IosVerdict } from '../_shared/appattest.ts';

const isNum = (x: unknown): x is number => typeof x === 'number' && Number.isFinite(x);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail(405, 'method', 'Méthode non autorisée.');

  const db = adminClient();
  const me = await caller(req, db);
  if (!me) return fail(401, 'auth', 'Session expirée : reconnectez-vous.');

  let body: any;
  try { body = await req.json(); } catch { return fail(400, 'body', 'Requête illisible.'); }

  // --- Validation de la forme des données ---
  if (body.type !== 'in' && body.type !== 'out') return fail(400, 'type', 'Type de pointage invalide.');
  const fixes: Fix[] = Array.isArray(body.fixes)
    ? body.fixes.slice(0, 10).filter((f: any) => isNum(f?.lat) && isNum(f?.lng) && isNum(f?.acc) && isNum(f?.ts))
        .map((f: any) => ({ lat: f.lat, lng: f.lng, acc: f.acc, ts: f.ts, mocked: f.mocked === true }))
    : [];
  const embedding: number[] = Array.isArray(body.embedding) && body.embedding.length === 192 && body.embedding.every(isNum) ? body.embedding : [];
  const device = body.device ?? {};
  const platform = device.platform === 'ios' ? 'ios' : 'android';
  const photoPath = typeof body.photoPath === 'string' && body.photoPath.startsWith(`${me.id}/`) ? body.photoPath : null;

  // --- Défi à usage unique (anti-rejeu) ---
  const now = Date.now();
  const { data: challenge } = await db.from('punch_challenges')
    .update({ used_at: new Date(now).toISOString() })
    .eq('id', body.challengeId ?? '00000000-0000-0000-0000-000000000000')
    .eq('user_id', me.id).is('used_at', null).gt('expires_at', new Date(now).toISOString())
    .select('nonce').maybeSingle();
  if (!challenge) return fail(409, 'challenge', 'Pointage expiré ou déjà utilisé. Recommencez.');

  // --- Données de référence et vérifications externes, en parallèle ---
  const ip = clientIp(req);
  const [settingsRes, sitesRes, templatesRes, previousRes, ipInfo, integrity] = await Promise.all([
    db.from('settings').select('rules').eq('id', 1).single(),
    db.from('sites').select('id, client, name, lat, lng, radius_m').eq('active', true).eq('company_id', me.company_id),
    db.from('face_templates').select('embedding').eq('user_id', me.id),
    db.from('punches').select('lat, lng, server_ts').eq('user_id', me.id).neq('status', 'blocked')
      .not('lat', 'is', null).order('server_ts', { ascending: false }).limit(1).maybeSingle(),
    lookupIp(ip),
    platform === 'android'
      ? verifyPlayIntegrity(typeof body.integrityToken === 'string' ? body.integrityToken : null, challenge.nonce)
      : verifyIos(db, me.id, body.ios, challenge.nonce),
  ]);

  const templates = (templatesRes.data ?? []).map((t: any) => t.embedding as number[]);
  const similarity = embedding.length ? bestSimilarity(embedding, templates) : null;
  const prev = previousRes.data;

  const verdict = evaluate({
    fixes,
    device: { platform, vpnActive: device.vpnActive === true, devMode: device.devMode === true, tz: typeof device.tz === 'string' ? device.tz : null },
    ip: ipInfo, integrity,
    face: { similarity, templates: templates.length },
    liveness: { passed: body.liveness?.passed === true, steps: body.liveness?.steps },
    // Option de l'entreprise (décidée par le serveur) : sans gestion des sites, pas de contrôle « hors site ».
    sites: me.company?.sites_enabled ? (sitesRes.data ?? []) : null, rules: { ...DEFAULT_RULES, ...(settingsRes.data?.rules ?? {}), ...(me.company?.rules ?? {}) },
    previous: prev ? { lat: prev.lat, lng: prev.lng, ts: new Date(prev.server_ts).getTime() } : null,
    now, deviceTs: isNum(body.deviceTs) ? body.deviceTs : null,
  });

  // Adresse : recherche du serveur, sinon celle trouvée par le téléphone (texte libre, nettoyé et borné).
  const deviceAddress = typeof body.deviceAddress === 'string'
    ? body.deviceAddress.replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, 300) || null : null;
  const address = verdict.best ? (await reverseGeocode(verdict.best.lat, verdict.best.lng)) ?? deviceAddress : null;

  const { data: punch, error } = await db.from('punches').insert({
    user_id: me.id, company_id: me.company_id, type: body.type,
    device_ts: isNum(body.deviceTs) ? new Date(body.deviceTs).toISOString() : null,
    lat: verdict.best?.lat ?? null, lng: verdict.best?.lng ?? null, accuracy_m: verdict.best?.acc ?? null,
    gps: { fixes, spread_m: verdict.spreadM },
    site_id: verdict.site?.id ?? null, site_distance_m: verdict.siteDistance, address,
    ip, ip_info: ipInfo,
    device: { platform, vpnActive: device.vpnActive ?? null, devMode: device.devMode ?? null, tz: device.tz ?? null,
              model: device.model ?? null, osVersion: device.osVersion ?? null, appVersion: device.appVersion ?? null },
    integrity, face_similarity: similarity,
    liveness: { passed: body.liveness?.passed === true, steps: body.liveness?.steps ?? [], durationMs: body.liveness?.durationMs ?? null },
    photo_path: photoPath, status: verdict.status, flags: verdict.flags,
  }).select('id, server_ts').single();
  if (error) return fail(500, 'db', "Le pointage n'a pas pu être enregistré. Réessayez.");

  return json({
    id: punch.id, serverTime: punch.server_ts, status: verdict.status, flags: verdict.flags,
    site: verdict.site ? { client: verdict.site.client, name: verdict.site.name } : null,
    siteDistance: verdict.siteDistance, address,
    // iPhone : demande une nouvelle attestation si la clé n'est plus connue du serveur.
    ...(platform === 'ios' ? { appAttest: (integrity as IosVerdict).appAttest ?? null } : {}),
  });
});
