-- Webhooks : refuse une adresse contenant « # » (la partie après # n'est jamais envoyée au serveur :
-- ex. l'adresse de la PAGE webhook.site « https://webhook.site/#!/view/… » au lieu de l'adresse de réception).
create or replace function public.create_webhook(company uuid, url text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare s text := 'whsec_' || encode(gen_random_bytes(24), 'hex');
begin
  if company is null or not coalesce(public.can_manage(company), false) then
    raise exception 'Vous ne pouvez gérer que votre entreprise.' using errcode = '42501';
  end if;
  if url !~ '^https://[^\s/?#]+[^\s#]*$' or length(url) > 500 then
    raise exception 'Adresse invalide : elle doit commencer par https:// et ne pas contenir « # ».' using errcode = '22023';
  end if;
  if (select count(*) from public.webhooks w where w.company_id = company) >= 5 then
    raise exception 'Maximum 5 webhooks par entreprise.' using errcode = '22023';
  end if;
  insert into public.webhooks (company_id, url, secret, created_by) values (company, trim(url), s, auth.uid());
  return s;
end $$;
