-- iPhone : clés App Attest certifiées par Apple (une par installation de l'application).
-- Lecture et écriture par le serveur uniquement (fonction « punch »).
create table public.ios_app_keys (
  key_id text primary key,            -- identifiant de la clé (base64), donné par iOS
  user_id uuid references public.profiles (id) on delete set null,  -- employé du premier pointage
  public_key text not null,           -- clé publique P-256 (SPKI, base64)
  counter bigint not null default 0,  -- compteur anti-rejeu, strictement croissant
  env text not null check (env in ('production', 'development')),
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
alter table public.ios_app_keys enable row level security;  -- aucune règle : inaccessible depuis l'app
