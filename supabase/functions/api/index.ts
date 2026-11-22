// API publique pour les ERP (lecture seule), authentifiée par clé d'API d'entreprise.
//
//   Authorization: Bearer ptk_…        (ou en-tête X-API-Key: ptk_…)
//
//   GET /api/v1/company                          entreprise et horaires de travail
//   GET /api/v1/employees                        employés (matricule = lien avec l'ERP)
//   GET /api/v1/punches?from=AAAA-MM-JJ&to=…     pointages bruts (pagination par curseur)
//   GET /api/v1/timesheets?from=…&to=…           feuilles de temps : 1 ligne par employé et par jour
//   GET /api/v1/absences?from=…&to=…            absences justifiées et jours fériés
//
// Les dates « from » / « to » sont des jours inclus, dans le fuseau horaire de l'entreprise.
// Une clé ne donne accès qu'aux données de SON entreprise. Aucune photo, IP ni donnée d'appareil n'est exposée.
import { adminClient } from '../_shared/http.ts';
import { formatPunch, localParts, PUNCH_SELECT } from '../_shared/erp.ts';

const headers = {
  'Content-Type': 'application/json; charset=utf-8',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-api-key, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Cache-Control': 'no-store',
};
const out = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
const err = (status: number, code: string, message: string) => out({ error: { code, message } }, status);

async function sha256(s: string) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Décalage (minutes) du fuseau `tz` à l'instant `at` — ex. Africa/Tunis → 60. */
function tzOffsetMin(tz: string, at: Date) {
  const s = new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'longOffset' }).formatToParts(at)
    .find((p) => p.type === 'timeZoneName')?.value ?? 'GMT';
  const m = s.match(/GMT([+-])(\d{2}):?(\d{2})?/);
  return m ? (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3] ?? 0)) : 0;
}

/** Minuit local du jour `day` (AAAA-MM-JJ) dans le fuseau `tz`, en instant UTC. */
function localMidnight(day: string, tz: string) {
  const guess = new Date(`${day}T00:00:00Z`);
  return new Date(guess.getTime() - tzOffsetMin(tz, guess) * 60_000);
}

const isDay = (s: string | null): s is string => !!s && /^\d{4}-\d{2}-\d{2}$/.test(s) && !isNaN(Date.parse(s));
const addDays = (day: string, n: number) => new Date(Date.parse(`${day}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);


Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers });
  if (req.method !== 'GET') return err(405, 'method', 'Seule la méthode GET est acceptée.');

  const url = new URL(req.url);
  const route = url.pathname.match(/\/v1\/(company|employees|punches|timesheets|absences)\/?$/)?.[1];
  if (!route) return err(404, 'not_found', 'Ressource inconnue. Voir la documentation : /v1/company, /v1/employees, /v1/punches, /v1/timesheets, /v1/absences.');

  // ---- Clé d'API ----
  const key = (req.headers.get('x-api-key') || (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '')).trim();
  if (!key.startsWith('ptk_')) return err(401, 'auth', "Clé d'API manquante (en-tête Authorization: Bearer ptk_…).");
  const db = adminClient();
  const { data: k } = await db.from('api_keys')
    .select('id, company_id, revoked_at, company:companies(id, name, active, timezone, notify_in, notify_out, notify_days, late_grace_min, sites_enabled)')
    .eq('key_hash', await sha256(key)).maybeSingle();
  // deno-lint-ignore no-explicit-any
  const company = (k as any)?.company;
  if (!k || k.revoked_at || !company) return err(401, 'auth', "Clé d'API invalide ou révoquée.");
  if (!company.active) return err(403, 'company', 'Entreprise désactivée.');
  await db.from('api_keys').update({ last_used_at: new Date().toISOString() }).eq('id', k.id);
  const tz: string = company.timezone || 'Africa/Tunis';

  // ---- /v1/company ----
  if (route === 'company') {
    return out({
      data: {
        id: company.id, name: company.name, timezone: tz, sites_enabled: company.sites_enabled,
        schedule: {
          start: String(company.notify_in).slice(0, 5), end: String(company.notify_out).slice(0, 5),
          days: company.notify_days, late_tolerance_min: company.late_grace_min,
        },
      },
    });
  }

  // ---- /v1/employees ----
  if (route === 'employees') {
    const { data, error } = await db.from('profiles')
      .select('id, full_name, matricule, role, active, created_at')
      .eq('company_id', company.id).neq('role', 'superadmin').order('full_name');
    if (error) return err(500, 'server', 'Lecture impossible.');
    const { data: faces } = await db.from('face_templates').select('user_id').in('user_id', (data ?? []).map((p) => p.id));
    const enrolled = new Set((faces ?? []).map((f) => f.user_id));
    return out({
      data: (data ?? []).map((p) => ({
        id: p.id, matricule: p.matricule, full_name: p.full_name, role: p.role, active: p.active,
        face_enrolled: enrolled.has(p.id), created_at: p.created_at,
      })),
    });
  }

  // ---- Période (punches, timesheets) ----
  const from = url.searchParams.get('from'), to = url.searchParams.get('to');
  if (!isDay(from) || !isDay(to)) return err(400, 'period', 'Paramètres from et to obligatoires, au format AAAA-MM-JJ.');
  if (to < from) return err(400, 'period', 'to doit être après from.');
  if ((Date.parse(to) - Date.parse(from)) / 86_400_000 > 366) return err(400, 'period', 'Période de 366 jours au maximum.');

  // ---- /v1/absences : congés, maladies, jours fériés… qui touchent la période ----
  if (route === 'absences') {
    const { data, error } = await db.from('absences')
      .select('id, user_id, kind, start_date, end_date, note, created_at, profile:profiles!absences_user_id_fkey(full_name, matricule)')
      .eq('company_id', company.id).lte('start_date', to).gte('end_date', from).order('start_date');
    if (error) return err(500, 'server', 'Lecture impossible.');
    // deno-lint-ignore no-explicit-any
    return out({ data: (data ?? []).map((a: any) => ({
      id: a.id, scope: a.user_id ? 'employee' : 'company', employee_id: a.user_id,
      matricule: a.profile?.matricule ?? null, full_name: a.profile?.full_name ?? null,
      kind: a.kind, start_date: a.start_date, end_date: a.end_date, note: a.note, created_at: a.created_at,
    })) });
  }

  // ---- /v1/timesheets ----
  if (route === 'timesheets') {
    const { data, error } = await db.rpc('timesheet_core', { p_company: company.id, p_from: from, p_to: to });
    if (error) return err(500, 'server', 'Calcul impossible.');
    // deno-lint-ignore no-explicit-any
    return out({ data: (data ?? []).map((r: any) => ({
      date: r.day, employee_id: r.user_id, matricule: r.matricule, full_name: r.full_name,
      first_in: r.first_in, last_out: r.last_out,
      first_in_local: r.first_in ? localParts(r.first_in, tz).local_time.slice(0, 5) : null,
      last_out_local: r.last_out ? localParts(r.last_out, tz).local_time.slice(0, 5) : null,
      worked_min: r.worked_min, expected_min: r.expected_min, late_min: r.late_min, overtime_min: r.overtime_min,
      punches: r.punches, status: r.status, absence: r.absence ?? null, manual_punches: r.manual ?? 0,
    })) });
  }

  // ---- /v1/punches (pagination : ?cursor=<next_cursor>) ----
  const limit = Math.min(Math.max(Number(url.searchParams.get('limit')) || 500, 1), 1000);
  const start = localMidnight(from, tz).toISOString();
  const end = localMidnight(addDays(to, 1), tz).toISOString();
  const cursor = url.searchParams.get('cursor');
  let q = db.from('punches')
    .select(PUNCH_SELECT)
    .eq('company_id', company.id).gte('server_ts', start).lt('server_ts', end)
    .order('server_ts').order('id').limit(limit + 1);
  if (cursor) {
    const [ts, id] = atob(cursor).split('|');
    if (!ts || !id) return err(400, 'cursor', 'Curseur invalide.');
    q = q.or(`server_ts.gt.${ts},and(server_ts.eq.${ts},id.gt.${id})`);
  }
  const { data, error } = await q;
  if (error) return err(500, 'server', 'Lecture impossible.');
  // deno-lint-ignore no-explicit-any
  const rows = (data ?? []) as any[];
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return out({
    data: page.map((p) => formatPunch(p, tz)),
    next_cursor: rows.length > limit && last ? btoa(`${last.server_ts}|${last.id}`) : null,
  });
});
