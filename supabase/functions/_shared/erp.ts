// Format des pointages pour les ERP : commun à l'API (/v1/punches) et aux webhooks.
// Aucune photo, IP ni donnée d'appareil n'est exposée.

export const PUNCH_SELECT =
  'id, user_id, company_id, type, server_ts, status, review_decision, manual, manual_reason, address, lat, lng, accuracy_m, site_distance_m, ' +
  'site:sites(client, name), profile:profiles!punches_user_id_fkey(full_name, matricule)';

/** Date et heure locales (fuseau de l'entreprise) d'un horodatage ISO. */
export function localParts(iso: string, tz: string) {
  const f = new Intl.DateTimeFormat('fr-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  });
  const p = Object.fromEntries(f.formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return { local_date: `${p.year}-${p.month}-${p.day}`, local_time: `${p.hour}:${p.minute}:${p.second}` };
}

// deno-lint-ignore no-explicit-any
export function formatPunch(p: any, tz: string) {
  return {
    id: p.id, employee_id: p.user_id, matricule: p.profile?.matricule ?? null, full_name: p.profile?.full_name ?? null,
    type: p.type, timestamp: p.server_ts, ...localParts(p.server_ts, tz),
    status: p.status, review: p.review_decision,
    // Saisi à la main par l'administrateur (oubli de pointage), avec son motif.
    manual: p.manual === true, manual_reason: p.manual_reason ?? null,
    // Même règle que les feuilles de temps : compté sauf refusé non validé, ou rejeté par l'admin.
    counted: (p.status !== 'blocked' || p.review_decision === 'approved') && p.review_decision !== 'rejected',
    site: p.site ? { client: p.site.client, name: p.site.name } : null,
    site_distance_m: p.site_distance_m == null ? null : Math.round(p.site_distance_m),
    address: p.address, latitude: p.lat, longitude: p.lng, accuracy_m: p.accuracy_m,
  };
}
