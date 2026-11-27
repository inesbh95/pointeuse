-- Modules activables par entreprise (Tickets aujourd'hui, RH et autres demain).
-- Le pointage reste le cœur de l'application : il n'est pas un module.
--
--   modules          catalogue des modules disponibles sur le serveur
--   company_modules  modules activés pour chaque entreprise (seul le super-admin les change)
--
-- C'est le serveur qui décide : chaque règle d'accès d'un module vérifie has_module(),
-- masquer un écran dans l'application n'est qu'un confort.

create table public.modules (
  key          text primary key check (key ~ '^[a-z][a-z0-9_]{1,30}$'),
  label        text not null,
  description  text,
  position     smallint not null default 0
);

insert into public.modules (key, label, description, position) values
  ('tickets', 'Tickets', 'Tâches créées par l''administrateur, assignées et traitées par les employés (statuts, commentaires, photos).', 10);

create table public.company_modules (
  company_id  uuid not null references public.companies (id) on delete cascade,
  module_key  text not null references public.modules (key) on delete cascade,
  enabled     boolean not null default true,
  settings    jsonb not null default '{}',     -- options propres au module
  changed_by  uuid references public.profiles (id) on delete set null,
  changed_at  timestamptz not null default now(),
  primary key (company_id, module_key)
);

alter table public.modules enable row level security;
alter table public.company_modules enable row level security;

create policy "modules : lecture" on public.modules for select to authenticated using (true);
create policy "modules entreprise : lecture" on public.company_modules for select to authenticated
  using (company_id = public.my_company() or public.is_superadmin());
-- Aucune écriture directe : tout passe par set_company_module().
revoke insert, update, delete on public.modules, public.company_modules from authenticated, anon;

-- Le module est-il actif pour cette entreprise ?
create or replace function public.has_module(company uuid, mod text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.company_modules m
     where m.company_id = company and m.module_key = mod and m.enabled);
$$;
grant execute on function public.has_module(uuid, text) to authenticated, service_role;

-- Activation / désactivation : super-admin uniquement. Les données sont conservées.
create or replace function public.set_company_module(company uuid, mod text, enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_superadmin() then
    raise exception 'Seul le super-admin active ou désactive les modules.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.modules where key = mod) then
    raise exception 'Module inconnu.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.companies where id = company) then
    raise exception 'Entreprise introuvable.' using errcode = '22023';
  end if;
  insert into public.company_modules (company_id, module_key, enabled, changed_by, changed_at)
  values (company, mod, enabled, auth.uid(), now())
  on conflict (company_id, module_key)
  do update set enabled = excluded.enabled, changed_by = excluded.changed_by, changed_at = now();
end $$;

revoke all on function public.set_company_module(uuid, text, boolean) from public, anon;
grant execute on function public.set_company_module(uuid, text, boolean) to authenticated;
