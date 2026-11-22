-- Webhooks : nouveaux événements
--   absence.created / absence.deleted   (congés, maladie, jours fériés… déclarés par l'admin)
--   employee.created / employee.updated (nouvel employé, nom, matricule, rôle ou activation modifiés)
-- Le contenu est photographié au moment de l'événement (colonne payload) : une absence supprimée
-- reste décrite dans l'envoi, même si elle n'existe plus en base.

alter table public.webhook_deliveries add column payload jsonb;

create or replace function public.webhook_enqueue_event(p_company uuid, p_event text, p_payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.webhook_deliveries (webhook_id, event, payload)
  select w.id, p_event, p_payload from public.webhooks w where w.company_id = p_company and w.active;
  if found then perform public.webhook_kick(); end if;
end $$;
revoke all on function public.webhook_enqueue_event(uuid, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Absences
-- ---------------------------------------------------------------------------
create or replace function public.absence_payload(a public.absences)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', a.id,
    'scope', case when a.user_id is null then 'company' else 'employee' end,
    'employee_id', a.user_id,
    'matricule', p.matricule,
    'full_name', p.full_name,
    'kind', a.kind,
    'start_date', a.start_date,
    'end_date', a.end_date,
    'note', a.note)
  from (select 1) x left join public.profiles p on p.id = a.user_id;
$$;
revoke all on function public.absence_payload(public.absences) from public, anon, authenticated;

create or replace function public.webhook_absence()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.webhook_enqueue_event(new.company_id, 'absence.created', public.absence_payload(new));
    return new;
  end if;
  perform public.webhook_enqueue_event(old.company_id, 'absence.deleted', public.absence_payload(old));
  return old;
end $$;

create trigger absences_webhook after insert or delete on public.absences
  for each row execute function public.webhook_absence();

-- ---------------------------------------------------------------------------
-- Employés (le super-admin n'est jamais envoyé)
-- ---------------------------------------------------------------------------
create or replace function public.webhook_employee()
returns trigger language plpgsql security definer set search_path = public as $$
declare payload jsonb;
begin
  if new.role = 'superadmin' or new.company_id is null then return new; end if;
  if tg_op = 'UPDATE' and (new.full_name, new.matricule, new.role, new.active, new.company_id)
       is not distinct from (old.full_name, old.matricule, old.role, old.active, old.company_id) then
    return new;
  end if;
  payload := jsonb_build_object(
    'id', new.id, 'matricule', new.matricule, 'full_name', new.full_name, 'role', new.role,
    'active', new.active, 'created_at', new.created_at,
    'face_enrolled', exists (select 1 from public.face_templates f where f.user_id = new.id));
  if tg_op = 'UPDATE' then
    payload := payload || jsonb_build_object('changes', (
      select coalesce(jsonb_agg(k), '[]'::jsonb) from (values
        ('full_name', new.full_name is distinct from old.full_name),
        ('matricule', new.matricule is distinct from old.matricule),
        ('role', new.role is distinct from old.role),
        ('active', new.active is distinct from old.active)) v(k, changed) where changed));
  end if;
  perform public.webhook_enqueue_event(new.company_id,
    case when tg_op = 'INSERT' or old.company_id is distinct from new.company_id then 'employee.created' else 'employee.updated' end,
    payload);
  return new;
end $$;

create trigger profiles_webhook after insert or update on public.profiles
  for each row execute function public.webhook_employee();
