// Tests du module Tickets (API ERP) : deno test supabase/functions/tests/
import { deepStrictEqual as assertEquals } from 'node:assert';
import { formatTicket, readTicketInput } from '../_shared/tickets.ts';

Deno.test('import : champs acceptés, nombres convertis', () => {
  assertEquals(readTicketInput({ source: 'odoo', external_id: 42, title: 'Fuite', assignee_matricule: 'M01', due_date: null }), {
    input: { source: 'odoo', external_id: '42', title: 'Fuite', assignee_matricule: 'M01', due_date: null },
  });
});

Deno.test('import : le statut ne passe pas par l\'API', () => {
  const r = readTicketInput({ title: 'Fuite', status: 'done' });
  assertEquals('error' in r && r.error.includes('status'), true);
});

Deno.test('import : titre obligatoire sans external_id, refus des objets', () => {
  assertEquals('error' in readTicketInput({ description: 'x' }), true);
  assertEquals('error' in readTicketInput([]), true);
  assertEquals('error' in readTicketInput(null), true);
  assertEquals('error' in readTicketInput({ title: { a: 1 } }), true);
  assertEquals('error' in readTicketInput({ external_id: null, title: 'x' }), true);
  // Mise à jour d'un ticket importé : le titre peut être omis
  assertEquals(readTicketInput({ source: 'odoo', external_id: '42', priority: 'high' }), {
    input: { source: 'odoo', external_id: '42', priority: 'high' },
  });
});

Deno.test('format : clé TK-n et assigné', () => {
  const t = formatTicket({
    id: 'u1', number: 7, title: 'Porte', description: null, type: 'task', priority: 'high', status: 'review',
    due_date: '2026-12-01', blocked_reason: null, created_at: 'c', updated_at: 'u', started_at: 's', done_at: null,
    source: 'internal', external_id: null, external_url: null,
    assignee: { id: 'e1', matricule: 'M01', full_name: 'Ali', extra: 'x' },
  });
  assertEquals(t.key, 'TK-7');
  assertEquals(t.assignee, { id: 'e1', matricule: 'M01', full_name: 'Ali' });
});
