-- Golf in Fife – run once in Supabase: SQL Editor > New query > Run
create table if not exists public.gif_players (
  id text primary key,
  name text not null,
  hcp numeric(4,1) not null default 0,
  sort int not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.gif_scores (
  player_id text not null references public.gif_players(id) on delete cascade,
  round_no int not null check (round_no between 1 and 3),
  hole int not null check (hole between 1 and 18),
  strokes int check (strokes is null or strokes between 0 and 20),  -- 0 = opgepakt (streep)
  updated_at timestamptz not null default now(),
  primary key (player_id, round_no, hole)
);

create table if not exists public.gif_settings (
  key text primary key,
  value jsonb,
  updated_at timestamptz not null default now()
);

alter table public.gif_players  enable row level security;
alter table public.gif_scores   enable row level security;
alter table public.gif_settings enable row level security;

drop policy if exists gif_players_all  on public.gif_players;
drop policy if exists gif_scores_all   on public.gif_scores;
drop policy if exists gif_settings_all on public.gif_settings;
create policy gif_players_all  on public.gif_players  for all to anon, authenticated using (true) with check (true);
create policy gif_scores_all   on public.gif_scores   for all to anon, authenticated using (true) with check (true);
create policy gif_settings_all on public.gif_settings for all to anon, authenticated using (true) with check (true);

grant select, insert, update, delete on public.gif_players, public.gif_scores, public.gif_settings to anon, authenticated;

-- Scores upserten: alleen overschrijven als de binnenkomende invoer nieuwer is (laatste invoer per hole wint)
create or replace function public.gif_upsert_scores(rows jsonb)
returns int
language plpgsql
as $$
declare n int;
begin
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
