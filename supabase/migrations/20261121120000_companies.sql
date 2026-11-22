-- Plusieurs entreprises sur un même serveur.
-- Chaque employé appartient à une entreprise ; un admin ne voit et ne gère que la sienne.
-- Le super-admin (rôle « superadmin ») crée les entreprises et voit tout.

-- ---------------------------------------------------------------------------
-- Entreprises
-- ---------------------------------------------------------------------------
create table public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (length(trim(name)) >= 2),
  active      boolean not null default true,
  rules       jsonb not null default '{}',   -- réglages propres à l'entreprise (priment sur « settings »)
  created_at  timestamptz not null default now()
);

-- Les données existantes vont dans une première entreprise
insert into public.companies (name) values ('Entreprise principale');

-- ---------------------------------------------------------------------------
-- Rattachement des employés, sites et pointages
-- ---------------------------------------------------------------------------
alter table public.profiles add column company_id uuid references public.companies (id);
update public.profiles set company_id = (select id from public.companies where name = 'Entreprise principale');
alter table public.profiles alter column company_id set not null;
create index on public.profiles (company_id);

alter table public.profiles drop constraint profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('employee', 'admin', 'superadmin'));

-- Un matricule est unique dans une entreprise, pas sur tout le serveur
alter table public.profiles drop constraint profiles_matricule_key;
alter table public.profiles add constraint profiles_company_matricule_key unique (company_id, matricule);

-- Le premier administrateur devient super-admin
update public.profiles set role = 'superadmin'
where id = (select id from public.profiles where role = 'admin' order by created_at limit 1);

alter table public.sites add column company_id uuid references public.companies (id);
update public.sites set company_id = (select id from public.companies where name = 'Entreprise principale');
alter table public.sites alter column company_id set not null;
create index on public.sites (company_id);

alter table public.punches add column company_id uuid references public.companies (id);
update public.punches p set company_id = pr.company_id from public.profiles pr where pr.id = p.user_id;
alter table public.punches alter column company_id set not null;
create index on public.punches (company_id, server_ts desc);

-- ---------------------------------------------------------------------------
-- Fonctions d'accès
-- ---------------------------------------------------------------------------
create or replace function public.my_company()
returns uuid language sql stable security definer set search_path = public as $$
  select company_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_superadmin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'superadmin' and active);
$$;

-- Admin d'une entreprise ou super-admin
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'superadmin') and active);
$$;

-- L'appelant peut-il gérer les données de cette entreprise ?
create or replace function public.can_manage(company uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_superadmin() or (public.is_admin() and company = public.my_company());
$$;

-- Les sites créés depuis l'application vont dans l'entreprise de l'admin
alter table public.sites alter column company_id set default public.my_company();

-- Nouveau compte : l'entreprise vient des app_metadata (posées uniquement par le serveur).
-- Sans entreprise, la création du compte échoue : impossible de s'inscrire seul.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  company uuid := nullif(new.raw_app_meta_data ->> 'company_id', '')::uuid;
begin
  if company is null then
    raise exception 'Compte sans entreprise : création réservée aux administrateurs.';
  end if;
  insert into public.profiles (id, full_name, matricule, company_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    nullif(upper(new.raw_user_meta_data ->> 'matricule'), ''),
    company
  );
  return new;
end $$;

-- Un admin ne peut ni nommer un super-admin, ni modifier un super-admin
create or replace function public.guard_profile_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.role() = 'service_role' or public.is_superadmin() then return new; end if;
  if new.role = 'superadmin' or old.role = 'superadmin' then
    raise exception 'Seul le super-admin peut gérer ce compte.';
  end if;
  return new;
end $$;

create trigger guard_profile_update
  before update on public.profiles
  for each row execute function public.guard_profile_update();

-- ---------------------------------------------------------------------------
-- Règles d'accès
-- ---------------------------------------------------------------------------
alter table public.companies enable row level security;

create policy "entreprises : lecture" on public.companies for select to authenticated
  using (id = public.my_company() or public.is_superadmin());
create policy "entreprises : super-admin écrit" on public.companies for all
  using (public.is_superadmin()) with check (public.is_superadmin());

drop policy "profil : lecture du sien" on public.profiles;
drop policy "profil : admin modifie" on public.profiles;
create policy "profil : lecture" on public.profiles for select
  using (id = auth.uid() or public.can_manage(company_id));
create policy "profil : admin modifie" on public.profiles for update
  using (public.can_manage(company_id)) with check (public.can_manage(company_id));

drop policy "sites : lecture" on public.sites;
drop policy "sites : admin écrit" on public.sites;
create policy "sites : lecture" on public.sites for select to authenticated
  using (company_id = public.my_company() or public.is_superadmin());
create policy "sites : admin écrit" on public.sites for all
  using (public.can_manage(company_id)) with check (public.can_manage(company_id));

drop policy "gabarits : admin" on public.face_templates;
create policy "gabarits : admin" on public.face_templates for select
  using (exists (select 1 from public.profiles p where p.id = user_id and public.can_manage(p.company_id)));

drop policy "pointages : lecture" on public.punches;
drop policy "pointages : revue admin" on public.punches;
create policy "pointages : lecture" on public.punches for select
  using (user_id = auth.uid() or public.can_manage(company_id));
create policy "pointages : revue admin" on public.punches for update
  using (public.can_manage(company_id)) with check (public.can_manage(company_id));

-- Réglages communs : seul le super-admin les modifie (chaque entreprise a les siens dans companies.rules)
drop policy "réglages : admin" on public.settings;
create policy "réglages : super-admin" on public.settings for update
  using (public.is_superadmin()) with check (public.is_superadmin());

drop policy "photos : lecture des siennes ou admin" on storage.objects;
create policy "photos : lecture des siennes ou admin" on storage.objects for select to authenticated
  using (bucket_id = 'punch-photos' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.profiles p where p.id::text = (storage.foldername(name))[1] and public.can_manage(p.company_id))
  ));
