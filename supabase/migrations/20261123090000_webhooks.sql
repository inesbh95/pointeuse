-- Webhooks pour les ERP : à chaque pointage (et à chaque décision de l'admin), le serveur
-- envoie une requête POST signée (HMAC-SHA256) aux adresses déclarées par l'entreprise.
--
--   punches (insert / update review) ──trigger──► webhook_deliveries (file d'attente)
--                                                     │  pg_net : réveil immédiat
--                                                     │  pg_cron : toutes les minutes (relances)
--                                                     ▼
--                                    fonction « webhook-dispatch » ──POST signé──► ERP

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------------
-- Adresses de webhook (max 5 par entreprise). Le secret de signature n'est montré qu'une fois.
-- ---------------------------------------------------------------------------
create table public.webhooks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  url text not null check (url ~ '^https://[^\s/?#]+[^\s]*$' and length(url) <= 500),
  secret text not null,
  active boolean not null default true,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_status int,          -- code HTTP de la dernière tentative (null = erreur réseau)
  last_error text
);
create index on public.webhooks (company_id);

alter table public.webhooks enable row level security;
create policy "webhooks : lecture admin" on public.webhooks for select to authenticated
  using (public.can_manage(company_id));
-- Le secret n'est jamais relisible depuis l'app : lecture limitée aux autres colonnes.
revoke select on public.webhooks from authenticated, anon;
grant select (id, company_id, url, active, created_at, last_attempt_at, last_success_at, last_status, last_error)
  on public.webhooks to authenticated;

-- ---------------------------------------------------------------------------
-- File d'envoi : un événement par webhook, relancé jusqu'à 8 fois (≈ 1 jour).
-- ---------------------------------------------------------------------------
create table public.webhook_deliveries (
  id uuid primary key default gen_random_uuid(),
  webhook_id uuid not null references public.webhooks (id) on delete cascade,
  event text not null,                 -- punch.created | punch.reviewed | ping
  punch_id uuid references public.punches (id) on delete cascade,
  created_at timestamptz not null default now(),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  delivered_at timestamptz,
  failed_at timestamptz,               -- abandonné après la dernière relance
  last_status int,
  last_error text
);
create index webhook_deliveries_pending on public.webhook_deliveries (next_attempt_at)
  where delivered_at is null and failed_at is null;
alter table public.webhook_deliveries enable row level security;  -- serveur uniquement

-- ---------------------------------------------------------------------------
-- Réveil de la fonction d'envoi (immédiat). Adresse et secret lus dans le coffre (vault).
-- ---------------------------------------------------------------------------
create or replace function public.webhook_kick()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  u text := (select decrypted_secret from vault.decrypted_secrets where name = 'webhook_dispatch_url');
  s text := (select decrypted_secret from vault.decrypted_secrets where name = 'webhook_dispatch_secret');
begin
  if u is null or s is null then return; end if;
  perform net.http_post(url := u, body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Dispatch-Secret', s),
    timeout_milliseconds := 2000);
exception when others then
  null;  -- un réveil raté n'empêche jamais un pointage : pg_cron reprendra la file
end $$;
revoke all on function public.webhook_kick() from public, anon, authenticated;

create or replace function public.webhook_enqueue()
returns trigger language plpgsql security definer set search_path = public as $$
declare ev text;
begin
  if tg_op = 'INSERT' then ev := 'punch.created';
  elsif new.review_decision is distinct from old.review_decision and new.review_decision is not null then ev := 'punch.reviewed';
  else return new;
  end if;
  insert into public.webhook_deliveries (webhook_id, event, punch_id)
  select w.id, ev, new.id from public.webhooks w where w.company_id = new.company_id and w.active;
  if found then perform public.webhook_kick(); end if;
  return new;
end $$;

create trigger punches_webhook after insert or update of review_decision on public.punches
  for each row execute function public.webhook_enqueue();

-- ---------------------------------------------------------------------------
-- Gestion par l'admin
-- ---------------------------------------------------------------------------
create or replace function public.create_webhook(company uuid, url text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare s text := 'whsec_' || encode(gen_random_bytes(24), 'hex');
begin
  if not public.can_manage(company) then
    raise exception 'Vous ne pouvez gérer que votre entreprise.' using errcode = '42501';
  end if;
  if url !~ '^https://[^\s/?#]+[^\s]*$' or length(url) > 500 then
    raise exception 'Adresse invalide : elle doit commencer par https://' using errcode = '22023';
  end if;
  if (select count(*) from public.webhooks w where w.company_id = company) >= 5 then
    raise exception 'Maximum 5 webhooks par entreprise.' using errcode = '22023';
  end if;
  insert into public.webhooks (company_id, url, secret, created_by) values (company, trim(url), s, auth.uid());
  return s;  -- montré une seule fois
end $$;

create or replace function public.set_webhook_active(hook uuid, enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  select company_id into c from public.webhooks where id = hook;
  if c is null or not public.can_manage(c) then raise exception 'Webhook introuvable.' using errcode = '42501'; end if;
  update public.webhooks set active = enabled where id = hook;
end $$;

create or replace function public.delete_webhook(hook uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  select company_id into c from public.webhooks where id = hook;
  if c is null or not public.can_manage(c) then raise exception 'Webhook introuvable.' using errcode = '42501'; end if;
  delete from public.webhooks where id = hook;
end $$;

-- Envoie un événement « ping » pour tester l'adresse.
create or replace function public.test_webhook(hook uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  select company_id into c from public.webhooks where id = hook;
  if c is null or not public.can_manage(c) then raise exception 'Webhook introuvable.' using errcode = '42501'; end if;
  insert into public.webhook_deliveries (webhook_id, event) values (hook, 'ping');
  perform public.webhook_kick();
end $$;

-- Réservation atomique des envois à faire (appelée par la fonction d'envoi).
create or replace function public.webhook_claim(max_rows int default 50)
returns setof public.webhook_deliveries language sql security definer set search_path = public as $$
  update public.webhook_deliveries d set locked_until = now() + interval '1 minute', attempts = d.attempts + 1
  where d.id in (
    select id from public.webhook_deliveries
    where delivered_at is null and failed_at is null and next_attempt_at <= now()
      and (locked_until is null or locked_until < now())
    order by created_at limit max_rows for update skip locked)
  returning d.*;
$$;

revoke all on function public.create_webhook(uuid, text) from public, anon;
revoke all on function public.set_webhook_active(uuid, boolean) from public, anon;
revoke all on function public.delete_webhook(uuid) from public, anon;
revoke all on function public.test_webhook(uuid) from public, anon;
revoke all on function public.webhook_claim(int) from public, anon, authenticated;
grant execute on function public.create_webhook(uuid, text) to authenticated;
grant execute on function public.set_webhook_active(uuid, boolean) to authenticated;
grant execute on function public.delete_webhook(uuid) to authenticated;
grant execute on function public.test_webhook(uuid) to authenticated;
grant execute on function public.webhook_claim(int) to service_role;

-- Relances : toutes les minutes, s'il reste des envois en attente.
select cron.schedule('webhook-dispatch', '* * * * *', $$
  select public.webhook_kick() where exists (
    select 1 from public.webhook_deliveries
    where delivered_at is null and failed_at is null and next_attempt_at <= now())
$$);

-- Ménage : les envois réussis ou abandonnés de plus de 30 jours sont supprimés (chaque nuit).
select cron.schedule('webhook-cleanup', '17 3 * * *', $$
  delete from public.webhook_deliveries
  where (delivered_at is not null or failed_at is not null) and created_at < now() - interval '30 days'
$$);
