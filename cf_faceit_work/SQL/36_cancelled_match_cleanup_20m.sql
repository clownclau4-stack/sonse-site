-- CF FACEIT v42: очистка отменённых матчей каждые 20 минут.
-- Запускай после matchmaking migrations SQL/10 и SQL/32.
-- Отменённые записи остаются видимыми не менее 20 минут, чтобы игроки успели
-- увидеть причину отмены; затем удаляются ближайшим 20-минутным запуском.
-- Удаляются только отменённые матчи и очередь, включая matched-записи,
-- привязанные к отменённому матчу. Завершённые матчи не трогаются.
-- Завершённые матчи, матчи на проверке, профили, ELO и жалобы не затрагиваются.

begin;

create extension if not exists pg_cron with schema pg_catalog;

create index if not exists cf_lobby_matches_cancelled_cleanup_idx
  on public.cf_lobby_matches (updated_at)
  where status = 'cancelled';

create index if not exists cf_matchmaking_queue_cancelled_cleanup_idx
  on public.cf_matchmaking_queue (updated_at)
  where queue_status = 'cancelled';

create index if not exists cf_matchmaking_queue_cancelled_match_cleanup_idx
  on public.cf_matchmaking_queue (match_id)
  where queue_status = 'matched';

create or replace function public.cf_cleanup_cancelled_matches_20m()
returns bigint
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_cutoff timestamptz := clock_timestamp() - interval '20 minutes';
  v_deleted_queue bigint := 0;
  v_deleted_matches bigint := 0;
begin
  -- Delete explicitly cancelled queue entries and matched queue entries whose
  -- linked match was cancelled long enough ago. This prevents orphaned 'matched'
  -- rows after the match is deleted below.
  delete from public.cf_matchmaking_queue q
   where (q.queue_status = 'cancelled' and q.updated_at < v_cutoff)
      or (q.queue_status = 'matched' and exists (
        select 1
          from public.cf_lobby_matches m
         where m.id = q.match_id
           and m.status = 'cancelled'
           and m.updated_at < v_cutoff
      ));
  get diagnostics v_deleted_queue = row_count;

  -- The FK from queue.match_id uses ON DELETE SET NULL. Only cancelled matches
  -- older than the retention window are removed; all other statuses are kept.
  delete from public.cf_lobby_matches m
   where m.status = 'cancelled'
     and m.updated_at < v_cutoff;
  get diagnostics v_deleted_matches = row_count;

  return v_deleted_queue + v_deleted_matches;
end;
$function$;

revoke all on function public.cf_cleanup_cancelled_matches_20m()
  from public, anon, authenticated;

-- Replace only this named job to make this migration safe to run again.
do $schedule$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid
      from cron.job
     where jobname = 'cf-clean-cancelled-matches-20m'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'cf-clean-cancelled-matches-20m',
    '*/20 * * * *',
    'select public.cf_cleanup_cancelled_matches_20m();'
  );
end;
$schedule$;

commit;

-- Expected: one active cron job named cf-clean-cancelled-matches-20m.
select jobname, schedule, active
  from cron.job
 where jobname = 'cf-clean-cancelled-matches-20m';
