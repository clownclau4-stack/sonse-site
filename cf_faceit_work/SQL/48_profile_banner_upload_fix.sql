-- CF FACEIT v56: repair profile banner uploads and profile_banner writes.
-- Run in Supabase SQL Editor after SQL/28_v30_prime_bans_banners.sql.
-- Safe to re-run: the bucket and policies are created/upserted idempotently.

begin;

alter table public.profiles
  add column if not exists profile_banner text not null default 'ember';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'cf-profile-banners',
  'cf-profile-banners',
  true,
  20971520,
  array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime','video/x-m4v']
)
on conflict (id) do update
set name = excluded.name,
    public = true,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Files are written below the authenticated player's UUID folder.
drop policy if exists cf_profile_banners_insert on storage.objects;
create policy cf_profile_banners_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'cf-profile-banners'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists cf_profile_banners_delete on storage.objects;
create policy cf_profile_banners_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'cf-profile-banners'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- A player's profile row may keep either a preset or their public bucket URL.
alter table public.profiles drop constraint if exists profiles_profile_banner_check;
alter table public.profiles add constraint profiles_profile_banner_check
check (
  profile_banner in ('ember','inferno','dust','royal')
  or (
    char_length(profile_banner) <= 1900
    and profile_banner ~ '^https://[^[:space:]]+/storage/v1/object/public/cf-profile-banners/[0-9a-f-]{36}/[A-Za-z0-9._/-]+$'
  )
);

-- Preserve the existing profile RLS policy; grant only the field this migration enables.
grant update (profile_banner) on public.profiles to authenticated;

commit;

select 'CF FACEIT v56 profile banner storage repaired' as result;
