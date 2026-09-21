-- Golf in Fife – update 2: logboek van alle ingevoerde scores + automatische back-ups
-- Draai eenmalig in Supabase: SQL Editor > New query > Run

-- 1. Logboek: elke ingestuurde score wordt bewaard, ook als hij later wordt overschreven
create table if not exists public.gif_score_log (
  id bigserial primary key,
  player_id text not null,
  round_no int not null,
  hole int not null,
  strokes int,
  updated_at timestamptz not null,
  device text,
  device_name text,
  logged_at timestamptz not null default now()
);
create index if not exists gif_score_log_key on public.gif_score_log (player_id, round_no, hole);
alter table public.gif_score_log enable row level security;
drop policy if exists gif_score_log_read on public.gif_score_log;
create policy gif_score_log_read on public.gif_score_log for select to anon, authenticated using (true);
grant select on public.gif_score_log to anon, authenticated;

-- 2. Back-ups: volledige momentopnames; de app kan ze lezen maar niet wissen of wijzigen
create table if not exists public.gif_backups (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  reason text,
  n_scores int,
  hash text,
  data jsonb not null
);
alter table public.gif_backups enable row level security;
drop policy if exists gif_backups_read on public.gif_backups;
create policy gif_backups_read on public.gif_backups for select to anon, authenticated using (true);
grant select on public.gif_backups to anon, authenticated;

-- 3. Scores upserten + alles loggen (laatste invoer per hole wint voor de live stand)
create or replace function public.gif_upsert_scores(rows jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  insert into public.gif_score_log (player_id, round_no, hole, strokes, updated_at, device, device_name)
  select r->>'player_id', (r->>'round_no')::int, (r->>'hole')::int, (r->>'strokes')::int,
         (r->>'updated_at')::timestamptz, r->>'device', r->>'device_name'
  from jsonb_array_elements(rows) r;

  insert into public.gif_scores (player_id, round_no, hole, strokes, updated_at)
  select r->>'player_id', (r->>'round_no')::int, (r->>'hole')::int,
         (r->>'strokes')::int, (r->>'updated_at')::timestamptz
  from jsonb_array_elements(rows) r
  where exists (select 1 from public.gif_players p where p.id = r->>'player_id')
  on conflict (player_id, round_no, hole) do update
    set strokes = excluded.strokes, updated_at = excluded.updated_at
    where public.gif_scores.updated_at < excluded.updated_at;
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.gif_upsert_scores(jsonb) to anon, authenticated;

-- 4. Momentopname maken (alleen als er echt iets veranderd is sinds de vorige)
create or replace function public.gif_make_snapshot(reason text default 'auto')
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare d jsonb; h text; last_h text; new_id bigint;
begin
  d := jsonb_build_object(
    'app','golf-in-fife','version',2,'exported_at', now(),
    'players',  coalesce((select jsonb_agg(to_jsonb(p) - 'updated_at' order by p.sort, p.id) from public.gif_players p), '[]'::jsonb),
    'scores',   coalesce((select jsonb_agg(jsonb_build_object('player_id',s.player_id,'round_no',s.round_no,'hole',s.hole,'strokes',s.strokes,'updated_at',s.updated_at) order by s.player_id, s.round_no, s.hole) from public.gif_scores s), '[]'::jsonb),
    'settings', coalesce((select jsonb_object_agg(x.key, x.value) from public.gif_settings x where x.key not like 'photo%'), '{}'::jsonb)
  );
  h := md5((d - 'exported_at')::text);
  select b.hash into last_h from public.gif_backups b order by b.id desc limit 1;
  if last_h is not distinct from h and reason = 'auto' then return null; end if;
  insert into public.gif_backups (reason, n_scores, hash, data)
  values (reason, jsonb_array_length(d->'scores'), h, d) returning id into new_id;
  return new_id;
end;
$$;
grant execute on function public.gif_make_snapshot(text) to anon, authenticated;
