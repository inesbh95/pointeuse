// Étape 1 du pointage : le serveur fournit un défi à usage unique (valable 3 minutes).
// Il sert de « nonce » au jeton Play Integrity et empêche de rejouer un ancien pointage.
import { adminClient, caller, cors, fail, json } from '../_shared/http.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail(405, 'method', 'Méthode non autorisée.');

  const db = adminClient();
  const me = await caller(req, db);
  if (!me) return fail(401, 'auth', 'Session expirée : reconnectez-vous.');

  // Limite : 10 défis par tranche de 5 minutes et par employé
  const since = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  const { count } = await db.from('punch_challenges').select('id', { count: 'exact', head: true }).eq('user_id', me.id).gte('created_at', since);
  if ((count ?? 0) >= 10) return fail(429, 'rate', 'Trop de tentatives. Patientez quelques minutes.');

  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const nonce = btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const { data, error } = await db.from('punch_challenges').insert({ user_id: me.id, nonce }).select('id, nonce, expires_at').single();
  if (error) return fail(500, 'db', 'Impossible de préparer le pointage.');

  return json({ challengeId: data.id, nonce: data.nonce, expiresAt: data.expires_at, serverTime: new Date().toISOString() });
});
