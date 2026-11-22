-- Pointeuse missions : schéma initial
-- Principe : l'application n'écrit JAMAIS directement un pointage. Elle envoie les données brutes
-- à la fonction serveur « punch », qui refait tous les contrôles et insère le résultat avec la clé service.

-- ---------------------------------------------------------------------------
-- Profils (un par compte Supabase Auth)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null,
  matricule   text unique,
  role        text not null default 'employee' check (role in ('employee', 'admin')),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Crée automatiquement le profil quand un compte est créé (nom et matricule passés en métadonnées)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, matricule)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    nullif(upper(new.raw_user_meta_data ->> 'matricule'), '')
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and active);
$$;

-- ---------------------------------------------------------------------------
-- Sites clients
-- ---------------------------------------------------------------------------
create table public.sites (
  id          uuid primary key default gen_random_uuid(),
  client      text not null,
  name        text not null,
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  radius_m    integer not null default 200 check (radius_m between 20 and 5000),
  active      boolean not null default true,
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Gabarits de visage (vecteurs MobileFaceNet de 192 valeurs, normalisés)
-- Jamais lisibles par les employés.
-- ---------------------------------------------------------------------------
create table public.face_templates (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  embedding   real[] not null check (array_length(embedding, 1) = 192),
  created_by  uuid references public.profiles (id),
  created_at  timestamptz not null default now()
);
create index on public.face_templates (user_id);

-- ---------------------------------------------------------------------------
-- Défis à usage unique : empêchent de rejouer un ancien pointage et
-- servent de « nonce » au jeton Play Integrity.
-- ---------------------------------------------------------------------------
create table public.punch_challenges (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  nonce       text not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '3 minutes',
  used_at     timestamptz
);
create index on public.punch_challenges (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Pointages (y compris les tentatives refusées, pour l'audit)
-- ---------------------------------------------------------------------------
create table public.punches (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  type            text not null check (type in ('in', 'out')),
  server_ts       timestamptz not null default now(),   -- heure qui fait foi
  device_ts       timestamptz,
  lat             double precision,
  lng             double precision,
  accuracy_m      real,
  gps             jsonb,          -- relevés bruts
  site_id         uuid references public.sites (id) on delete set null,
  site_distance_m integer,
  address         text,
  ip              inet,
  ip_info         jsonb,          -- réponse du service de réputation IP
  device          jsonb,          -- plateforme, VPN actif, mode développeur, etc.
  integrity       jsonb,          -- verdict Play Integrity / App Attest
  face_similarity real,
  liveness        jsonb,
  photo_path      text,
  status          text not null check (status in ('ok', 'suspect', 'blocked')),
  flags           jsonb not null default '[]',
  reviewed_by     uuid references public.profiles (id),
  reviewed_at     timestamptz,
  review_note     text,
  review_decision text check (review_decision in ('approved', 'rejected'))
);
create index on public.punches (user_id, server_ts desc);
create index on public.punches (server_ts desc);
create index on public.punches (status) where status <> 'ok';

-- ---------------------------------------------------------------------------
-- Réglages (une seule ligne)
-- ---------------------------------------------------------------------------
create table public.settings (
  id     smallint primary key default 1 check (id = 1),
  rules  jsonb not null
);
insert into public.settings (rules) values ('{
  "vpnPolicy": "block",
  "offSitePolicy": "warn",
  "mockPolicy": "block",
  "integrityPolicy": "block",
  "devModePolicy": "warn",
  "netUnknownPolicy": "warn",
  "livenessPolicy": "block",
  "maxAccuracy": 100,
  "maxIpGpsKm": 300,
  "maxSpeedKmh": 200,
  "maxClockDriftSec": 180,
  "faceMinSimilarity": 0.6
}');

-- ---------------------------------------------------------------------------
-- Vue : heures par employé et par jour (tentatives refusées exclues)
-- ---------------------------------------------------------------------------
create or replace view public.daily_hours with (security_invoker = true) as
with ordered as (
  select p.*, (p.server_ts at time zone 'Africa/Tunis')::date as day,
         lead(p.type)      over w as next_type,
         lead(p.server_ts) over w as next_ts
  from public.punches p
  where p.status <> 'blocked' and coalesce(p.review_decision, 'approved') <> 'rejected'
  window w as (partition by p.user_id, (p.server_ts at time zone 'Africa/Tunis')::date order by p.server_ts)
)
select user_id, day,
       min(server_ts) filter (where type = 'in')  as first_in,
       max(server_ts) filter (where type = 'out') as last_out,
       sum(extract(epoch from next_ts - server_ts)) filter (where type = 'in' and next_type = 'out') / 3600.0 as hours,
       bool_or(status = 'suspect' and review_decision is null) as needs_review,
       array_agg(distinct site_id) filter (where site_id is not null) as site_ids
from ordered
group by user_id, day;

-- ---------------------------------------------------------------------------
-- Sécurité au niveau des lignes
-- ---------------------------------------------------------------------------
alter table public.profiles         enable row level security;
alter table public.sites            enable row level security;
alter table public.face_templates   enable row level security;
alter table public.punch_challenges enable row level security;
alter table public.punches          enable row level security;
alter table public.settings         enable row level security;

-- Profils : chacun lit le sien, l'admin lit et modifie tout
create policy "profil : lecture du sien" on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profil : admin modifie"   on public.profiles for update using (public.is_admin()) with check (public.is_admin());

-- Sites : lisibles par tout employé connecté, modifiables par l'admin
create policy "sites : lecture"      on public.sites for select to authenticated using (true);
create policy "sites : admin écrit"  on public.sites for all using (public.is_admin()) with check (public.is_admin());

-- Gabarits : admin uniquement (l'enrôlement passe par la fonction serveur)
create policy "gabarits : admin" on public.face_templates for select using (public.is_admin());

-- Défis : aucune politique → seule la clé service (fonctions serveur) y accède

-- Pointages : lecture des siens ; l'admin lit tout et renseigne la revue. Aucune insertion côté client.
create policy "pointages : lecture" on public.punches for select using (user_id = auth.uid() or public.is_admin());
create policy "pointages : revue admin" on public.punches for update using (public.is_admin()) with check (public.is_admin());

-- Seules les colonnes de revue sont modifiables, même par l'admin
revoke update on public.punches from authenticated;
grant update (reviewed_by, reviewed_at, review_note, review_decision) on public.punches to authenticated;

-- Un admin ne peut pas changer son propre rôle par erreur ; les employés ne modifient rien
revoke update on public.profiles from authenticated;
grant update (full_name, matricule, role, active) on public.profiles to authenticated;

create policy "réglages : lecture" on public.settings for select to authenticated using (true);
create policy "réglages : admin"   on public.settings for update using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- Stockage des photos de pointage : dossier privé par employé
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('punch-photos', 'punch-photos', false)
on conflict (id) do nothing;

create policy "photos : l'employé dépose dans son dossier" on storage.objects for insert to authenticated
  with check (bucket_id = 'punch-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos : lecture des siennes ou admin" on storage.objects for select to authenticated
  using (bucket_id = 'punch-photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
