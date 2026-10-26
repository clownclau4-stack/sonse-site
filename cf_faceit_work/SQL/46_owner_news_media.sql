-- CF FACEIT v53: owner-only publishing of shared news with photo/MP4 media.
-- Run in Supabase SQL Editor after the base online schema and role/moderation SQL.

begin;

do $requirements$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'Сначала установи основную схему онлайн-аккаунтов и таблицу public.profiles.';
  end if;
end;
$requirements$;

create table if not exists public.news (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  link text,
  image_path text,
  published boolean not null default false,
  author_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.news
  add column if not exists title text not null default '',
  add column if not exists description text not null default '',
  add column if not exists link text,
  add column if not exists image_path text,
  add column if not exists media_path text,
  add column if not exists media_type text,
  add column if not exists published boolean not null default false,
  add column if not exists author_id uuid references auth.users(id),
  add column if not exists created_at timestamptz not null default now();

do $constraint$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.news'::regclass and conname='cf_news_media_type_allowed'
  ) then
    alter table public.news add constraint cf_news_media_type_allowed
      check (media_type is null or media_type in ('image','video'));
  end if;
end;
$constraint$;

alter table public.news enable row level security;
-- Remove any legacy write policies: publishing is only through the checked RPC below.
do $policies$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname='public' and tablename='news' loop
    execute format('drop policy %I on public.news',p.policyname);
  end loop;
end;
$policies$;
create policy cf_news_public_read_published on public.news
  for select to anon,authenticated using (published=true);
revoke all on public.news from public,anon,authenticated;
grant select on public.news to anon,authenticated;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('cf-news-media','cf-news-media',true,52428800,
        array['image/jpeg','image/png','image/webp','image/gif','video/mp4']::text[])
on conflict (id) do update set name=excluded.name,public=true,
  file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

-- Public media is deliberately readable; only a founder can create, replace or delete it.
drop policy if exists cf_news_media_public_read on storage.objects;
create policy cf_news_media_public_read on storage.objects
  for select to anon,authenticated using (bucket_id='cf-news-media');
drop policy if exists cf_news_media_founder_insert on storage.objects;
create policy cf_news_media_founder_insert on storage.objects
  for insert to authenticated with check (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  );
drop policy if exists cf_news_media_founder_update on storage.objects;
create policy cf_news_media_founder_update on storage.objects
  for update to authenticated using (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  ) with check (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  );
drop policy if exists cf_news_media_founder_delete on storage.objects;
create policy cf_news_media_founder_delete on storage.objects
  for delete to authenticated using (
    bucket_id='cf-news-media'
    and (storage.foldername(name))[1]=auth.uid()::text
    and exists (select 1 from public.profiles p where p.id=auth.uid() and p.role='founder')
  );

create or replace function public.cf_owner_publish_news(
  p_title text,
  p_description text,
  p_link text default null,
  p_media_path text default null,
  p_media_type text default null
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth,storage
as $function$
declare
  v_uid uuid:=auth.uid();
  v_role text;
  v_title text:=btrim(coalesce(p_title,''));
  v_description text:=btrim(coalesce(p_description,''));
  v_link text:=nullif(btrim(coalesce(p_link,'')),'');
  v_path text:=nullif(btrim(coalesce(p_media_path,'')),'');
  v_type text:=nullif(btrim(coalesce(p_media_type,'')),'');
  v_news public.news%rowtype;
begin
  if v_uid is null then raise exception 'Нужно войти в аккаунт владельца'; end if;
  select p.role into v_role from public.profiles p where p.id=v_uid;
  if coalesce(v_role,'player')<>'founder' then raise exception 'Публиковать новости может только владелец'; end if;
  if v_title='' or char_length(v_title)>100 then raise exception 'Заголовок должен содержать от 1 до 100 символов'; end if;
  if v_description='' or char_length(v_description)>240 then raise exception 'Описание должно содержать от 1 до 240 символов'; end if;
  if v_link is not null and (char_length(v_link)>500 or v_link !~ '^https://[^[:space:]]+$') then
    raise exception 'Ссылка должна быть HTTPS и не длиннее 500 символов';
  end if;
  if v_path is null and v_type is not null then raise exception 'Укажи файл для типа медиа'; end if;
  if v_path is not null then
    if v_type not in ('image','video') then raise exception 'Недопустимый тип медиа'; end if;
    if v_path !~ ('^'||v_uid::text||'/[A-Za-z0-9-]+[.](jpg|jpeg|png|webp|gif|mp4)$') then
      raise exception 'Недопустимый путь медиа';
    end if;
    if v_type='video' and v_path !~* '[.]mp4$' then raise exception 'Для видео разрешён только MP4'; end if;
    if v_type='image' and v_path ~* '[.]mp4$' then raise exception 'Укажи тип видео для MP4'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id='cf-news-media' and o.name=v_path) then
      raise exception 'Загруженный файл не найден';
    end if;
  end if;
  insert into public.news(title,description,link,image_path,media_path,media_type,published,author_id,created_at)
  values(v_title,v_description,v_link,v_path,v_path,v_type,true,v_uid,clock_timestamp())
  returning * into v_news;
  return jsonb_build_object('ok',true,'id',v_news.id,'title',v_news.title,'published',v_news.published,'created_at',v_news.created_at);
end;
$function$;
revoke all on function public.cf_owner_publish_news(text,text,text,text,text) from public,anon;
grant execute on function public.cf_owner_publish_news(text,text,text,text,text) to authenticated;

-- Refresh PostgREST so the newly installed RPC is immediately visible to the site.
notify pgrst, 'reload schema';

commit;
