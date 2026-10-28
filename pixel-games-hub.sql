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
alter table public.px_bans add column if not exists "by" text not null default 'owner';   -- who set it: owner or helper (a helper can lift only their own bans)
alter table public.px_bans add column if not exists "full" boolean not null default false;   -- true: banned from the whole game, not just online play
create table if not exists public.px_staff (uid text primary key, role text not null, name text, at timestamptz not null default now());
alter table public.px_staff drop constraint if exists px_staff_role_check;
alter table public.px_staff add constraint px_staff_role_check check (role in ('owner', 'moderator', 'helper'));   -- creator (owner) > moderator > helper
-- each helper gets their own name and password, so the log shows who did what and each has their own 30 levels a day
create table if not exists public.px_helpers (name text primary key, salt text not null, hash text not null, added timestamptz not null default now(), last_login timestamptz);
alter table public.px_helpers enable row level security; revoke all on public.px_helpers from anon, authenticated;
alter table public.px_mod_log add column if not exists by_name text;
alter table public.px_mod_log add column if not exists by_email text;
alter table public.px_bans add column if not exists by_name text;
alter table public.px_staff add column if not exists hname text;
create table if not exists public.px_dels (id bigserial primary key, at timestamptz not null default now(), mid bigint, uid text);   -- chat lines a mod deleted: every game drops them
create table if not exists public.px_levels (id bigserial primary key, at timestamptz not null default now(), uid text, n int not null, who text not null);
alter table public.px_levels add column if not exists hname text;
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
  perform px_google_touch(p_uid);   -- (signed in with Google? remember whose account this device is)
  update px_players set name = coalesce(left(p_name, 16), name), lv = coalesce(p_lv, lv), rb = coalesce(p_rb, rb), st = coalesce(left(p_st, 40), st), seen = now(),
    info = case when p_info is not null and jsonb_typeof(p_info) = 'object' and length(p_info::text) < 1800 then p_info else info end where uid = p_uid returning * into r;
  select count(*) into onl from px_players where seen > now() - interval '40 seconds';
  select * into bn from px_bans where uid = p_uid and kind = 'ban' and (until is null or until > now());
  select * into mu from px_bans where uid = p_uid and kind = 'mute' and (until is null or until > now());
  select jsonb_build_object('id', id, 'x', x) into ann from px_announce where until > now() order by id desc limit 1;
  if bn.uid is not null then -- banned: no chat, no people, just the news that they are
    return jsonb_build_object('last', 0, 'msgs', '[]'::jsonb, 'people', null, 'online', onl, 'ann', ann, 'cfg', px_pub_cfg(),
      'ban', jsonb_build_object('until', case when bn.until is null then null else (extract(epoch from bn.until) * 1000)::bigint end, 'why', bn.reason, 'full', bn."full"),
      'me', jsonb_build_object('ef', r.elo_f, 'gf', r.gf, 'wf', r.wf, 'eh', r.elo_h, 'gh', r.gh, 'wh', r.wh, 'grade', r.grade, 'staff', px_staff_rank(p_uid)));
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
  return jsonb_build_object('last', mx, 'msgs', msgs, 'people', ppl, 'online', onl, 'ann', ann, 'cfg', px_pub_cfg(), 'edits', eds, 'dels', dels, 'dmax', dcur,
    'mute', case when mu.uid is null then null else jsonb_build_object('until', case when mu.until is null then null else (extract(epoch from mu.until) * 1000)::bigint end, 'why', mu.reason) end,
    'me', jsonb_build_object('ef', r.elo_f, 'gf', r.gf, 'wf', r.wf, 'eh', r.elo_h, 'gh', r.gh, 'wh', r.wh, 'grade', r.grade, 'staff', px_staff_rank(p_uid)));
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

-- a fighter nobody could really have (a stat above what their rebirth allows, a rebirth that doesn't exist) can't hold a block
create or replace function public.px_turf_check_fighter(f jsonb) returns void language plpgsql immutable as $$
declare rb int := 0; cap int;
begin
  if f is null then return; end if;
  if (f ->> 'rebirths') ~ '^[0-9]{1,3}$' then rb := (f ->> 'rebirths')::int; end if;
  if rb > 10 then raise exception 'That fighter''s rebirths don''t add up'; end if;
  cap := 20 + 2 * rb;   -- (the stat cap in the game: 100 at rebirth 0, +10 for every rebirth, as ranks of 5)
  if jsonb_typeof(f -> 'stats') = 'object' and exists (select 1 from jsonb_each_text(f -> 'stats') e where e.value !~ '^[0-9]{1,3}(\.[0-9]+)?$' or e.value::numeric > cap + 0.001) then
    raise exception 'That fighter''s stats don''t add up';
  end if;
end $$;

-- an attack starts: checks it's allowed and hands out the ticket
create or replace function public.px_turf_start(p_uid text, p_key text, p_fid text, p_block text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t record; nid bigint; live_owner text; live_uid text;
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then raise exception 'You are banned from online play'; end if;
  if coalesce((select turf_minver from px_mod_cfg where id = 1), 0) > coalesce((select case when (info ->> 'ver') ~ '^[0-9]{1,4}$' then (info ->> 'ver')::int end from px_players where uid = p_uid), 0) then
    raise exception 'Update the game to play Turf Wars (it needs version %)', (select turf_minver from px_mod_cfg where id = 1);   -- (the owner can set this in the panel)
  end if;
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
  perform px_turf_check_fighter(p_fighter);
  select * into t from turf where id = k.block for update;
  if t.owner_id is not null and t.claimed_at >= px_turf_week() then live_owner := t.owner_id; end if;
  if live_owner is distinct from k.owner_was then raise exception 'Someone else took that block first'; end if;
  -- who held it before (and when), newest first, eight deep: the weekly crown is worked out from this
  hist := jsonb_build_array(jsonb_build_object('o', t.owner_id, 'n', t.owner_name, 'at', coalesce((extract(epoch from t.claimed_at) * 1000)::bigint, 0)))
    || coalesce((select jsonb_agg(h) from (select h from jsonb_array_elements(coalesce(t.fighter -> 'hist', '[]'::jsonb)) h limit 7) q), '[]'::jsonb);
  insert into px_turf_log (uid, name, block, secs, owner_was, owner_name, won, tk) values (p_uid, left(coalesce(p_name, 'Player'), 24), k.block, secs, k.owner_was, t.owner_name, true, k.id);  -- (how long each win took: the mods look for ones that were too quick)
  if random() < 0.05 then delete from px_turf_log where at < now() - interval '30 days'; end if;
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
  insert into px_turf_log (uid, name, block, secs, owner_was, owner_name, won, tk) values (p_uid, (select name from px_players where uid = p_uid), k.block, extract(epoch from now() - k.started), k.owner_was, null, false, k.id);
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
declare c px_mod_cfg; su text; sk text; pl px_players; st px_staff;
begin
  perform set_config('px.who', '', true); perform set_config('px.hname', '', true); perform set_config('px.rank', '', true); perform set_config('px.suid', '', true);
  -- staff (helper, moderator, creator) are known by who they are, not by a password: "<player id>|<their secret key>"
  if p_pw is not null and position('|' in p_pw) > 0 and length(p_pw) <= 120 then
    su := split_part(p_pw, '|', 1); sk := substr(p_pw, position('|' in p_pw) + 1);
    select * into pl from px_players where uid = su and keyhash = md5(sk || ':pxk');
    if not found then return 'wrong'; end if;
    select * into st from px_staff where uid = su;
    if not found then return 'wrong'; end if;
    perform set_config('px.hname', coalesce(pl.name, 'Staff'), true); perform set_config('px.suid', su, true);
    if st.role = 'owner' then perform set_config('px.who', 'owner', true); perform set_config('px.rank', 'creator', true); return 'ok'; end if;
    perform set_config('px.who', 'helper', true); perform set_config('px.rank', case when st.role = 'moderator' then 'moderator' else 'helper' end, true);
    return 'helper';
  end if;
  -- the creator's own password (still there for the SQL Editor and as a spare; it's never asked for in the game)
  select * into c from px_mod_cfg where id = 1 for update;
  if not found or c.pwhash is null then return 'setup'; end if;
  if c.locked_until is not null and c.locked_until > now() then return 'locked'; end if;
  if p_pw is not null and length(p_pw) <= 64 then
    if encode(sha256(convert_to(c.salt || p_pw, 'utf8')), 'hex') = c.pwhash then
      if c.fails > 0 or c.strikes > 0 then update px_mod_cfg set fails = 0, strikes = 0 where id = 1; end if;
      perform set_config('px.who', 'owner', true); perform set_config('px.rank', 'creator', true);
      return 'ok';
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
create or replace function public.px_mod_check_h(p_pw text) returns text language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin return case when v = 'helper' then 'ok' else v end; end $$;
create or replace function public.px_is_helper() returns boolean language sql stable security definer set search_path = public as $$ select coalesce(current_setting('px.who', true), '') = 'helper' $$;
-- "is that player protected from me?": staff of the same rank or higher can't be banned, muted or edited by a helper or moderator
create or replace function public.px_is_staff(p_uid text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from px_staff s where s.uid = p_uid and (case s.role when 'owner' then 3 when 'moderator' then 2 else 1 end) >= (case coalesce(current_setting('px.rank', true), '') when 'moderator' then 2 when 'creator' then 3 else 1 end)) $$;
create or replace function public.px_rank() returns text language sql stable security definer set search_path = public as $$ select coalesce(nullif(current_setting('px.rank', true), ''), 'creator') $$;
create or replace function public.px_staff_rank(p_uid text) returns text language sql stable security definer set search_path = public as $$
  select case role when 'owner' then 'creator' else role end from px_staff where uid = p_uid $$;
-- the log remembers who did each thing
create or replace function public.px_mod_log_who() returns trigger language plpgsql as $$
begin new.who := case when coalesce(current_setting('px.who', true), '') = 'helper' then (case when coalesce(current_setting('px.rank', true), '') = 'moderator' then 'moderator' else 'helper' end) else 'owner' end;
  new.by_name := case when new.who <> 'owner' then coalesce(nullif(current_setting('px.hname', true), ''), 'Staff') end;
  new.by_email := px_google_email(); return new; end $$;
drop trigger if exists px_mod_log_who on public.px_mod_log;
create trigger px_mod_log_who before insert on public.px_mod_log for each row execute function public.px_mod_log_who();

-- a helper can give at most 30 levels in any 24 hours
create or replace function public.px_levels_left() returns int language sql stable security definer set search_path = public as $$
  select greatest(0, (case when current_setting('px.rank', true) = 'moderator' then 100 else 30 end) - coalesce((select sum(n) from px_levels where who = 'helper' and hname = coalesce(nullif(current_setting('px.suid', true), ''), '?') and at > now() - interval '24 hours'), 0))::int $$;  -- (each person has their own: 30 a day for a helper, 100 for a moderator)

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
  if v = 'helper' and (select coalesce(req_helper, false) from px_mod_cfg where id = 1) and px_google_email() is null then return jsonb_build_object('err', 'google'); end if;   -- (staff have to be signed in with their email when the creator says so)
  if v = 'ok' and position('|' in coalesce(p_pw, '')) = 0 and p_uid is not null and length(p_uid) between 8 and 32 then   -- (the creator's password from the SQL Editor: that player becomes a creator)
    select name into nm from px_players where uid = p_uid;
    insert into px_staff (uid, role, name) values (p_uid, 'owner', nm) on conflict (uid) do update set role = 'owner', name = coalesce(excluded.name, px_staff.name);
  end if;
  if v = 'helper' then insert into px_mod_log (act, target, note) values ('staff login', coalesce(current_setting('px.suid', true), '?'), px_rank()); end if;
  return jsonb_build_object('role', case when v = 'ok' then 'owner' else 'helper' end, 'rank', px_rank(), 'lv_left', px_levels_left(), 'name', nullif(current_setting('px.hname', true), ''), 'email', px_google_email());
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
  elsif p_filter = 'nograde' then wh := 'grade is null';
  elsif p_filter = 'signed' then wh := 'uid in (select uid from px_google)';
  elsif p_filter = 'nosign' then wh := 'uid not in (select uid from px_google)'; end if;
  if q is not null then wh := wh || ' and (name ilike ' || quote_literal('%' || replace(replace(q, '%', ''), '_', '') || '%') || ' or uid like ' || quote_literal(replace(replace(q, '%', ''), '_', '') || '%') || ' or uid in (select uid from px_google where email ilike ' || quote_literal('%' || replace(replace(q, '%', ''), '_', '') || '%') || '))'; end if;
  execute 'select count(*) from px_players where ' || wh into tot;
  execute 'select coalesce(jsonb_agg(x), ''[]'') from (select jsonb_build_object(''uid'', uid, ''n'', name, ''lv'', lv, ''rb'', rb, ''st'', st, ''grade'', grade, ''seen'', px_ms(seen), ''created'', px_ms(created),
      ''on'', seen > now() - interval ''40 seconds'', ''ef'', elo_f, ''gf'', gf, ''wf'', wf, ''eh'', elo_h, ''gh'', gh, ''wh'', wh, ''info'', info,
      ''ban'', (select jsonb_build_object(''until'', px_ms(b.until), ''why'', b.reason) from px_bans b where b.uid = px_players.uid and b.kind = ''ban'' and (b.until is null or b.until > now())),
      ''mute'', (select jsonb_build_object(''until'', px_ms(b.until), ''why'', b.reason) from px_bans b where b.uid = px_players.uid and b.kind = ''mute'' and (b.until is null or b.until > now())),
      ''email'', (select g.email from px_google g where g.uid = px_players.uid), ''blocks'', px_mod_blocks(uid)) as x from px_players where ' || wh || ' order by ' || ord || ' limit ' || least(greatest(coalesce(p_limit, 25), 1), 100) || ' offset ' || greatest(coalesce(p_offset, 0), 0) || ') q' into rows;
  return jsonb_build_object('total', tot, 'rows', rows);
end $$;

-- one player in full: stats, last ranked matches, last chat lines, blocks
create or replace function public.px_mod_player(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); pl px_players; ms jsonb; ch jsonb; bl jsonb := '[]'; bans jsonb; lk jsonb; lg jsonb; tf jsonb;
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
  select coalesce(jsonb_agg(jsonb_build_object('k', kind, 'full', "full", 'why', reason, 'by', "by", 'at', px_ms(at), 'until', px_ms(until), 'active', (until is null or until > now()))), '[]') into bans from px_bans where uid = p_uid;
  lk := '[]'::jsonb;   -- (everyone at school uses the same computers, so "same device" says nothing: only the same email links accounts)
  -- other devices signed in with the same Google account
  select coalesce(jsonb_agg(jsonb_build_object('uid', q.uid, 'n', q.name, 'seen', px_ms(q.seen), 'created', px_ms(q.created), 'lv', q.lv, 'staff', exists (select 1 from px_staff s where s.uid = q.uid), 'g', true,
      'ban', exists (select 1 from px_bans b where b.uid = q.uid and b.kind = 'ban' and (b.until is null or b.until > now()))) order by q.seen desc), '[]') into lg
    from (select o.* from px_players o join px_google g on g.uid = o.uid where o.uid <> p_uid and g.sub = (select sub from px_google where uid = p_uid) order by o.seen desc limit 12) q;
  lk := coalesce(lk, '[]'::jsonb) || (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(lg) x where not exists (select 1 from jsonb_array_elements(coalesce(lk, '[]'::jsonb)) y where y ->> 'uid' = x ->> 'uid'));
  -- how this player's Turf fights went, and how long the wins took
  select jsonb_build_object('w', count(*) filter (where won), 'l', count(*) filter (where not won), 'fast', count(*) filter (where won and secs < 12), 'min', min(secs) filter (where won), 'avg', avg(secs) filter (where won),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('b', block, 's', round(secs::numeric, 1), 'won', won, 'from', owner_name, 'at', px_ms(at)) order by id desc) from (select * from px_turf_log where uid = p_uid order by id desc limit 8) r), '[]')) into tf
    from px_turf_log where uid = p_uid and at > now() - interval '14 days';
  return jsonb_build_object('linked', lk, 'turf', tf, 'uid', pl.uid, 'n', pl.name, 'grade', pl.grade, 'lv', pl.lv, 'rb', pl.rb, 'st', pl.st, 'seen', px_ms(pl.seen), 'created', px_ms(pl.created), 'on', pl.seen > now() - interval '40 seconds',
    'ef', pl.elo_f, 'gf', pl.gf, 'wf', pl.wf, 'eh', pl.elo_h, 'gh', pl.gh, 'wh', pl.wh, 'info', pl.info, 'matches', ms, 'chat', ch, 'blocks', bl, 'bans', bans, 'google', (select g.email from px_google g where g.uid = p_uid), 'cloud', (select px_ms(cl.at) from px_cloud cl join px_google g2 on g2.sub = cl.sub where g2.uid = p_uid), 'staff', (select role from px_staff where uid = p_uid), 'sname', (select hname from px_staff where uid = p_uid), 'lv_left', px_levels_left(), 'helper', px_is_helper());
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
    if px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;          -- a helper can ban and mute anyone but the staff
  elsif p_kind = 'ban' and exists (select 1 from px_staff where uid = p_uid and role = 'owner') then return jsonb_build_object('err', 'that is an owner device'); end if;
  select name into nm from px_players where uid = p_uid;
  if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  insert into px_bans (uid, kind, name, reason, at, until, "full", "by", by_name) values (p_uid, p_kind, nm, left(coalesce(p_reason, ''), 120), now(), case when hrs is null or hrs <= 0 then null else now() + make_interval(secs => (hrs * 3600)::int) end, false, case when px_is_helper() then 'helper' else 'owner' end, case when px_is_helper() then coalesce(nullif(current_setting('px.hname', true), ''), 'Helper') end)
    on conflict (uid, kind) do update set name = excluded.name, reason = excluded.reason, at = now(), until = excluded.until, "full" = false, "by" = excluded."by", by_name = excluded.by_name;
  if p_kind = 'ban' then delete from px_queue where uid = p_uid; end if;
  insert into px_mod_log (act, target, note) values (p_kind, p_uid || ' (' || nm || ')', coalesce(case when hrs is null or hrs <= 0 then 'for good' else hrs || ' h' end, '') || ' · ' || left(coalesce(p_reason, ''), 120));
  return jsonb_build_object('ok', true);
end $$;

-- ban from the WHOLE game: the game itself shuts, online or not
create or replace function public.px_mod_ban_game(p_pw text, p_uid text, p_hours numeric, p_reason text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); nm text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() and px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
  if exists (select 1 from px_staff where uid = p_uid and role = 'owner') then return jsonb_build_object('err', 'that is an owner device'); end if;
  select name into nm from px_players where uid = p_uid;
  if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  insert into px_bans (uid, kind, name, reason, at, until, "full", "by", by_name) values (p_uid, 'ban', nm, left(coalesce(p_reason, ''), 120), now(), case when p_hours is null or p_hours <= 0 then null else now() + make_interval(secs => (p_hours * 3600)::int) end, true, case when px_is_helper() then 'helper' else 'owner' end, case when px_is_helper() then coalesce(nullif(current_setting('px.hname', true), ''), 'Helper') end)
    on conflict (uid, kind) do update set name = excluded.name, reason = excluded.reason, at = now(), until = excluded.until, "full" = true, "by" = excluded."by", by_name = excluded.by_name;
  delete from px_queue where uid = p_uid;
  insert into px_mod_log (act, target, note) values ('ban from game', p_uid || ' (' || nm || ')', coalesce(case when p_hours is null or p_hours <= 0 then 'for good' else p_hours || ' h' end, '') || ' · ' || left(coalesce(p_reason, ''), 120));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_unban(p_pw text, p_uid text, p_kind text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() then
    if px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
    -- a helper can lift any mute and any ban they set themselves, but not a ban the owner set
    if exists (select 1 from px_bans where uid = p_uid and kind = 'ban' and "by" <> 'helper' and (until is null or until > now()) and (p_kind is null or p_kind = 'ban')) then
      if p_kind is null then delete from px_bans where uid = p_uid and kind = 'mute'; insert into px_mod_log (act, target, note) values ('lift mute', p_uid, ''); end if;
      return jsonb_build_object('err', 'owner only');
    end if;
  end if;
  delete from px_bans where uid = p_uid and (p_kind is null or kind = p_kind);
  insert into px_mod_log (act, target, note) values ('lift ' || coalesce(p_kind, 'ban+mute'), p_uid, '');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_bans(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', coalesce((select name from px_players p where p.uid = b.uid), b.name), 'k', kind, 'full', "full", 'why', reason, 'by', "by", 'bn', by_name, 'at', px_ms(at), 'until', px_ms(until)) order by at desc), '[]') into rows
    from px_bans b where until is null or until > now();
  return jsonb_build_object('rows', rows);
end $$;

-- fix a rating (reset to 1000 and 0 games, or set it by hand), or an unfit name
create or replace function public.px_mod_elo(p_pw text, p_uid text, p_game text, p_elo int, p_reset boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() and not (px_rank() = 'moderator' and coalesce(p_reset, false)) then return jsonb_build_object('err', 'owner only'); end if;   -- (a moderator can reset an Elo, only the creator can set one)
  if px_is_helper() and px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
  if p_game = 'h' then
    if p_reset then update px_players set elo_h = 1000, gh = 0, wh = 0 where uid = p_uid; else update px_players set elo_h = least(4000, greatest(100, p_elo)) where uid = p_uid; end if;
  else
    if p_reset then update px_players set elo_f = 1000, gf = 0, wf = 0 where uid = p_uid; else update px_players set elo_f = least(4000, greatest(100, p_elo)) where uid = p_uid; end if;
  end if;
  insert into px_mod_log (act, target, note) values (case when p_reset then 'reset elo' else 'set elo' end, p_uid, p_game || coalesce(' ' || p_elo, ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_rename(p_pw text, p_uid text, p_name text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); old text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() and px_is_staff(p_uid) then return jsonb_build_object('err', 'staff'); end if;
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
declare v text := px_mod_check_h(p_pw); rows jsonb := '[]';
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if to_regclass('public.turf') is null then return jsonb_build_object('rows', '[]'::jsonb, 'none', true); end if;
  execute 'select coalesce(jsonb_agg(jsonb_build_object(''id'', id, ''own'', owner_name, ''uid'', owner_uid, ''def'', defenses, ''at'', px_ms(claimed_at), ''live'', owner_id is not null and claimed_at >= px_turf_week(), ''ev'', last_event) order by length(id), id), ''[]'') from public.turf' into rows;
  return jsonb_build_object('minver', (select turf_minver from px_mod_cfg where id = 1), 'rows', rows, 'watch', px_turf_watch(), 'log', coalesce((select jsonb_agg(jsonb_build_object('uid', uid, 'n', name, 'b', block, 's', round(secs::numeric, 1), 'from', owner_name, 'at', px_ms(at), 'rp', (select r.id from px_replays r where r.tk = q.tk)) order by id desc) from (select * from px_turf_log where won order by id desc limit 30) q), '[]'));
end $$;

create or replace function public.px_mod_turf_release(p_pw text, p_mode text, p_arg text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); n int := 0;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_mode = 'all' and px_is_helper() then return jsonb_build_object('err', 'owner only'); end if;   -- (a helper can release a block or one player's blocks, not wipe the map)
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
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() then p_hours := least(coalesce(p_hours, 1), case when px_rank() = 'moderator' then 24 else 1 end); end if;   -- (a helper's announcement lasts an hour at most, a moderator's a day)
  update px_announce set until = now() where until > now();
  if p_text is not null and length(btrim(p_text)) > 0 then
    insert into px_announce (x, until) values (left(btrim(p_text), 200), now() + make_interval(secs => (least(greatest(coalesce(p_hours, 6), 0.1), 720) * 3600)::int));
    insert into px_mod_log (act, note) values ('announce', left(btrim(p_text), 120));
  else insert into px_mod_log (act, note) values ('announcement cleared', ''); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_log(p_pw text, p_limit int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() and px_rank() <> 'moderator' then return jsonb_build_object('err', 'owner only'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('at', px_ms(at), 'act', act, 'target', target, 'note', note, 'who', who, 'by', by_name, 'em', by_email) order by id desc), '[]') into rows
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
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() and px_rank() <> 'moderator' then return jsonb_build_object('err', 'owner only'); end if;
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
  if p_status = 'delete' then if px_is_helper() and px_rank() <> 'moderator' then return jsonb_build_object('err', 'owner only'); end if; delete from px_suggest where id = p_id;
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
  insert into px_levels (uid, n, who, hname) values (p_uid, p_n, case when px_is_helper() then 'helper' else 'owner' end, case when px_is_helper() then coalesce(nullif(current_setting('px.suid', true), ''), '?') end);
  insert into px_mod_log (act, target, note) values ('give levels', p_uid || ' (' || nm || ')', '+' || p_n);
  return jsonb_build_object('ok', true, 'lv_left', px_levels_left());
end $$;

grant execute on function public.px_mod_login(text, text), public.px_mod_ban_game(text, text, numeric, text), public.px_mod_give_levels(text, text, int) to anon, authenticated;
revoke all on function public.px_mod_check_h(text), public.px_is_helper(), public.px_is_staff(text), public.px_levels_left(), public.px_mod_set_helper_password(text), public.px_mod_clear_helper_password(), public.px_mod_log_who() from public, anon, authenticated;

-- how long each Turf fight took (so the mods can spot wins that were too quick to be real fights)
create table if not exists public.px_turf_log (id bigserial primary key, at timestamptz not null default now(), uid text, name text, block text, secs real, owner_was text, owner_name text, won boolean not null default true);
create index if not exists px_turf_log_uid on public.px_turf_log (uid, id desc);
alter table public.px_turf_log add column if not exists tk bigint;   -- (the fight ticket, so a win can be matched to its recording)
alter table public.px_turf_log enable row level security;
revoke all on public.px_turf_log from anon, authenticated;

-- the staff chat: the owner and the helper(s) talk to each other, nobody else can read it
create table if not exists public.px_staffchat (id bigserial primary key, at timestamptz not null default now(), uid text, role text not null, name text, x text not null);
alter table public.px_staffchat enable row level security;
revoke all on public.px_staffchat from anon, authenticated;
create or replace function public.px_staff_say(p_pw text, p_uid text, p_x text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); t text := btrim(left(coalesce(p_x, ''), 400)); nm text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if t = '' then return jsonb_build_object('err', 'empty'); end if;
  select name into nm from px_players where uid = p_uid;
  insert into px_staffchat (uid, role, name, x) values (p_uid, case when px_is_helper() then px_rank() else 'owner' end, left(coalesce(nullif(current_setting('px.hname', true), ''), nm, 'Staff'), 24), t);
  if random() < 0.05 then delete from px_staffchat where at < now() - interval '30 days'; end if;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_staff_list(p_pw text, p_since bigint default 0) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb; mx bigint;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(max(id), 0) into mx from px_staffchat;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'r', role, 'n', name, 'x', x, 'at', px_ms(at), 'u', uid) order by id), '[]') into rows
    from (select * from px_staffchat where id > coalesce(p_since, 0) order by id desc limit 150) q;
  return jsonb_build_object('rows', rows, 'last', mx);
end $$;
grant execute on function public.px_staff_say(text, text, text), public.px_staff_list(text, bigint) to anon, authenticated;

-- ---------- helpers, one account each (the owner manages them in the panel's Overview tab, or here) ----------
-- the list: who they are, when they last logged in, what they've done this week, levels given today
create or replace function public.px_mod_helpers(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); rows jsonb; c px_mod_cfg; lg jsonb := '[]';
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select * into c from px_mod_cfg where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('n', h.name, 'added', px_ms(h.added), 'login', px_ms(h.last_login),
      'acts', (select count(*) from px_mod_log l where l.by_name = h.name and l.act <> 'helper login' and l.at > now() - interval '7 days'),
      'lv', coalesce((select sum(n) from px_levels x where x.who = 'helper' and x.hname = h.name and x.at > now() - interval '24 hours'), 0)) order by h.name), '[]') into rows from px_helpers h;
  if c.hhash is not null then   -- the old single helper password still works until you remove it
    lg := jsonb_build_array(jsonb_build_object('n', 'Helper', 'shared', true, 'login', (select px_ms(max(at)) from px_mod_log where act = 'helper login' and by_name = 'Helper'),
      'acts', (select count(*) from px_mod_log l where l.by_name = 'Helper' and l.act <> 'helper login' and l.at > now() - interval '7 days'),
      'lv', coalesce((select sum(n) from px_levels x where x.who = 'helper' and coalesce(x.hname, 'Helper') = 'Helper' and x.at > now() - interval '24 hours'), 0)));
  end if;
  return jsonb_build_object('rows', lg || rows);
end $$;
-- add a helper (or change their password): a name for the log and their own password
create or replace function public.px_mod_helper_set(p_pw text, p_name text, p_hpw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); c px_mod_cfg; h px_helpers; nm text := btrim(coalesce(p_name, '')); s text := replace(gen_random_uuid()::text, '-', ''); fresh boolean;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if nm !~ '^[A-Za-z0-9 _.-]{2,16}$' then return jsonb_build_object('err', 'name: 2 to 16 letters or numbers'); end if;
  if lower(nm) = 'helper' or lower(nm) = 'owner' then return jsonb_build_object('err', 'pick a real name for them (not "' || nm || '")'); end if;
  if p_hpw is null or length(p_hpw) < 4 or length(p_hpw) > 64 then return jsonb_build_object('err', 'password: 4 to 64 characters'); end if;
  select * into c from px_mod_cfg where id = 1;
  if encode(sha256(convert_to(c.salt || p_hpw, 'utf8')), 'hex') = c.pwhash then return jsonb_build_object('err', 'that''s your own password; give them a different one'); end if;
  if c.hhash is not null and encode(sha256(convert_to(c.hsalt || p_hpw, 'utf8')), 'hex') = c.hhash then return jsonb_build_object('err', 'that''s the old shared helper password; pick a new one'); end if;
  for h in select * from px_helpers where lower(name) <> lower(nm) loop
    if encode(sha256(convert_to(h.salt || p_hpw, 'utf8')), 'hex') = h.hash then return jsonb_build_object('err', 'another helper already has that password'); end if;
  end loop;
  fresh := not exists (select 1 from px_helpers where lower(name) = lower(nm));
  delete from px_helpers where lower(name) = lower(nm);
  insert into px_helpers (name, salt, hash) values (nm, s, encode(sha256(convert_to(s || p_hpw, 'utf8')), 'hex'));
  insert into px_mod_log (act, target, note) values (case when fresh then 'add helper' else 'new helper password' end, nm, '');
  return jsonb_build_object('ok', true);
end $$;
-- take a helper away (their password stops working at once); "Helper" is the old shared one
create or replace function public.px_mod_helper_remove(p_pw text, p_name text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_name = 'Helper' then update px_mod_cfg set hsalt = null, hhash = null where id = 1;
  else delete from px_helpers where name = p_name; end if;
  delete from px_staff where role = 'helper' and hname = p_name;   -- (their device is no longer protected as staff)
  insert into px_mod_log (act, target, note) values ('remove helper', coalesce(p_name, '?'), '');
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_helpers(text), public.px_mod_helper_set(text, text, text), public.px_mod_helper_remove(text, text) to anon, authenticated;

-- ---------- Sign in with Google ----------
-- The game signs people in with Supabase Auth (Google). Their requests then carry a signed login token and the database reads the
-- email straight from it, so nobody can claim an email that isn't theirs. Nothing else about the game changes: a device keeps its
-- own online profile, and signing in just attaches the Google account to it.
alter table public.px_mod_cfg add column if not exists req_game boolean not null default false;     -- everyone has to be signed in to play
alter table public.px_mod_cfg add column if not exists req_helper boolean not null default false;
alter table public.px_mod_cfg add column if not exists dm_mode text not null default 'all';   -- private messages: all | grade | off   -- helpers have to be signed in to open the panel
alter table public.px_mod_cfg add column if not exists upd_until timestamptz;   -- the game is being updated: every game pauses behind a "please hold" screen until then (or until the owner ends it)
create table if not exists public.px_google (uid text primary key, sub text not null, email text not null, at timestamptz not null default now(), seen timestamptz not null default now());
create index if not exists px_google_sub on public.px_google (sub);
alter table public.px_google enable row level security;
revoke all on public.px_google from anon, authenticated;
create or replace function public.px_jwt() returns jsonb language sql stable security definer set search_path = public as $$
  select case when coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') ~ '^\{' then current_setting('request.jwt.claims', true)::jsonb else '{}'::jsonb end $$;
-- the verified email of whoever's login token came with this request (null for an ordinary, not signed in request)
create or replace function public.px_google_email() returns text language sql stable security definer set search_path = public as $$
  select case when px_jwt() ->> 'role' = 'authenticated' and coalesce(px_jwt() ->> 'email', '') <> '' then lower(px_jwt() ->> 'email') end $$;
create or replace function public.px_google_touch(p_uid text) returns void language plpgsql security definer set search_path = public as $$
declare e text := px_google_email(); sb text := px_jwt() ->> 'sub';
begin
  if e is null or sb is null then return; end if;
  insert into px_google (uid, sub, email) values (p_uid, sb, left(e, 120)) on conflict (uid) do update set sub = excluded.sub, email = excluded.email, seen = now();
end $$;
-- what every game is told each time it checks in
create or replace function public.px_pub_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('reqg', coalesce((select req_game from px_mod_cfg where id = 1), false), 'upd', coalesce((select upd_until > now() from px_mod_cfg where id = 1), false), 'dm', coalesce((select dm_mode from px_mod_cfg where id = 1), 'all')) $$;
-- the owner's switches
create or replace function public.px_mod_google_cfg(p_pw text, p_game boolean, p_helper boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_game is not null then update px_mod_cfg set req_game = p_game where id = 1; insert into px_mod_log (act, target, note) values ('google for everyone', case when p_game then 'required' else 'optional' end, ''); end if;
  if p_helper is not null then update px_mod_cfg set req_helper = p_helper where id = 1; insert into px_mod_log (act, target, note) values ('google for helpers', case when p_helper then 'required' else 'optional' end, ''); end if;
  return (select jsonb_build_object('game', req_game, 'helper', req_helper, 'linked', (select count(*) from px_google)) from px_mod_cfg where id = 1);
end $$;
create or replace function public.px_mod_google_get(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return (select jsonb_build_object('game', req_game, 'helper', req_helper, 'linked', (select count(*) from px_google), 'players', (select count(*) from px_players), 'upd', case when upd_until > now() then px_ms(upd_until) end) from px_mod_cfg where id = 1);
end $$;
-- the owner pauses every game for an update (and lets them back in when it's done); it ends by itself after p_mins in case it's forgotten
create or replace function public.px_mod_update_mode(p_pw text, p_on boolean, p_mins int default 20) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_mod_cfg set upd_until = case when p_on then now() + make_interval(mins => least(greatest(coalesce(p_mins, 20), 1), 120)) end where id = 1;
  insert into px_mod_log (act, target, note) values (case when p_on then 'update started' else 'update finished' end, '', case when p_on then 'every game is paused' else '' end);
  return (select jsonb_build_object('upd', case when upd_until > now() then px_ms(upd_until) end) from px_mod_cfg where id = 1);
end $$;
grant execute on function public.px_mod_google_cfg(text, boolean, boolean), public.px_mod_google_get(text), public.px_mod_update_mode(text, boolean, int) to anon, authenticated;
revoke all on function public.px_jwt(), public.px_google_email(), public.px_google_touch(text), public.px_pub_cfg() from public, anon, authenticated;

-- ---------- Cloud backup (for people signed in with Google): the save follows the Google account, not the browser ----------
-- Clearing a browser, a school laptop that wipes itself, a new device: sign in with Google and the fighters come back. The backup is
-- only ever handed to the Google account it belongs to (the database reads who that is from the login token).
create table if not exists public.px_cloud (sub text primary key, email text, uid text, data jsonb not null, bytes int, at timestamptz not null default now());
alter table public.px_cloud enable row level security;
revoke all on public.px_cloud from anon, authenticated;
drop function if exists public.px_cloud_put(text, text, jsonb);
create or replace function public.px_cloud_put(p_uid text, p_key text, p_data jsonb, p_base bigint default null, p_force boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare sb text := px_jwt() ->> 'sub'; e text := px_google_email(); n int := length(coalesce(p_data::text, '')); c px_cloud;
begin
  perform px_auth(p_uid, p_key);
  if sb is null or e is null then return jsonb_build_object('err', 'signin'); end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' or n < 20 or n > 900000 then return jsonb_build_object('err', 'size'); end if;
  select * into c from px_cloud where sub = sb for update;
  -- a device that hasn't seen the newest backup can't write over it (it has to ask the player first)
  if found and not coalesce(p_force, false) and px_ms(c.at) is distinct from p_base then return jsonb_build_object('err', 'newer', 'at', px_ms(c.at)); end if;
  insert into px_cloud (sub, email, uid, data, bytes) values (sb, left(e, 120), p_uid, p_data, n)
    on conflict (sub) do update set email = excluded.email, uid = excluded.uid, data = excluded.data, bytes = excluded.bytes, at = now();
  return jsonb_build_object('ok', true, 'at', (select px_ms(at) from px_cloud where sub = sb));
end $$;
-- what's in the backup (no save data): when, and who the fighters are
create or replace function public.px_cloud_meta() returns jsonb language plpgsql security definer set search_path = public as $$
declare sb text := px_jwt() ->> 'sub'; c px_cloud;
begin
  if sb is null or px_google_email() is null then return jsonb_build_object('err', 'signin'); end if;
  select * into c from px_cloud where sub = sb;
  if not found then return jsonb_build_object('has', false); end if;
  return jsonb_build_object('has', true, 'at', px_ms(c.at), 'uid', c.uid, 'bytes', c.bytes,
    'f', coalesce((select jsonb_agg(jsonb_build_object('n', x ->> 'name', 'lv', x -> 'level', 'rb', x -> 'rebirths')) from jsonb_array_elements(coalesce(c.data -> 'save' -> 'fighters', '[]'::jsonb)) x), '[]'::jsonb));
end $$;
create or replace function public.px_cloud_get() returns jsonb language plpgsql security definer set search_path = public as $$
declare sb text := px_jwt() ->> 'sub'; c px_cloud;
begin
  if sb is null or px_google_email() is null then return jsonb_build_object('err', 'signin'); end if;
  select * into c from px_cloud where sub = sb;
  if not found then return jsonb_build_object('has', false); end if;
  return jsonb_build_object('has', true, 'at', px_ms(c.at), 'data', c.data);
end $$;
grant execute on function public.px_cloud_put(text, text, jsonb, bigint, boolean), public.px_cloud_meta(), public.px_cloud_get() to anon, authenticated;

-- ---------- v15: the Turf watch list, and more for the helpers to do ----------
-- who holds land and how: number of blocks, how fast their wins were (a real fight takes a while), whether the clone's stats are possible,
-- whether other accounts on the same device hold land too. Anyone on the staff can read it; it only reads.
create or replace function public.px_turf_watch() returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb := '[]';
begin
  if to_regclass('public.turf') is null then return r; end if;
  begin
    execute $q$
      select coalesce(jsonb_agg(x order by (x ->> 'blocks')::int desc, (x ->> 'wins7')::int desc), '[]') from (
        select jsonb_build_object('uid', h.uid, 'n', coalesce(p.name, h.nm), 'blocks', h.blocks, 'wins7', coalesce(w.wins7, 0), 'wins1', coalesce(w.wins1, 0), 'losses7', coalesce(w.l7, 0),
          'fast', coalesce(w.fast, 0), 'min', w.mn, 'avg', w.av, 'maxst', h.maxst, 'rb', h.rb, 'lv', h.lv, 'alts', coalesce(a.alts, 0), 'altsblocks', coalesce(a.altsblocks, 0),
          'via', p.info ->> 'via', 'ver', case when (p.info ->> 'ver') ~ '^[0-9]{1,4}$' then (p.info ->> 'ver')::int end, 'tapes', coalesce(w.tapes, 0), 'flags', (
            select coalesce(jsonb_agg(f), '[]'::jsonb) from unnest(array_remove(array[
              case when h.blocks >= 5 then 'holds ' || h.blocks || ' blocks' end,
              case when coalesce(w.fast, 0) >= 3 and coalesce(w.fast, 0) * 2 >= coalesce(w.wins7, 0) then coalesce(w.fast, 0) || ' of ' || w.wins7 || ' wins were over almost as soon as the minimum time' end,
              case when coalesce(w.wins1, 0) >= 12 then w.wins1 || ' wins in the last 24 hours' end,
              case when coalesce(w.wins7, 0) >= 8 and coalesce(w.l7, 0) = 0 then 'has never lost a fight' end,
              case when h.maxst > 20 + 2 * least(h.rb, 10) then 'a stat of ' || (h.maxst * 5)::int || ' is above what rebirth ' || h.rb || ' allows' end,
              case when h.rb > 10 then 'rebirth ' || h.rb || ' does not exist' end,
              case when coalesce(a.altsblocks, 0) > 0 then 'another account with the same email holds land too' end,
              case when (p.info ->> 'ver') !~ '^[0-9]{1,4}$' then 'no game version reported (a very old or edited copy)' end,
              case when (p.info ->> 'ver') ~ '^[0-9]{1,4}$' and (p.info ->> 'ver')::int < (select coalesce(max((o2.info ->> 'ver')::int), 0) from px_players o2 where o2.seen > now() - interval '14 days' and (o2.info ->> 'ver') ~ '^[0-9]{1,4}$') - 1 then 'on v' || (p.info ->> 'ver') || ' while others are on a newer version' end,
              case when (p.info ->> 'ver') ~ '^[0-9]{1,4}$' and (p.info ->> 'ver')::int >= 15 and coalesce(w.wins7, 0) >= 3 and coalesce(w.tapes, 0) = 0 then 'none of ' || w.wins7 || ' wins has a recorded fight (this version always records them)' end
            ], null)) f)) x
        from (
          select t.owner_uid uid, max(t.owner_name) nm, count(*) blocks,
            max((select max(e.value::numeric) from jsonb_each_text(case when jsonb_typeof(t.fighter -> 'stats') = 'object' then t.fighter -> 'stats' else '{}'::jsonb end) e where e.value ~ '^[0-9]{1,6}(\.[0-9]+)?$')) maxst,
            max(case when (t.fighter ->> 'rebirths') ~ '^[0-9]{1,3}$' then (t.fighter ->> 'rebirths')::int else 0 end) rb,
            max(case when (t.fighter ->> 'level') ~ '^[0-9]{1,4}$' then (t.fighter ->> 'level')::int else 0 end) lv
          from public.turf t where t.owner_id is not null and t.owner_uid is not null and t.claimed_at >= px_turf_week() group by t.owner_uid) h
        left join px_players p on p.uid = h.uid
        left join lateral (select count(*) filter (where won and at > now() - interval '7 days') wins7, count(*) filter (where won and at > now() - interval '1 day') wins1,
            count(*) filter (where not won and at > now() - interval '7 days') l7, count(*) filter (where won and at > now() - interval '7 days' and exists (select 1 from px_replays r where r.tk = l.tk)) tapes,
            count(*) filter (where won and at > now() - interval '7 days' and secs < case when owner_was is null then 20 else 10 end) fast,
            min(secs) filter (where won and at > now() - interval '7 days') mn, avg(secs) filter (where won and at > now() - interval '7 days') av
          from px_turf_log l where l.uid = h.uid) w on true
        left join lateral (select count(*) alts, count(*) filter (where exists (select 1 from public.turf t2 where t2.owner_uid = o.uid and t2.owner_id is not null and t2.claimed_at >= px_turf_week())) altsblocks
          from px_players o where o.uid <> h.uid and exists (select 1 from px_google g1 join px_google g2 on g2.sub = g1.sub where g1.uid = h.uid and g2.uid = o.uid)) a on true
        order by h.blocks desc limit 15) z
    $q$ into r;
  exception when others then r := '[]'; end;
  return r;
end $$;
revoke all on function public.px_turf_watch(), public.px_turf_check_fighter(jsonb) from public, anon, authenticated;

-- private notes on a player, for the staff to leave each other ("watching this one", "warned them twice")
create table if not exists public.px_notes (id bigserial primary key, at timestamptz not null default now(), uid text not null, who text not null, by_name text, x text not null);
create index if not exists px_notes_uid on public.px_notes (uid, id desc);
alter table public.px_notes enable row level security; revoke all on public.px_notes from anon, authenticated;
create or replace function public.px_mod_notes(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', px_ms(at), 'who', who, 'by', by_name, 'x', x) order by id desc) from (select * from px_notes where uid = p_uid order by id desc limit 30) q), '[]'::jsonb));
end $$;
create or replace function public.px_mod_note_add(p_pw text, p_uid text, p_text text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_uid is null or length(btrim(coalesce(p_text, ''))) = 0 then return jsonb_build_object('err', 'empty'); end if;
  insert into px_notes (uid, who, by_name, x) values (p_uid, case when px_is_helper() then 'helper' else 'owner' end,
    case when px_is_helper() then coalesce(nullif(current_setting('px.hname', true), ''), 'Helper') end, left(btrim(p_text), 300));
  insert into px_mod_log (act, target, note) values ('note', p_uid, left(btrim(p_text), 120));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_mod_note_del(p_pw text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() and px_rank() <> 'moderator' then return jsonb_build_object('err', 'owner only'); end if;
  delete from px_notes where id = p_id; return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_notes(text, text), public.px_mod_note_add(text, text, text), public.px_mod_note_del(text, bigint) to anon, authenticated;


-- ---------- v15: recorded Turf fights (nobody sees any sign of it) ----------
-- the game saves each Turf fight as a small tape and sends it when the fight ends; the staff can watch them from the Turf tab and a player's page.
-- One per fight ticket, the last 14 days, the latest 60 per player.
create table if not exists public.px_replays (id bigserial primary key, at timestamptz not null default now(), tk bigint not null unique, uid text not null, name text, block text, won boolean, secs real, meta jsonb, tape text not null, bytes int);
create index if not exists px_replays_uid on public.px_replays (uid, id desc);
alter table public.px_replays enable row level security; revoke all on public.px_replays from anon, authenticated;
create or replace function public.px_replay_put(p_uid text, p_key text, p_tk bigint, p_block text, p_won boolean, p_secs real, p_meta jsonb, p_tape text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  if p_tape is null or length(p_tape) < 20 or length(p_tape) > 900000 or length(coalesce(p_meta::text, '')) > 30000 then return jsonb_build_object('err', 'size'); end if;
  if not exists (select 1 from px_turf_tickets where id = p_tk and uid = p_uid) then return jsonb_build_object('err', 'ticket'); end if;   -- (only for a real fight this player started)
  insert into px_replays (tk, uid, name, block, won, secs, meta, tape, bytes) values (p_tk, p_uid, (select name from px_players where uid = p_uid), left(coalesce(p_block, ''), 20), p_won, p_secs, p_meta, p_tape, length(p_tape))
    on conflict (tk) do nothing;
  if random() < 0.1 then
    delete from px_replays where at < now() - interval '14 days';
    delete from px_replays where uid = p_uid and id not in (select id from px_replays where uid = p_uid order by id desc limit 60);
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_replay_put(text, text, bigint, text, boolean, real, jsonb, text) to anon, authenticated;
-- the list (no tape in it): one player's, or the latest of everyone's
create or replace function public.px_mod_replays(p_pw text, p_uid text, p_limit int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', name, 'b', block, 'won', won, 's', round(secs::numeric, 1), 'at', px_ms(at), 'kb', (bytes / 1024), 'vs', meta ->> 'vs') order by id desc)
    from (select * from px_replays where p_uid is null or uid = p_uid order by id desc limit least(greatest(coalesce(p_limit, 30), 1), 80)) q), '[]'::jsonb));
end $$;
create or replace function public.px_mod_replay_get(p_pw text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); r px_replays;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select * into r from px_replays where id = p_id;
  if not found then return jsonb_build_object('err', 'gone'); end if;
  insert into px_mod_log (act, target, note) values ('watched replay', r.uid, coalesce(r.name, '?') || ' · ' || coalesce(r.block, ''));
  return jsonb_build_object('meta', r.meta, 'tape', r.tape, 'won', r.won, 's', r.secs, 'n', r.name, 'b', r.block, 'at', px_ms(r.at));
end $$;
grant execute on function public.px_mod_replays(text, text, int), public.px_mod_replay_get(text, bigint) to anon, authenticated;


-- the owner can say "Turf Wars needs at least this game version": older copies get told to update (0 = no rule)
alter table public.px_mod_cfg add column if not exists turf_minver int;
create or replace function public.px_mod_turf_minver(p_pw text, p_ver int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_mod_cfg set turf_minver = nullif(least(greatest(coalesce(p_ver, 0), 0), 9999), 0) where id = 1;
  insert into px_mod_log (act, note) values ('turf min version', coalesce(p_ver, 0)::text);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_turf_minver(text, int) to anon, authenticated;


-- ---------- v15: the phone: private messages and group chats ----------
-- Anyone can text anyone privately, and make group chats. A player can block anyone; a message can be reported (the staff see it with the lines around it).
-- The owner has three switches (Overview tab): everyone / same grade only / off. Muted and banned players can't text. Lines are filtered like Global chat.
create table if not exists public.px_threads (id bigserial primary key, kind text not null check (kind in ('dm', 'group')), name text, dm_key text unique, owner text, at timestamptz not null default now(), last_at timestamptz not null default now());
create table if not exists public.px_thread_members (thread bigint not null references public.px_threads (id) on delete cascade, uid text not null, joined timestamptz not null default now(), last_read bigint not null default 0, primary key (thread, uid));
create index if not exists px_thread_members_uid on public.px_thread_members (uid);
create table if not exists public.px_tmsgs (id bigserial primary key, thread bigint not null references public.px_threads (id) on delete cascade, uid text not null, x text not null, at timestamptz not null default now());
create index if not exists px_tmsgs_thread on public.px_tmsgs (thread, id desc);
create table if not exists public.px_dm_blocks (uid text not null, target text not null, at timestamptz not null default now(), primary key (uid, target));
create table if not exists public.px_dm_reports (id bigserial primary key, at timestamptz not null default now(), reporter text not null, thread bigint, msg bigint, target text, why text, done boolean not null default false, done_by text);
alter table public.px_threads enable row level security; alter table public.px_thread_members enable row level security; alter table public.px_tmsgs enable row level security;
alter table public.px_dm_blocks enable row level security; alter table public.px_dm_reports enable row level security;
revoke all on public.px_threads, public.px_thread_members, public.px_tmsgs, public.px_dm_blocks, public.px_dm_reports from anon, authenticated;
alter table public.px_mod_cfg add column if not exists dm_mode text not null default 'all';   -- all | grade | off

create or replace function public.px_dm_clean(x text) returns text language sql immutable as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(x, ''), '[\u0000-\u001f\u007f]', ' ', 'g'), '\s+', ' ', 'g')), 300) $$;
create or replace function public.px_dm_filter(x text) returns text language sql immutable as $$
  select regexp_replace(px_dm_clean(x), '\y(f+u+c+k+\w*|s+h+i+t+\w*|b+i+t+c+h+\w*|c+u+n+t+\w*|n+i+g+g+\w*|f+a+g+\w*|r+e+t+a+r+d+\w*|d+i+c+k+\w*|p+u+s+s+y+\w*|w+h+o+r+e+\w*|s+l+u+t+\w*)\y', '****', 'gi') $$;
-- may this player text right now?
create or replace function public.px_dm_gate(r px_players) returns void language plpgsql security definer set search_path = public as $$
declare m text := coalesce((select dm_mode from px_mod_cfg where id = 1), 'all');
begin
  if px_is_banned(r.uid) then raise exception 'banned'; end if;
  if px_is_banned(r.uid, 'mute') then raise exception 'muted'; end if;
  if m = 'off' then raise exception 'Messages are switched off right now'; end if;
end $$;
-- is this player (a) allowed to start a chat with that player?
create or replace function public.px_dm_can(a px_players, b_uid text) returns void language plpgsql security definer set search_path = public as $$
declare b px_players; m text := coalesce((select dm_mode from px_mod_cfg where id = 1), 'all');
begin
  select * into b from px_players where uid = b_uid;
  if not found then raise exception 'nobody'; end if;
  if exists (select 1 from px_dm_blocks where uid = b_uid and target = a.uid) then raise exception 'unavailable'; end if;   -- (they blocked me: it just doesn't go through)
  if exists (select 1 from px_dm_blocks where uid = a.uid and target = b_uid) then raise exception 'You blocked that player'; end if;
  if m = 'grade' and a.grade is distinct from b.grade then raise exception 'You can only message people in your grade right now'; end if;
end $$;

-- find a player by name to text them
create or replace function public.px_dm_find(p_uid text, p_key text, p_q text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; q text := lower(btrim(coalesce(p_q, ''))); m text := coalesce((select dm_mode from px_mod_cfg where id = 1), 'all');
begin
  r := px_auth(p_uid, p_key);
  if length(q) < 1 then return jsonb_build_object('rows', '[]'::jsonb); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('u', uid, 'n', name, 'lv', lv, 'rb', rb, 'on', seen > now() - interval '40 seconds') order by (seen > now() - interval '40 seconds') desc, seen desc)
    from (select * from px_players o where o.uid <> p_uid and o.seen > now() - interval '60 days' and lower(o.name) like '%' || replace(replace(q, '%', ''), '_', '') || '%'
        and (m <> 'grade' or o.grade is not distinct from r.grade) and not exists (select 1 from px_dm_blocks b where b.uid = o.uid and b.target = p_uid) and not px_is_banned(o.uid) order by (o.seen > now() - interval '40 seconds') desc, o.seen desc limit 12) q2), '[]'::jsonb));
end $$;

-- start (or find) a private chat with someone
create or replace function public.px_dm_open(p_uid text, p_key text, p_with text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; k text; t bigint;
begin
  r := px_auth(p_uid, p_key); perform px_dm_gate(r);
  if p_with is null or p_with = p_uid then raise exception 'nobody'; end if;
  perform px_dm_can(r, p_with);
  k := least(p_uid, p_with) || '|' || greatest(p_uid, p_with);
  select id into t from px_threads where dm_key = k;
  if t is null then
    if (select count(*) from px_threads where owner = p_uid and at > now() - interval '1 hour') >= 15 then raise exception 'slow down'; end if;
    insert into px_threads (kind, dm_key, owner) values ('dm', k, p_uid) returning id into t;
  end if;
  insert into px_thread_members (thread, uid) values (t, p_uid) on conflict do nothing;
  return jsonb_build_object('thread', t);
end $$;

-- a group chat of your own (up to 12 people)
create or replace function public.px_dm_group(p_uid text, p_key text, p_name text, p_members text[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; t bigint; u text; n int := 0; nm text := left(px_dm_filter(p_name), 24);
begin
  r := px_auth(p_uid, p_key); perform px_dm_gate(r);
  if length(nm) < 1 then nm := 'Group chat'; end if;
  if (select count(*) from px_threads where owner = p_uid and kind = 'group' and at > now() - interval '1 hour') >= 6 then raise exception 'slow down'; end if;
  if (select count(*) from px_threads t2 join px_thread_members m on m.thread = t2.id where m.uid = p_uid and t2.kind = 'group') >= 30 then raise exception 'You are in too many group chats'; end if;
  insert into px_threads (kind, name, owner) values ('group', nm, p_uid) returning id into t;
  insert into px_thread_members (thread, uid) values (t, p_uid);
  foreach u in array coalesce(p_members, '{}') loop
    exit when n >= 11;
    if u = p_uid or u is null then continue; end if;
    begin perform px_dm_can(r, u); exception when others then continue; end;
    insert into px_thread_members (thread, uid) values (t, u) on conflict do nothing; n := n + 1;
  end loop;
  insert into px_tmsgs (thread, uid, x) values (t, '-', coalesce(r.name, 'Someone') || ' made the group');
  return jsonb_build_object('thread', t);
end $$;
create or replace function public.px_dm_add(p_uid text, p_key text, p_thread bigint, p_members text[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; u text; n int := 0; th px_threads; cur int; w text;
begin
  r := px_auth(p_uid, p_key); perform px_dm_gate(r);
  select * into th from px_threads where id = p_thread and kind = 'group' and owner = p_uid;
  if not found then raise exception 'Only the person who made the group can add people'; end if;
  select count(*) into cur from px_thread_members where thread = p_thread;
  foreach u in array coalesce(p_members, '{}') loop
    exit when cur + n >= 12;
    begin perform px_dm_can(r, u); exception when others then continue; end;
    insert into px_thread_members (thread, uid) values (p_thread, u) on conflict do nothing;
    if found then n := n + 1; select name into w from px_players where uid = u; insert into px_tmsgs (thread, uid, x) values (p_thread, '-', coalesce(w, 'Someone') || ' was added'); end if;
  end loop;
  return jsonb_build_object('added', n);
end $$;
create or replace function public.px_dm_leave(p_uid text, p_key text, p_thread bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; th px_threads;
begin
  r := px_auth(p_uid, p_key);
  select * into th from px_threads where id = p_thread; if not found then return jsonb_build_object('ok', true); end if;
  delete from px_thread_members where thread = p_thread and uid = p_uid;
  if th.kind = 'group' then
    if not exists (select 1 from px_thread_members where thread = p_thread) then delete from px_threads where id = p_thread;
    else insert into px_tmsgs (thread, uid, x) values (p_thread, '-', coalesce(r.name, 'Someone') || ' left'); if th.owner = p_uid then update px_threads set owner = (select uid from px_thread_members where thread = p_thread order by joined limit 1) where id = p_thread; end if; end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_dm_send(p_uid text, p_key text, p_thread bigint, p_x text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; th px_threads; x text := px_dm_filter(p_x); nid bigint; o text;
begin
  r := px_auth(p_uid, p_key); perform px_dm_gate(r);
  if length(x) = 0 then raise exception 'empty'; end if;
  if not exists (select 1 from px_thread_members where thread = p_thread and uid = p_uid) then raise exception 'You are not in that chat'; end if;
  if (select count(*) from px_tmsgs where uid = p_uid and at > now() - interval '8 seconds') >= 6 then raise exception 'slow down'; end if;
  select * into th from px_threads where id = p_thread;
  if th.kind = 'dm' then   -- (the other person: blocked me? then it doesn't go through. Left the chat? it comes back to them)
    o := case when split_part(th.dm_key, '|', 1) = p_uid then split_part(th.dm_key, '|', 2) else split_part(th.dm_key, '|', 1) end;
    perform px_dm_can(r, o);
    insert into px_thread_members (thread, uid) values (p_thread, o) on conflict do nothing;
  end if;
  insert into px_tmsgs (thread, uid, x) values (p_thread, p_uid, x) returning id into nid;
  update px_threads set last_at = now() where id = p_thread;
  update px_thread_members set last_read = greatest(last_read, nid) where thread = p_thread and uid = p_uid;
  if random() < 0.03 then delete from px_tmsgs where at < now() - interval '30 days'; delete from px_threads where last_at < now() - interval '60 days'; end if;
  return jsonb_build_object('id', nid, 'x', x);
end $$;

-- everything new for me: my chats (with the last line and how many I haven't read), and the lines since p_since
create or replace function public.px_dm_poll(p_uid text, p_key text, p_since bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare r px_players; th jsonb; ms jsonb := '[]'; mx bigint;
begin
  r := px_auth(p_uid, p_key);
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'k', t.kind, 'name', t.name, 'owner', t.owner, 'at', px_ms(t.last_at),
      'mem', (select coalesce(jsonb_agg(jsonb_build_object('u', m2.uid, 'n', coalesce(p.name, '?'))), '[]') from px_thread_members m2 left join px_players p on p.uid = m2.uid where m2.thread = t.id),
      'last', (select jsonb_build_object('id', l.id, 'u', l.uid, 'x', l.x, 'at', px_ms(l.at)) from px_tmsgs l where l.thread = t.id order by l.id desc limit 1),
      'unread', (select count(*) from px_tmsgs u where u.thread = t.id and u.id > m.last_read and u.uid <> p_uid and u.uid <> '-')) order by t.last_at desc), '[]') into th
    from px_thread_members m join px_threads t on t.id = m.thread where m.uid = p_uid;
  select coalesce(max(x.id), 0) into mx from px_tmsgs x join px_thread_members m on m.thread = x.thread and m.uid = p_uid;
  if p_since is not null and p_since >= 0 then
    select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 't', q.thread, 'u', q.uid, 'n', coalesce(p.name, ''), 'x', q.x, 'at', px_ms(q.at)) order by q.id), '[]') into ms
      from (select x.* from px_tmsgs x join px_thread_members m on m.thread = x.thread and m.uid = p_uid where x.id > p_since order by x.id limit 200) q left join px_players p on p.uid = q.uid;
  end if;
  return jsonb_build_object('threads', th, 'msgs', ms, 'last', mx, 'blocked', coalesce((select jsonb_agg(target) from px_dm_blocks where uid = p_uid), '[]'),
    'mode', coalesce((select dm_mode from px_mod_cfg where id = 1), 'all'));
end $$;
create or replace function public.px_dm_history(p_uid text, p_key text, p_thread bigint, p_before bigint, p_limit int) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  if not exists (select 1 from px_thread_members where thread = p_thread and uid = p_uid) then raise exception 'You are not in that chat'; end if;
  return jsonb_build_object('msgs', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 't', q.thread, 'u', q.uid, 'n', coalesce(p.name, ''), 'x', q.x, 'at', px_ms(q.at)) order by q.id)
    from (select * from px_tmsgs where thread = p_thread and (p_before is null or id < p_before) order by id desc limit least(greatest(coalesce(p_limit, 40), 1), 100)) q left join px_players p on p.uid = q.uid), '[]'::jsonb));
end $$;
create or replace function public.px_dm_read(p_uid text, p_key text, p_thread bigint, p_upto bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  update px_thread_members set last_read = greatest(last_read, coalesce(p_upto, 0)) where thread = p_thread and uid = p_uid;
end $$;
create or replace function public.px_dm_block(p_uid text, p_key text, p_target text, p_on boolean) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  if p_target is null or p_target = p_uid then return jsonb_build_object('ok', false); end if;
  if p_on then insert into px_dm_blocks (uid, target) values (p_uid, p_target) on conflict do nothing; else delete from px_dm_blocks where uid = p_uid and target = p_target; end if;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_dm_report(p_uid text, p_key text, p_thread bigint, p_msg bigint, p_why text) returns jsonb language plpgsql security definer set search_path = public as $$
declare tg text;
begin
  perform px_auth(p_uid, p_key);
  if not exists (select 1 from px_thread_members where thread = p_thread and uid = p_uid) then raise exception 'You are not in that chat'; end if;
  select uid into tg from px_tmsgs where id = p_msg and thread = p_thread;
  if (select count(*) from px_dm_reports where reporter = p_uid and at > now() - interval '1 hour') >= 10 then raise exception 'slow down'; end if;
  insert into px_dm_reports (reporter, thread, msg, target, why) values (p_uid, p_thread, p_msg, nullif(tg, '-'), left(coalesce(p_why, ''), 200));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_dm_find(text, text, text), public.px_dm_open(text, text, text), public.px_dm_group(text, text, text, text[]), public.px_dm_add(text, text, bigint, text[]),
  public.px_dm_leave(text, text, bigint), public.px_dm_send(text, text, bigint, text), public.px_dm_poll(text, text, bigint), public.px_dm_history(text, text, bigint, bigint, int),
  public.px_dm_read(text, text, bigint, bigint), public.px_dm_block(text, text, text, boolean), public.px_dm_report(text, text, bigint, bigint, text) to anon, authenticated;
revoke all on function public.px_dm_clean(text), public.px_dm_filter(text), public.px_dm_gate(px_players), public.px_dm_can(px_players, text) from public, anon, authenticated;

-- staff side: reported lines (with the chat around them), the owner's switch, and the owner reading a player's chats when something's wrong
create or replace function public.px_mod_reports(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('mode', (select dm_mode from px_mod_cfg where id = 1), 'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'at', px_ms(r.at), 'why', r.why, 'thread', r.thread, 'msg', r.msg,
      'by', (select name from px_players where uid = r.reporter), 'byu', r.reporter, 'tu', r.target, 'tn', (select name from px_players where uid = r.target),
      'tname', (select coalesce(name, kind) from px_threads where id = r.thread),
      'ctx', coalesce((select jsonb_agg(jsonb_build_object('u', c.uid, 'n', coalesce(p.name, ''), 'x', c.x, 'at', px_ms(c.at), 'hit', c.id = r.msg) order by c.id) from (select * from px_tmsgs where thread = r.thread and id between coalesce(r.msg, 0) - 12 and coalesce(r.msg, 0) + 4 order by id) c left join px_players p on p.uid = c.uid), '[]'::jsonb)) order by r.id desc)
    from (select * from px_dm_reports where not done order by id desc limit 30) r), '[]'::jsonb));
end $$;
create or replace function public.px_mod_report_done(p_pw text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_dm_reports set done = true, done_by = coalesce(nullif(current_setting('px.hname', true), ''), case when px_is_helper() then 'Helper' else 'Owner' end) where id = p_id;
  insert into px_mod_log (act, target, note) values ('report handled', p_id::text, '');
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_mod_dm_cfg(p_pw text, p_mode text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_mode not in ('all', 'grade', 'off') then return jsonb_build_object('err', 'bad mode'); end if;
  update px_mod_cfg set dm_mode = p_mode where id = 1;
  insert into px_mod_log (act, note) values ('messages', p_mode);
  return jsonb_build_object('ok', true, 'mode', p_mode);
end $$;
create or replace function public.px_mod_dms(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  insert into px_mod_log (act, target, note) values ('read private messages', p_uid, '');
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('t', t.id, 'k', t.kind, 'name', t.name, 'mem', (select string_agg(coalesce(p.name, '?'), ', ') from px_thread_members m2 left join px_players p on p.uid = m2.uid where m2.thread = t.id),
      'msgs', (select coalesce(jsonb_agg(jsonb_build_object('u', x.uid, 'n', coalesce(p2.name, ''), 'x', x.x, 'at', px_ms(x.at)) order by x.id), '[]'::jsonb) from (select * from px_tmsgs where thread = t.id order by id desc limit 25) x left join px_players p2 on p2.uid = x.uid)) order by t.last_at desc)
    from px_threads t join px_thread_members m on m.thread = t.id and m.uid = p_uid), '[]'::jsonb));
end $$;
grant execute on function public.px_mod_reports(text), public.px_mod_report_done(text, bigint), public.px_mod_dm_cfg(text, text), public.px_mod_dms(text, text) to anon, authenticated;

-- ---------- v15: three ranks (helper, moderator, creator), no passwords for staff ----------
-- The creator picks people from a player's page. Staff open the panel by who they are (their player id and secret key, checked here on
-- every call), so there's nothing to type or share, and a click on the hidden corner does nothing for anyone who isn't staff.
create table if not exists public.px_migrations (name text primary key, at timestamptz not null default now());
alter table public.px_migrations enable row level security; revoke all on public.px_migrations from anon, authenticated;
do $$ begin   -- one time only: the old helper devices and passwords are cleared, so the creator picks everyone fresh
  if not exists (select 1 from px_migrations where name = 'ranks_v1') then
    delete from px_staff where role = 'helper';
    delete from px_helpers;
    update px_mod_cfg set hsalt = null, hhash = null where id = 1;
    insert into px_migrations (name) values ('ranks_v1');
  end if;
end $$;
create or replace function public.px_mod_staff_set(p_pw text, p_uid text, p_rank text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); nm text; cur px_staff;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select name into nm from px_players where uid = p_uid;
  if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  select * into cur from px_staff where uid = p_uid;
  if found and cur.role = 'owner' then return jsonb_build_object('err', 'creator'); end if;
  if p_rank is null or p_rank in ('', 'none') then
    delete from px_staff where uid = p_uid; insert into px_mod_log (act, target, note) values ('staff removed', p_uid || ' (' || nm || ')', '');
  elsif p_rank in ('helper', 'moderator') then
    insert into px_staff (uid, role, name) values (p_uid, p_rank, nm) on conflict (uid) do update set role = excluded.role, name = excluded.name;
    insert into px_mod_log (act, target, note) values ('staff set', p_uid || ' (' || nm || ')', p_rank);
  else return jsonb_build_object('err', 'bad rank'); end if;
  return jsonb_build_object('ok', true, 'rank', p_rank);
end $$;
create or replace function public.px_mod_staff_list(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('uid', s.uid, 'n', coalesce(p.name, s.name, '?'), 'rank', case s.role when 'owner' then 'creator' else s.role end,
      'seen', px_ms(p.seen), 'on', p.seen > now() - interval '40 seconds', 'email', (select g.email from px_google g where g.uid = s.uid), 'acts', (select count(*) from px_mod_log l where l.by_name = coalesce(p.name, s.name) and l.at > now() - interval '7 days'))
      order by (case s.role when 'owner' then 0 when 'moderator' then 1 else 2 end), p.name) from px_staff s left join px_players p on p.uid = s.uid), '[]'::jsonb));
end $$;
-- run in the SQL Editor to make a player a creator (their id is on their Settings screen): select px_mod_make_creator('their id');
create or replace function public.px_mod_make_creator(p_uid text) returns void language sql security definer set search_path = public as $$
  insert into px_staff (uid, role, name) values (p_uid, 'owner', (select name from px_players where uid = p_uid)) on conflict (uid) do update set role = 'owner' $$;
revoke all on function public.px_mod_make_creator(text), public.px_rank(), public.px_staff_rank(text) from public, anon, authenticated;
grant execute on function public.px_mod_staff_set(text, text, text), public.px_mod_staff_list(text) to anon, authenticated;


-- ONE-TIME, PRIVATE: set the mod password by running this single line yourself in the SQL Editor (don't save it into this file):
--   select px_mod_set_password('your password here');
-- Same way, once, for your helper (a weaker mod: chat moderation, 30 levels a day, no bans; you see everything they do in the Log tab).
-- It has to be different from yours:
--   select px_mod_set_helper_password('their password here');
-- To switch their access off:   select px_mod_clear_helper_password();
