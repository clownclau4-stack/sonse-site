-- CF FACEIT: explicit founder bootstrap template (trusted SQL editor only).
-- This is NOT an automatic migration. Never use a nickname or email to grant founder.
-- Before running, independently verify the account owner and replace NULL below with
-- the immutable auth.users.id UUID from the trusted Supabase Auth dashboard.
-- Review existing founder assignments separately; this template intentionally does not revoke anyone.

do $bootstrap$
declare
  v_owner_uid uuid := null;
begin
  if v_owner_uid is null then
    raise exception 'Set v_owner_uid to the independently verified auth.users UUID before running this template';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_owner_uid) then
    raise exception 'The supplied UUID does not identify an Auth user';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_owner_uid) then
    raise exception 'The Auth user has no public profile; complete the normal signup flow first';
  end if;

  update public.profiles
     set role = 'founder', verified = true
   where id = v_owner_uid;
end;
$bootstrap$;
