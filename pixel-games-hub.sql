-- Pixel Games online hub: who's online, global chat + invites, Quick Match queue, ranked Elo.
-- Paste into Supabase: SQL Editor -> New query -> Run. Safe to run again (it only adds what's missing).
-- The tables are locked (row level security, no policies): the game only talks to them through the
-- functions below, so nobody can edit a rating or post as someone else from the browser.

create table if not exists public.px_players (
  uid text primary key,
  keyhash text not null,
  name text not null default 'Player',
  lv int not null default 1,
  rb int not null default 0,
  st text not null default '',
  seen timestamptz not null default now(),
  elo_f int not null default 1000, gf int not null default 0, wf int not null default 0,
  elo_h int not null default 1000, gh int not null default 0, wh int not null default 0,
  created timestamptz not null default now()
);
create index if not exists px_players_seen on public.px_players (seen desc);
create index if not exists px_players_elo_f on public.px_players (elo_f desc) where gf > 0;
create index if not exists px_players_elo_h on public.px_players (elo_h desc) where gh > 0;

create table if not exists public.px_msgs (
  id bigserial primary key,
  at timestamptz not null default now(),
  uid text not null,
  n text not null,
  kind text not null,
  to_uid text,
  x text not null default '',
  data jsonb
);
create index if not exists px_msgs_at on public.px_msgs (at);
create index if not exists px_msgs_to on public.px_msgs (to_uid, id);

create table if not exists public.px_queue (
  uid text primary key,
  game text not null,
  code text not null,
  lv int not null default 1,
  ver int not null default 0,
  at timestamptz not null default now(),
  paired_with text,
  paired_code text
);

create table if not exists public.px_matches (
  id text primary key,
  game text not null,
  a text not null, b text not null,
  ra text, rb text,          -- 'W' / 'L' (each starts as a pending 'L' so quitting counts as losing)
  ma real, mb real,          -- how one-sided it was, 0..1, as each side saw it
  ea boolean not null default false, eb boolean not null default false,
  at timestamptz not null default now(),
  ended_at timestamptz,
  done boolean not null default false,
  da int, db int
);
create index if not exists px_matches_open on public.px_matches (done, ended_at);

alter table public.px_players enable row level security;
alter table public.px_msgs enable row level security;
alter table public.px_queue enable row level security;
alter table public.px_matches enable row level security;
revoke all on public.px_players, public.px_msgs, public.px_queue, public.px_matches from anon, authenticated;

-- each copy of the game has its own id and a secret it keeps; the first call claims the id
create or replace function public.px_auth(p_uid text, p_key text, p_name text default null)
returns public.px_players language plpgsql security definer set search_path = public as $$
declare r public.px_players;
begin
  if p_uid is null or length(p_uid) < 8 or length(p_uid) > 32 or p_key is null or length(p_key) < 16 then raise exception 'bad id'; end if;
  select * into r from px_players where uid = p_uid;
  if not found then
    insert into px_players (uid, keyhash, name) values (p_uid, md5(p_key || ':pxk'), coalesce(left(p_name, 16), 'Player')) returning * into r;
  elsif r.keyhash <> md5(p_key || ':pxk') then raise exception 'bad key';
  end if;
  return r;
end $$;

-- elo change for one finished match (called with the row locked)
create or replace function public.px_settle(m public.px_matches)
returns void language plpgsql security definer set search_path = public as $$
declare pa px_players; pb px_players; r_a int; r_b int; ga int; gb int; e_a real; k real; perf real; d int; aw boolean;
begin
  if m.done then return; end if;
  if m.ra is null or m.rb is null or m.ra = m.rb then update px_matches set done = true where id = m.id; return; end if; -- no winner both agree on
  aw := m.ra = 'W';
  select * into pa from px_players where uid = m.a for update;
  select * into pb from px_players where uid = m.b for update;
  if pa.uid is null or pb.uid is null then update px_matches set done = true where id = m.id; return; end if;
  if m.game = 'f' then r_a := pa.elo_f; r_b := pb.elo_f; ga := pa.gf; gb := pb.gf; else r_a := pa.elo_h; r_b := pb.elo_h; ga := pa.gh; gb := pb.gh; end if;
  e_a := 1 / (1 + power(10, (r_b - r_a) / 400.0));
  perf := 0.8 + 0.5 * least(1, greatest(0, coalesce((coalesce(m.ma, m.mb) + coalesce(m.mb, m.ma)) / 2, 0.5)));
  k := case when least(ga, gb) < 10 then 40 else 32 end;
  d := greatest(1, round(k * (case when aw then 1 - e_a else e_a end) * perf));
  if not aw then d := -d; end if;   -- d: what a gains
  if m.game = 'f' then
    update px_players set elo_f = greatest(100, elo_f + d), gf = gf + 1, wf = wf + (case when aw then 1 else 0 end) where uid = m.a;
    update px_players set elo_f = greatest(100, elo_f - d), gf = gf + 1, wf = wf + (case when aw then 0 else 1 end) where uid = m.b;
  else
    update px_players set elo_h = greatest(100, elo_h + d), gh = gh + 1, wh = wh + (case when aw then 1 else 0 end) where uid = m.a;
    update px_players set elo_h = greatest(100, elo_h - d), gh = gh + 1, wh = wh + (case when aw then 0 else 1 end) where uid = m.b;
  end if;
  update px_matches set done = true, da = d, db = -d where id = m.id;
end $$;

-- a match nobody finished cleanly: one side reported the end and the other never did (closed the game, lost
-- connection, rage quit) -> after 45 s it's settled with what the reporter said (the quitter's pending 'L' stands)
create or replace function public.px_sweep(p_uid text)
returns void language plpgsql security definer set search_path = public as $$
declare m px_matches;
begin
  for m in select * from px_matches where done = false and (a = p_uid or b = p_uid) and (ea or eb) and not (ea and eb) and ended_at < now() - interval '45 seconds' for update skip locked loop
    perform px_settle(m);
  end loop;
  -- started but nobody ever reported (both crashed): forget it after an hour
  update px_matches set done = true where done = false and not ea and not eb and at < now() - interval '1 hour' and (a = p_uid or b = p_uid);
end $$;

-- every few seconds from each open game: I'm here (and what I'm doing), anything new for me?
create or replace function public.px_hello(p_uid text, p_key text, p_name text, p_lv int, p_rb int, p_st text, p_since bigint, p_people boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; msgs jsonb; ppl jsonb := null; mx bigint; onl int;
begin
  r := px_auth(p_uid, p_key, p_name);
  update px_players set name = coalesce(left(p_name, 16), name), lv = coalesce(p_lv, lv), rb = coalesce(p_rb, rb), st = coalesce(left(p_st, 40), st), seen = now() where uid = p_uid returning * into r;
  select coalesce(max(id), 0) into mx from px_msgs;
  if coalesce(p_since, -1) < 0 then -- first call: the last few lines as history
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', n, 'k', kind, 'x', x, 'ts', (extract(epoch from at) * 1000)::bigint) order by id), '[]') into msgs
      from (select * from px_msgs where kind = 'm' and at > now() - interval '15 minutes' order by id desc limit 15) q;
  else
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', n, 'k', kind, 'x', x, 'd', data, 'ts', (extract(epoch from at) * 1000)::bigint) order by id), '[]') into msgs
      from (select * from px_msgs where id > p_since and (kind = 'm' or to_uid = p_uid) and uid <> p_uid order by id limit 60) q;
  end if;
  select count(*) into onl from px_players where seen > now() - interval '40 seconds';
  if p_people then
    select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', name, 'lv', lv, 'rb', rb, 'st', st, 'ef', elo_f, 'eh', elo_h)), '[]') into ppl
      from (select * from px_players where seen > now() - interval '40 seconds' and uid <> p_uid order by seen desc limit 80) q;
  end if;
  if random() < 0.2 then perform px_sweep(p_uid); end if;
  return jsonb_build_object('last', mx, 'msgs', msgs, 'people', ppl, 'online', onl,
    'me', jsonb_build_object('ef', r.elo_f, 'gf', r.gf, 'wf', r.wf, 'eh', r.elo_h, 'gh', r.gh, 'wh', r.wh));
end $$;

-- a chat line ('m', to everyone) or an invite / answer to one player ('inv', 'invno', 'invok')
create or replace function public.px_say(p_uid text, p_key text, p_kind text, p_to text, p_x text, p_data jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare r px_players; nid bigint; recent int;
begin
  r := px_auth(p_uid, p_key);
  if p_kind not in ('m', 'inv', 'invno', 'invok') then raise exception 'bad kind'; end if;
  if p_kind = 'm' and (p_x is null or length(btrim(p_x)) = 0) then raise exception 'empty'; end if;
  if p_kind <> 'm' and p_to is null then raise exception 'no target'; end if;
  select count(*) into recent from px_msgs where uid = p_uid and at > now() - interval '8 seconds';
  if recent >= 6 then raise exception 'slow down'; end if;
  insert into px_msgs (uid, n, kind, to_uid, x, data) values (p_uid, r.name, p_kind, case when p_kind = 'm' then null else p_to end, left(coalesce(p_x, ''), 160), case when p_data is null then null when length(p_data::text) > 400 then null else p_data end) returning id into nid;
  if random() < 0.05 then delete from px_msgs where at < now() - interval '20 minutes'; end if;
  return nid;
end $$;

-- Quick Match: pair me with someone waiting (closest level first), or put me in the line with the room I'll host
create or replace function public.px_queue(p_uid text, p_key text, p_game text, p_code text, p_lv int, p_ver int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me px_queue; o px_queue;
begin
  perform px_auth(p_uid, p_key);
  select * into me from px_queue where uid = p_uid;
  if found and me.paired_with is not null then
    delete from px_queue where uid = p_uid;
    return jsonb_build_object('host', me.code, 'opp', me.paired_with);
  end if;
  select * into o from px_queue where game = p_game and ver = p_ver and uid <> p_uid and paired_with is null and at > now() - interval '6 seconds'
    order by abs(lv - coalesce(p_lv, 1)), at limit 1 for update skip locked;
  if found then
    update px_queue set paired_with = p_uid where uid = o.uid;
    delete from px_queue where uid = p_uid;
    return jsonb_build_object('join', o.code, 'opp', o.uid);
  end if;
  insert into px_queue (uid, game, code, lv, ver, at) values (p_uid, p_game, left(p_code, 12), coalesce(p_lv, 1), coalesce(p_ver, 0), now())
    on conflict (uid) do update set game = excluded.game, code = excluded.code, lv = excluded.lv, ver = excluded.ver, at = now(), paired_with = null, paired_code = null;
  if random() < 0.1 then delete from px_queue where at < now() - interval '1 minute'; end if;
  return jsonb_build_object('wait', true);
end $$;

create or replace function public.px_unqueue(p_uid text, p_key text)
returns void language plpgsql security definer set search_path = public as $$
begin perform px_auth(p_uid, p_key); delete from px_queue where uid = p_uid; end $$;

-- a ranked match begins: both players call this (each one starts as a pending loss, so quitting can't dodge it)
create or replace function public.px_match_start(p_uid text, p_key text, p_match text, p_game text, p_opp text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m px_matches; lo text; hi text;
begin
  perform px_auth(p_uid, p_key);
  if p_game not in ('f', 'h') or p_opp is null or p_opp = p_uid or length(p_match) > 48 then raise exception 'bad match'; end if;
  if not exists (select 1 from px_players where uid = p_opp) then raise exception 'unknown opponent'; end if;
  lo := least(p_uid, p_opp); hi := greatest(p_uid, p_opp);
  insert into px_matches (id, game, a, b) values (p_match, p_game, lo, hi) on conflict (id) do nothing;
  select * into m from px_matches where id = p_match for update;
  if m.a <> lo or m.b <> hi or m.game <> p_game then raise exception 'not your match'; end if;
  if m.done then return jsonb_build_object('ok', false); end if;
  if p_uid = m.a then update px_matches set ra = coalesce(ra, 'L') where id = p_match; else update px_matches set rb = coalesce(rb, 'L') where id = p_match; end if;
  return jsonb_build_object('ok', true);
end $$;

-- a ranked match ended: my result and how one-sided it was. Settles once both sides agree (or the other side never answers)
create or replace function public.px_match_end(p_uid text, p_key text, p_match text, p_win boolean, p_margin real)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m px_matches; mg real := least(1, greatest(0, coalesce(p_margin, 0.5))); me px_players;
begin
  perform px_auth(p_uid, p_key);
  select * into m from px_matches where id = p_match for update;
  if not found or (m.a <> p_uid and m.b <> p_uid) then raise exception 'not your match'; end if;
  if not m.done then
    if p_uid = m.a and not m.ea then update px_matches set ra = case when p_win then 'W' else 'L' end, ma = mg, ea = true, ended_at = coalesce(ended_at, now()) where id = p_match;
    elsif p_uid = m.b and not m.eb then update px_matches set rb = case when p_win then 'W' else 'L' end, mb = mg, eb = true, ended_at = coalesce(ended_at, now()) where id = p_match;
    end if;
    select * into m from px_matches where id = p_match;
    if m.ea and m.eb then perform px_settle(m); end if;
    select * into m from px_matches where id = p_match;
  end if;
  select * into me from px_players where uid = p_uid;
  return jsonb_build_object('done', m.done, 'd', case when not m.done then null when p_uid = m.a then m.da else m.db end,
    'elo', case when m.game = 'f' then me.elo_f else me.elo_h end);
end $$;

-- the leaderboard: top 50 for a game, plus where I stand
create or replace function public.px_top(p_game text, p_uid text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare top jsonb; me px_players; rk int; tot int;
begin
  if p_game = 'h' then
    select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', name, 'e', elo_h, 'g', gh, 'w', wh, 'lv', lv, 'on', seen > now() - interval '40 seconds')), '[]') into top
      from (select * from px_players where gh > 0 order by elo_h desc, gh desc limit 50) q;
    select count(*) into tot from px_players where gh > 0;
  else
    select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', name, 'e', elo_f, 'g', gf, 'w', wf, 'lv', lv, 'on', seen > now() - interval '40 seconds')), '[]') into top
      from (select * from px_players where gf > 0 order by elo_f desc, gf desc limit 50) q;
    select count(*) into tot from px_players where gf > 0;
  end if;
  select * into me from px_players where uid = p_uid;
  if found then
    if p_game = 'h' then select count(*) + 1 into rk from px_players where gh > 0 and elo_h > me.elo_h;
    else select count(*) + 1 into rk from px_players where gf > 0 and elo_f > me.elo_f; end if;
  end if;
  return jsonb_build_object('top', top, 'total', tot, 'rank', rk,
    'me', case when me.uid is null then null else jsonb_build_object('e', case when p_game = 'h' then me.elo_h else me.elo_f end, 'g', case when p_game = 'h' then me.gh else me.gf end, 'w', case when p_game = 'h' then me.wh else me.wf end) end);
end $$;

revoke all on function public.px_auth(text, text, text), public.px_settle(public.px_matches), public.px_sweep(text) from public, anon, authenticated;
grant execute on function public.px_hello(text, text, text, int, int, text, bigint, boolean), public.px_say(text, text, text, text, text, jsonb),
  public.px_queue(text, text, text, text, int, int), public.px_unqueue(text, text), public.px_match_start(text, text, text, text, text),
  public.px_match_end(text, text, text, boolean, real), public.px_top(text, text) to anon, authenticated;
