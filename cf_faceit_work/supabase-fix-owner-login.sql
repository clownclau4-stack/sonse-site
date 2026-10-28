-- CF FACEIT: safe owner recovery guidance.
-- This file intentionally does not confirm email addresses, set passwords,
-- or grant roles by email/nickname. Recover the account through Supabase Auth's
-- password-reset flow, then use a trusted SQL editor only if role repair is needed.
-- For a new founder assignment, use supabase-founder-admin-setup.sql and an
-- independently verified immutable auth.users.id UUID. Review existing role grants first.

select
  'Use Supabase Auth password recovery; do not bypass email confirmation or identify owners by nickname/email.' as recovery_guidance;
