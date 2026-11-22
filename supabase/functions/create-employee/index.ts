// Création d'un compte employé par un administrateur.
// Corps : { email, password, fullName, matricule, role?, companyId? }
// Un admin crée dans sa propre entreprise ; le super-admin peut choisir l'entreprise (companyId).
import { adminClient, caller, canManage, cors, fail, isAdmin, json } from '../_shared/http.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail(405, 'method', 'Méthode non autorisée.');

  const db = adminClient();
  const me = await caller(req, db);
  if (!me) return fail(401, 'auth', 'Session expirée : reconnectez-vous.');
  if (!isAdmin(me)) return fail(403, 'role', 'Seul un administrateur peut créer un compte.');

  let b: any;
  try { b = await req.json(); } catch { return fail(400, 'body', 'Requête illisible.'); }
  const email = String(b.email ?? '').trim().toLowerCase();
  const fullName = String(b.fullName ?? '').trim();
  const matricule = String(b.matricule ?? '').trim().toUpperCase();
  const password = String(b.password ?? '');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return fail(400, 'email', 'Adresse e-mail invalide.');
  if (fullName.length < 2) return fail(400, 'name', 'Indiquez le nom complet.');
  if (password.length < 8) return fail(400, 'password', 'Le mot de passe doit contenir au moins 8 caractères.');

  const companyId = typeof b.companyId === 'string' && b.companyId ? b.companyId : me.company_id;
  if (!canManage(me, companyId)) return fail(403, 'company', 'Vous ne pouvez créer des comptes que dans votre entreprise.');
  const { data: company } = await db.from('companies').select('id, active').eq('id', companyId).maybeSingle();
  if (!company) return fail(404, 'company', 'Entreprise introuvable.');
  if (!company.active) return fail(409, 'company', 'Cette entreprise est désactivée.');

  if (matricule) {
    const { data: same } = await db.from('profiles').select('id').eq('company_id', companyId).eq('matricule', matricule).maybeSingle();
    if (same) return fail(409, 'matricule', 'Ce matricule est déjà utilisé dans cette entreprise.');
  }

  // L'entreprise passe par app_metadata : seul le serveur peut la poser (le déclencheur la lit).
  const { data, error } = await db.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { full_name: fullName, matricule },
    app_metadata: { company_id: companyId },
  });
  if (error) return fail(409, 'create', error.message.includes('already') ? 'Un compte existe déjà avec cette adresse.' : 'Création impossible : ' + error.message);

  // Le profil est créé par le déclencheur quand l'entreprise est posée : on s'assure qu'il existe.
  const { data: profile } = await db.from('profiles').select('id').eq('id', data.user.id).maybeSingle();
  if (!profile) {
    await db.auth.admin.deleteUser(data.user.id);
    return fail(500, 'profile', "Le compte n'a pas pu être rattaché à l'entreprise. Réessayez.");
  }

  if (b.role === 'admin') await db.from('profiles').update({ role: 'admin' }).eq('id', data.user.id);
  return json({ id: data.user.id, email, fullName, matricule, companyId });
});
