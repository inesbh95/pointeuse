/** Signature HMAC-SHA256 en hexadécimal. */
export async function sign(secret: string, message: string) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Délai avant la relance suivante (minutes) : 1, 5, 15, 60, 180, 360, 720. */
export function nextDelayMin(attempts: number) {
  const steps = [1, 5, 15, 60, 180, 360, 720];
  return steps[Math.min(Math.max(attempts - 1, 0), steps.length - 1)];
}

/** Refuse les adresses locales ou privées (protection contre l'accès au réseau interne). */
export function blockedHost(host: string) {
  const h = host.toLowerCase().replace(/^\[|\]$/g, '');
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') || h.endsWith('.internal')) return true;
  if (h.includes(':')) return true; // IPv6 littérale : refusée (utiliser un nom de domaine)
  const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return /^\d+$/.test(h); // nombre seul (ex. 2130706433 = 127.0.0.1)
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}
