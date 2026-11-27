-- ============================================================================
-- REMISE À ZÉRO : supprime TOUTES les données, sauf le compte super-admin.
-- IRRÉVERSIBLE. À exécuter dans Supabase › SQL Editor, AVANT seed_demo.sql.
--
-- Conservé : le compte super-admin (connexion, profil, visage enregistré),
--            son entreprise, et les réglages anti-fraude (table settings).
-- Supprimé : tous les autres comptes, toutes les autres entreprises, tous les
--            pointages (y compris ceux du super-admin), sites, clés d'API, webhooks.
-- Les photos de pointage se suppriment à part : Storage › punch-photos (voir README).
-- ============================================================================

begin;

do $$
declare
  sa_id      uuid;
  sa_company uuid;
  n          int;
begin
  select count(*) into n from public.profiles where role = 'superadmin';
  if n <> 1 then
    raise exception 'Arrêt : % super-admin trouvé(s), il en faut exactement 1. Rien n''a été supprimé.', n;
  end if;
  select id, company_id into sa_id, sa_company from public.profiles where role = 'superadmin';

  delete from public.webhook_deliveries;
  delete from public.webhooks;
  delete from public.api_keys;
  delete from public.punches;
  delete from public.punch_challenges;
  delete from public.sites;
  delete from public.face_templates where user_id <> sa_id;
  update public.face_templates set created_by = sa_id where created_by is distinct from sa_id;
  delete from auth.users where id <> sa_id;              -- supprime aussi les profils (cascade)
  delete from public.companies where id <> sa_company;

  raise notice 'Terminé. Conservé : super-admin %, entreprise %.', sa_id, sa_company;
end $$;

commit;

-- Contrôle : il doit rester 1 compte, 1 entreprise, 0 pointage.
select (select count(*) from auth.users)       as comptes,
       (select count(*) from public.profiles)  as profils,
       (select count(*) from public.companies) as entreprises,
       (select count(*) from public.punches)   as pointages,
       (select count(*) from public.sites)     as sites;
