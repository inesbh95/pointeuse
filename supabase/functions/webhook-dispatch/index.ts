// Envoi des webhooks aux ERP. Réveillée par la base (pg_net) à chaque événement, et toutes les
// minutes par pg_cron pour les relances. Réservée au serveur : en-tête X-Dispatch-Secret obligatoire.
//
// Requête envoyée à l'ERP :
//   POST <url>   Content-Type: application/json
//   X-Pointeuse-Event: punch.created | punch.reviewed | absence.created | absence.deleted | employee.created | employee.updated
//                      | ticket.created | ticket.assigned | ticket.status_changed | ticket.updated | ticket.commented | ping
//   X-Pointeuse-Delivery: <id unique de l'envoi>      (identique à chaque relance : anti-doublon)
//   X-Pointeuse-Timestamp: <secondes Unix>
//   X-Pointeuse-Signature: sha256=<hex HMAC-SHA256(secret, "<timestamp>.<corps>")>
import { adminClient } from '../_shared/http.ts';
import { formatPunch, PUNCH_SELECT } from '../_shared/erp.ts';
import { blockedHost, nextDelayMin, sign } from './lib.ts';

const MAX_ATTEMPTS = 8;
const TIMEOUT_MS = 10_000;

Deno.serve(async (req) => {
  const secret = Deno.env.get('WEBHOOK_DISPATCH_SECRET');
  if (!secret || req.headers.get('x-dispatch-secret') !== secret) return new Response('forbidden', { status: 403 });

  const db = adminClient();
  const started = Date.now();
  let sent = 0, failed = 0;

  while (Date.now() - started < 40_000) {
    const { data: batch, error } = await db.rpc('webhook_claim', { max_rows: 25 });
    if (error) { console.error('claim', error.message); break; }
    if (!batch?.length) break;

    // deno-lint-ignore no-explicit-any
    await Promise.all(batch.map(async (d: any) => {
      const { data: hook } = await db.from('webhooks')
        .select('id, url, secret, active, company:companies(id, name, timezone, active)').eq('id', d.webhook_id).maybeSingle();
      // deno-lint-ignore no-explicit-any
      const company = (hook as any)?.company;
      const finish = async (ok: boolean, status: number | null, msg: string | null, final = false) => {
        const now = new Date().toISOString();
        const giveUp = !ok && (final || d.attempts >= MAX_ATTEMPTS);
        await db.from('webhook_deliveries').update({
          delivered_at: ok ? now : null, failed_at: giveUp ? now : null, locked_until: null,
          last_status: status, last_error: msg,
          next_attempt_at: new Date(Date.now() + nextDelayMin(d.attempts) * 60_000).toISOString(),
        }).eq('id', d.id);
        if (hook) {
          await db.from('webhooks').update({
            last_attempt_at: now, last_status: status, last_error: ok ? null : msg, ...(ok ? { last_success_at: now } : {}),
          }).eq('id', hook.id);
        }
        ok ? sent++ : failed++;
      };

      if (!hook || !hook.active || !company?.active) return finish(false, null, 'Webhook désactivé.', true);
      const host = new URL(hook.url).hostname;
      if (blockedHost(host)) return finish(false, null, 'Adresse refusée (réseau privé).', true);

      let data: unknown = { message: 'Test du webhook Pointeuse.' };
      if (d.payload) {
        data = d.payload; // absence.* et employee.* : contenu photographié au moment de l'événement
      } else if (d.event.startsWith('punch.')) {
        const { data: p } = await db.from('punches').select(PUNCH_SELECT).eq('id', d.punch_id).maybeSingle();
        if (!p) return finish(false, null, 'Pointage introuvable.', true);
        data = formatPunch(p, company.timezone || 'Africa/Tunis');
      }
      const body = JSON.stringify({
        id: d.id, event: d.event, created_at: d.created_at,
        company: { id: company.id, name: company.name }, data,
      });
      const ts = Math.floor(Date.now() / 1000).toString();

      try {
        const r = await fetch(hook.url, {
          method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT_MS),
          headers: {
            'Content-Type': 'application/json', 'User-Agent': 'Pointeuse-Webhook/1.0',
            'X-Pointeuse-Event': d.event, 'X-Pointeuse-Delivery': d.id, 'X-Pointeuse-Timestamp': ts,
            'X-Pointeuse-Signature': `sha256=${await sign(hook.secret, `${ts}.${body}`)}`,
          },
          body,
        });
        await r.body?.cancel();
        if (r.status >= 200 && r.status < 300) return finish(true, r.status, null);
        return finish(false, r.status, `Réponse HTTP ${r.status}.`);
      } catch (e) {
        return finish(false, null, e instanceof Error && e.name === 'TimeoutError' ? 'Pas de réponse en 10 s.' : 'Adresse injoignable.');
      }
    }));
  }
  return new Response(JSON.stringify({ sent, failed }), { headers: { 'Content-Type': 'application/json' } });
});
