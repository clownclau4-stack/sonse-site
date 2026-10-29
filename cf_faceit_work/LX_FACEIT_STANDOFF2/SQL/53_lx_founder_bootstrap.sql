-- LX FACEIT — promote an already-registered founder account in the dedicated LX database.
-- This does NOT create a Supabase Auth user and does NOT set or store a password.
-- First complete the normal email-confirmed signup flow. Then copy the immutable auth.users.id
-- from the trusted Supabase Auth dashboard, set the profile nickname below, and run this script.
-- Use only in the dedicated LX FACEIT project after the baseline profile schema is installed.

do $bootstrap$
declare
  v_owner_uid uuid := null;
  v_expected_nickname text := null;
  v_nickname text;
begin
  if v_owner_uid is null then
    raise exception 'Set v_owner_uid to the independently verified auth.users UUID before running this template';
  end if;
  if v_expected_nickname is null or btrim(v_expected_nickname) = '' then
    raise exception 'Set v_expected_nickname to the profile nickname verified in the Auth dashboard';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_owner_uid) then
    raise exception 'The supplied UUID does not identify an Auth user';
  end if;
  select lower(btrim(p.nickname)) into v_nickname
  from public.profiles p
  where p.id = v_owner_uid
  for update;
  if not found or v_nickname <> lower(btrim(v_expected_nickname)) then
    raise exception 'The verified Auth UUID must belong to the profile nickname entered above';
  end if;
  update public.profiles
     set role = 'founder', verified = true
   where id = v_owner_uid;
end;
$bootstrap$;
