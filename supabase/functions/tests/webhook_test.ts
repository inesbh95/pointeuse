// Tests de l'envoi des webhooks : deno test supabase/functions/tests/
import { deepStrictEqual as assertEquals } from 'node:assert';
import { blockedHost, nextDelayMin, sign } from '../webhook-dispatch/lib.ts';

Deno.test('signature HMAC-SHA256 (vecteur RFC 4231 n°2)', async () => {
  assertEquals(await sign('Jefe', 'what do ya want for nothing?'),
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
});

Deno.test('relances : 1, 5, 15 min… puis 12 h au plus', () => {
  assertEquals([1, 2, 3, 4, 7, 8, 20].map(nextDelayMin), [1, 5, 15, 60, 720, 720, 720]);
});

Deno.test('adresses privées refusées, publiques acceptées', () => {
  for (const h of ['localhost', 'api.localhost', '127.0.0.1', '10.1.2.3', '172.20.0.1', '192.168.1.10', '169.254.169.254', '100.64.0.1', '0.0.0.0', '[::1]', '2130706433', 'erp.internal']) {
    assertEquals(blockedHost(h), true, h);
  }
  for (const h of ['erp.example.com', '8.8.8.8', '172.32.0.1', 'odoo.client.tn']) assertEquals(blockedHost(h), false, h);
});
