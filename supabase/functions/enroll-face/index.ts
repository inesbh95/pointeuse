// Enregistrement du visage d'un employé. Réservé aux administrateurs.
// Corps : { userId, embeddings: number[192][], replace?: boolean }
import { adminClient, caller, canManage, cors, fail, isAdmin, json } from '../_shared/http.ts';

const valid = (v: unknown): v is number[] => Array.isArray(v) && v.length === 192 && v.every((x) => typeof x === 'number' && Number.isFinite(x));

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail(405, 'method', 'Méthode non autorisée.');

  const db = adminClient();
  const me = await caller(req, db);
  if (!me) return fail(401, 'auth', 'Session expirée : reconnectez-vous.');
  if (!isAdmin(me)) return fail(403, 'role', "Seul un administrateur peut enregistrer un visage.");

  let body: any;
  try { body = await req.json(); } catch { return fail(400, 'body', 'Requête illisible.'); }
  const embeddings = Array.isArray(body.embeddings) ? body.embeddings.filter(valid) : [];
  if (embeddings.length < 3 || embeddings.length > 10) return fail(400, 'embeddings', 'Il faut entre 3 et 10 captures du visage.');

  const { data: target } = await db.from('profiles').select('id, full_name, company_id').eq('id', body.userId).maybeSingle();
  if (!target || !canManage(me, target.company_id)) return fail(404, 'user', 'Employé introuvable.');

  // Refuse un visage déjà enregistré pour un autre employé de la même entreprise (similarité ≥ 0,75)
  const { data: colleagues } = await db.from('profiles').select('id').eq('company_id', target.company_id).neq('id', target.id);
  const ids = (colleagues ?? []).map((c: any) => c.id);
  const { data: others } = ids.length
    ? await db.from('face_templates').select('user_id, embedding').in('user_id', ids)
    : { data: [] as any[] };
  const cos = (a: number[], b: number[]) => {
    let d = 0, na = 0, nb = 0; for (let i = 0; i < a.length; i++) { d += a[i] * b[i]; na += a[i] ** 2; nb += b[i] ** 2; }
    return d / Math.sqrt(na * nb);
  };
  for (const o of others ?? []) {
    if (embeddings.some((e: number[]) => cos(e, o.embedding) >= 0.75)) {
      const { data: p } = await db.from('profiles').select('full_name').eq('id', o.user_id).single();
      return fail(409, 'duplicate', `Ce visage ressemble à celui de ${p?.full_name ?? 'un autre employé'}, déjà enregistré.`);
    }
  }

  if (body.replace !== false) await db.from('face_templates').delete().eq('user_id', target.id);
  const { error } = await db.from('face_templates').insert(embeddings.map((e: number[]) => ({ user_id: target.id, embedding: e, created_by: me.id })));
  if (error) return fail(500, 'db', "Le visage n'a pas pu être enregistré.");
  return json({ ok: true, count: embeddings.length, name: target.full_name });
});
