-- Une seule application : la gestion des sites clients devient une option par entreprise.
--   activée   : pointage rattaché au site le plus proche, contrôle « hors site »
--   désactivée: pas de notion de site, seule l'adresse du lieu est affichée
-- C'est le serveur qui décide (fonction punch), pas l'application.

alter table public.companies add column sites_enabled boolean not null default false;

-- Les entreprises qui ont déjà des sites gardent leur fonctionnement.
update public.companies c set sites_enabled = true
 where exists (select 1 from public.sites s where s.company_id = c.id and s.active);

create or replace function public.set_company_sites(company uuid, enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage(company) then
    raise exception 'Vous ne pouvez modifier que votre entreprise.' using errcode = '42501';
  end if;
  update public.companies set sites_enabled = enabled where id = company;
end $$;

revoke all on function public.set_company_sites(uuid, boolean) from public, anon;
grant execute on function public.set_company_sites(uuid, boolean) to authenticated;
