/* ---------- Apple App Attest (iPhone) ----------
   Équivalent iOS de Google Play Integrity : prouve que le pointage vient de la vraie application,
   non modifiée, sur un vrai iPhone.

   1er pointage d'un iPhone : « attestation » — une clé est créée dans la puce sécurisée du téléphone,
      Apple certifie cette clé (chaîne de certificats jusqu'à la racine App Attest d'Apple).
      Le serveur vérifie la chaîne puis enregistre la clé publique.
   Pointages suivants : « assertion » — le téléphone signe le défi du serveur avec cette clé ;
      le serveur vérifie la signature et que le compteur augmente (anti-rejeu).

   Variable : IOS_APP_ID = "<TEAM_ID>.<bundle id>" (ex. "AB12CD34EF.com.pointeuse.pointeuse").
   Sans elle, les iPhone sont « intégrité non vérifiée » (avertissement, pas de blocage).
   Référence : developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server */
import * as x509 from 'npm:@peculiar/x509@1.12.3';
import { decode as cborDecode } from 'npm:cbor-x@1.6.0';
import type { Integrity } from './checks.ts';

x509.cryptoProvider.set(crypto);

/** Racine « Apple App Attestation Root CA » (apple.com/certificateauthority, valable jusqu'en 2045).
    Empreinte SHA-256 : 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32 */
export const APPLE_APP_ATTEST_ROOT = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const NONCE_OID = '1.2.840.113635.100.8.2';
const enc = new TextEncoder();

const sha256 = async (...parts: Uint8Array[]) => {
  const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { all.set(p, o); o += p.length; }
  return new Uint8Array(await crypto.subtle.digest('SHA-256', all));
};
const eq = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i]);
export const b64 = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
export const toB64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));

export interface AuthData { rpIdHash: Uint8Array; counter: number; aaguid: Uint8Array; credId: Uint8Array }
export function parseAuthData(a: Uint8Array): AuthData {
  if (a.length < 37) throw new Error('authData trop court');
  const counter = new DataView(a.buffer, a.byteOffset + 33, 4).getUint32(0);
  const out: AuthData = { rpIdHash: a.slice(0, 32), counter, aaguid: new Uint8Array(), credId: new Uint8Array() };
  if (a.length >= 55) {
    out.aaguid = a.slice(37, 53);
    const len = new DataView(a.buffer, a.byteOffset + 53, 2).getUint16(0);
    out.credId = a.slice(55, 55 + len);
  }
  return out;
}

/** Signature ECDSA DER → format brut r||s attendu par WebCrypto. */
export function derToRaw(der: Uint8Array, size = 32): Uint8Array {
  let i = 2;
  if (der[0] !== 0x30) throw new Error('signature DER invalide');
  if (der[1] & 0x80) i = 2 + (der[1] & 0x7f);
  const int = () => {
    if (der[i++] !== 0x02) throw new Error('signature DER invalide');
    const len = der[i++];
    let v = der.slice(i, i + len);
    i += len;
    while (v.length > size && v[0] === 0) v = v.slice(1);
    const out = new Uint8Array(size);
    out.set(v, size - v.length);
    return out;
  };
  const r = int(), s = int();
  const raw = new Uint8Array(size * 2);
  raw.set(r); raw.set(s, size);
  return raw;
}

const AAGUID_PROD = enc.encode('appattest\0\0\0\0\0\0\0');
const AAGUID_DEV = enc.encode('appattestdevelop');

/** Vérifie une attestation (1er pointage). Renvoie la clé publique (SPKI, base64) à enregistrer. */
export async function verifyAttestation(opts: {
  attestation: string; keyId: string; clientData: string; appId: string; now?: Date; root?: string;
}): Promise<{ publicKey: string; env: 'production' | 'development' }> {
  // deno-lint-ignore no-explicit-any
  const att: any = cborDecode(b64(opts.attestation));
  if (att?.fmt !== 'apple-appattest') throw new Error('format inconnu');
  const x5c: Uint8Array[] = att.attStmt?.x5c ?? [];
  const authData = new Uint8Array(att.authData);
  if (x5c.length < 2) throw new Error('chaîne de certificats absente');

  // 1. Chaîne : certificat de la clé → intermédiaire → racine Apple
  const [leaf, inter] = x5c.map((c) => new x509.X509Certificate(new Uint8Array(c)));
  const root = new x509.X509Certificate(opts.root ?? APPLE_APP_ATTEST_ROOT);
  const date = opts.now ?? new Date();
  if (!(await leaf.verify({ publicKey: inter.publicKey, date })) ||
      !(await inter.verify({ publicKey: root.publicKey, date }))) throw new Error('chaîne de certificats invalide');

  // 2. Le certificat contient le hachage (authData ‖ SHA256(défi)) : lie l'attestation au défi du serveur
  const nonce = await sha256(authData, await sha256(enc.encode(opts.clientData)));
  const ext = leaf.getExtension(NONCE_OID);
  const v = ext ? new Uint8Array(ext.value) : new Uint8Array();
  if (v.length < 34 || v[v.length - 34] !== 0x04 || v[v.length - 33] !== 0x20 || !eq(v.slice(-32), nonce)) {
    throw new Error('défi non correspondant');
  }

  // 3. L'identifiant de clé est le SHA-256 de la clé publique
  const spki = new Uint8Array(leaf.publicKey.rawData);
  const key = await crypto.subtle.importKey('spki', spki, { name: 'ECDSA', namedCurve: 'P-256' }, true, ['verify']);
  const point = new Uint8Array(await crypto.subtle.exportKey('raw', key));
  const keyId = b64(opts.keyId);
  if (!eq(await sha256(point), keyId)) throw new Error('identifiant de clé incorrect');

  // 4. Application attendue, compteur à 0, environnement
  const ad = parseAuthData(authData);
  if (!eq(ad.rpIdHash, await sha256(enc.encode(opts.appId)))) throw new Error('application différente');
  if (ad.counter !== 0) throw new Error('compteur inattendu');
  const env = eq(ad.aaguid, AAGUID_PROD) ? 'production' : eq(ad.aaguid, AAGUID_DEV) ? 'development' : null;
  if (!env) throw new Error('environnement inconnu');
  if (!eq(ad.credId, keyId)) throw new Error('identifiant de clé incorrect');

  return { publicKey: toB64(spki), env };
}

/** Vérifie une assertion (pointages suivants). Renvoie le nouveau compteur. */
export async function verifyAssertion(opts: {
  assertion: string; publicKey: string; storedCounter: number; clientData: string; appId: string;
}): Promise<number> {
  // deno-lint-ignore no-explicit-any
  const a: any = cborDecode(b64(opts.assertion));
  const authData = new Uint8Array(a?.authenticatorData ?? []);
  const sig = new Uint8Array(a?.signature ?? []);
  const nonce = await sha256(authData, await sha256(enc.encode(opts.clientData)));
  const key = await crypto.subtle.importKey('spki', b64(opts.publicKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, derToRaw(sig) as BufferSource, nonce as BufferSource);
  if (!ok) throw new Error('signature invalide');
  const ad = parseAuthData(authData);
  if (!eq(ad.rpIdHash, await sha256(enc.encode(opts.appId)))) throw new Error('application différente');
  if (ad.counter <= opts.storedCounter) throw new Error('compteur rejoué');
  return ad.counter;
}

export interface IosProof { keyId?: unknown; attestation?: unknown; assertion?: unknown }
export type IosVerdict = Integrity & { appAttest?: 'ok' | 'reattest' };

/** Vérifie la preuve App Attest envoyée avec un pointage iPhone (défi = nonce du serveur). */
// deno-lint-ignore no-explicit-any
export async function verifyIos(db: any, userId: string, proof: IosProof | null | undefined, nonce: string): Promise<IosVerdict> {
  const appId = Deno.env.get('IOS_APP_ID');
  if (!appId) return { verdict: 'unverified', reasons: ['App Attest non configuré sur le serveur'] };
  const keyId = typeof proof?.keyId === 'string' ? proof.keyId : null;
  if (!keyId) return { verdict: 'unverified', reasons: ['App Attest indisponible sur cet iPhone'] };

  try {
    if (typeof proof?.attestation === 'string') {
      const { publicKey, env } = await verifyAttestation({ attestation: proof.attestation, keyId, clientData: nonce, appId });
      await db.from('ios_app_keys').upsert({ key_id: keyId, user_id: userId, public_key: publicKey, counter: 0, env, last_used_at: new Date().toISOString() });
      return { verdict: 'ok', reasons: [], appAttest: 'ok' };
    }
    if (typeof proof?.assertion === 'string') {
      const { data: k } = await db.from('ios_app_keys').select('public_key, counter').eq('key_id', keyId).maybeSingle();
      if (!k) return { verdict: 'unverified', reasons: ['iPhone inconnu : nouvelle attestation au prochain pointage'], appAttest: 'reattest' };
      const counter = await verifyAssertion({ assertion: proof.assertion, publicKey: k.public_key, storedCounter: Number(k.counter), clientData: nonce, appId });
      // Mise à jour conditionnelle : deux requêtes simultanées ne peuvent pas réutiliser le même compteur.
      const { data: upd } = await db.from('ios_app_keys').update({ counter, last_used_at: new Date().toISOString() })
        .eq('key_id', keyId).lt('counter', counter).select('key_id');
      if (!upd?.length) return { verdict: 'fail', reasons: ['App Attest : requête rejouée'] };
      return { verdict: 'ok', reasons: [] };
    }
    return { verdict: 'unverified', reasons: ['App Attest : preuve absente'] };
  } catch (e) {
    return { verdict: 'fail', reasons: [`App Attest : ${e instanceof Error ? e.message : 'invalide'}`] };
  }
}
