-- add_absence : refus explicite si l'entreprise est absente (can_manage(null) renvoie null).
create or replace function public.add_absence(p_company uuid, p_user uuid, p_kind text, p_from date, p_to date, p_note text)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if p_company is null or not coalesce(public.can_manage(p_company), false) then
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
