-- Correctif : Supabase Auth crée d'abord le compte, PUIS pose les app_metadata (company_id)
-- par une mise à jour. Le profil est donc créé dès que l'entreprise est connue,
-- à la création ou à cette mise à jour. Un compte sans entreprise (inscription libre)
-- n'a pas de profil : il ne peut rien voir ni pointer.

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  company uuid := nullif(new.raw_app_meta_data ->> 'company_id', '')::uuid;
begin
  if company is null or exists (select 1 from public.profiles where id = new.id) then
    return new;
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

create trigger on_auth_user_company_set
  after update of raw_app_meta_data on auth.users
  for each row execute function public.handle_new_user();
