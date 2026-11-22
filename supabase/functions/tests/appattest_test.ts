// Tests App Attest avec une fausse autorité (même format que les certificats d'Apple) :
//   deno test supabase/functions/tests/
import { deepStrictEqual as assertEquals, rejects } from 'node:assert';
import * as x509 from 'npm:@peculiar/x509@1.12.3';
import { encode as cborEncode } from 'npm:cbor-x@1.6.0';
import { APPLE_APP_ATTEST_ROOT, derToRaw, toB64, verifyAssertion, verifyAttestation } from '../_shared/appattest.ts';

x509.cryptoProvider.set(crypto);
const enc = new TextEncoder();
const APP_ID = 'TEAM123456.com.pointeuse.pointeuse';
const NONCE = 'defi-du-serveur-abc';
const sha = async (...p: Uint8Array[]) => {
  const all = new Uint8Array(p.reduce((n, x) => n + x.length, 0));
  let o = 0; for (const x of p) { all.set(x, o); o += x.length; }
  return new Uint8Array(await crypto.subtle.digest('SHA-256', all));
};
const EC = { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' } as const;

function authData(rpIdHash: Uint8Array, counter: number, credId?: Uint8Array, aaguid = 'appattest\0\0\0\0\0\0\0') {
  const head = new Uint8Array(37);
  head.set(rpIdHash); head[32] = 0x40;
  new DataView(head.buffer).setUint32(33, counter);
  if (!credId) return head;
  const rest = new Uint8Array(16 + 2 + credId.length);
  rest.set(enc.encode(aaguid)); new DataView(rest.buffer).setUint16(16, credId.length); rest.set(credId, 18);
  const out = new Uint8Array(head.length + rest.length); out.set(head); out.set(rest, head.length);
  return out;
}

/** Fabrique une attestation complète, signée par une fausse racine. */
async function fakeAttestation(opts: { appId?: string; nonce?: string; counter?: number; aaguid?: string } = {}) {
  const rootKeys = await crypto.subtle.generateKey(EC, true, ['sign', 'verify']) as CryptoKeyPair;
  const interKeys = await crypto.subtle.generateKey(EC, true, ['sign', 'verify']) as CryptoKeyPair;
  const leafKeys = await crypto.subtle.generateKey(EC, true, ['sign', 'verify']) as CryptoKeyPair;
  const nb = new Date(Date.now() - 86_400_000), na = new Date(Date.now() + 86_400_000);
  const root = await x509.X509CertificateGenerator.createSelfSigned({ serialNumber: '01', name: 'CN=Fausse racine', notBefore: nb, notAfter: na, keys: rootKeys, signingAlgorithm: EC });
  const inter = await x509.X509CertificateGenerator.create({ serialNumber: '02', subject: 'CN=Intermediaire', issuer: root.subject, notBefore: nb, notAfter: na, publicKey: interKeys.publicKey, signingKey: rootKeys.privateKey, signingAlgorithm: EC });

  const point = new Uint8Array(await crypto.subtle.exportKey('raw', leafKeys.publicKey));
  const keyId = await sha(point);
  const ad = authData(await sha(enc.encode(opts.appId ?? APP_ID)), opts.counter ?? 0, keyId, opts.aaguid);
  const nonceHash = await sha(ad, await sha(enc.encode(opts.nonce ?? NONCE)));
  const extValue = new Uint8Array([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20, ...nonceHash]);
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: '03', subject: 'CN=Cle', issuer: inter.subject, notBefore: nb, notAfter: na,
    publicKey: leafKeys.publicKey, signingKey: interKeys.privateKey, signingAlgorithm: EC,
    extensions: [new x509.Extension('1.2.840.113635.100.8.2', false, extValue)],
  });
  const att = cborEncode({ fmt: 'apple-appattest', attStmt: { x5c: [new Uint8Array(leaf.rawData), new Uint8Array(inter.rawData)], receipt: new Uint8Array() }, authData: ad });
  return { attestation: toB64(new Uint8Array(att)), keyId: toB64(keyId), root: root.toString('pem'), leafKeys };
}

/** Assertion signée en DER, comme iOS. */
async function fakeAssertion(priv: CryptoKey, counter: number, appId = APP_ID, nonce = NONCE) {
  const ad = authData(await sha(enc.encode(appId)), counter);
  const msg = await sha(ad, await sha(enc.encode(nonce)));
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, priv, msg));
  const int = (v: Uint8Array) => { let i = 0; while (i < v.length - 1 && v[i] === 0) i++; v = v.slice(i); return v[0] & 0x80 ? new Uint8Array([0, ...v]) : v; };
  const r = int(raw.slice(0, 32)), s = int(raw.slice(32));
  const der = new Uint8Array([0x30, r.length + s.length + 4, 0x02, r.length, ...r, 0x02, s.length, ...s]);
  return toB64(new Uint8Array(cborEncode({ signature: der, authenticatorData: ad })));
}

Deno.test('la racine Apple embarquée est lisible et valable', () => {
  const c = new x509.X509Certificate(APPLE_APP_ATTEST_ROOT);
  assertEquals(c.subject.includes('Apple App Attestation Root CA'), true);
  assertEquals(c.notAfter > new Date(), true);
});

Deno.test('attestation valide acceptée, puis assertions avec compteur croissant', async () => {
  const f = await fakeAttestation();
  const r = await verifyAttestation({ attestation: f.attestation, keyId: f.keyId, clientData: NONCE, appId: APP_ID, root: f.root });
  assertEquals(r.env, 'production');
  const c1 = await verifyAssertion({ assertion: await fakeAssertion(f.leafKeys.privateKey, 1), publicKey: r.publicKey, storedCounter: 0, clientData: NONCE, appId: APP_ID });
  assertEquals(c1, 1);
  await rejects(verifyAssertion({ assertion: await fakeAssertion(f.leafKeys.privateKey, 1), publicKey: r.publicKey, storedCounter: 1, clientData: NONCE, appId: APP_ID }), /compteur/);
  await rejects(verifyAssertion({ assertion: await fakeAssertion(f.leafKeys.privateKey, 2, APP_ID, 'autre-defi'), publicKey: r.publicKey, storedCounter: 1, clientData: NONCE, appId: APP_ID }), /signature/);
  await rejects(verifyAssertion({ assertion: await fakeAssertion(f.leafKeys.privateKey, 2, 'X.autre.app'), publicKey: r.publicKey, storedCounter: 1, clientData: NONCE, appId: APP_ID }), /application/);
});

Deno.test('attestation refusée : mauvaise racine, mauvais défi, autre app, compteur ≠ 0', async () => {
  const f = await fakeAttestation();
  await rejects(verifyAttestation({ attestation: f.attestation, keyId: f.keyId, clientData: NONCE, appId: APP_ID }), /chaîne/); // vraie racine Apple
  await rejects(verifyAttestation({ attestation: f.attestation, keyId: f.keyId, clientData: 'autre', appId: APP_ID, root: f.root }), /défi/);
  await rejects(verifyAttestation({ attestation: f.attestation, keyId: f.keyId, clientData: NONCE, appId: 'X.autre', root: f.root }), /application/);
  const g = await fakeAttestation({ counter: 3 });
  await rejects(verifyAttestation({ attestation: g.attestation, keyId: g.keyId, clientData: NONCE, appId: APP_ID, root: g.root }), /compteur/);
  const h = await fakeAttestation({ aaguid: 'appattestdevelop' });
  assertEquals((await verifyAttestation({ attestation: h.attestation, keyId: h.keyId, clientData: NONCE, appId: APP_ID, root: h.root })).env, 'development');
  await rejects(verifyAttestation({ attestation: f.attestation, keyId: g.keyId, clientData: NONCE, appId: APP_ID, root: f.root }), /identifiant/);
});

Deno.test('signature DER → brute', () => {
  const der = new Uint8Array([0x30, 0x08, 0x02, 0x02, 0x00, 0x81, 0x02, 0x02, 0x01, 0x02]);
  const raw = derToRaw(der, 4);
  assertEquals([...raw], [0, 0, 0, 0x81, 0, 0, 1, 2]);
});
