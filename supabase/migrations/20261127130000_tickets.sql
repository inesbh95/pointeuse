-- Module Tickets (V1) : l'administrateur crée un ticket et l'assigne ; l'employé assigné le traite
-- depuis l'app mobile (statut, commentaires, photos). L'employé ne crée pas de ticket.
--
--   À faire ─► En cours ─► En revue ─► Terminé          (l'admin valide)
--                 │  ▲         │
--                 ▼  │         └──► En cours           (rouvert)
--               Bloqué (motif obligatoire)
--   L'admin peut mettre n'importe quel statut (dont Annulé), l'employé suit les flèches ci-dessus.
--
-- Prévu pour l'import depuis Odoo ou un autre système : source, external_id, external_url.
-- Règle : le système d'origine fait foi pour le titre et la description,
--         la Pointeuse fait foi pour le statut et les commentaires.
--
-- Aucune écriture directe depuis l'application : uniquement les fonctions ticket_* ci-dessous.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.ticket_counters (
  company_id  uuid primary key references public.companies (id) on delete cascade,
  last        int not null default 0
);

create table public.ticket_tickets (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies (id) on delete cascade,
  number          int not null,                                   -- TK-<number>, par entreprise
  title           text not null check (length(trim(title)) between 3 and 200),
  description     text check (description is null or length(description) <= 10000),
  type            text not null default 'task' check (type in ('task', 'incident', 'request', 'bug')),
  priority        text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  status          text not null default 'todo'
                  check (status in ('todo', 'in_progress', 'blocked', 'review', 'done', 'cancelled')),
  assignee_id     uuid references public.profiles (id) on delete set null,
  due_date        date,
  blocked_reason  text,
  created_by      uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  started_at      timestamptz,          -- premier passage « En cours »
  done_at         timestamptz,          -- passage « Terminé »
  -- Origine (import Odoo, Jira, ERP… plus tard)
  source          text not null default 'internal' check (source ~ '^[a-z][a-z0-9_]{1,30}$'),
  external_id     text check (external_id is null or length(external_id) <= 200),
  external_url    text check (external_url is null or (external_url ~ '^https?://' and length(external_url) <= 500)),
  unique (company_id, number)
);
create unique index ticket_tickets_external on public.ticket_tickets (company_id, source, external_id)
  where external_id is not null;
create index on public.ticket_tickets (company_id, status);
create index on public.ticket_tickets (assignee_id, status);
create index on public.ticket_tickets (company_id, updated_at desc);

create table public.ticket_comments (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.ticket_tickets (id) on delete cascade,
  company_id   uuid not null references public.companies (id) on delete cascade,
  author_id    uuid references public.profiles (id) on delete set null,   -- null = système externe (API)
  body         text not null check (length(trim(body)) between 1 and 5000),
  is_internal  boolean not null default false,   -- note interne : jamais visible par l'employé
  created_at   timestamptz not null default now()
);
create index on public.ticket_comments (ticket_id, created_at);

create table public.ticket_attachments (
  id            uuid primary key default gen_random_uuid(),
  ticket_id     uuid not null references public.ticket_tickets (id) on delete cascade,
  comment_id    uuid references public.ticket_comments (id) on delete cascade,
  company_id    uuid not null references public.companies (id) on delete cascade,
  storage_path  text not null unique,             -- <ticket_id>/<fichier> dans le stockage « ticket-files »
  file_name     text not null check (length(file_name) between 1 and 200),
  mime          text,
  size_bytes    int check (size_bytes is null or size_bytes between 0 and 10485760),
  uploaded_by   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index on public.ticket_attachments (ticket_id);

-- Historique : création, assignation, statut, modification, commentaire, note interne
create table public.ticket_events (
  id          uuid primary key default gen_random_uuid(),
  ticket_id   uuid not null references public.ticket_tickets (id) on delete cascade,
  company_id  uuid not null references public.companies (id) on delete cascade,
  actor_id    uuid references public.profiles (id) on delete set null,     -- null = API / système externe
  kind        text not null check (kind in ('created', 'assigned', 'status', 'updated', 'comment', 'note')),
  from_value  text,
  to_value    text,
  note        text,
  created_at  timestamptz not null default now()
);
create index on public.ticket_events (ticket_id, created_at);

-- ---------------------------------------------------------------------------
-- Règles d'accès : lecture seule depuis l'application
--   employé : les tickets qui lui sont assignés, sans les notes internes
--   admin   : tous les tickets de son entreprise (super-admin : toutes)
--   et seulement si le module est actif pour l'entreprise
-- ---------------------------------------------------------------------------
alter table public.ticket_counters    enable row level security;   -- serveur uniquement
alter table public.ticket_tickets     enable row level security;
alter table public.ticket_comments    enable row level security;
alter table public.ticket_attachments enable row level security;
alter table public.ticket_events      enable row level security;

revoke insert, update, delete on public.ticket_counters, public.ticket_tickets, public.ticket_comments,
  public.ticket_attachments, public.ticket_events from authenticated, anon;
revoke select on public.ticket_counters from authenticated, anon;

create policy "tickets : lecture" on public.ticket_tickets for select to authenticated
  using (public.has_module(company_id, 'tickets') and (assignee_id = auth.uid() or public.can_manage(company_id)));

-- Les sous-requêtes sur ticket_tickets passent elles-mêmes par la règle ci-dessus.
create policy "tickets commentaires : lecture" on public.ticket_comments for select to authenticated
  using (exists (select 1 from public.ticket_tickets t where t.id = ticket_id)
         and (not is_internal or public.can_manage(company_id)));

create policy "tickets fichiers : lecture" on public.ticket_attachments for select to authenticated
  using (exists (select 1 from public.ticket_tickets t where t.id = ticket_id)
         and (comment_id is null or exists (select 1 from public.ticket_comments c where c.id = comment_id)));

create policy "tickets historique : lecture" on public.ticket_events for select to authenticated
  using (exists (select 1 from public.ticket_tickets t where t.id = ticket_id)
         and (kind <> 'note' or public.can_manage(company_id)));

-- ---------------------------------------------------------------------------
-- Fonctions internes (non appelables depuis l'application)
-- ---------------------------------------------------------------------------

-- L'utilisateur connecté peut-il voir (et donc traiter / commenter) ce ticket ?
create or replace function public.ticket_access(p_ticket text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.ticket_tickets t
     where t.id::text = p_ticket
       and public.has_module(t.company_id, 'tickets')
       and (t.assignee_id = auth.uid() or public.can_manage(t.company_id)));
$$;
grant execute on function public.ticket_access(text) to authenticated;

-- Transitions de statut autorisées. Même tableau dans les applications (boutons affichés).
create or replace function public.ticket_transition_allowed(p_from text, p_to text, p_admin boolean)
returns boolean language sql immutable as $$
  select p_from is distinct from p_to
     and p_to in ('todo', 'in_progress', 'blocked', 'review', 'done', 'cancelled')
     and (p_admin or (p_from, p_to) in (
           ('todo', 'in_progress'),
           ('in_progress', 'blocked'), ('in_progress', 'review'),
           ('blocked', 'in_progress'),
           ('review', 'in_progress')));
$$;

create or replace function public.ticket_log(p_ticket public.ticket_tickets, p_actor uuid, p_kind text,
                                             p_from text, p_to text, p_note text)
returns void language sql security definer set search_path = public as $$
  insert into public.ticket_events (ticket_id, company_id, actor_id, kind, from_value, to_value, note)
  values (p_ticket.id, p_ticket.company_id, p_actor, p_kind, p_from, p_to, p_note);
$$;

-- Employé assignable : actif, de la même entreprise, pas le super-admin.
create or replace function public.ticket_check_assignee(p_company uuid, p_assignee uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if p_assignee is not null and not exists (
       select 1 from public.profiles
        where id = p_assignee and company_id = p_company and active and role <> 'superadmin') then
    raise exception 'Employé introuvable dans cette entreprise.' using errcode = '22023';
  end if;
end $$;

-- Création ou modification (sans contrôle de droits : fait par l'appelant).
create or replace function public.ticket_write(
  p_id uuid, p_company uuid, p_actor uuid,
  p_title text, p_description text, p_type text, p_priority text, p_assignee uuid, p_due date,
  p_source text default 'internal', p_external_id text default null, p_external_url text default null
) returns public.ticket_tickets language plpgsql security definer set search_path = public as $$
declare
  t public.ticket_tickets;
  prev public.ticket_tickets;
  n int;
  changes text[] := '{}';
  who_from text;
  who_to text;
begin
  if length(trim(coalesce(p_title, ''))) not between 3 and 200 then
    raise exception 'Le titre doit faire entre 3 et 200 caractères.' using errcode = '22023';
  end if;
  if coalesce(p_type, 'task') not in ('task', 'incident', 'request', 'bug') then
    raise exception 'Type de ticket invalide.' using errcode = '22023';
  end if;
  if coalesce(p_priority, 'normal') not in ('low', 'normal', 'high', 'urgent') then
    raise exception 'Priorité invalide.' using errcode = '22023';
  end if;
  if length(coalesce(p_description, '')) > 10000 then
    raise exception 'Description trop longue (10 000 caractères au maximum).' using errcode = '22023';
  end if;

  if p_id is null then
    perform public.ticket_check_assignee(p_company, p_assignee);
    insert into public.ticket_counters (company_id, last) values (p_company, 1)
    on conflict (company_id) do update set last = public.ticket_counters.last + 1
    returning last into n;
    insert into public.ticket_tickets (company_id, number, title, description, type, priority, assignee_id, due_date,
                                       created_by, source, external_id, external_url)
    values (p_company, n, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), coalesce(p_type, 'task'),
            coalesce(p_priority, 'normal'), p_assignee, p_due, p_actor,
            coalesce(p_source, 'internal'), p_external_id, p_external_url)
    returning * into t;
    perform public.ticket_log(t, p_actor, 'created', null, null, null);
    if p_assignee is not null then
      perform public.ticket_log(t, p_actor, 'assigned', null, (select full_name from public.profiles where id = p_assignee), null);
    end if;
    return t;
  end if;

  select * into prev from public.ticket_tickets where id = p_id for update;
  if prev.id is null then raise exception 'Ticket introuvable.' using errcode = '42501'; end if;
  perform public.ticket_check_assignee(prev.company_id, p_assignee);

  update public.ticket_tickets set
    title = trim(p_title), description = nullif(trim(coalesce(p_description, '')), ''),
    type = coalesce(p_type, prev.type), priority = coalesce(p_priority, prev.priority),
    assignee_id = p_assignee, due_date = p_due,
    external_url = coalesce(p_external_url, prev.external_url),
    updated_at = now()
  where id = p_id returning * into t;

  if t.title is distinct from prev.title then changes := array_append(changes, 'titre'); end if;
  if t.description is distinct from prev.description then changes := array_append(changes, 'description'); end if;
  if t.type is distinct from prev.type then changes := array_append(changes, 'type'); end if;
  if t.priority is distinct from prev.priority then changes := array_append(changes, 'priorité'); end if;
  if t.due_date is distinct from prev.due_date then changes := array_append(changes, 'échéance'); end if;
  if cardinality(changes) > 0 then
    perform public.ticket_log(t, p_actor, 'updated', null, null, array_to_string(changes, ', '));
  end if;
  if t.assignee_id is distinct from prev.assignee_id then
    select full_name into who_from from public.profiles where id = prev.assignee_id;
    select full_name into who_to from public.profiles where id = t.assignee_id;
    perform public.ticket_log(t, p_actor, 'assigned', who_from, who_to, null);
  end if;
  return t;
end $$;

-- Changement de statut (sans contrôle de droits : fait par l'appelant).
create or replace function public.ticket_set_status(p_ticket uuid, p_actor uuid, p_admin boolean, p_status text, p_note text)
returns public.ticket_tickets language plpgsql security definer set search_path = public as $$
declare
  t public.ticket_tickets;
  old_status text;
  note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select status into old_status from public.ticket_tickets where id = p_ticket for update;
  if old_status is null then raise exception 'Ticket introuvable.' using errcode = '42501'; end if;
  if not public.ticket_transition_allowed(old_status, p_status, p_admin) then
    raise exception 'Changement de statut non autorisé.' using errcode = '42501';
  end if;
  if p_status = 'blocked' and length(coalesce(note, '')) < 3 then
    raise exception 'Indiquez pourquoi le ticket est bloqué.' using errcode = '22023';
  end if;
  if length(coalesce(note, '')) > 1000 then
    raise exception 'Motif trop long (1000 caractères au maximum).' using errcode = '22023';
  end if;

  update public.ticket_tickets set
    status = p_status,
    started_at = case when p_status = 'in_progress' then coalesce(started_at, now()) else started_at end,
    done_at = case when p_status = 'done' then now() else null end,
    blocked_reason = case when p_status = 'blocked' then note else null end,
    updated_at = now()
  where id = p_ticket returning * into t;
  perform public.ticket_log(t, p_actor, 'status', old_status, p_status, note);
  return t;
end $$;

-- Commentaire (sans contrôle de droits : fait par l'appelant).
create or replace function public.ticket_comment(p_ticket uuid, p_actor uuid, p_body text, p_internal boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  t public.ticket_tickets;
  c uuid;
begin
  if length(trim(coalesce(p_body, ''))) not between 1 and 5000 then
    raise exception 'Le commentaire doit faire entre 1 et 5000 caractères.' using errcode = '22023';
  end if;
  update public.ticket_tickets set updated_at = now() where id = p_ticket returning * into t;
  if t.id is null then raise exception 'Ticket introuvable.' using errcode = '42501'; end if;
  insert into public.ticket_comments (ticket_id, company_id, author_id, body, is_internal)
  values (t.id, t.company_id, p_actor, trim(p_body), coalesce(p_internal, false))
  returning id into c;
  perform public.ticket_log(t, p_actor, case when p_internal then 'note' else 'comment' end, null, null, left(trim(p_body), 200));
  return c;
end $$;

revoke all on function public.ticket_transition_allowed(text, text, boolean) from public, anon;
grant execute on function public.ticket_transition_allowed(text, text, boolean) to authenticated, service_role;
revoke all on function public.ticket_log(public.ticket_tickets, uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.ticket_check_assignee(uuid, uuid) from public, anon, authenticated;
revoke all on function public.ticket_write(uuid, uuid, uuid, text, text, text, text, uuid, date, text, text, text) from public, anon, authenticated;
revoke all on function public.ticket_set_status(uuid, uuid, boolean, text, text) from public, anon, authenticated;
revoke all on function public.ticket_comment(uuid, uuid, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fonctions appelées par l'application (contrôle des droits ici)
-- ---------------------------------------------------------------------------

-- Admin : crée (p_id null) ou modifie un ticket. Renvoie son identifiant.
create or replace function public.ticket_save(
  p_id uuid, p_company uuid, p_title text, p_description text, p_type text, p_priority text,
  p_assignee uuid, p_due date
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  c uuid := p_company;
  t public.ticket_tickets;
begin
  if p_id is not null then
    select company_id into c from public.ticket_tickets where id = p_id;
  end if;
  if c is null or not coalesce(public.can_manage(c), false) then
    raise exception 'Ticket introuvable.' using errcode = '42501';
  end if;
  if not public.has_module(c, 'tickets') then
    raise exception 'Le module Tickets n''est pas activé pour cette entreprise.' using errcode = '42501';
  end if;
  t := public.ticket_write(p_id, c, auth.uid(), p_title, p_description, p_type, p_priority, p_assignee, p_due);
  return t.id;
end $$;

-- Admin ou employé assigné : change le statut selon les transitions autorisées.
create or replace function public.ticket_change_status(p_ticket uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  c uuid;
  a uuid;
  admin boolean;
begin
  select company_id, assignee_id into c, a from public.ticket_tickets where id = p_ticket;
  if c is null or not public.ticket_access(p_ticket::text) then
    raise exception 'Ticket introuvable.' using errcode = '42501';
  end if;
  admin := coalesce(public.can_manage(c), false);
  if not admin and a is distinct from auth.uid() then
    raise exception 'Ticket introuvable.' using errcode = '42501';
  end if;
  perform public.ticket_set_status(p_ticket, auth.uid(), admin, p_status, p_note);
end $$;

-- Admin ou employé assigné : ajoute un commentaire. Note interne : admin uniquement.
create or replace function public.ticket_add_comment(p_ticket uuid, p_body text, p_internal boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  select company_id into c from public.ticket_tickets where id = p_ticket;
  if c is null or not public.ticket_access(p_ticket::text) then
    raise exception 'Ticket introuvable.' using errcode = '42501';
  end if;
  if coalesce(p_internal, false) and not coalesce(public.can_manage(c), false) then
    raise exception 'Seul l''administrateur écrit des notes internes.' using errcode = '42501';
  end if;
  return public.ticket_comment(p_ticket, auth.uid(), p_body, coalesce(p_internal, false));
end $$;

-- Enregistre une pièce jointe déjà déposée dans le stockage « ticket-files » (<ticket_id>/<fichier>).
create or replace function public.ticket_add_attachment(p_ticket uuid, p_comment uuid, p_path text,
                                                        p_name text, p_mime text, p_size int)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  c uuid;
  new_id uuid;
begin
  select company_id into c from public.ticket_tickets where id = p_ticket;
  if c is null or not public.ticket_access(p_ticket::text) then
    raise exception 'Ticket introuvable.' using errcode = '42501';
  end if;
  if p_path is null or split_part(p_path, '/', 1) <> p_ticket::text or p_path like '%..%' then
    raise exception 'Fichier invalide.' using errcode = '22023';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'ticket-files' and name = p_path) then
    raise exception 'Fichier introuvable : déposez-le avant de l''enregistrer.' using errcode = '22023';
  end if;
  if p_comment is not null and not exists (
       select 1 from public.ticket_comments where id = p_comment and ticket_id = p_ticket
          and (not is_internal or public.can_manage(c))) then
    raise exception 'Commentaire introuvable.' using errcode = '22023';
  end if;
  insert into public.ticket_attachments (ticket_id, comment_id, company_id, storage_path, file_name, mime, size_bytes, uploaded_by)
  values (p_ticket, p_comment, c, p_path, left(coalesce(nullif(trim(p_name), ''), 'fichier'), 200), p_mime, p_size, auth.uid())
  returning id into new_id;
  update public.ticket_tickets set updated_at = now() where id = p_ticket;
  return new_id;
end $$;

revoke all on function public.ticket_save(uuid, uuid, text, text, text, text, uuid, date) from public, anon;
revoke all on function public.ticket_change_status(uuid, text, text) from public, anon;
revoke all on function public.ticket_add_comment(uuid, text, boolean) from public, anon;
revoke all on function public.ticket_add_attachment(uuid, uuid, text, text, text, int) from public, anon;
grant execute on function public.ticket_save(uuid, uuid, text, text, text, text, uuid, date) to authenticated;
grant execute on function public.ticket_change_status(uuid, text, text) to authenticated;
grant execute on function public.ticket_add_comment(uuid, text, boolean) to authenticated;
grant execute on function public.ticket_add_attachment(uuid, uuid, text, text, text, int) to authenticated;

-- ---------------------------------------------------------------------------
-- API ERP (fonction serveur « api », clé service) : création ou mise à jour idempotente
-- d'un ticket venant d'un autre système, repéré par (source, external_id).
-- Le statut n'est jamais modifié par un import : il appartient à la Pointeuse.
--   p : { title, description, type, priority, due_date, assignee_id | assignee_matricule,
--         source, external_id, external_url }
-- ---------------------------------------------------------------------------
create or replace function public.ticket_api_upsert(p_company uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  src text := lower(coalesce(nullif(trim(p ->> 'source'), ''), 'api'));
  ext text := nullif(trim(p ->> 'external_id'), '');
  existing uuid;
  who uuid;
  due date;
  t public.ticket_tickets;
begin
  if not public.has_module(p_company, 'tickets') then
    raise exception 'Le module Tickets n''est pas activé pour cette entreprise.' using errcode = '42501';
  end if;
  if src = 'internal' or src !~ '^[a-z][a-z0-9_]{1,30}$' then
    raise exception 'source invalide (lettres minuscules, chiffres, _).' using errcode = '22023';
  end if;
  if p ? 'due_date' and p ->> 'due_date' is not null then
    begin
      due := (p ->> 'due_date')::date;
    exception when others then
      raise exception 'due_date invalide (AAAA-MM-JJ).' using errcode = '22023';
    end;
  end if;
  if nullif(p ->> 'external_url', '') is not null and (p ->> 'external_url' !~ '^https?://' or length(p ->> 'external_url') > 500) then
    raise exception 'external_url invalide.' using errcode = '22023';
  end if;

  if nullif(p ->> 'assignee_id', '') is not null then
    select id into who from public.profiles
     where id::text = p ->> 'assignee_id' and company_id = p_company and active and role <> 'superadmin';
    if who is null then raise exception 'Employé introuvable (assignee_id).' using errcode = '22023'; end if;
  elsif nullif(trim(p ->> 'assignee_matricule'), '') is not null then
    select id into who from public.profiles
     where matricule = upper(trim(p ->> 'assignee_matricule')) and company_id = p_company and active and role <> 'superadmin';
    if who is null then raise exception 'Employé introuvable (assignee_matricule).' using errcode = '22023'; end if;
  end if;

  if ext is not null then
    select id into existing from public.ticket_tickets where company_id = p_company and source = src and external_id = ext;
  end if;

  if existing is null then
    t := public.ticket_write(null, p_company, null, p ->> 'title', p ->> 'description', p ->> 'type', p ->> 'priority',
                             who, due, src, ext, nullif(p ->> 'external_url', ''));
    return jsonb_build_object('id', t.id, 'number', t.number, 'created', true);
  end if;

  -- Mise à jour : les champs absents gardent leur valeur.
  select * into t from public.ticket_tickets where id = existing;
  t := public.ticket_write(existing, p_company, null,
         coalesce(p ->> 'title', t.title),
         case when p ? 'description' then p ->> 'description' else t.description end,
         coalesce(p ->> 'type', t.type), coalesce(p ->> 'priority', t.priority),
         case when p ? 'assignee_id' or p ? 'assignee_matricule' then who else t.assignee_id end,
         case when p ? 'due_date' then due else t.due_date end,
         src, ext, nullif(p ->> 'external_url', ''));
  return jsonb_build_object('id', t.id, 'number', t.number, 'created', false);
end $$;

-- API ERP : commentaire d'un système externe (auteur null = « système externe »).
create or replace function public.ticket_api_comment(p_company uuid, p_ticket uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not public.has_module(p_company, 'tickets')
     or not exists (select 1 from public.ticket_tickets where id = p_ticket and company_id = p_company) then
    raise exception 'Ticket introuvable.' using errcode = '42501';
  end if;
  return public.ticket_comment(p_ticket, null, p_body, false);
end $$;

revoke all on function public.ticket_api_upsert(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ticket_api_comment(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.ticket_api_upsert(uuid, jsonb) to service_role;
grant execute on function public.ticket_api_comment(uuid, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Stockage des pièces jointes : <ticket_id>/<fichier>, 10 Mo maximum
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('ticket-files', 'ticket-files', false, 10485760)
on conflict (id) do nothing;

create policy "tickets fichiers : dépôt" on storage.objects for insert to authenticated
  with check (bucket_id = 'ticket-files' and public.ticket_access((storage.foldername(name))[1]));
create policy "tickets fichiers : lecture" on storage.objects for select to authenticated
  using (bucket_id = 'ticket-files' and public.ticket_access((storage.foldername(name))[1]));

-- ---------------------------------------------------------------------------
-- Webhooks : ticket.created | ticket.assigned | ticket.status_changed | ticket.updated | ticket.commented
-- (les notes internes ne sont jamais envoyées)
-- ---------------------------------------------------------------------------
create or replace function public.ticket_payload(p_ticket uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'key', 'TK-' || t.number, 'number', t.number,
    'title', t.title, 'description', t.description, 'type', t.type, 'priority', t.priority, 'status', t.status,
    'assignee', case when a.id is null then null else jsonb_build_object('id', a.id, 'matricule', a.matricule, 'full_name', a.full_name) end,
    'due_date', t.due_date, 'blocked_reason', t.blocked_reason,
    'created_at', t.created_at, 'updated_at', t.updated_at, 'started_at', t.started_at, 'done_at', t.done_at,
    'source', t.source, 'external_id', t.external_id, 'external_url', t.external_url)
  from public.ticket_tickets t left join public.profiles a on a.id = t.assignee_id
  where t.id = p_ticket;
$$;
revoke all on function public.ticket_payload(uuid) from public, anon, authenticated;
grant execute on function public.ticket_payload(uuid) to service_role;

create or replace function public.webhook_ticket()
returns trigger language plpgsql security definer set search_path = public as $$
declare ev text;
begin
  ev := case new.kind
          when 'created'  then 'ticket.created'
          when 'assigned' then 'ticket.assigned'
          when 'status'   then 'ticket.status_changed'
          when 'updated'  then 'ticket.updated'
          when 'comment'  then 'ticket.commented'
        end;
  if ev is null then return new; end if;  -- note interne
  perform public.webhook_enqueue_event(new.company_id, ev, jsonb_build_object(
    'ticket', public.ticket_payload(new.ticket_id),
    'change', jsonb_build_object('from', new.from_value, 'to', new.to_value, 'note', new.note,
                                 'by', (select full_name from public.profiles where id = new.actor_id))));
  return new;
end $$;

create trigger ticket_events_webhook after insert on public.ticket_events
  for each row execute function public.webhook_ticket();

-- ---------------------------------------------------------------------------
-- Clés d'API : droits (« read » par défaut, « tickets:write » pour créer des tickets depuis l'ERP).
-- Les clés existantes restent en lecture seule.
-- ---------------------------------------------------------------------------
alter table public.api_keys add column scopes text[] not null default '{read}'
  check (scopes <@ array['read', 'tickets:write']::text[]);

drop function public.create_api_key(uuid, text);
create function public.create_api_key(company uuid, label text, scopes text[] default '{read}')
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  k text := 'ptk_' || encode(gen_random_bytes(24), 'hex');
  s text[] := array(select distinct x from unnest(coalesce(scopes, '{read}') || '{read}'::text[]) x order by 1);
begin
  if not public.can_manage(company) then
    raise exception 'Vous ne pouvez gérer que votre entreprise.' using errcode = '42501';
  end if;
  if not s <@ array['read', 'tickets:write']::text[] then
    raise exception 'Droit inconnu.' using errcode = '22023';
  end if;
  if (select count(*) from public.api_keys a where a.company_id = company and a.revoked_at is null) >= 10 then
    raise exception 'Maximum 10 clés actives par entreprise : révoquez-en une.' using errcode = '22023';
  end if;
  insert into public.api_keys (company_id, label, prefix, key_hash, created_by, scopes)
  values (company, trim(label), left(k, 12), encode(digest(k, 'sha256'), 'hex'), auth.uid(), s);
  return k;  -- montrée une seule fois
end $$;
revoke all on function public.create_api_key(uuid, text, text[]) from public, anon;
grant execute on function public.create_api_key(uuid, text, text[]) to authenticated;
