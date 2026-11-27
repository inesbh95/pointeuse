// Module Tickets : format exposé aux ERP (API /v1/tickets) et lecture des données reçues.

export const TICKET_SELECT =
  'id, number, title, description, type, priority, status, due_date, blocked_reason, ' +
  'created_at, updated_at, started_at, done_at, source, external_id, external_url, ' +
  'assignee:profiles!ticket_tickets_assignee_id_fkey(id, matricule, full_name)';

// deno-lint-ignore no-explicit-any
export function formatTicket(t: any) {
  return {
    id: t.id, key: `TK-${t.number}`, number: t.number,
    title: t.title, description: t.description, type: t.type, priority: t.priority, status: t.status,
    assignee: t.assignee ? { id: t.assignee.id, matricule: t.assignee.matricule, full_name: t.assignee.full_name } : null,
    due_date: t.due_date, blocked_reason: t.blocked_reason,
    created_at: t.created_at, updated_at: t.updated_at, started_at: t.started_at, done_at: t.done_at,
    source: t.source, external_id: t.external_id, external_url: t.external_url,
  };
}

export const TICKET_STATUSES = ['todo', 'in_progress', 'blocked', 'review', 'done', 'cancelled'] as const;

const FIELDS = ['title', 'description', 'type', 'priority', 'due_date', 'assignee_id', 'assignee_matricule',
  'source', 'external_id', 'external_url'] as const;

/** Champs acceptés pour créer / mettre à jour un ticket. Renvoie un message d'erreur ou les champs retenus.
 *  Les contrôles métier (longueurs, employé, module…) sont refaits par la base. */
export function readTicketInput(body: unknown): { error: string } | { input: Record<string, string | null> } {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: 'Corps JSON attendu : un objet.' };
  const b = body as Record<string, unknown>;
  const unknown = Object.keys(b).filter((k) => !(FIELDS as readonly string[]).includes(k));
  if (unknown.length) return { error: `Champ inconnu : ${unknown.join(', ')}. Le statut ne se modifie pas par l'API.` };
  const input: Record<string, string | null> = {};
  for (const k of FIELDS) {
    if (!(k in b)) continue;
    const v = b[k];
    if (v === null) input[k] = null;
    else if (typeof v === 'string' || typeof v === 'number') input[k] = String(v);
    else return { error: `${k} doit être une chaîne de caractères.` };
  }
  if (input.external_id == null && 'external_id' in b) return { error: 'external_id ne peut pas être null.' };
  if (!('external_id' in input) && !input.title) return { error: 'title obligatoire.' };
  return { input };
}
