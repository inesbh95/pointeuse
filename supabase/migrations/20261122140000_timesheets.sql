-- Feuilles de temps : une ligne par employé et par jour, calculée à partir des pointages
-- et des horaires de travail de l'entreprise. Sert à l'écran « Feuilles de temps »,
-- à l'export Excel et, plus tard, aux connecteurs ERP (Odoo, Sage, API).
--
-- Horaires de l'entreprise : notify_in (arrivée), notify_out (départ), notify_days (jours travaillés)
-- — les mêmes que pour les rappels — plus une tolérance de retard et un fuseau horaire.

alter table public.companies
  add column late_grace_min smallint not null default 5 check (late_grace_min between 0 and 120),
  add column timezone text not null default 'Africa/Tunis';

-- Réglage des horaires (admin de l'entreprise ou super-admin).
create or replace function public.set_company_schedule(
  company uuid, time_in time, time_out time, days smallint[], grace smallint, reminders boolean
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage(company) then
    raise exception 'Vous ne pouvez modifier que votre entreprise.' using errcode = '42501';
  end if;
  if time_out <= time_in then
    raise exception 'L''heure de départ doit être après l''heure d''arrivée.' using errcode = '22023';
  end if;
  if cardinality(days) = 0 then
    raise exception 'Choisissez au moins un jour travaillé.' using errcode = '22023';
  end if;
  update public.companies
     set notify_in = time_in, notify_out = time_out, notify_days = days,
         late_grace_min = grace, notify_enabled = reminders
   where id = company;
end $$;

revoke all on function public.set_company_schedule(uuid, time, time, smallint[], smallint, boolean) from public, anon;
grant execute on function public.set_company_schedule(uuid, time, time, smallint[], smallint, boolean) to authenticated;

-- Feuille de temps d'une entreprise (p_company null = toutes : super-admin seulement).
-- Règles :
--  * pointages pris en compte : acceptés ou à vérifier, et refusés validés par l'admin ; jamais les rejetés ;
--  * heures travaillées = somme des paires entrée → sortie de la journée (les pauses pointées sont déduites) ;
--  * retard = minutes entre l'heure d'arrivée prévue et la première entrée, au-delà de la tolérance ;
--  * heures sup = temps travaillé au-delà de la journée prévue (départ − arrivée) ;
--  * statut : complet, absent (jour travaillé sans pointage), sortie_manquante, entree_manquante,
--    en_cours (aujourd'hui, pas encore sorti) ; les jours non travaillés n'apparaissent que s'il y a des pointages ;
--  * une personne n'apparaît qu'à partir du jour de création de son compte, et jusqu'à aujourd'hui.
create or replace function public.timesheet(p_company uuid, p_from date, p_to date)
returns table (
  day date, user_id uuid, full_name text, matricule text, company_id uuid, company_name text,
  first_in timestamptz, last_out timestamptz, worked_min int, expected_min int,
  late_min int, overtime_min int, punches int, status text
) language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if p_company is null then
    if not public.is_superadmin() then
      raise exception 'Choisissez une entreprise.' using errcode = '42501';
    end if;
  elsif not public.can_manage(p_company) then
    raise exception 'Vous ne pouvez consulter que votre entreprise.' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 366 then
    raise exception 'Période invalide (366 jours au maximum).' using errcode = '22023';
  end if;

  return query
  with emp as (
    select p.id, p.full_name, p.matricule, p.company_id, c.name as cname, c.timezone as tz,
           c.notify_in as t_in, c.notify_out as t_out, c.notify_days as wdays, c.late_grace_min as grace,
           (p.created_at at time zone c.timezone)::date as since,
           (now() at time zone c.timezone)::date as today
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
     and (a.n is not null or g.wd)
   order by g.d, g.full_name;
end $$;

revoke all on function public.timesheet(uuid, date, date) from public, anon;
grant execute on function public.timesheet(uuid, date, date) to authenticated;
