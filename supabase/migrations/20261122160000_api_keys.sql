-- API pour les ERP : clés d'API par entreprise, et calcul des feuilles de temps
-- utilisable par le serveur (fonction « api ») sans utilisateur connecté.

-- ---------------------------------------------------------------------------
-- Clés d'API : seule l'empreinte SHA-256 est stockée ; la clé n'est montrée qu'une fois.
-- ---------------------------------------------------------------------------
create table public.api_keys (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  label text not null check (length(trim(label)) between 1 and 80),
  prefix text not null,                -- début de la clé, pour la reconnaître (ptk_ab12cd34…)
  key_hash text not null unique,       -- sha256 hex
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
create index on public.api_keys (company_id);

alter table public.api_keys enable row level security;
-- Lecture par l'admin de l'entreprise (jamais l'empreinte côté app : elle ne la sélectionne pas).
create policy "clés api : lecture admin" on public.api_keys for select to authenticated
  using (public.can_manage(company_id));
-- Pas d'écriture directe : création et révocation passent par les fonctions ci-dessous.

create or replace function public.create_api_key(company uuid, label text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  k text := 'ptk_' || encode(gen_random_bytes(24), 'hex');
begin
  if not public.can_manage(company) then
    raise exception 'Vous ne pouvez gérer que votre entreprise.' using errcode = '42501';
  end if;
  if (select count(*) from public.api_keys a where a.company_id = company and a.revoked_at is null) >= 10 then
    raise exception 'Maximum 10 clés actives par entreprise : révoquez-en une.' using errcode = '22023';
  end if;
  insert into public.api_keys (company_id, label, prefix, key_hash, created_by)
  values (company, trim(label), left(k, 12), encode(digest(k, 'sha256'), 'hex'), auth.uid());
  return k;  -- montrée une seule fois
end $$;

create or replace function public.revoke_api_key(key_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  select company_id into c from public.api_keys where id = key_id;
  if c is null or not public.can_manage(c) then
    raise exception 'Clé introuvable.' using errcode = '42501';
  end if;
  update public.api_keys set revoked_at = now() where id = key_id and revoked_at is null;
end $$;

revoke all on function public.create_api_key(uuid, text) from public, anon;
revoke all on function public.revoke_api_key(uuid) from public, anon;
grant execute on function public.create_api_key(uuid, text) to authenticated;
grant execute on function public.revoke_api_key(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Feuilles de temps : calcul séparé des contrôles d'accès.
--   timesheet_core : calcul seul, réservé au serveur (service_role) ;
--   timesheet      : contrôle de l'utilisateur connecté puis calcul (app et web).
-- ---------------------------------------------------------------------------
create or replace function public.timesheet_core(p_company uuid, p_from date, p_to date)
returns table (
  day date, user_id uuid, full_name text, matricule text, company_id uuid, company_name text,
  first_in timestamptz, last_out timestamptz, worked_min int, expected_min int,
  late_min int, overtime_min int, punches int, status text
) language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if p_to < p_from or p_to - p_from > 366 then
    raise exception 'Période invalide (366 jours au maximum).' using errcode = '22023';
  end if;

  return query
  with emp as (
    select p.id, p.full_name, p.matricule, p.company_id, c.name as cname, c.timezone as tz,
           c.notify_in as t_in, c.notify_out as t_out, c.notify_days as wdays, c.late_grace_min as grace,
           (p.created_at at time zone c.timezone)::date as since,
           (now() at time zone c.timezone)::date as today,
           (now() at time zone c.timezone)::time as now_t
      from public.profiles p
      join public.companies c on c.id = p.company_id
     where p.active and p.role <> 'superadmin'
       and (p_company is null or p.company_id = p_company)
  ),
  pu as (
    select pn.user_id, (pn.server_ts at time zone e.tz)::date as d, pn.type, pn.server_ts as ts,
           lead(pn.type) over w as ntype, lead(pn.server_ts) over w as nts
      from public.punches pn
      join emp e on e.id = pn.user_id
     where pn.server_ts >= p_from::timestamptz - interval '1 day'
       and pn.server_ts <  (p_to + 2)::timestamptz
       and (pn.status <> 'blocked' or pn.review_decision = 'approved')
       and pn.review_decision is distinct from 'rejected'
    window w as (partition by pn.user_id, (pn.server_ts at time zone e.tz)::date order by pn.server_ts)
  ),
  agg as (
    select pu.user_id, pu.d,
           min(pu.ts) filter (where pu.type = 'in') as fin,
           max(pu.ts) filter (where pu.type = 'out') as lout,
           (coalesce(sum(extract(epoch from pu.nts - pu.ts)) filter (where pu.type = 'in' and pu.ntype = 'out'), 0) / 60)::int as wmin,
           count(*)::int as n,
           (array_agg(pu.type order by pu.ts desc))[1] as last_type
      from pu
     group by pu.user_id, pu.d
  ),
  grid as (
    select e.*, g.d::date as d, extract(isodow from g.d)::smallint = any (e.wdays) as wd
      from emp e
     cross join generate_series(p_from, p_to, interval '1 day') g(d)
  )
  select g.d, g.id, g.full_name, g.matricule, g.company_id, g.cname,
         a.fin, a.lout,
         coalesce(a.wmin, 0),
         case when g.wd then (extract(epoch from g.t_out - g.t_in) / 60)::int else 0 end,
         case
           when g.wd and a.fin is not null
            and extract(epoch from (a.fin at time zone g.tz)::time - g.t_in) / 60 > g.grace
           then (extract(epoch from (a.fin at time zone g.tz)::time - g.t_in) / 60)::int
           else 0
         end,
         greatest(0, coalesce(a.wmin, 0) - case when g.wd then (extract(epoch from g.t_out - g.t_in) / 60)::int else 0 end),
         coalesce(a.n, 0),
         case
           when a.n is null then 'absent'
           when a.fin is null then 'entree_manquante'
           when a.last_type = 'in' then case when g.d = g.today then 'en_cours' else 'sortie_manquante' end
           else 'complet'
         end
    from grid g
    left join agg a on a.user_id = g.id and a.d = g.d
   where g.d >= g.since and g.d <= g.today
     and (a.n is not null or (g.wd and not (g.d = g.today and g.now_t < g.t_out)))
   order by g.d, g.full_name;
end $$;

revoke all on function public.timesheet_core(uuid, date, date) from public, anon, authenticated;
grant execute on function public.timesheet_core(uuid, date, date) to service_role;

create or replace function public.timesheet(p_company uuid, p_from date, p_to date)
returns table (
  day date, user_id uuid, full_name text, matricule text, company_id uuid, company_name text,
  first_in timestamptz, last_out timestamptz, worked_min int, expected_min int,
  late_min int, overtime_min int, punches int, status text
) language plpgsql stable security definer set search_path = public as $$
begin
  if p_company is null then
    if not public.is_superadmin() then
      raise exception 'Choisissez une entreprise.' using errcode = '42501';
    end if;
  elsif not public.can_manage(p_company) then
    raise exception 'Vous ne pouvez consulter que votre entreprise.' using errcode = '42501';
  end if;
  return query select * from public.timesheet_core(p_company, p_from, p_to);
end $$;
