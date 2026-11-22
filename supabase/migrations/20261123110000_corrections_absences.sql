-- Corrections de l'administrateur :
--   1. pointages saisis à la main (oubli de pointage), toujours signalés « saisi par l'admin » avec un motif ;
--   2. absences justifiées (congé, maladie, mission…) et jours fériés de l'entreprise.
-- Les feuilles de temps en tiennent compte (colonnes absence et manual).

-- ---------------------------------------------------------------------------
-- 1. Pointages saisis par l'administrateur
-- ---------------------------------------------------------------------------
alter table public.punches
  add column manual boolean not null default false,
  add column manual_by uuid references public.profiles (id) on delete set null,
  add column manual_reason text;

create or replace function public.add_manual_punch(p_user uuid, p_type text, p_ts timestamptz, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  c uuid;
  r text := trim(coalesce(p_reason, ''));
  new_id uuid;
begin
  select company_id into c from public.profiles where id = p_user and role <> 'superadmin';
  if c is null or not public.can_manage(c) then
    raise exception 'Employé introuvable.' using errcode = '42501';
  end if;
  if p_type not in ('in', 'out') then
    raise exception 'Type de pointage invalide.' using errcode = '22023';
  end if;
  if length(r) < 3 or length(r) > 300 then
    raise exception 'Indiquez un motif (3 à 300 caractères).' using errcode = '22023';
  end if;
  if p_ts > now() + interval '5 minutes' then
    raise exception 'Impossible de saisir un pointage dans le futur.' using errcode = '22023';
  end if;
  if p_ts < now() - interval '400 days' then
    raise exception 'Pointage trop ancien.' using errcode = '22023';
  end if;
  insert into public.punches (user_id, company_id, type, server_ts, status, flags, manual, manual_by, manual_reason)
  values (p_user, c, p_type, p_ts, 'ok', '[]', true, auth.uid(), r)
  returning id into new_id;
  return new_id;
end $$;

revoke all on function public.add_manual_punch(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.add_manual_punch(uuid, text, timestamptz, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Absences justifiées (user_id null = toute l'entreprise, ex. jour férié)
-- ---------------------------------------------------------------------------
create table public.absences (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  user_id uuid references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('conge_paye', 'maladie', 'sans_solde', 'mission', 'ferie', 'autre')),
  start_date date not null,
  end_date date not null,
  note text check (note is null or length(note) <= 300),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (end_date >= start_date and end_date - start_date <= 366)
);
create index on public.absences (company_id, start_date, end_date);
create index on public.absences (user_id, start_date);

alter table public.absences enable row level security;
-- L'admin voit les absences de son entreprise ; l'employé voit les siennes et les jours fériés.
create policy "absences : lecture" on public.absences for select to authenticated
  using (public.can_manage(company_id) or user_id = auth.uid() or (user_id is null and company_id = public.my_company()));

create or replace function public.add_absence(p_company uuid, p_user uuid, p_kind text, p_from date, p_to date, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if not public.can_manage(p_company) then
    raise exception 'Vous ne pouvez gérer que votre entreprise.' using errcode = '42501';
  end if;
  if p_user is not null and not exists (select 1 from public.profiles where id = p_user and company_id = p_company) then
    raise exception 'Employé introuvable.' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 366 then
    raise exception 'Période invalide (366 jours au maximum).' using errcode = '22023';
  end if;
  insert into public.absences (company_id, user_id, kind, start_date, end_date, note, created_by)
  values (p_company, p_user, p_kind, p_from, p_to, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.delete_absence(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  select company_id into c from public.absences where id = p_id;
  if c is null or not public.can_manage(c) then
    raise exception 'Absence introuvable.' using errcode = '42501';
  end if;
  delete from public.absences where id = p_id;
end $$;

revoke all on function public.add_absence(uuid, uuid, text, date, date, text) from public, anon;
revoke all on function public.delete_absence(uuid) from public, anon;
grant execute on function public.add_absence(uuid, uuid, text, date, date, text) to authenticated;
grant execute on function public.delete_absence(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Feuilles de temps : absences et pointages manuels
--   - absence : type d'absence couvrant ce jour (celle de l'employé prime sur celle de l'entreprise) ;
--   - jour férié : journée non travaillée (0 min prévue, tout le temps pointé est en heures sup) ;
--   - jour travaillé sans pointage mais avec absence : statut « justifie » au lieu de « absent » ;
--   - manual : nombre de pointages saisis par l'admin ce jour-là.
-- ---------------------------------------------------------------------------
drop function public.timesheet(uuid, date, date);
drop function public.timesheet_core(uuid, date, date);

create function public.timesheet_core(p_company uuid, p_from date, p_to date)
returns table (
  day date, user_id uuid, full_name text, matricule text, company_id uuid, company_name text,
  first_in timestamptz, last_out timestamptz, worked_min int, expected_min int,
  late_min int, overtime_min int, punches int, status text, absence text, manual int
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
    select pn.user_id, (pn.server_ts at time zone e.tz)::date as d, pn.type, pn.server_ts as ts, pn.manual,
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
           (count(*) filter (where pu.manual))::int as nman,
           (array_agg(pu.type order by pu.ts desc))[1] as last_type
      from pu
     group by pu.user_id, pu.d
  ),
  grid as (
    select e.*, g.d::date as d,
           (select ab.kind from public.absences ab
             where ab.company_id = e.company_id and (ab.user_id = e.id or ab.user_id is null)
               and g.d::date between ab.start_date and ab.end_date
             order by (ab.user_id is null), ab.created_at desc limit 1) as abs_kind
      from emp e
     cross join generate_series(p_from, p_to, interval '1 day') g(d)
  ),
  g2 as (
    select grid.*,
           (extract(isodow from grid.d)::smallint = any (grid.wdays)) and grid.abs_kind is distinct from 'ferie' as wd
      from grid
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
           when a.n is null and g.abs_kind is not null then 'justifie'
           when a.n is null then 'absent'
           when a.fin is null then 'entree_manquante'
           when a.last_type = 'in' then case when g.d = g.today then 'en_cours' else 'sortie_manquante' end
           else 'complet'
         end,
         g.abs_kind,
         coalesce(a.nman, 0)
    from g2 g
    left join agg a on a.user_id = g.id and a.d = g.d
   where g.d >= g.since and g.d <= g.today
     and (a.n is not null
          or (g.wd and not (g.d = g.today and g.now_t < g.t_out))
          -- jour férié tombant un jour habituellement travaillé : affiché comme « justifié »
          or (g.abs_kind = 'ferie' and extract(isodow from g.d)::smallint = any (g.wdays)))
   order by g.d, g.full_name;
end $$;

revoke all on function public.timesheet_core(uuid, date, date) from public, anon, authenticated;
grant execute on function public.timesheet_core(uuid, date, date) to service_role;

create function public.timesheet(p_company uuid, p_from date, p_to date)
returns table (
  day date, user_id uuid, full_name text, matricule text, company_id uuid, company_name text,
  first_in timestamptz, last_out timestamptz, worked_min int, expected_min int,
  late_min int, overtime_min int, punches int, status text, absence text, manual int
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

revoke all on function public.timesheet(uuid, date, date) from public, anon;
grant execute on function public.timesheet(uuid, date, date) to authenticated;
