// Appels aux services externes : réputation IP, Google Play Integrity, adresse (OpenStreetMap).
import type { Integrity, IpInfo } from './checks.ts';

const withTimeout = (ms: number) => AbortSignal.timeout(ms);

/* Adresse IP réelle du client, transmise par la passerelle Supabase. */
export function clientIp(req: Request): string | null {
  const xff = req.headers.get('x-forwarded-for');
  if (xff) return xff.split(',')[0].trim();
  return req.headers.get('x-real-ip') || req.headers.get('cf-connecting-ip');
}

/* Réputation IP via ipapi.is (clé : variable IPAPI_KEY ; sans clé, offre gratuite limitée). */
export async function lookupIp(ip: string | null): Promise<IpInfo> {
  if (!ip) return { error: 'ip_absente' };
  const key = Deno.env.get('IPAPI_KEY');
  const url = `https://api.ipapi.is/?q=${encodeURIComponent(ip)}${key ? '&key=' + encodeURIComponent(key) : ''}`;
  try {
    const r = await fetch(url, { signal: withTimeout(5000) });
    if (!r.ok) return { error: `http_${r.status}`, ip };
    const j = await r.json();
    if (j.error) return { error: String(j.error), ip };
    const loc = j.location || {};
    return {
      ip, vpn: !!j.is_vpn, proxy: !!j.is_proxy, tor: !!j.is_tor, datacenter: !!j.is_datacenter,
      vpnService: j.vpn?.service ?? null, operator: j.company?.name ?? j.asn?.org ?? null,
      country: loc.country ?? null, city: loc.city ?? null,
      lat: loc.latitude ?? null, lng: loc.longitude ?? null, tz: loc.timezone ?? null,
    };
  } catch (e) {
    return { error: 'injoignable', ip };
  }
}

export async function reverseGeocode(lat: number, lng: number): Promise<string | null> {
  try {
    const r = await fetch(`https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${lat}&lon=${lng}&accept-language=fr&zoom=18`, {
      headers: { 'User-Agent': Deno.env.get('GEOCODER_USER_AGENT') || 'pointeuse-missions/1.0' },
      signal: withTimeout(3000),
    });
    if (!r.ok) return null;
    return (await r.json()).display_name ?? null;
  } catch { return null; }
}

/* ---------- Google Play Integrity (Android) ----------
   Variables : GOOGLE_SERVICE_ACCOUNT_JSON (compte de service avec accès à l'API Play Integrity)
               ANDROID_PACKAGE_NAME (ex. com.pointeuse.pointeuse)                                    */

const b64url = (data: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = ''; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

let cachedToken: { value: string; exp: number } | null = null;
async function googleAccessToken(sa: { client_email: string; private_key: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.exp > now + 60) return cachedToken.value;
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email, scope: 'https://www.googleapis.com/auth/playintegrity',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`));
  const jwt = `${header}.${claims}.${b64url(sig)}`;
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
    signal: withTimeout(5000),
  });
  if (!r.ok) throw new Error('oauth_' + r.status);
  const j = await r.json();
  cachedToken = { value: j.access_token, exp: now + (j.expires_in ?? 3600) };
  return cachedToken.value;
}

/* Interprète la réponse décodée de Google. Séparé pour pouvoir être testé. */
export function judgePlayIntegrity(payload: any, expected: { nonce: string; packageName: string; now: number }): Integrity {
  const reasons: string[] = [];
  const req = payload?.requestDetails ?? {};
  if (req.nonce !== expected.nonce) reasons.push('jeton rejoué ou falsifié');
  if (req.requestPackageName && req.requestPackageName !== expected.packageName) reasons.push('autre application');
  if (req.timestampMillis && Math.abs(expected.now - Number(req.timestampMillis)) > 5 * 60 * 1000) reasons.push('jeton périmé');
  const app = payload?.appIntegrity ?? {};
  if (app.appRecognitionVerdict !== 'PLAY_RECOGNIZED') reasons.push('application modifiée ou non installée depuis Google Play');
  const dev: string[] = payload?.deviceIntegrity?.deviceRecognitionVerdict ?? [];
  if (!dev.includes('MEETS_DEVICE_INTEGRITY')) reasons.push(dev.length ? 'téléphone rooté ou émulateur' : 'téléphone non certifié');
  return { verdict: reasons.length ? 'fail' : 'ok', reasons };
}

export async function verifyPlayIntegrity(token: string | null, nonce: string): Promise<Integrity> {
  const saJson = Deno.env.get('GOOGLE_SERVICE_ACCOUNT_JSON');
  const packageName = Deno.env.get('ANDROID_PACKAGE_NAME') || 'com.pointeuse.pointeuse';
  if (!saJson) return { verdict: 'unverified', reasons: ['Play Integrity non configuré sur le serveur'] };
  if (!token) return { verdict: 'fail', reasons: ["jeton d'intégrité absent"] };
  try {
    const access = await googleAccessToken(JSON.parse(saJson));
    const r = await fetch(`https://playintegrity.googleapis.com/v1/${packageName}:decodeIntegrityToken`, {
      method: 'POST', headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ integrity_token: token }), signal: withTimeout(6000),
    });
    if (!r.ok) return { verdict: 'unverified', reasons: [`Google a répondu ${r.status}`] };
    const j = await r.json();
    return judgePlayIntegrity(j.tokenPayloadExternal, { nonce, packageName, now: Date.now() });
  } catch (e) {
    return { verdict: 'unverified', reasons: ['Google Play Integrity injoignable'] };
  }
}

