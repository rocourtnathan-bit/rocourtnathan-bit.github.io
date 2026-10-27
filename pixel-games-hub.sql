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

-- moderation: bans and mutes, announcements, a log of what the mods did, and the mod panel's password check
alter table public.px_players add column if not exists info jsonb not null default '{}';
alter table public.px_players add column if not exists grade text;   -- freshman | sophomore | junior | senior (chosen once; the mods can reset it)
alter table public.px_msgs add column if not exists grade text;      -- the grade a chat line was said in (Global chat is one room per grade)
create table if not exists public.px_bans (
  uid text not null,
  kind text not null default 'ban' check (kind in ('ban', 'mute')),
  name text,
  reason text not null default '',
  at timestamptz not null default now(),
  until timestamptz,            -- null = for good
  primary key (uid, kind)
);
create table if not exists public.px_announce (id bigserial primary key, at timestamptz not null default now(), x text not null, until timestamptz not null);
create table if not exists public.px_mod_log (id bigserial primary key, at timestamptz not null default now(), act text not null, target text, note text);
-- changes a mod made to a player's fighter (rebirth, level, stats): waiting for that player's game to pick them up
-- the helper account (a weaker mod), who did what in the log, and the people a helper can never touch
alter table public.px_mod_log add column if not exists who text not null default 'owner';
alter table public.px_bans add column if not exists "full" boolean not null default false;   -- true: banned from the whole game, not just online play
create table if not exists public.px_staff (uid text primary key, role text not null check (role in ('owner', 'helper')), name text, at timestamptz not null default now());
create table if not exists public.px_dels (id bigserial primary key, at timestamptz not null default now(), mid bigint, uid text);   -- chat lines a mod deleted: every game drops them
create table if not exists public.px_levels (id bigserial primary key, at timestamptz not null default now(), uid text, n int not null, who text not null);
alter table public.px_staff enable row level security; alter table public.px_dels enable row level security; alter table public.px_levels enable row level security;
revoke all on public.px_staff, public.px_dels, public.px_levels from anon, authenticated;
create table if not exists public.px_edits (id bigserial primary key, uid text not null, at timestamptz not null default now(), edit jsonb not null, applied boolean not null default false);
create index if not exists px_edits_open on public.px_edits (uid) where not applied;
alter table public.px_edits enable row level security;
revoke all on public.px_edits from anon, authenticated;
create table if not exists public.px_mod_cfg (
  id int primary key default 1 check (id = 1),
  salt text, pwhash text, hsalt text, hhash text,
  fails int not null default 0, strikes int not null default 0, locked_until timestamptz
);
alter table public.px_mod_cfg add column if not exists hsalt text; alter table public.px_mod_cfg add column if not exists hhash text;
alter table public.px_bans enable row level security;
alter table public.px_announce enable row level security;
alter table public.px_mod_log enable row level security;
alter table public.px_mod_cfg enable row level security;
revoke all on public.px_bans, public.px_announce, public.px_mod_log, public.px_mod_cfg from anon, authenticated;
create or replace function public.px_is_banned(p_uid text, p_kind text default 'ban') returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from px_bans where uid = p_uid and kind = p_kind and (until is null or until > now())) $$;

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
-- (p_info: a few totals about this player for the mods: version, wins, play time...)
drop function if exists public.px_hello(text, text, text, int, int, text, bigint, boolean);
create or replace function public.px_hello(p_uid text, p_key text, p_name text, p_lv int, p_rb int, p_st text, p_since bigint, p_people boolean, p_info jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; msgs jsonb; ppl jsonb := null; mx bigint; onl int; bn px_bans; mu px_bans; ann jsonb; eds jsonb; ds bigint; dels jsonb := null; dcur bigint;
begin
  r := px_auth(p_uid, p_key, p_name);
  update px_players set name = coalesce(left(p_name, 16), name), lv = coalesce(p_lv, lv), rb = coalesce(p_rb, rb), st = coalesce(left(p_st, 40), st), seen = now(),
    info = case when p_info is not null and jsonb_typeof(p_info) = 'object' and length(p_info::text) < 900 then p_info else info end where uid = p_uid returning * into r;
  select count(*) into onl from px_players where seen > now() - interval '40 seconds';
  select * into bn from px_bans where uid = p_uid and kind = 'ban' and (until is null or until > now());
  select * into mu from px_bans where uid = p_uid and kind = 'mute' and (until is null or until > now());
  select jsonb_build_object('id', id, 'x', x) into ann from px_announce where until > now() order by id desc limit 1;
  if bn.uid is not null then -- banned: no chat, no people, just the news that they are
    return jsonb_build_object('last', 0, 'msgs', '[]'::jsonb, 'people', null, 'online', onl, 'ann', ann,
      'ban', jsonb_build_object('until', case when bn.until is null then null else (extract(epoch from bn.until) * 1000)::bigint end, 'why', bn.reason, 'full', bn."full"),
      'me', jsonb_build_object('ef', r.elo_f, 'gf', r.gf, 'wf', r.wf, 'eh', r.elo_h, 'gh', r.gh, 'wh', r.wh, 'grade', r.grade));
  end if;
  select coalesce(max(id), 0) into mx from px_msgs;
  if coalesce(p_since, -1) < 0 then -- first call: the last few lines as history
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', coalesce((select name from px_players o where o.uid = q.uid), q.n), 'fl', (select info -> 'fl' from px_players o where o.uid = q.uid), 'k', kind, 'x', x, 'ts', (extract(epoch from at) * 1000)::bigint) order by id), '[]') into msgs
      from (select * from px_msgs where kind = 'm' and grade is not distinct from r.grade and at > now() - interval '15 minutes' order by id desc limit 15) q;
  else
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', coalesce((select name from px_players o where o.uid = q.uid), q.n), 'fl', (select info -> 'fl' from px_players o where o.uid = q.uid), 'k', kind, 'x', x, 'd', data, 'ts', (extract(epoch from at) * 1000)::bigint) order by id), '[]') into msgs
      from (select * from px_msgs where id > p_since and ((kind = 'm' and grade is not distinct from r.grade) or to_uid = p_uid) and uid <> p_uid order by id limit 60) q;
  end if;
  if p_people then
    select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', name, 'lv', lv, 'rb', rb, 'st', st, 'ef', elo_f, 'eh', elo_h, 'fl', info -> 'fl')), '[]') into ppl
      from (select * from px_players where seen > now() - interval '40 seconds' and uid <> p_uid and not px_is_banned(uid) order by seen desc limit 80) q;
  end if;
  if random() < 0.2 then perform px_sweep(p_uid); end if;
  select jsonb_agg(jsonb_build_object('id', id, 'e', edit) order by id) into eds from (select * from px_edits where uid = p_uid and not applied order by id limit 5) q;
  -- chat lines a mod deleted since this game last asked (its cursor rides in p_info as 'ds'; -1 = just tell me where we are)
  ds := case when p_info is not null and jsonb_typeof(p_info) = 'object' and (p_info ->> 'ds') ~ '^-?[0-9]+$' then (p_info ->> 'ds')::bigint else null end;
  if ds is not null then
    if ds < 0 then select coalesce(max(id), 0) into dcur from px_dels;
    else
      select coalesce(jsonb_agg(jsonb_build_object('m', mid, 'u', uid) order by id), '[]'), coalesce(max(id), ds) into dels, dcur from (select * from px_dels where id > ds order by id limit 200) q;
    end if;
  end if;
  return jsonb_build_object('last', mx, 'msgs', msgs, 'people', ppl, 'online', onl, 'ann', ann, 'edits', eds, 'dels', dels, 'dmax', dcur,
    'mute', case when mu.uid is null then null else jsonb_build_object('until', case when mu.until is null then null else (extract(epoch from mu.until) * 1000)::bigint end, 'why', mu.reason) end,
    'me', jsonb_build_object('ef', r.elo_f, 'gf', r.gf, 'wf', r.wf, 'eh', r.elo_h, 'gh', r.gh, 'wh', r.wh, 'grade', r.grade));
end $$;

-- a chat line ('m', to everyone) or an invite / answer to one player ('inv', 'invno', 'invok')
create or replace function public.px_say(p_uid text, p_key text, p_kind text, p_to text, p_x text, p_data jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare r px_players; nid bigint; recent int;
begin
  r := px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then raise exception 'banned'; end if;
  if p_kind = 'm' and px_is_banned(p_uid, 'mute') then raise exception 'muted'; end if;
  if p_kind = 'm' and r.grade is null then raise exception 'pick a grade first'; end if;
  if p_kind not in ('m', 'inv', 'invno', 'invok') then raise exception 'bad kind'; end if;
  if p_kind = 'm' and (p_x is null or length(btrim(p_x)) = 0) then raise exception 'empty'; end if;
  if p_kind <> 'm' and p_to is null then raise exception 'no target'; end if;
  select count(*) into recent from px_msgs where uid = p_uid and at > now() - interval '8 seconds';
  if recent >= 6 then raise exception 'slow down'; end if;
  insert into px_msgs (uid, n, kind, to_uid, x, data, grade) values (p_uid, r.name, p_kind, case when p_kind = 'm' then null else p_to end, left(coalesce(p_x, ''), 160), case when p_data is null then null when length(p_data::text) > 400 then null else p_data end, case when p_kind = 'm' then r.grade else null end) returning id into nid;
  if random() < 0.05 then delete from px_msgs where (kind <> 'm' and at < now() - interval '20 minutes') or at < now() - interval '3 days'; end if; -- (chat lines stay 3 days so the mods can look back)
  return nid;
end $$;

-- Quick Match: pair me with someone waiting (closest level first), or put me in the line with the room I'll host
create or replace function public.px_queue(p_uid text, p_key text, p_game text, p_code text, p_lv int, p_ver int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me px_queue; o px_queue;
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then delete from px_queue where uid = p_uid; return jsonb_build_object('ban', true); end if;
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
  if px_is_banned(p_uid) or px_is_banned(p_opp) then return jsonb_build_object('ok', false); end if;
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
      from (select * from px_players where gh > 0 and not px_is_banned(uid) order by elo_h desc, gh desc limit 50) q;
    select count(*) into tot from px_players where gh > 0 and not px_is_banned(uid);
  else
    select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', name, 'e', elo_f, 'g', gf, 'w', wf, 'lv', lv, 'on', seen > now() - interval '40 seconds')), '[]') into top
      from (select * from px_players where gf > 0 and not px_is_banned(uid) order by elo_f desc, gf desc limit 50) q;
    select count(*) into tot from px_players where gf > 0 and not px_is_banned(uid);
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
grant execute on function public.px_hello(text, text, text, int, int, text, bigint, boolean, jsonb), public.px_say(text, text, text, text, text, jsonb),
  public.px_queue(text, text, text, text, int, int), public.px_unqueue(text, text), public.px_match_start(text, text, text, text, text),
  public.px_match_end(text, text, text, boolean, real), public.px_top(text, text) to anon, authenticated;

-- ---------- Turf Wars (only if the turf table is set up) ----------
-- 30 blocks (was 20), and two rules the server enforces so nobody can get round them:
-- a block that held off 3 attacks this week can't change hands until Monday, and nothing changes hands on the weekend.
create or replace function public.px_turf_guard()
returns trigger language plpgsql as $$
declare wk timestamptz := date_trunc('week', now() at time zone 'America/New_York') at time zone 'America/New_York';
begin
  if current_setting('px.mod', true) = '1' then return new; end if; -- (a mod releasing blocks)
  if new.owner_id is distinct from old.owner_id then
    if extract(isodow from now() at time zone 'America/New_York') >= 6 then raise exception 'Turf Wars is closed for the weekend'; end if;
    if old.owner_id is not null and coalesce(old.defenses, 0) >= 3 and old.claimed_at >= wk then raise exception 'That block is locked for the week'; end if;
  end if;
  return new;
end $$;
do $$ begin
  if to_regclass('public.turf') is not null then
    insert into public.turf (id) select 'd' || g from generate_series(0, 29) g on conflict do nothing;
    drop trigger if exists px_turf_guard on public.turf;
    create trigger px_turf_guard before update on public.turf for each row execute function public.px_turf_guard();
  end if;
end $$;

-- ---------- Turf Wars, no shortcuts ----------
-- Every change to the map goes through these functions (the table itself becomes read-only): you get a ticket when
-- a fight for a block starts, and only that ticket, used once, after a real fight's worth of time, can take the
-- block or count a defence. Nobody can claim without fighting, claim twice, lock their own block, or farm a lock
-- with their own second fighter.
create table if not exists public.px_turf_tickets (
  id bigserial primary key,
  uid text not null,
  fid text not null,
  block text not null,
  owner_was text,
  started timestamptz not null default now(),
  used boolean not null default false
);
create index if not exists px_turf_tickets_uid on public.px_turf_tickets (uid, started desc);
alter table public.px_turf_tickets enable row level security;
revoke all on public.px_turf_tickets from anon, authenticated;
do $$ begin
  if to_regclass('public.turf') is not null then
    alter table public.turf add column if not exists owner_uid text;
    drop policy if exists "turf write" on public.turf;
    revoke update, insert, delete on public.turf from anon, authenticated;
  end if;
end $$;

create or replace function public.px_turf_week() returns timestamptz language sql stable as $$
  select date_trunc('week', now() at time zone 'America/New_York') at time zone 'America/New_York' $$;

-- an attack starts: checks it's allowed and hands out the ticket
create or replace function public.px_turf_start(p_uid text, p_key text, p_fid text, p_block text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; nid bigint; live_owner text; live_uid text;
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then raise exception 'You are banned from online play'; end if;
  if p_fid is null or length(p_fid) > 40 then raise exception 'bad fighter'; end if;
  select * into t from turf where id = p_block;
  if not found then raise exception 'no such block'; end if;
  if extract(isodow from now() at time zone 'America/New_York') >= 6 then raise exception 'Turf Wars is closed for the weekend'; end if;
  -- blocks only change hands 7:45 AM to 2:15 PM, New York time (a fight started in time still counts when it ends)
  if (now() at time zone 'America/New_York')::time < time '07:45' or (now() at time zone 'America/New_York')::time >= time '14:15' then raise exception 'Blocks can only be taken from 7:45 AM to 2:15 PM (New York time)'; end if;
  -- last week's claims count as unclaimed
  if t.owner_id is not null and t.claimed_at >= px_turf_week() then live_owner := t.owner_id; live_uid := t.owner_uid; end if;
  if live_owner is not null and coalesce(t.defenses, 0) >= 3 then raise exception 'That block is locked for the week'; end if;
  if live_owner = p_fid or (live_uid is not null and live_uid = p_uid) then raise exception 'That block is already yours'; end if;
  if (select count(*) from px_turf_tickets where uid = p_uid and started > now() - interval '1 minute') >= 6 then raise exception 'Slow down'; end if;
  update px_turf_tickets set used = true where uid = p_uid and not used; -- one fight at a time
  insert into px_turf_tickets (uid, fid, block, owner_was) values (p_uid, p_fid, p_block, live_owner) returning id into nid;
  if random() < 0.05 then delete from px_turf_tickets where started < now() - interval '1 day'; end if;
  return jsonb_build_object('ticket', nid, 'owner', live_owner);
end $$;

-- I won: the block is mine (if nobody else got there first and it didn't lock meanwhile)
create or replace function public.px_turf_win(p_uid text, p_key text, p_ticket bigint, p_name text, p_fighter jsonb, p_dna jsonb, p_event text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k px_turf_tickets; t record; live_owner text; hist jsonb; secs real;
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then raise exception 'You are banned from online play'; end if;
  select * into k from px_turf_tickets where id = p_ticket and uid = p_uid for update;
  if not found or k.used then raise exception 'That fight was already counted'; end if;
  secs := extract(epoch from now() - k.started);
  if secs < (case when k.owner_was is null then 15 else 6 end) then raise exception 'That was too quick to be a real fight'; end if;
  if secs > 1800 then raise exception 'That fight took too long to count'; end if;
  update px_turf_tickets set used = true where id = k.id;
  if length(coalesce(p_fighter::text, '')) > 30000 or length(coalesce(p_dna::text, '')) > 30000 then raise exception 'too big'; end if;
  select * into t from turf where id = k.block for update;
  if t.owner_id is not null and t.claimed_at >= px_turf_week() then live_owner := t.owner_id; end if;
  if live_owner is distinct from k.owner_was then raise exception 'Someone else took that block first'; end if;
  -- who held it before (and when), newest first, eight deep: the weekly crown is worked out from this
  hist := jsonb_build_array(jsonb_build_object('o', t.owner_id, 'n', t.owner_name, 'at', coalesce((extract(epoch from t.claimed_at) * 1000)::bigint, 0)))
    || coalesce((select jsonb_agg(h) from (select h from jsonb_array_elements(coalesce(t.fighter -> 'hist', '[]'::jsonb)) h limit 7) q), '[]'::jsonb);
  update turf set owner_id = k.fid, owner_uid = p_uid, owner_name = left(coalesce(p_name, 'Player'), 24),
    fighter = coalesce(p_fighter, '{}'::jsonb) - 'hist' || jsonb_build_object('hist', hist), dna = p_dna,
    claimed_at = now(), defenses = 0, last_event = left(p_event, 120) where id = k.block;
  return (select to_jsonb(x) from turf x where id = k.block);
end $$;

-- I lost: the owner's clone held it (counts toward the weekly lock)
create or replace function public.px_turf_lost(p_uid text, p_key text, p_ticket bigint, p_challenger text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k px_turf_tickets; t record; n int;
begin
  perform px_auth(p_uid, p_key);
  select * into k from px_turf_tickets where id = p_ticket and uid = p_uid for update;
  if not found or k.used then raise exception 'That fight was already counted'; end if;
  if extract(epoch from now() - k.started) < 6 or extract(epoch from now() - k.started) > 1800 then raise exception 'Not a real fight'; end if;
  update px_turf_tickets set used = true where id = k.id;
  if k.owner_was is null then return null; end if; -- (lost to a street crew: nothing to count)
  select * into t from turf where id = k.block for update;
  if t.owner_id is distinct from k.owner_was or t.claimed_at < px_turf_week() then return null; end if;
  n := coalesce(t.defenses, 0) + 1;
  update turf set defenses = n, last_event = left(coalesce(t.owner_name, 'Their') || '''s clone beat ' || coalesce(p_challenger, 'someone') || (case when n = 3 then ' and locked it for the week' else '' end), 120) where id = k.block;
  return (select to_jsonb(x) from turf x where id = k.block);
end $$;

-- keep my clones up to date (only on blocks this copy of the game really took)
create or replace function public.px_turf_sync(p_uid text, p_key text, p_fid text, p_name text, p_fighter jsonb, p_dna jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform px_auth(p_uid, p_key);
  if length(coalesce(p_fighter::text, '')) > 30000 or length(coalesce(p_dna::text, '')) > 30000 then raise exception 'too big'; end if;
  update turf set owner_name = left(coalesce(p_name, owner_name), 24), dna = p_dna,
    fighter = coalesce(p_fighter, '{}'::jsonb) - 'hist' || jsonb_build_object('hist', coalesce(fighter -> 'hist', '[]'::jsonb))
    where owner_id = p_fid and owner_uid = p_uid;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function public.px_turf_start(text, text, text, text), public.px_turf_win(text, text, bigint, text, jsonb, jsonb, text),
  public.px_turf_lost(text, text, bigint, text), public.px_turf_sync(text, text, text, text, jsonb, jsonb) to anon, authenticated;

-- ---------- The mod panel ----------
-- Everything below checks the mod password on the server, every call. The password itself is NOT in this file: you set it
-- once, privately, in the SQL Editor (see the line at the very end). Five wrong tries lock the panel for 15 minutes, then
-- 30, 60... (up to a day), so it can't be guessed by hammering it.
create or replace function public.px_mod_set_password(p_pw text) returns void language plpgsql security definer set search_path = public as $$
declare s text := replace(gen_random_uuid()::text, '-', '');
begin
  if p_pw is null or length(p_pw) < 4 or length(p_pw) > 64 then raise exception 'password: 4 to 64 characters'; end if;
  insert into px_mod_cfg (id, salt, pwhash) values (1, s, encode(sha256(convert_to(s || p_pw, 'utf8')), 'hex'))
    on conflict (id) do update set salt = excluded.salt, pwhash = excluded.pwhash, fails = 0, strikes = 0, locked_until = null;
end $$;

-- 'ok' (the owner) | 'helper' (the weaker account) | 'wrong' | 'locked' | 'setup' (it returns instead of raising so a wrong guess is still counted)
create or replace function public.px_mod_check(p_pw text) returns text language plpgsql security definer set search_path = public as $$
declare c px_mod_cfg;
begin
  perform set_config('px.who', '', true);
  select * into c from px_mod_cfg where id = 1 for update;
  if not found or c.pwhash is null then return 'setup'; end if;
  if c.locked_until is not null and c.locked_until > now() then return 'locked'; end if;
  if p_pw is not null and length(p_pw) <= 64 then
    if encode(sha256(convert_to(c.salt || p_pw, 'utf8')), 'hex') = c.pwhash then
      if c.fails > 0 or c.strikes > 0 then update px_mod_cfg set fails = 0, strikes = 0 where id = 1; end if;
      perform set_config('px.who', 'owner', true);
      return 'ok';
    elsif c.hhash is not null and encode(sha256(convert_to(c.hsalt || p_pw, 'utf8')), 'hex') = c.hhash then
      if c.fails > 0 then update px_mod_cfg set fails = 0 where id = 1; end if;
      perform set_config('px.who', 'helper', true);
      return 'helper';
    end if;
  end if;
  if c.fails + 1 >= 5 then
    update px_mod_cfg set fails = 0, strikes = c.strikes + 1, locked_until = now() + make_interval(mins => least(1440, (15 * power(2, c.strikes))::int)) where id = 1;
    insert into px_mod_log (act, note) values ('lockout', 'five wrong passwords in a row');
  else
    update px_mod_cfg set fails = c.fails + 1 where id = 1;
  end if;
  return 'wrong';
end $$;

-- for the calls a helper may make too: 'ok' for either account
create or replace function public.px_mod_check_h(p_pw text) returns text language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin return case when v = 'helper' then 'ok' else v end; end $$;
create or replace function public.px_is_helper() returns boolean language sql stable security definer set search_path = public as $$ select coalesce(current_setting('px.who', true), '') = 'helper' $$;
create or replace function public.px_is_staff(p_uid text) returns boolean language sql stable security definer set search_path = public as $$ select exists (select 1 from px_staff where uid = p_uid) $$;
-- the log remembers who did each thing
create or replace function public.px_mod_log_who() returns trigger language plpgsql as $$
begin new.who := case when coalesce(current_setting('px.who', true), '') = 'helper' then 'helper' else 'owner' end; return new; end $$;
drop trigger if exists px_mod_log_who on public.px_mod_log;
create trigger px_mod_log_who before insert on public.px_mod_log for each row execute function public.px_mod_log_who();

-- a helper can give at most 30 levels in any 24 hours
create or replace function public.px_levels_left() returns int language sql stable security definer set search_path = public as $$
  select greatest(0, 30 - coalesce((select sum(n) from px_levels where who = 'helper' and at > now() - interval '24 hours'), 0))::int $$;

-- the helper's own password, set once by the owner in the SQL Editor (see the end of this file); it has to differ from the owner's
create or replace function public.px_mod_set_helper_password(p_pw text) returns void language plpgsql security definer set search_path = public as $$
declare s text := replace(gen_random_uuid()::text, '-', ''); c px_mod_cfg;
begin
  select * into c from px_mod_cfg where id = 1;
  if not found or c.pwhash is null then raise exception 'set the main mod password first'; end if;
  if p_pw is null or length(p_pw) < 4 or length(p_pw) > 64 then raise exception 'password: 4 to 64 characters'; end if;
  if encode(sha256(convert_to(c.salt || p_pw, 'utf8')), 'hex') = c.pwhash then raise exception 'the helper password has to be different from yours'; end if;
  update px_mod_cfg set hsalt = s, hhash = encode(sha256(convert_to(s || p_pw, 'utf8')), 'hex') where id = 1;
end $$;
create or replace function public.px_mod_clear_helper_password() returns void language sql security definer set search_path = public as $$ update px_mod_cfg set hsalt = null, hhash = null where id = 1 $$;

-- logging in: remembers this device as staff (so a helper can never act on the owner), and logs a helper coming in
create or replace function public.px_mod_login(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); nm text;
begin
  if v not in ('ok', 'helper') then return jsonb_build_object('err', v); end if;
  if p_uid is not null and length(p_uid) between 8 and 32 then
    select name into nm from px_players where uid = p_uid;
    insert into px_staff (uid, role, name) values (p_uid, case when v = 'ok' then 'owner' else 'helper' end, nm)
      on conflict (uid) do update set role = case when px_staff.role = 'owner' or excluded.role = 'owner' then 'owner' else 'helper' end, name = coalesce(excluded.name, px_staff.name);
  end if;
  if v = 'helper' then insert into px_mod_log (act, target, note) values ('helper login', coalesce(p_uid, '?'), coalesce(nm, '')); end if;
  return jsonb_build_object('role', case when v = 'ok' then 'owner' else 'helper' end, 'lv_left', px_levels_left());
end $$;

create or replace function public.px_mod_blocks(p_uid text) returns int language plpgsql security definer set search_path = public as $$
declare n int := 0;
begin
  if to_regclass('public.turf') is null then return 0; end if;
  begin execute 'select count(*) from public.turf where owner_uid = $1 and owner_id is not null and claimed_at >= px_turf_week()' into n using p_uid; exception when others then n := 0; end;
  return coalesce(n, 0);
end $$;

create or replace function public.px_ms(t timestamptz) returns bigint language sql immutable as $$ select case when t is null then null else (extract(epoch from t) * 1000)::bigint end $$;

-- the numbers on the front page
create or replace function public.px_mod_overview(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); o jsonb; vers jsonb; blocks int := 0; owners int := 0; ann jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_object_agg(ver, n), '{}') into vers from (select coalesce(info ->> 'ver', '?') as ver, count(*) n from px_players group by 1 order by 2 desc limit 8) q;
  if to_regclass('public.turf') is not null then
    begin execute 'select count(*), count(distinct owner_uid) from public.turf where owner_id is not null and claimed_at >= px_turf_week()' into blocks, owners; exception when others then blocks := 0; end;
  end if;
  select jsonb_build_object('id', id, 'x', x, 'until', px_ms(until)) into ann from px_announce where until > now() order by id desc limit 1;
  select jsonb_build_object(
    'players', count(*), 'online', count(*) filter (where seen > now() - interval '40 seconds'),
    'day', count(*) filter (where seen > now() - interval '1 day'), 'week', count(*) filter (where seen > now() - interval '7 days'),
    'new_day', count(*) filter (where created > now() - interval '1 day'), 'new_week', count(*) filter (where created > now() - interval '7 days'),
    'rebirthed', count(*) filter (where rb > 0), 'avg_lv', round(coalesce(avg(lv), 0)::numeric, 1),
    'ranked_f', count(*) filter (where gf > 0), 'ranked_h', count(*) filter (where gh > 0),
    'top_f', coalesce(max(elo_f) filter (where gf > 0), 0), 'top_h', coalesce(max(elo_h) filter (where gh > 0), 0),
    'hours', round((coalesce(sum((info ->> 'play')::numeric), 0) / 3600.0), 1)) into o from px_players;
  o := o || jsonb_build_object('bans', (select count(*) from px_bans where kind = 'ban' and (until is null or until > now())),
    'mutes', (select count(*) from px_bans where kind = 'mute' and (until is null or until > now())),
    'matches', (select count(*) from px_matches where done), 'matches_day', (select count(*) from px_matches where done and at > now() - interval '1 day'),
    'chat_hour', (select count(*) from px_msgs where kind = 'm' and at > now() - interval '1 hour'),
    'blocks', blocks, 'owners', owners, 'vers', vers, 'ann', ann,
    'grades', (select coalesce(jsonb_object_agg(coalesce(grade, '?'), n), '{}') from (select grade, count(*) n from px_players group by 1) g),
    'suggest_new', (select count(*) from px_suggest where status = 'new'));
  if px_is_helper() then
    o := jsonb_build_object('helper', true, 'online', o -> 'online', 'day', o -> 'day', 'players', o -> 'players', 'chat_hour', o -> 'chat_hour', 'mutes', o -> 'mutes', 'suggest_new', o -> 'suggest_new', 'ann', o -> 'ann', 'lv_left', px_levels_left());
  end if;
  return o;
end $$;

-- everyone who has ever opened the game: search, sort, filter
create or replace function public.px_mod_players(p_pw text, p_q text, p_sort text, p_filter text, p_limit int, p_offset int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); ord text; wh text := 'true'; q text := nullif(btrim(coalesce(p_q, '')), ''); tot int; rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  ord := case p_sort when 'name' then 'lower(name) asc' when 'lv' then 'rb desc, lv desc' when 'elo_f' then 'elo_f desc' when 'elo_h' then 'elo_h desc' when 'new' then 'created desc'
    when 'games' then '(gf + gh) desc' when 'play' then 'coalesce((info ->> ''play'')::numeric, 0) desc' else 'seen desc' end;
  if p_filter = 'online' then wh := 'seen > now() - interval ''40 seconds''';
  elsif p_filter = 'day' then wh := 'seen > now() - interval ''1 day''';
  elsif p_filter = 'banned' then wh := 'px_is_banned(uid) or px_is_banned(uid, ''mute'')';
  elsif p_filter = 'ranked' then wh := '(gf + gh) > 0';
  elsif p_filter = 'staff' then wh := 'uid in (select uid from px_staff)';
  elsif p_filter in ('freshman', 'sophomore', 'junior', 'senior') then wh := 'grade = ' || quote_literal(p_filter);
  elsif p_filter = 'nograde' then wh := 'grade is null'; end if;
  if q is not null then wh := wh || ' and (name ilike ' || quote_literal('%' || replace(replace(q, '%', ''), '_', '') || '%') || ' or uid like ' || quote_literal(replace(replace(q, '%', ''), '_', '') || '%') || ')'; end if;
  execute 'select count(*) from px_players where ' || wh into tot;
  execute 'select coalesce(jsonb_agg(x), ''[]'') from (select jsonb_build_object(''uid'', uid, ''n'', name, ''lv'', lv, ''rb'', rb, ''st'', st, ''grade'', grade, ''seen'', px_ms(seen), ''created'', px_ms(created),
      ''on'', seen > now() - interval ''40 seconds'', ''ef'', elo_f, ''gf'', gf, ''wf'', wf, ''eh'', elo_h, ''gh'', gh, ''wh'', wh, ''info'', info,
      ''ban'', (select jsonb_build_object(''until'', px_ms(b.until), ''why'', b.reason) from px_bans b where b.uid = px_players.uid and b.kind = ''ban'' and (b.until is null or b.until > now())),
      ''mute'', (select jsonb_build_object(''until'', px_ms(b.until), ''why'', b.reason) from px_bans b where b.uid = px_players.uid and b.kind = ''mute'' and (b.until is null or b.until > now())),
      ''blocks'', px_mod_blocks(uid)) as x from px_players where ' || wh || ' order by ' || ord || ' limit ' || least(greatest(coalesce(p_limit, 25), 1), 100) || ' offset ' || greatest(coalesce(p_offset, 0), 0) || ') q' into rows;
  return jsonb_build_object('total', tot, 'rows', rows);
end $$;

-- one player in full: stats, last ranked matches, last chat lines, blocks
create or replace function public.px_mod_player(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); pl px_players; ms jsonb; ch jsonb; bl jsonb := '[]'; bans jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select * into pl from px_players where uid = p_uid;
  if not found then return jsonb_build_object('err', 'nobody'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('g', game, 'at', px_ms(at), 'opp', coalesce((select name from px_players o where o.uid = case when m.a = p_uid then m.b else m.a end), '?'),
      'won', case when not done then null when (m.a = p_uid) = (m.ra = 'W') then true else false end, 'd', case when m.a = p_uid then da else db end, 'done', done) order by at desc), '[]') into ms
    from (select * from px_matches m where a = p_uid or b = p_uid order by at desc limit 12) m;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'x', x, 'ts', px_ms(at)) order by id desc), '[]') into ch from (select * from px_msgs where uid = p_uid and kind = 'm' order by id desc limit 15) q;
  if to_regclass('public.turf') is not null then
    begin execute 'select coalesce(jsonb_agg(jsonb_build_object(''id'', id, ''defenses'', defenses, ''at'', px_ms(claimed_at))), ''[]'') from public.turf where owner_uid = $1 and owner_id is not null and claimed_at >= px_turf_week()' into bl using p_uid; exception when others then bl := '[]'; end;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('k', kind, 'full', "full", 'why', reason, 'at', px_ms(at), 'until', px_ms(until), 'active', (until is null or until > now()))), '[]') into bans from px_bans where uid = p_uid;
  return jsonb_build_object('uid', pl.uid, 'n', pl.name, 'grade', pl.grade, 'lv', pl.lv, 'rb', pl.rb, 'st', pl.st, 'seen', px_ms(pl.seen), 'created', px_ms(pl.created), 'on', pl.seen > now() - interval '40 seconds',
    'ef', pl.elo_f, 'gf', pl.gf, 'wf', pl.wf, 'eh', pl.elo_h, 'gh', pl.gh, 'wh', pl.wh, 'info', pl.info, 'matches', ms, 'chat', ch, 'blocks', bl, 'bans', bans, 'staff', (select role from px_staff where uid = p_uid), 'lv_left', px_levels_left(), 'helper', px_is_helper());
end $$;

create or replace function public.px_mod_chat(p_pw text, p_limit int, p_before bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', coalesce((select name from px_players o where o.uid = q.uid), q.n), 'g', grade, 'x', x, 'ts', px_ms(at), 'ban', px_is_banned(uid), 'mute', px_is_banned(uid, 'mute')) order by id desc), '[]') into rows
    from (select * from px_msgs where kind = 'm' and (p_before is null or id < p_before) order by id desc limit least(greatest(coalesce(p_limit, 40), 1), 150)) q;
  return jsonb_build_object('rows', rows);
end $$;

create or replace function public.px_mod_delmsg(p_pw text, p_id bigint, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); n int := 0; who text; snip text; wn text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_id is not null then
    select uid, left(x, 80) into who, snip from px_msgs where id = p_id;
    if who is null then return jsonb_build_object('ok', true, 'n', 0); end if;
    if px_is_helper() and px_is_staff(who) then return jsonb_build_object('err', 'staff'); end if;
    delete from px_msgs where id = p_id; get diagnostics n = row_count;
    insert into px_dels (mid, uid) values (p_id, null);   -- every game still showing that line drops it
    select name into wn from px_players where uid = who;
    insert into px_mod_log (act, target, note) values ('delete chat', who || ' (' || coalesce(wn, '?') || ')', '"' || coalesce(snip, '') || '"');
  elsif p_uid is not null then
    if px_is_helper() and px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
    delete from px_msgs where uid = p_uid and kind = 'm'; get diagnostics n = row_count;
    insert into px_dels (mid, uid) values (null, p_uid);   -- everything they ever said disappears from every screen
    select name into wn from px_players where uid = p_uid;
    insert into px_mod_log (act, target, note) values ('delete all chat', p_uid || ' (' || coalesce(wn, '?') || ')', n || ' line(s)');
  end if;
  if random() < 0.05 then delete from px_dels where at < now() - interval '2 days'; end if;
  return jsonb_build_object('ok', true, 'n', n);
end $$;

-- ban (can't play online: chat, Quick Match, ranked, Turf Wars, and the game shuts its online screens) or mute (can't chat)
create or replace function public.px_mod_ban(p_pw text, p_uid text, p_kind text, p_hours numeric, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); nm text; hrs numeric := p_hours;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_kind not in ('ban', 'mute') then return jsonb_build_object('err', 'bad kind'); end if;
  if px_is_helper() then
    if p_kind <> 'mute' then return jsonb_build_object('err', 'owner only'); end if;       -- a helper can mute, never ban
    if px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
    if hrs is null or hrs <= 0 or hrs > 24 then hrs := 24; end if;                          -- and for up to a day
  elsif p_kind = 'ban' and exists (select 1 from px_staff where uid = p_uid and role = 'owner') then return jsonb_build_object('err', 'that is an owner device'); end if;
  select name into nm from px_players where uid = p_uid;
  if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  insert into px_bans (uid, kind, name, reason, at, until, "full") values (p_uid, p_kind, nm, left(coalesce(p_reason, ''), 120), now(), case when hrs is null or hrs <= 0 then null else now() + make_interval(secs => (hrs * 3600)::int) end, false)
    on conflict (uid, kind) do update set name = excluded.name, reason = excluded.reason, at = now(), until = excluded.until, "full" = false;
  if p_kind = 'ban' then delete from px_queue where uid = p_uid; end if;
  insert into px_mod_log (act, target, note) values (p_kind, p_uid || ' (' || nm || ')', coalesce(case when hrs is null or hrs <= 0 then 'for good' else hrs || ' h' end, '') || ' · ' || left(coalesce(p_reason, ''), 120));
  return jsonb_build_object('ok', true);
end $$;

-- ban from the WHOLE game (the owner only): the game itself shuts, online or not
create or replace function public.px_mod_ban_game(p_pw text, p_uid text, p_hours numeric, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); nm text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if exists (select 1 from px_staff where uid = p_uid and role = 'owner') then return jsonb_build_object('err', 'that is an owner device'); end if;
  select name into nm from px_players where uid = p_uid;
  if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  insert into px_bans (uid, kind, name, reason, at, until, "full") values (p_uid, 'ban', nm, left(coalesce(p_reason, ''), 120), now(), case when p_hours is null or p_hours <= 0 then null else now() + make_interval(secs => (p_hours * 3600)::int) end, true)
    on conflict (uid, kind) do update set name = excluded.name, reason = excluded.reason, at = now(), until = excluded.until, "full" = true;
  delete from px_queue where uid = p_uid;
  insert into px_mod_log (act, target, note) values ('ban from game', p_uid || ' (' || nm || ')', coalesce(case when p_hours is null or p_hours <= 0 then 'for good' else p_hours || ' h' end, '') || ' · ' || left(coalesce(p_reason, ''), 120));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_unban(p_pw text, p_uid text, p_kind text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() then
    if p_kind is distinct from 'mute' then return jsonb_build_object('err', 'owner only'); end if;   -- a helper can only lift mutes
    if px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
  end if;
  delete from px_bans where uid = p_uid and (p_kind is null or kind = p_kind);
  insert into px_mod_log (act, target, note) values ('lift ' || coalesce(p_kind, 'ban+mute'), p_uid, '');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_bans(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', coalesce((select name from px_players p where p.uid = b.uid), b.name), 'k', kind, 'full', "full", 'why', reason, 'at', px_ms(at), 'until', px_ms(until)) order by at desc), '[]') into rows
    from px_bans b where until is null or until > now();
  return jsonb_build_object('rows', rows);
end $$;

-- fix a rating (reset to 1000 and 0 games, or set it by hand), or an unfit name
create or replace function public.px_mod_elo(p_pw text, p_uid text, p_game text, p_elo int, p_reset boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_game = 'h' then
    if p_reset then update px_players set elo_h = 1000, gh = 0, wh = 0 where uid = p_uid; else update px_players set elo_h = least(4000, greatest(100, p_elo)) where uid = p_uid; end if;
  else
    if p_reset then update px_players set elo_f = 1000, gf = 0, wf = 0 where uid = p_uid; else update px_players set elo_f = least(4000, greatest(100, p_elo)) where uid = p_uid; end if;
  end if;
  insert into px_mod_log (act, target, note) values (case when p_reset then 'reset elo' else 'set elo' end, p_uid, p_game || coalesce(' ' || p_elo, ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_rename(p_pw text, p_uid text, p_name text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); old text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select name into old from px_players where uid = p_uid;
  update px_players set name = left(coalesce(nullif(btrim(p_name), ''), 'Player'), 16) where uid = p_uid;
  insert into px_mod_log (act, target, note) values ('rename', p_uid, coalesce(old, '?') || ' → ' || left(coalesce(p_name, 'Player'), 16));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_matches(p_pw text, p_limit int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'g', game, 'at', px_ms(at), 'a', coalesce((select name from px_players p where p.uid = m.a), '?'), 'b', coalesce((select name from px_players p where p.uid = m.b), '?'),
    'au', a, 'bu', b, 'ra', ra, 'rb', rb, 'da', da, 'db', db, 'done', done) order by at desc), '[]') into rows
    from (select * from px_matches order by at desc limit least(greatest(coalesce(p_limit, 30), 1), 100)) m;
  return jsonb_build_object('rows', rows);
end $$;

-- Turf Wars: who holds what this week, release a block / a player's blocks / the whole map
create or replace function public.px_mod_turf(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); rows jsonb := '[]';
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if to_regclass('public.turf') is null then return jsonb_build_object('rows', '[]'::jsonb, 'none', true); end if;
  execute 'select coalesce(jsonb_agg(jsonb_build_object(''id'', id, ''own'', owner_name, ''uid'', owner_uid, ''def'', defenses, ''at'', px_ms(claimed_at), ''live'', owner_id is not null and claimed_at >= px_turf_week(), ''ev'', last_event) order by length(id), id), ''[]'') from public.turf' into rows;
  return jsonb_build_object('rows', rows);
end $$;

create or replace function public.px_mod_turf_release(p_pw text, p_mode text, p_arg text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); n int := 0;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if to_regclass('public.turf') is null then return jsonb_build_object('err', 'no turf table'); end if;
  perform set_config('px.mod', '1', true);
  if p_mode = 'block' then execute 'update public.turf set owner_id = null, owner_uid = null, owner_name = null, fighter = null, dna = null, defenses = 0, claimed_at = now() - interval ''30 days'', last_event = ''Released by a mod'' where id = $1' using p_arg;
  elsif p_mode = 'player' then execute 'update public.turf set owner_id = null, owner_uid = null, owner_name = null, fighter = null, dna = null, defenses = 0, claimed_at = now() - interval ''30 days'', last_event = ''Released by a mod'' where owner_uid = $1' using p_arg;
  elsif p_mode = 'all' then execute 'update public.turf set owner_id = null, owner_uid = null, owner_name = null, fighter = null, dna = null, defenses = 0, claimed_at = now() - interval ''30 days'', last_event = ''Map reset by a mod'' where owner_id is not null';
  else return jsonb_build_object('err', 'bad mode'); end if;
  get diagnostics n = row_count;
  insert into px_mod_log (act, target, note) values ('turf release', p_mode || ' ' || coalesce(p_arg, ''), n || ' block(s)');
  return jsonb_build_object('ok', true, 'n', n);
end $$;

-- a message every player sees once, the next time their game checks in
create or replace function public.px_mod_announce(p_pw text, p_text text, p_hours numeric) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_announce set until = now() where until > now();
  if p_text is not null and length(btrim(p_text)) > 0 then
    insert into px_announce (x, until) values (left(btrim(p_text), 200), now() + make_interval(secs => (least(greatest(coalesce(p_hours, 6), 0.1), 720) * 3600)::int));
    insert into px_mod_log (act, note) values ('announce', left(btrim(p_text), 120));
  else insert into px_mod_log (act, note) values ('announcement cleared', ''); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_log(p_pw text, p_limit int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_agg(jsonb_build_object('at', px_ms(at), 'act', act, 'target', target, 'note', note, 'who', who) order by id desc), '[]') into rows
    from (select * from px_mod_log order by id desc limit least(greatest(coalesce(p_limit, 60), 1), 200)) q;
  return jsonb_build_object('rows', rows);
end $$;

-- change a player's fighter: rebirth, level and stats. It waits until their game checks in (seconds, if it's open), which applies it
-- to their active fighter and works out the stat points that go with that level. p_edit: {rb, lv, max, st:{hp,spd,str,iq,sta,skl,men}} (stats as ranks)
create or replace function public.px_mod_edit(p_pw text, p_uid text, p_edit jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); k text; x numeric; rb_n int; lv_n int;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if not exists (select 1 from px_players where uid = p_uid) then return jsonb_build_object('err', 'nobody'); end if;
  if p_edit is null or jsonb_typeof(p_edit) <> 'object' or length(p_edit::text) > 600 then return jsonb_build_object('err', 'bad edit'); end if;
  rb_n := (p_edit ->> 'rb')::int; lv_n := (p_edit ->> 'lv')::int;
  if rb_n is not null and (rb_n < 0 or rb_n > 10) then return jsonb_build_object('err', 'rebirth 0-10'); end if;
  if lv_n is not null and (lv_n < 1 or lv_n > 300) then return jsonb_build_object('err', 'level 1-300'); end if;
  if p_edit ? 'st' then
    for k, x in select key, value::numeric from jsonb_each_text(p_edit -> 'st') loop
      if k not in ('hp', 'spd', 'str', 'iq', 'sta', 'skl', 'men') or x < 1 or x > 50 then return jsonb_build_object('err', 'bad stat ' || k); end if;
    end loop;
  end if;
  insert into px_edits (uid, edit) values (p_uid, p_edit);
  update px_players set lv = coalesce(lv_n, lv), rb = coalesce(rb_n, px_players.rb) where uid = p_uid;
  insert into px_mod_log (act, target, note) values ('edit fighter', p_uid, left(p_edit::text, 200));
  return jsonb_build_object('ok', true);
end $$;

-- a player's game says it applied these edits
create or replace function public.px_edit_done(p_uid text, p_key text, p_ids bigint[]) returns void language plpgsql security definer set search_path = public as $$
begin perform px_auth(p_uid, p_key); update px_edits set applied = true where uid = p_uid and id = any(p_ids); end $$;

-- a record, W-L, and the Elo that goes with it. Elo comes from the record by default: 1000 + 400 x log10((W+1)/(L+1)), so 10-2 is about 1226, 12-0 about 1446,
-- 5-5 is 1000 and 2-8 is about 800. Or give an exact Elo.
create or replace function public.px_mod_record(p_pw text, p_uid text, p_game text, p_w int, p_l int, p_elo int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); e int;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_game not in ('f', 'h') or p_w is null or p_l is null or p_w < 0 or p_l < 0 or p_w > 100000 or p_l > 100000 then return jsonb_build_object('err', 'bad record'); end if;
  e := least(4000, greatest(100, coalesce(p_elo, 1000 + round(400 * log((p_w + 1)::numeric / (p_l + 1)))::int)));
  if p_game = 'h' then update px_players set elo_h = e, gh = p_w + p_l, wh = p_w where uid = p_uid;
  else update px_players set elo_f = e, gf = p_w + p_l, wf = p_w where uid = p_uid; end if;
  insert into px_mod_log (act, target, note) values ('set record', p_uid, p_game || ' ' || p_w || '-' || p_l || ' elo ' || e);
  return jsonb_build_object('ok', true, 'elo', e);
end $$;

-- only the panel's own functions are open to the game; the password check and setup stay inside the database
revoke all on function public.px_mod_set_password(text), public.px_mod_check(text), public.px_mod_blocks(text), public.px_is_banned(text, text) from public, anon, authenticated;
grant execute on function public.px_edit_done(text, text, bigint[]), public.px_mod_edit(text, text, jsonb), public.px_mod_record(text, text, text, int, int, int) to anon, authenticated;
grant execute on function public.px_mod_overview(text), public.px_mod_players(text, text, text, text, int, int), public.px_mod_player(text, text), public.px_mod_chat(text, int, bigint),
  public.px_mod_delmsg(text, bigint, text), public.px_mod_ban(text, text, text, numeric, text), public.px_mod_unban(text, text, text), public.px_mod_bans(text),
  public.px_mod_elo(text, text, text, int, boolean), public.px_mod_rename(text, text, text), public.px_mod_matches(text, int), public.px_mod_turf(text),
  public.px_mod_turf_release(text, text, text), public.px_mod_announce(text, text, numeric), public.px_mod_log(text, int) to anon, authenticated;


-- ===== grades, suggestions, room codes, and a no-websocket way to connect =====
-- Everyone picks a grade once; Global chat is one room per grade (the mods see every grade in their panel).
create or replace function public.px_set_grade(p_uid text, p_key text, p_grade text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players;
begin
  r := px_auth(p_uid, p_key);
  if p_grade is null or p_grade not in ('freshman', 'sophomore', 'junior', 'senior') then raise exception 'bad grade'; end if;
  if r.grade is not null then return jsonb_build_object('grade', r.grade, 'kept', true); end if; -- once
  update px_players set grade = p_grade where uid = p_uid;
  return jsonb_build_object('grade', p_grade);
end $$;

-- a mod can set or clear someone's grade (clearing makes the game ask them again)
create or replace function public.px_mod_grade(p_pw text, p_uid text, p_grade text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_grade is not null and p_grade not in ('freshman', 'sophomore', 'junior', 'senior') then return jsonb_build_object('err', 'bad grade'); end if;
  update px_players set grade = p_grade where uid = p_uid;
  insert into px_mod_log (act, target, note) values ('set grade', p_uid, coalesce(p_grade, 'cleared'));
  return jsonb_build_object('ok', true);
end $$;

-- suggestions from players, for the mods to read
create table if not exists public.px_suggest (
  id bigserial primary key, at timestamptz not null default now(), uid text not null, name text not null default 'Player', grade text,
  x text not null, status text not null default 'new', note text
);
alter table public.px_suggest enable row level security;
revoke all on public.px_suggest from anon, authenticated;

create or replace function public.px_suggest(p_uid text, p_key text, p_x text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; recent int; t text := btrim(coalesce(p_x, ''));
begin
  r := px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then raise exception 'banned'; end if;
  if length(t) < 4 then raise exception 'too short'; end if;
  select count(*) into recent from px_suggest where uid = p_uid and at > now() - interval '1 hour';
  if recent >= 4 then raise exception 'slow down'; end if;
  insert into px_suggest (uid, name, grade, x) values (p_uid, r.name, r.grade, left(t, 500));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_suggestions(p_pw text, p_status text, p_limit int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', coalesce((select name from px_players o where o.uid = q.uid), q.name), 'g', grade, 'x', x, 'ts', px_ms(at), 'st', status) order by id desc), '[]') into rows
    from (select * from px_suggest where (p_status is null or p_status = 'all' or status = p_status) order by id desc limit least(greatest(coalesce(p_limit, 60), 1), 200)) q;
  return jsonb_build_object('rows', rows, 'new', (select count(*) from px_suggest where status = 'new'));
end $$;

create or replace function public.px_mod_suggest_set(p_pw text, p_id bigint, p_status text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_status = 'delete' then if px_is_helper() then return jsonb_build_object('err', 'owner only'); end if; delete from px_suggest where id = p_id;
  elsif p_status in ('new', 'seen', 'done', 'no') then update px_suggest set status = p_status where id = p_id;
  else return jsonb_build_object('err', 'bad status'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 4-digit room codes: a host claims one so two rooms can't share it (a claim lapses after 3 hours or when the host leaves)
create table if not exists public.px_rooms (code text primary key, game text not null default '', uid text not null, at timestamptz not null default now());
alter table public.px_rooms enable row level security;
revoke all on public.px_rooms from anon, authenticated;

create or replace function public.px_room_claim(p_uid text, p_key text, p_code text, p_game text) returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform px_auth(p_uid, p_key);
  if p_code is null or p_code !~ '^[0-9]{4}$' then return false; end if;
  insert into px_rooms (code, game, uid) values (p_code, left(coalesce(p_game, ''), 8), p_uid)
    on conflict (code) do update set uid = excluded.uid, game = excluded.game, at = now() where px_rooms.uid = excluded.uid or px_rooms.at < now() - interval '3 hours';
  get diagnostics n = row_count;
  if random() < 0.05 then delete from px_rooms where at < now() - interval '3 hours'; end if;
  return n > 0;
end $$;

create or replace function public.px_room_release(p_uid text, p_key text, p_code text) returns void language plpgsql security definer set search_path = public as $$
begin perform px_auth(p_uid, p_key); delete from px_rooms where code = p_code and uid = p_uid; end $$;

-- when the live-link service can't be reached (a network that blocks it, or it's down): rooms talk through plain web requests instead
create table if not exists public.px_sig (id bigserial primary key, room text not null, frm text not null, d jsonb not null, at timestamptz not null default now());
create index if not exists px_sig_room on public.px_sig (room, id);
alter table public.px_sig enable row level security;
revoke all on public.px_sig from anon, authenticated;

create or replace function public.px_sig_send(p_uid text, p_key text, p_room text, p_from text, p_d jsonb) returns bigint language plpgsql security definer set search_path = public as $$
declare nid bigint;
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then raise exception 'banned'; end if;
  if p_room is null or length(p_room) > 40 or p_from is null or length(p_from) > 24 or jsonb_typeof(p_d) <> 'array' or length(p_d::text) > 12000 then raise exception 'bad message'; end if;
  insert into px_sig (room, frm, d) values (p_room, p_from, p_d) returning id into nid;
  if random() < 0.03 then delete from px_sig where at < now() - interval '3 minutes'; end if;
  return nid;
end $$;

-- everything new in a room since p_since (-1: just tell me where the room is now)
create or replace function public.px_sig_poll(p_room text, p_since bigint, p_from text) returns jsonb language plpgsql security definer set search_path = public as $$
declare mx bigint; rows jsonb;
begin
  if p_room is null or length(p_room) > 40 then return jsonb_build_object('last', 0, 'rows', '[]'::jsonb); end if;
  select coalesce(max(id), 0) into mx from px_sig where room = p_room;
  if coalesce(p_since, -1) < 0 then return jsonb_build_object('last', mx, 'rows', '[]'::jsonb); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'f', frm, 'd', d) order by id), '[]') into rows
    from (select * from px_sig where room = p_room and id > p_since and frm <> coalesce(p_from, '') order by id limit 80) q;
  return jsonb_build_object('last', greatest(mx, coalesce(p_since, 0)), 'rows', rows);
end $$;

grant execute on function public.px_set_grade(text, text, text), public.px_mod_grade(text, text, text), public.px_suggest(text, text, text),
  public.px_mod_suggestions(text, text, int), public.px_mod_suggest_set(text, bigint, text), public.px_room_claim(text, text, text, text),
  public.px_room_release(text, text, text), public.px_sig_send(text, text, text, text, jsonb), public.px_sig_poll(text, bigint, text) to anon, authenticated;


-- give levels: a relative edit ("+n levels") on the player's active fighter, applied when their game checks in.
-- The owner can give up to 100 at a time; a helper up to 30 in any 24 hours, and never to staff.
create or replace function public.px_mod_give_levels(p_pw text, p_uid text, p_n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); nm text; left_ int;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_n is null or p_n < 1 then return jsonb_build_object('err', 'pick 1 or more levels'); end if;
  select name into nm from px_players where uid = p_uid;
  if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  if px_is_helper() then
    if px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
    left_ := px_levels_left();
    if p_n > left_ then return jsonb_build_object('err', 'limit', 'lv_left', left_); end if;
  elsif p_n > 100 then return jsonb_build_object('err', 'up to 100 at a time'); end if;
  insert into px_edits (uid, edit) values (p_uid, jsonb_build_object('addlv', p_n));
  insert into px_levels (uid, n, who) values (p_uid, p_n, case when px_is_helper() then 'helper' else 'owner' end);
  insert into px_mod_log (act, target, note) values ('give levels', p_uid || ' (' || nm || ')', '+' || p_n);
  return jsonb_build_object('ok', true, 'lv_left', px_levels_left());
end $$;

grant execute on function public.px_mod_login(text, text), public.px_mod_ban_game(text, text, numeric, text), public.px_mod_give_levels(text, text, int) to anon, authenticated;
revoke all on function public.px_mod_check_h(text), public.px_is_helper(), public.px_is_staff(text), public.px_levels_left(), public.px_mod_set_helper_password(text), public.px_mod_clear_helper_password(), public.px_mod_log_who() from public, anon, authenticated;

-- ONE-TIME, PRIVATE: set the mod password by running this single line yourself in the SQL Editor (don't save it into this file):
--   select px_mod_set_password('your password here');
-- Same way, once, for your helper (a weaker mod: chat moderation, 30 levels a day, no bans; you see everything they do in the Log tab).
-- It has to be different from yours:
--   select px_mod_set_helper_password('their password here');
-- To switch their access off:   select px_mod_clear_helper_password();
