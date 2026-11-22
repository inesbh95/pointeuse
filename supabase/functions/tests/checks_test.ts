// Tests des règles de fiabilité : deno test supabase/functions/tests/
import { deepStrictEqual as assertEquals } from 'node:assert';
import { bestSimilarity, DEFAULT_RULES, evaluate, type Fix, type Input } from '../_shared/checks.ts';
import { judgePlayIntegrity } from '../_shared/services.ts';

const NOW = Date.UTC(2026, 9, 26, 9, 0, 0);
const site = { id: 's1', client: 'Clinique El Amen', name: 'Lac 2', lat: 36.838, lng: 10.242, radius_m: 200 };
const jitter = (n: number): Fix[] => Array.from({ length: n }, (_, k) => ({ lat: 36.8381 + k * 0.00002, lng: 10.2421 - k * 0.00001, acc: 12 + k, ts: NOW - 2000 }));
const base = (over: Partial<Input> = {}): Input => ({
  fixes: jitter(4),
  device: { platform: 'android', vpnActive: false, devMode: false, tz: 'Africa/Tunis' },
  ip: { ip: '197.15.1.2', vpn: false, proxy: false, tor: false, datacenter: false, operator: 'Tunisie Telecom', country: 'Tunisia', city: 'Tunis', lat: 36.8, lng: 10.18, tz: 'Africa/Tunis' },
  integrity: { verdict: 'ok', reasons: [] },
  face: { similarity: 0.82, templates: 3 },
  liveness: { passed: true },
  sites: [site], rules: DEFAULT_RULES, previous: null, now: NOW, deviceTs: NOW + 1000,
  ...over,
});
const codes = (i: Input) => evaluate(i).flags.map((f) => f.code).sort();

Deno.test('pointage normal sur site : vérifié', () => {
  const v = evaluate(base());
  assertEquals(v.status, 'ok');
  assertEquals(v.site?.id, 's1');
  assertEquals(v.flags, []);
});

Deno.test('VPN actif sur le téléphone : refusé', () => {
  const v = evaluate(base({ device: { platform: 'android', vpnActive: true, devMode: false, tz: 'Africa/Tunis' } }));
  assertEquals(v.status, 'blocked');
  assertEquals(codes(base({ device: { platform: 'android', vpnActive: true, tz: 'Africa/Tunis' } })), ['vpn_device']);
});

Deno.test('VPN vu par l\'IP (Paris) : refusé + IP éloignée + fuseau', () => {
  const v = base({ ip: { ip: '5.6.7.8', vpn: true, datacenter: true, vpnService: 'NordVPN', operator: 'M247', city: 'Paris', lat: 48.85, lng: 2.35, tz: 'Europe/Paris' } });
  assertEquals(evaluate(v).status, 'blocked');
  assertEquals(codes(v), ['ip_far', 'tz_mismatch', 'vpn']);
});

Deno.test('position simulée signalée par Android : refusée', () => {
  const f = jitter(4); f[1] = { ...f[1], mocked: true };
  assertEquals(evaluate(base({ fixes: f })).status, 'blocked');
  assertEquals(codes(base({ fixes: f })), ['mock_location']);
});

Deno.test('position figée : refusée', () => {
  const same = { lat: 36.8381, lng: 10.2421, acc: 10, ts: NOW };
  assertEquals(codes(base({ fixes: [same, same, same] })), ['frozen_gps']);
});

Deno.test('hors site : à vérifier', () => {
  const v = evaluate(base({ fixes: jitter(3).map((f) => ({ ...f, lat: f.lat - 0.04 })) }));
  assertEquals(v.status, 'suspect');
  assertEquals(v.flags[0].code, 'off_site');
});

Deno.test('application sans sites (sites: null) : pas de contrôle « hors site »', () => {
  const v = evaluate(base({ sites: null, fixes: jitter(3).map((f) => ({ ...f, lat: f.lat - 0.04 })) }));
  assertEquals(v.status, 'ok');
  assertEquals(v.site, null);
  assertEquals(v.flags, []);
});

Deno.test('visage différent : refusé ; non enrôlé : refusé', () => {
  assertEquals(codes(base({ face: { similarity: 0.31, templates: 3 } })), ['face_mismatch']);
  assertEquals(codes(base({ face: { similarity: null, templates: 0 } })), ['no_template']);
});

Deno.test('téléphone rooté (Play Integrity) : refusé', () => {
  assertEquals(evaluate(base({ integrity: { verdict: 'fail', reasons: ['téléphone rooté ou émulateur'] } })).status, 'blocked');
});

Deno.test('trajet impossible et horloge décalée : à vérifier', () => {
  const v = base({ previous: { lat: 35.8256, lng: 10.6084, ts: NOW - 20 * 60 * 1000 }, deviceTs: NOW + 30 * 60 * 1000 });
  assertEquals(codes(v), ['clock', 'impossible_travel']);
  assertEquals(evaluate(v).status, 'suspect');
});

Deno.test('règle VPN en mode « signaler » : à vérifier au lieu de refusé', () => {
  const v = base({ device: { platform: 'android', vpnActive: true, tz: 'Africa/Tunis' }, rules: { ...DEFAULT_RULES, vpnPolicy: 'warn' } });
  assertEquals(evaluate(v).status, 'suspect');
});

Deno.test('similarité cosinus', () => {
  const a = Array.from({ length: 192 }, (_, i) => Math.sin(i));
  assertEquals(bestSimilarity(a, [a]), 1);
  assertEquals(bestSimilarity(a, []), null);
  assertEquals(bestSimilarity(a, [a.map((x) => -x)]), -1);
});

Deno.test('verdict Play Integrity', () => {
  const good = {
    requestDetails: { nonce: 'n1', requestPackageName: 'com.pointeuse.pointeuse', timestampMillis: String(NOW) },
    appIntegrity: { appRecognitionVerdict: 'PLAY_RECOGNIZED' },
    deviceIntegrity: { deviceRecognitionVerdict: ['MEETS_DEVICE_INTEGRITY'] },
  };
  const exp = { nonce: 'n1', packageName: 'com.pointeuse.pointeuse', now: NOW };
  assertEquals(judgePlayIntegrity(good, exp).verdict, 'ok');
  assertEquals(judgePlayIntegrity({ ...good, deviceIntegrity: { deviceRecognitionVerdict: [] } }, exp).verdict, 'fail');
  assertEquals(judgePlayIntegrity(good, { ...exp, nonce: 'autre' }).reasons, ['jeton rejoué ou falsifié']);
});
