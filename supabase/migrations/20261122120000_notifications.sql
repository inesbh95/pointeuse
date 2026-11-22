-- Rappels de pointage par entreprise : activés ou non, heure d'arrivée, heure de départ, jours.
-- Les téléphones des employés programment eux-mêmes les rappels à partir de ces réglages.

alter table public.companies
  add column notify_enabled boolean not null default false,
  add column notify_in time not null default '08:00',
  add column notify_out time not null default '17:00',
  -- Jours ISO : 1 = lundi … 7 = dimanche
  add column notify_days smallint[] not null default '{1,2,3,4,5}'
    check (notify_days <@ array[1,2,3,4,5,6,7]::smallint[]);

-- L'admin d'une entreprise (ou le super-admin) modifie uniquement ces réglages,
-- sans avoir le droit d'écrire le reste de la table companies.
create or replace function public.set_company_notifications(
  company uuid, enabled boolean, time_in time, time_out time, days smallint[]
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage(company) then
    raise exception 'Vous ne pouvez modifier que votre entreprise.' using errcode = '42501';
  end if;
  if cardinality(days) = 0 and enabled then
    raise exception 'Choisissez au moins un jour.' using errcode = '22023';
  end if;
  update public.companies
     set notify_enabled = enabled, notify_in = time_in, notify_out = time_out, notify_days = days
   where id = company;
end $$;

revoke all on function public.set_company_notifications(uuid, boolean, time, time, smallint[]) from public, anon;
grant execute on function public.set_company_notifications(uuid, boolean, time, time, smallint[]) to authenticated;
