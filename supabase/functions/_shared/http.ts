import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.117.3';

export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

export const fail = (status: number, code: string, message: string) => json({ error: { code, message } }, status);

/* Client « service » : contourne les règles d'accès. À n'utiliser qu'après avoir identifié l'appelant. */
export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export interface Caller {
  id: string; full_name: string; role: 'employee' | 'admin' | 'superadmin'; active: boolean;
  company_id: string; company: { active: boolean; sites_enabled: boolean; rules: Record<string, unknown> };
}

/* Identifie l'utilisateur à partir de son jeton et charge son profil et son entreprise.
   Un compte d'une entreprise désactivée est refusé (sauf le super-admin). */
export async function caller(req: Request, db: SupabaseClient): Promise<Caller | null> {
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) return null;
  const { data: profile } = await db.from('profiles')
    .select('id, full_name, role, active, company_id, company:companies(active, sites_enabled, rules)').eq('id', data.user.id).single();
  if (!profile || !profile.active) return null;
  const me = profile as unknown as Caller;
  if (!me.company?.active && me.role !== 'superadmin') return null;
  return me;
}

export const isAdmin = (me: Caller) => me.role === 'admin' || me.role === 'superadmin';

/* L'appelant peut-il gérer les données de cette entreprise ? (même règle que can_manage en base) */
export const canManage = (me: Caller, companyId: string) => me.role === 'superadmin' || (me.role === 'admin' && me.company_id === companyId);
