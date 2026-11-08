-- Pixel Games online hub: who's online, global chat + invites, Quick Match queue, ranked Elo.
set check_function_bodies = off; -- (functions are checked when they run, so the order they're made in doesn't matter: a fresh database installs cleanly)
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
alter table public.px_staff add column if not exists creator_dev boolean not null default false;   -- (v27) a device the creator signed into with the creator password
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
    insert into px_players (uid, keyhash, name) values (p_uid, md5(p_key || ':pxk'), coalesce(px_name_clean(p_name), 'Player')) returning * into r;
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
declare r px_players; msgs jsonb; ppl jsonb := null; mx bigint; onl int; bn px_bans; mu px_bans; ann jsonb; eds jsonb; ds bigint; dels jsonb := null; dcur bigint; mv int; vv int; oldv boolean := false;
begin
  r := px_auth(p_uid, p_key, p_name);
  perform px_google_touch(p_uid);   -- (signed in with Google? remember whose account this device is)
  update px_players set name = case when name_lock then name else coalesce(px_name_clean(p_name), name) end, iph = coalesce(px_net_tag(), iph), lv = coalesce(p_lv, lv), rb = coalesce(p_rb, rb), st = coalesce(left(p_st, 40), st), seen = now(),
    info = case when p_info is null or jsonb_typeof(p_info) <> 'object' then info when length(p_info::text) < 1800 then p_info when length(coalesce(p_info -> 'fs', 'null'::jsonb)::text) < 600 then jsonb_build_object('ver', p_info -> 'ver', 'fs', p_info -> 'fs', 'big', true) else coalesce(info, '{}'::jsonb) || jsonb_build_object('big', true) end /* (v27: padding the report can't hide the fighter from the checks) */ where uid = p_uid returning * into r;
  select count(*) into onl from px_players where seen > now() - interval '40 seconds';
  perform px_ban_follow(p_uid, p_info);   -- (a ban or mute on another id this device used, or this Google account, follows the player here)
  select * into bn from px_bans where uid = p_uid and kind = 'ban' and (until is null or until > now());
  select * into mu from px_bans where uid = p_uid and kind = 'mute' and (until is null or until > now());
  ann := px_ann_json(p_uid);
  -- an old copy of the game (below the minimum version the creator set) that can't show its own update screen (older than v15): shut like a ban until it's
  -- updated. Copies from v13 up close the whole game; older ones (or ones that don't say) lose the online doors. Staff are never locked out.
  select min_ver into mv from px_mod_cfg where id = 1;
  vv := case when p_info is not null and jsonb_typeof(p_info) = 'object' and (p_info ->> 'ver') ~ '^[0-9]{1,4}$' then (p_info ->> 'ver')::int end;
  -- (a copy from v15 up has its own full-screen "download the update" screen, which a lock screen would cover: the game itself is told the minimum in the config, below, and shows that screen)
  if coalesce(mv, 0) > 0 and bn.uid is null and (vv is null or (vv < mv and vv < 15)) and px_staff_rank(p_uid) is null then oldv := true; end if;
  if bn.uid is not null or oldv then -- banned: no chat, no people, just the news that they are
    return jsonb_build_object('last', 0, 'msgs', '[]'::jsonb, 'people', null, 'online', onl, 'ann', ann, 'cfg', px_pub_cfg(),
      'ban', case when oldv then jsonb_build_object('until', null, 'why', left('Out of date. Get Pixel Games v' || mv || ' or newer: re-download it, or open rocourtnathan-bit.github.io/pixel-games.html', 120), 'full', (vv is not null and vv >= 13))
        else jsonb_build_object('until', case when bn.until is null then null else (extract(epoch from bn.until) * 1000)::bigint end, 'why', bn.reason, 'full', bn."full") end,
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
  if px_staff_role(p_uid) is null then perform px_chat_rules(p_uid, p_kind); end if;
  if p_kind not in ('m', 'inv', 'invno', 'invok') then raise exception 'bad kind'; end if;
  if p_kind = 'm' and (p_x is null or length(btrim(p_x)) = 0) then raise exception 'empty'; end if;
  if p_kind = 'm' and px_chat_guard(r, p_x) then return -1; end if;   -- (-1: the chat just muted them; the line isn't posted, the mute is kept)
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
  if coalesce((select online_off from px_mod_cfg where id = 1), false) and px_staff_role(p_uid) is null then delete from px_queue where uid = p_uid; return jsonb_build_object('off', true); end if;
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
  if (select cheat from px_players where uid = p_uid) is not null or (select cheat from px_players where uid = p_opp) is not null then return jsonb_build_object('ok', false, 'why', 'edited'); end if;   -- (v27: an edited fighter's games don't count)
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
      from (select * from px_players where gh > 0 and not px_is_banned(uid) and cheat is null order by elo_h desc, gh desc limit 50) q;
    select count(*) into tot from px_players where gh > 0 and not px_is_banned(uid);
  else
    select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', name, 'e', elo_f, 'g', gf, 'w', wf, 'lv', lv, 'on', seen > now() - interval '40 seconds')), '[]') into top
      from (select * from px_players where gf > 0 and not px_is_banned(uid) and cheat is null order by elo_f desc, gf desc limit 50) q;
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
  if (select cheat from px_players where uid = p_uid) is not null then raise exception 'This fighter''s numbers look edited, so it can''t fight for turf. Ask a moderator if that''s a mistake.'; end if;
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
declare c px_mod_cfg; su text; sk text; tk text; pl px_players; st px_staff; rl text;
begin
  perform set_config('px.who', '', true); perform set_config('px.hname', '', true); perform set_config('px.rank', '', true); perform set_config('px.suid', '', true); perform set_config('px.tok', '', true);
  -- staff (helper, moderator, admin) are known by who they are, not by a password: "<player id>|<their secret key>" and, once they
  -- have a panel PIN, "|<the session the PIN opened>"
  if p_pw is not null and position('|' in p_pw) > 0 and length(p_pw) <= 200 then
    su := split_part(p_pw, '|', 1); sk := split_part(p_pw, '|', 2); tk := nullif(split_part(p_pw, '|', 3), '');
    select * into pl from px_players where uid = su and keyhash = md5(sk || ':pxk');
    if not found then return 'wrong'; end if;
    rl := px_staff_role(su);
    if rl is null then return 'wrong'; end if;
    insert into px_staff (uid, role, name) values (su, rl, pl.name) on conflict (uid) do nothing;   -- (staff by Google account: this device joins the list)
    select * into st from px_staff where uid = su;
    -- the panel PIN: needed once a staff member has set one, and by everyone when an admin switched that on
    if st.pin_hash is not null or coalesce((select req_pin from px_mod_cfg where id = 1), false) then
      if st.pin_hash is null then return 'needpin'; end if;
      if tk is null or not exists (select 1 from px_staff_sessions s where s.uid = su and s.token_hash = encode(sha256(convert_to(tk, 'utf8')), 'hex') and s.expires > now()) then return 'pin'; end if;
      perform set_config('px.tok', encode(sha256(convert_to(tk, 'utf8')), 'hex'), true);
    end if;
    perform set_config('px.hname', coalesce(pl.name, 'Staff'), true); perform set_config('px.suid', su, true);
    if st.role = 'owner' and px_is_creator(su) then perform set_config('px.who', 'owner', true); perform set_config('px.rank', 'creator', true); return 'ok'; end if;
    perform set_config('px.who', 'helper', true); perform set_config('px.rank', case when st.role in ('moderator', 'owner') then 'moderator' else 'helper' end, true);   -- (an old admin who isn't the creator: a moderator)
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
  insert into px_sec_log (act, note, iph) values ('wrong creator password', (c.fails + 1) || ' in a row', px_net_tag());
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
    insert into px_staff (uid, role, name, creator_dev) values (p_uid, 'owner', nm, true) on conflict (uid) do update set role = 'owner', creator_dev = true, name = coalesce(excluded.name, px_staff.name);
  end if;
  if v = 'helper' then insert into px_mod_log (act, target, note) values ('staff login', coalesce(current_setting('px.suid', true), '?'), px_rank()); end if;
  insert into px_sec_log (act, uid, name, note, iph) values (case when position('|' in coalesce(p_pw, '')) = 0 then 'signed in with the creator password' else 'opened the panel' end,
    coalesce(nullif(current_setting('px.suid', true), ''), p_uid), coalesce(nullif(current_setting('px.hname', true), ''), (select name from px_players where uid = p_uid)), px_rank(), px_net_tag());
  update px_staff set last_login = now() where uid = coalesce(nullif(current_setting('px.suid', true), ''), p_uid);
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
  ann := px_ann_json(null);
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
    'blocks', blocks, 'owners', owners, 'vers', vers, 'ann', ann, 'polls', px_ann_polls(),
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
  elsif p_filter = 'nosign' then wh := 'uid not in (select uid from px_google)';
  elsif p_filter = 'cheat' then wh := 'cheat is not null'; end if;   -- (v27: the anti-cheat's flags)
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
  return jsonb_build_object('cheat', pl.cheat, 'nlock', pl.name_lock, 'prev', (select coalesce(jsonb_agg(jsonb_build_object('uid', o.uid, 'n', o.name, 'seen', px_ms(o.seen), 'ban', px_is_banned(o.uid))), '[]'::jsonb) from px_players o where o.uid = any(coalesce(pl.prev, '{}')) and o.uid <> pl.uid)) || jsonb_build_object('linked', lk, 'turf', tf, 'uid', pl.uid, 'n', pl.name, 'grade', pl.grade, 'lv', pl.lv, 'rb', pl.rb, 'st', pl.st, 'seen', px_ms(pl.seen), 'created', px_ms(pl.created), 'on', pl.seen > now() - interval '40 seconds',
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
  delete from px_ban_ok where uid = p_uid; update px_bans set src = null where uid = p_uid and kind = p_kind;
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
  delete from px_queue where uid = p_uid; delete from px_ban_ok where uid = p_uid; update px_bans set src = null where uid = p_uid and kind = 'ban';
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
  delete from px_bans where (uid = p_uid or src = p_uid) and (p_kind is null or kind = p_kind);
  insert into px_ban_ok (uid) values (p_uid) on conflict do nothing;   -- (cleared by a mod: an old id's ban doesn't follow onto this one again)
  insert into px_mod_log (act, target, note) values ('lift ' || coalesce(p_kind, 'ban+mute'), p_uid, '');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.px_mod_bans(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', coalesce((select name from px_players p where p.uid = b.uid), b.name), 'k', kind, 'full', "full", 'why', reason, 'by', "by", 'bn', by_name, 'at', px_ms(at), 'until', px_ms(until), 'src', src, 'srcn', (select name from px_players p where p.uid = b.src)) order by at desc), '[]') into rows
    from px_bans b where until is null or until > now();
  return jsonb_build_object('rows', rows, 'evaders', px_evaders());
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
  update px_players set name = left(coalesce(nullif(btrim(p_name), ''), 'Player'), 16), name_lock = true where uid = p_uid;
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
drop function if exists public.px_mod_announce(text, text, numeric);
create or replace function public.px_mod_announce(p_pw text, p_text text, p_hours numeric, p_poll boolean default false) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() then p_hours := least(coalesce(p_hours, 1), case when px_rank() = 'moderator' then 24 else 1 end); end if;   -- (a helper's announcement lasts an hour at most, a moderator's a day)
  update px_announce set until = now() where until > now();
  if p_text is not null and length(btrim(p_text)) > 0 then
    insert into px_announce (x, until, poll) values (left(btrim(p_text), 1000),   -- (v27: up to 1000 letters, it was 200)
      now() + make_interval(secs => (least(greatest(coalesce(p_hours, 6), 0.1), 720) * 3600)::int), coalesce(p_poll, false));
    insert into px_mod_log (act, note) values ('announce', left(btrim(p_text), 110) || case when coalesce(p_poll, false) then ' (with a poll)' else '' end);
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
      if k not in ('hp', 'spd', 'str', 'iq', 'sta', 'skl', 'men') or x < 1 or x > (case when (p_edit ->> 'free') = 'true' then 2000 else 50 end) then return jsonb_build_object('err', 'bad stat ' || k); end if;   -- (v27: the creator's "no limits" goes to 2000 ranks)
    end loop;
  end if;
  insert into px_edits (uid, edit) values (p_uid, p_edit);
  update px_players set lv = coalesce(lv_n, lv), rb = coalesce(rb_n, px_players.rb),
    free_ok = case when (p_edit ->> 'free') = 'true' then true when p_edit ? 'st' then false else free_ok end, cheat = null where uid = p_uid;   -- (a staff edit is legal by definition)
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
  public.px_mod_turf_release(text, text, text), public.px_mod_announce(text, text, numeric, boolean), public.px_mod_log(text, int) to anon, authenticated;


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
alter table public.px_mod_cfg add column if not exists byline text;   -- (the start screen line, below)
-- v22: is Pixel Football open to everyone? (false = only staff can open it; everyone else sees "under development")
alter table public.px_mod_cfg add column if not exists football_public boolean not null default true;
alter table public.px_mod_cfg alter column football_public set default true;   -- (v23: open to everyone unless the creator makes it private)
create or replace function public.px_pub_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('reqg', coalesce((select req_game from px_mod_cfg where id = 1), false), 'upd', coalesce((select upd_until > now() from px_mod_cfg where id = 1), false), 'dm', coalesce((select dm_mode from px_mod_cfg where id = 1), 'all'), 'minv', (select nullif(min_ver, 0) from px_mod_cfg where id = 1), 'by', (select byline from px_mod_cfg where id = 1), 'fb', coalesce((select football_public from px_mod_cfg where id = 1), false)) $$;
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
  return (select jsonb_build_object('game', req_game, 'helper', req_helper, 'linked', (select count(*) from px_google), 'players', (select count(*) from px_players), 'minver', nullif(min_ver, 0), 'by', byline, 'fb', football_public, 'upd', case when upd_until > now() then px_ms(upd_until) end) from px_mod_cfg where id = 1);
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
    'f', coalesce((select jsonb_agg(jsonb_build_object('n', x ->> 'name', 'lv', x -> 'level', 'rb', x -> 'rebirths', 'xp', x -> 'xp')) from jsonb_array_elements(coalesce(c.data -> 'save' -> 'fighters', '[]'::jsonb)) x), '[]'::jsonb));
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
  if found and cur.role = 'owner' and px_is_creator(p_uid) then return jsonb_build_object('err', 'creator'); end if;
  if p_rank is null or p_rank in ('', 'none') then
    delete from px_staff where uid = p_uid; insert into px_mod_log (act, target, note) values ('staff removed', p_uid || ' (' || nm || ')', '');
  elsif p_rank = 'admin' then
    return jsonb_build_object('err', 'Only the creator has the owner panel. Pick Moderator for staff.');
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
  insert into px_staff (uid, role, name, creator_dev) values (p_uid, 'owner', (select name from px_players where uid = p_uid), true) on conflict (uid) do update set role = 'owner', creator_dev = true $$;
revoke all on function public.px_mod_make_creator(text), public.px_rank(), public.px_staff_rank(text) from public, anon, authenticated;
grant execute on function public.px_mod_staff_set(text, text, text), public.px_mod_staff_list(text) to anon, authenticated;

-- the lowest game version that may play at all. Anything older is locked until it updates (see px_hello). 0 turns it off.
alter table public.px_mod_cfg add column if not exists min_ver int not null default 0;
create or replace function public.px_mod_min_ver(p_pw text, p_ver int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_mod_cfg set min_ver = least(greatest(coalesce(p_ver, 0), 0), 9999) where id = 1;
  insert into px_mod_log (act, note) values ('minimum version', coalesce(p_ver, 0)::text);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_min_ver(text, int) to anon, authenticated;
do $$ begin   -- one time: v15 is out, so older copies are locked until they update (the creator can change or switch this off in the panel)
  if not exists (select 1 from px_migrations where name = 'minver_15') then
    update px_mod_cfg set min_ver = 15 where id = 1 and min_ver = 0;
    insert into px_migrations (name) values ('minver_15');
  end if;
end $$;


-- ---------- v15: how good are people's online connections? ----------
-- Every online match, the game sends one small summary when it ends (typical ping, the slow spells, how it got through,
-- how often the fight had to wait or rewind). The mods see the totals, so we can fix what's actually wrong instead of guessing.
-- Nothing in it says who they played or what was said. Kept for two weeks.
create table if not exists public.px_netlog (id bigserial primary key, at timestamptz not null default now(), uid text not null, game text not null, secs int, rtt int, rtt90 int, jit int, loss int,
  route text, stalls int, rolls int, maxroll int, ver int, dev text, via text);
create index if not exists px_netlog_at on public.px_netlog (at desc);
alter table public.px_netlog enable row level security; revoke all on public.px_netlog from anon, authenticated;
create or replace function public.px_net_put(p_uid text, p_key text, p_r jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl px_players; g text;
begin
  pl := px_auth(p_uid, p_key);
  if p_r is null or jsonb_typeof(p_r) <> 'object' then return jsonb_build_object('ok', false); end if;
  g := case when (p_r ->> 'g') in ('f', 'h') then p_r ->> 'g' end; if g is null then return jsonb_build_object('ok', false); end if;
  if (select count(*) from px_netlog where uid = p_uid and at > now() - interval '1 hour') >= 40 then return jsonb_build_object('ok', false); end if;
  insert into px_netlog (uid, game, secs, rtt, rtt90, jit, loss, route, stalls, rolls, maxroll, ver, dev, via)
  values (p_uid, g,
    least(greatest(coalesce((p_r ->> 's') ::numeric, 0), 0), 3600)::int, least(greatest(coalesce((p_r ->> 'rtt') ::numeric, 0), 0), 5000)::int, least(greatest(coalesce((p_r ->> 'r90') ::numeric, 0), 0), 5000)::int,
    least(greatest(coalesce((p_r ->> 'jit') ::numeric, 0), 0), 5000)::int, least(greatest(coalesce((p_r ->> 'loss') ::numeric, 0), 0), 100)::int,
    case when (p_r ->> 'route') in ('DIRECT', 'RELAY', 'SERVER') then p_r ->> 'route' else 'SERVER' end,
    least(greatest(coalesce((p_r ->> 'st') ::numeric, 0), 0), 100000)::int, least(greatest(coalesce((p_r ->> 'ro') ::numeric, 0), 0), 100000)::int, least(greatest(coalesce((p_r ->> 'mr') ::numeric, 0), 0), 1000)::int,
    case when (pl.info ->> 'ver') ~ '^[0-9]{1,4}$' then (pl.info ->> 'ver')::int end, left(pl.info -> 'dev' ->> 'k', 20), left(pl.info ->> 'via', 8));
  if random() < 0.05 then delete from px_netlog where at < now() - interval '14 days'; end if;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_mod_net(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); res jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  with w as (select *, (case when secs > 0 then stalls * 60.0 / secs else 0 end) spm from px_netlog where at > now() - interval '7 days'),
  smooth as (select count(*) filter (where rtt < 120 and spm < 3 and loss < 3) good, count(*) filter (where rtt >= 250 or spm >= 10 or loss >= 8) rough, count(*) n from w)
  select jsonb_build_object('n', (select n from smooth), 'good', (select good from smooth), 'rough', (select rough from smooth),
    'rtt', (select percentile_cont(0.5) within group (order by rtt) from w), 'rtt90', (select percentile_cont(0.9) within group (order by rtt) from w),
    'routes', (select coalesce(jsonb_object_agg(route, c), '{}'::jsonb) from (select route, count(*) c from w group by route) q),
    'games', (select coalesce(jsonb_object_agg(game, c), '{}'::jsonb) from (select game, count(*) c from w group by game) q),
    'dev', (select coalesce(jsonb_agg(jsonb_build_object('k', coalesce(dev, '?'), 'via', coalesce(via, '?'), 'n', c, 'rtt', m, 'rough', r) order by c desc), '[]'::jsonb) from (select dev, via, count(*) c, round(percentile_cont(0.5) within group (order by rtt)) m, count(*) filter (where rtt >= 250 or spm >= 10 or loss >= 8) r from w group by dev, via order by c desc limit 8) q),
    'worst', (select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'n', (select name from px_players p where p.uid = q.uid), 'c', c, 'rtt', m, 'spm', round(sp::numeric, 1), 'route', rt) order by m desc), '[]'::jsonb)
      from (select uid, count(*) c, round(percentile_cont(0.5) within group (order by rtt)) m, avg(spm) sp, mode() within group (order by route) rt from w group by uid having count(*) >= 2 order by percentile_cont(0.5) within group (order by rtt) desc limit 8) q))
  into res;
  return res;
end $$;
grant execute on function public.px_net_put(text, text, jsonb), public.px_mod_net(text) to anon, authenticated;

-- ---------- v16: the Online Shop's items, edited by the creator ----------
-- The list of things for sale (name, what it gives, price) lives here, so the creator can add, remove, rename and re-price them in the
-- panel without a new version of the game. null = never edited: the game shows its built-in starting list. Buying isn't switched on yet.
alter table public.px_mod_cfg add column if not exists shop jsonb;
-- v21: the "under development" switch for buying (true = pressing Buy says under development for everyone, even for items that have a payment link)
alter table public.px_mod_cfg add column if not exists shop_dev boolean not null default true;
create or replace function public.px_shop_get() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('items', (select shop from px_mod_cfg where id = 1), 'dev', coalesce((select shop_dev from px_mod_cfg where id = 1), true)) $$;
create or replace function public.px_mod_shop_save(p_pw text, p_items jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); res jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then return jsonb_build_object('err', 'bad items'); end if;
  if jsonb_array_length(p_items) > 30 then return jsonb_build_object('err', 'too many (30 at most)'); end if;
  with a as (
    select ord, case when (e ->> 'id') ~ '^[a-z0-9_]{1,20}$' then e ->> 'id' else 'i' || ord end id0, left(btrim(coalesce(e ->> 'name', '')), 40) nm,
      case when (e ->> 'kind') in ('levels', 'cash', 'clothes', 'other') then e ->> 'kind' else 'other' end kd,
      case when (e ->> 'amount') ~ '^[0-9]{1,6}$' then (e ->> 'amount')::int else 0 end am,
      case when (e ->> 'ref') ~ '^[a-z0-9_]{1,40}$' then e ->> 'ref' else '' end rf,
      case when (e ->> 'price') ~ '^[0-9]{1,3}(\.[0-9]{1,2})?$' then (e ->> 'price')::numeric else 0 end pr,
      case when (e ->> 'link') ~ '^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]{4,250}$' then e ->> 'link' else '' end lk
    from jsonb_array_elements(p_items) with ordinality t (e, ord)),
  b as (select *, case when count(*) over (partition by id0) > 1 then id0 || '_' || ord else id0 end id from a where nm <> '')
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', nm, 'kind', kd, 'amount', am, 'ref', rf, 'price', pr, 'link', lk) order by ord), '[]'::jsonb) into res from b;
  update px_mod_cfg set shop = res where id = 1;
  insert into px_mod_log (act, note) values ('shop items', jsonb_array_length(res)::text || ' items');
  return jsonb_build_object('ok', true, 'items', res);
end $$;
grant execute on function public.px_shop_get(), public.px_mod_shop_save(text, jsonb) to anon, authenticated;

-- ---------- the line on the start screen ("Made by ..."): the creator can change it ----------
create or replace function public.px_mod_byline(p_pw text, p_text text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); t text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  t := left(btrim(regexp_replace(coalesce(p_text, ''), '[<>[:cntrl:]]', '', 'g')), 60);
  update px_mod_cfg set byline = nullif(t, '') where id = 1;
  insert into px_mod_log (act, target, note) values ('start screen line', '', left(t, 60));
  return jsonb_build_object('ok', true, 'by', nullif(t, ''));
end $$;
grant execute on function public.px_mod_byline(text, text) to anon, authenticated;


-- ONE-TIME, PRIVATE: set the mod password by running this single line yourself in the SQL Editor (don't save it into this file):
--   select px_mod_set_password('your password here');
-- Same way, once, for your helper (a weaker mod: chat moderation, 30 levels a day, no bans; you see everything they do in the Log tab).
-- It has to be different from yours:
--   select px_mod_set_helper_password('their password here');
-- To switch their access off:   select px_mod_clear_helper_password();

-- ---------- v21: buying in the Online Shop ----------
-- How a purchase gets to a player (the game never decides "this player paid", only this table can):
--   1. The player taps Buy. The game opens the item's payment link (Stripe) with the player's id on it.
--   2. Stripe tells the server (the small "stripe-webhook" function, see pixel-games-stripe-setup.md) the payment worked.
--   3. That function writes a row here, using the server's secret key. The game's own key can't write here at all.
--   4. The game asks "anything paid for me?" (px_shop_claims), then takes it once (px_shop_claim) and gives the levels / credits / outfit.
-- provider_ref (the Stripe checkout id) is unique, so the same payment can never be recorded twice.
create table if not exists public.px_purchases (
  id bigint generated always as identity primary key,
  uid text not null,
  item_id text not null,
  name text not null default '',
  kind text not null default 'other',
  amount int not null default 0,
  ref text not null default '',
  price numeric not null default 0,
  provider text not null default 'stripe',
  provider_ref text unique,
  status text not null default 'paid',        -- paid (waiting to be taken) → claimed (given) | refunded (taken back before it was claimed)
  created_at timestamptz not null default now(),
  claimed_at timestamptz);
create index if not exists px_purchases_uid on public.px_purchases (uid, status);
alter table public.px_purchases enable row level security;   -- no policies: the game's key can't read or write the table itself
revoke all on public.px_purchases from anon, authenticated;

-- what is waiting for this player (nothing is changed)
create or replace function public.px_shop_claims(p_uid text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'name', name, 'kind', kind, 'amount', amount, 'ref', ref) order by id)
    from px_purchases where uid = p_uid and status = 'paid' and p_uid ~ '^[a-z0-9]{8,32}$'), '[]'::jsonb)) $$;
-- take these purchases (once: a second call gets nothing). Returns exactly the ones this call took.
create or replace function public.px_shop_claim(p_uid text, p_ids bigint[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  if p_uid !~ '^[a-z0-9]{8,32}$' or p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 50 then return jsonb_build_object('items', '[]'::jsonb); end if;
  with c as (update px_purchases set status = 'claimed', claimed_at = now() where uid = p_uid and status = 'paid' and id = any (p_ids)
    returning id, item_id, name, kind, amount, ref)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'name', name, 'kind', kind, 'amount', amount, 'ref', ref) order by id), '[]'::jsonb) into res from c;
  return jsonb_build_object('items', res);
end $$;
grant execute on function public.px_shop_claims(text), public.px_shop_claim(text, bigint[]) to anon, authenticated;

-- the creator's list of recent purchases, and "take back" for one nobody has claimed yet (a refund)
create or replace function public.px_mod_purchases(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(r order by (r ->> 'id')::bigint desc) from (
    select jsonb_build_object('id', p.id, 'uid', p.uid, 'player', (select name from px_players q where q.uid = p.uid), 'name', p.name, 'price', p.price, 'status', p.status, 'at', p.created_at, 'claimed', p.claimed_at) r
    from px_purchases p order by p.id desc limit 40) t), '[]'::jsonb),
    'paid', (select coalesce(sum(price), 0) from px_purchases where status in ('paid', 'claimed')),
    'waiting', (select count(*) from px_purchases where status = 'paid'));
end $$;
create or replace function public.px_mod_purchase_refund(p_pw text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); n int;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_purchases set status = 'refunded' where id = p_id and status = 'paid'; get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('err', 'already given to the player (or not found): nothing to take back'); end if;
  insert into px_mod_log (act, note) values ('purchase refunded', p_id::text);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_purchases(text), public.px_mod_purchase_refund(text, bigint) to anon, authenticated;

-- the creator's "under development" switch: yes = nothing can be bought yet, no = items with a payment link can be bought
create or replace function public.px_mod_shop_dev(p_pw text, p_on boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_mod_cfg set shop_dev = coalesce(p_on, true) where id = 1;
  insert into px_mod_log (act, note) values ('shop under development', case when coalesce(p_on, true) then 'yes' else 'no (buying on)' end);
  return jsonb_build_object('ok', true, 'dev', coalesce(p_on, true));
end $$;
grant execute on function public.px_mod_shop_dev(text, boolean) to anon, authenticated;

-- the creator makes Pixel Football public (everyone) or private (staff only)
create or replace function public.px_mod_football(p_pw text, p_public boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_mod_cfg set football_public = coalesce(p_public, false) where id = 1;
  insert into px_mod_log (act, note) values ('football', case when coalesce(p_public, false) then 'public: everyone can play' else 'private: staff only' end);
  return jsonb_build_object('ok', true, 'fb', coalesce(p_public, false));
end $$;
grant execute on function public.px_mod_football(text, boolean) to anon, authenticated;


-- ===== v24: a poll on an announcement (a check or an X: do people like the update?) =====
alter table public.px_announce add column if not exists poll boolean not null default false;
create table if not exists public.px_ann_votes (ann_id bigint not null, uid text not null, v smallint not null check (v in (1, -1)), at timestamptz not null default now(), primary key (ann_id, uid));
alter table public.px_ann_votes enable row level security;
revoke all on public.px_ann_votes from anon, authenticated;
-- the live announcement, with its poll totals and (for a player) how that player voted
create or replace function public.px_ann_json(p_uid text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'x', a.x, 'poll', a.poll, 'until', px_ms(a.until),
    'yes', (select count(*) from px_ann_votes where ann_id = a.id and v = 1), 'no', (select count(*) from px_ann_votes where ann_id = a.id and v = -1),
    'mine', (select v from px_ann_votes where ann_id = a.id and uid = p_uid))
  from px_announce a where a.until > now() order by a.id desc limit 1
$$;
-- the last few polls with their results (for the creator panel)
create or replace function public.px_ann_polls() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(q order by (q ->> 'id')::bigint desc), '[]'::jsonb) from (
    select jsonb_build_object('id', a.id, 'x', a.x, 'at', px_ms(a.at), 'live', a.until > now(),
      'yes', (select count(*) from px_ann_votes where ann_id = a.id and v = 1), 'no', (select count(*) from px_ann_votes where ann_id = a.id and v = -1)) q
    from px_announce a where a.poll order by a.id desc limit 6) z
$$;
create or replace function public.px_ann_vote(p_uid text, p_key text, p_id bigint, p_v int) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  if not exists (select 1 from px_announce where id = p_id and poll and until > now()) then return jsonb_build_object('err', 'closed'); end if;
  if p_v in (1, -1) then insert into px_ann_votes (ann_id, uid, v) values (p_id, p_uid, p_v) on conflict (ann_id, uid) do update set v = excluded.v, at = now();
  else delete from px_ann_votes where ann_id = p_id and uid = p_uid; end if;
  return jsonb_build_object('ok', true, 'ann', px_ann_json(p_uid));
end $$;
revoke all on function public.px_ann_json(text), public.px_ann_polls() from public, anon, authenticated;
grant execute on function public.px_ann_vote(text, text, bigint, int) to anon, authenticated;


-- ===== v25: bans that stick, names that stay clean, chat that mutes spam and hate on its own =====
alter table public.px_players add column if not exists name_lock boolean not null default false;   -- a mod renamed them: their game can't change it back
alter table public.px_players add column if not exists prev text[];                                -- the other ids this device has used (it remembers them outside the save)
alter table public.px_players add column if not exists iph text;                                    -- a scrambled tag of the network they play from (never the address itself)
alter table public.px_bans add column if not exists src text;                                       -- a ban that followed the player from another id: that id
create table if not exists public.px_ban_ok (uid text primary key, at timestamptz not null default now());   -- ids a mod cleared: old bans don't follow onto them
alter table public.px_ban_ok enable row level security; revoke all on public.px_ban_ok from anon, authenticated;
create index if not exists px_players_iph on public.px_players (iph);

-- hateful words (not just swearing): these get an automatic mute; the spellings people use to sneak them past a filter count too
create or replace function public.px_slur(x text) returns boolean language sql immutable as $$
  select regexp_replace(translate(lower(coalesce(x, '')), '134@0!9$', 'ieaaoigs'), '[^a-z\s]', '', 'g')
    ~ '\y(n+i+g+g+(a|ah|as|az|e|er|ers|uh|uhs)?|n+i+g+a+s?|f+a+g+s?|f+a+g+o+t+s?|r+e+t+a+r+d+s?|r+e+t+a+r+d+e+d|k+i+k+e+s?|c+h+i+n+k+s?|s+p+i+c+s?|t+r+a+n+n+y+)\y' $$;
-- (whole words only, so "spicy" or "snigger" are fine; spellings with numbers and dots inside count)

-- a name nobody should wear becomes Player; otherwise trimmed to 16
create or replace function public.px_name_clean(n text) returns text language sql immutable as $$
  select case when n is null then null when px_slur(n) or px_dm_filter(n) <> px_dm_clean(n) then 'Player' else nullif(left(btrim(regexp_replace(n, '[\u0000-\u001f\u007f]', '', 'g')), 16), '') end $$;

-- the network a request came from, scrambled (the same network gives the same tag; the address can't be read back)
create or replace function public.px_net_tag() returns text language plpgsql stable as $$
declare h json; ip text;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then return null; end;
  if h is null then return null; end if;
  ip := coalesce(h ->> 'cf-connecting-ip', h ->> 'x-real-ip', split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1));
  ip := nullif(btrim(coalesce(ip, '')), ''); if ip is null then return null; end if;
  return left(md5('pxn:' || ip), 12);
end $$;

-- a ban or mute on another id this device used (the game remembers them outside the save), or on this Google account,
-- follows the player onto this id. Staff are never caught, and an id a mod cleared stays clear.
create or replace function public.px_ban_follow(p_uid text, p_info jsonb) returns void language plpgsql security definer set search_path = public as $$
declare pv text[]; g text; b px_bans; k text; nm text;
begin
  pv := array(select left(x, 32) from jsonb_array_elements_text(case when p_info is not null and jsonb_typeof(p_info -> 'pv') = 'array' then p_info -> 'pv' else '[]'::jsonb end) x where x <> p_uid limit 8);
  if array_length(pv, 1) > 0 then
    update px_players set prev = (select array(select distinct v from unnest(coalesce(prev, '{}') || pv) v limit 16)) where uid = p_uid and (prev is null or not (prev @> pv));
  end if;
  if px_is_staff(p_uid) or exists (select 1 from px_ban_ok where uid = p_uid) then return; end if;
  select sub into g from px_google where uid = p_uid;
  if coalesce(array_length(pv, 1), 0) = 0 and g is null then return; end if;
  foreach k in array array['ban', 'mute'] loop
    if px_is_banned(p_uid, k) then continue; end if;
    select * into b from px_bans x where x.kind = k and (x.until is null or x.until > now()) and x.uid <> p_uid
      and (x.uid = any(pv) or (g is not null and x.uid in (select uid from px_google where sub = g)))
      order by x."full" desc, x.until desc nulls first limit 1;
    if found then
      select name into nm from px_players where uid = p_uid;
      insert into px_bans (uid, kind, name, reason, at, until, "full", "by", by_name, src) values (p_uid, k, nm, b.reason, now(), b.until, b."full", b."by", b.by_name, coalesce(b.src, b.uid))
        on conflict (uid, kind) do update set reason = excluded.reason, at = now(), until = excluded.until, "full" = excluded."full", "by" = excluded."by", by_name = excluded.by_name, src = excluded.src;
      insert into px_mod_log (act, target, note) values (k || ' followed to a new id', p_uid || ' (' || coalesce(nm, '?') || ')', 'from ' || b.uid || ' (' || coalesce(b.name, '?') || ')');
    end if;
  end loop;
end $$;

-- Global chat on its own: a hateful word mutes the sender for 30 minutes; the same line over and over, or a flood, for 5
drop function if exists public.px_chat_guard(px_players, text);
create or replace function public.px_chat_guard(r px_players, p_x text) returns boolean language plpgsql security definer set search_path = public as $$
declare why text; mins int;
begin
  if px_is_staff(r.uid) then return false; end if;
  if px_slur(p_x) then why := 'Auto: hateful language'; mins := 30;
  elsif px_word_hit(p_x) then why := 'Auto: a word the admins blocked'; mins := 10;
  elsif (select count(*) from px_msgs where uid = r.uid and kind = 'm' and at > now() - interval '60 seconds' and lower(btrim(x)) = lower(btrim(left(p_x, 160)))) >= 2 then why := 'Auto: spamming the same message'; mins := 5;
  elsif (select count(*) from px_msgs where uid = r.uid and kind = 'm' and at > now() - interval '40 seconds') >= 14 then why := 'Auto: flooding the chat'; mins := 5;
  end if;
  if why is null then return false; end if;
  insert into px_bans (uid, kind, name, reason, at, until, "full", "by") values (r.uid, 'mute', r.name, why, now(), now() + make_interval(mins => mins), false, 'auto')
    on conflict (uid, kind) do update set reason = excluded.reason, at = now(), until = excluded.until, "by" = 'auto', src = null;
  insert into px_mod_log (act, target, note) values ('auto-mute', r.uid || ' (' || coalesce(r.name, '?') || ')', why || ' · ' || mins || ' min · "' || left(p_x, 80) || '"');
  return true;
end $$;

-- players who look like a banned player back on a new id: made after the ban, on the same network AND the same kind of device.
-- (Schools share networks and computers, so this is a pointer for a mod to check, never an automatic ban.)
create or replace function public.px_evaders() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(q order by (q ->> 'created')::bigint desc), '[]'::jsonb) from (
    select jsonb_build_object('uid', o.uid, 'n', o.name, 'created', px_ms(o.created), 'seen', px_ms(o.seen), 'buid', b.uid, 'bn', bp.name, 'samename', lower(o.name) = lower(bp.name)) q
    from px_bans b join px_players bp on bp.uid = b.uid
    join px_players o on o.iph = bp.iph and o.iph is not null and o.uid <> b.uid and o.created > b.at - interval '1 hour' and o.created > now() - interval '30 days'
      and coalesce(o.info -> 'dev' ->> 'id', '') = coalesce(bp.info -> 'dev' ->> 'id', '-') and coalesce(o.info -> 'dev' ->> 'id', '') <> ''
    where b.kind = 'ban' and (b.until is null or b.until > now()) and b.src is null
      and not px_is_banned(o.uid) and not px_is_staff(o.uid)
    limit 30) z $$;

-- let a renamed player pick their own name again
create or replace function public.px_mod_name_free(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_players set name_lock = false where uid = p_uid;
  insert into px_mod_log (act, target, note) values ('name unlocked', p_uid, '');
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.px_slur(text), public.px_name_clean(text), public.px_net_tag(), public.px_ban_follow(text, jsonb), public.px_chat_guard(px_players, text), public.px_evaders() from public, anon, authenticated;
grant execute on function public.px_mod_name_free(text, text) to anon, authenticated;


-- ===== v26: a safer panel (PINs, sessions, a security log), admins, signing in from any device, the online switch, the chat's rules =====
alter table public.px_staff add column if not exists pin_salt text;
alter table public.px_staff add column if not exists pin_hash text;
alter table public.px_staff add column if not exists pin_fails int not null default 0;
alter table public.px_staff add column if not exists pin_locked timestamptz;
alter table public.px_staff add column if not exists last_login timestamptz;
create table if not exists public.px_staff_sessions (token_hash text primary key, uid text not null, at timestamptz not null default now(), expires timestamptz not null, dev text, iph text);
create table if not exists public.px_staff_emails (email text primary key, role text not null check (role in ('owner', 'moderator', 'helper')), added_by text, at timestamptz not null default now());
create table if not exists public.px_sec_log (id bigserial primary key, at timestamptz not null default now(), act text not null, uid text, name text, note text, iph text);
alter table public.px_staff_sessions enable row level security; alter table public.px_staff_emails enable row level security; alter table public.px_sec_log enable row level security;
revoke all on public.px_staff_sessions, public.px_staff_emails, public.px_sec_log from anon, authenticated;
alter table public.px_mod_cfg add column if not exists req_pin boolean not null default false;
alter table public.px_mod_cfg add column if not exists online_off boolean not null default false;
alter table public.px_mod_cfg add column if not exists online_msg text;
alter table public.px_mod_cfg add column if not exists chat_off boolean not null default false;
alter table public.px_mod_cfg add column if not exists chat_slow int not null default 0;
alter table public.px_mod_cfg add column if not exists words text[] not null default '{}';

-- (v27) ONLY THE CREATOR HAS THE OWNER PANEL. The creator is whoever signs in with the creator's email (kept here only as a
-- scrambled sha256, so this public file doesn't show it), or a device the creator signed into with the creator password.
-- Everyone else who used to be an admin is a moderator now, and nobody can be made an admin from the panel.
create table if not exists public.px_creator (id int primary key default 1 check (id = 1), email_hash text not null);
alter table public.px_creator enable row level security; revoke all on public.px_creator from anon, authenticated;
insert into public.px_creator (id, email_hash) values (1, '7fcf2bf2b13c5429e17e29e964a58fbf6f4f9df32767617deb4e510092aae974') on conflict (id) do update set email_hash = excluded.email_hash;
create or replace function public.px_is_creator(p_uid text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from px_google g, px_creator c where g.uid = p_uid and encode(sha256(convert_to(lower(btrim(g.email)), 'utf8')), 'hex') = c.email_hash)
      or exists (select 1 from px_staff s where s.uid = p_uid and s.role = 'owner' and s.creator_dev) $$;
revoke all on function public.px_is_creator(text) from public, anon, authenticated;
-- the rank a player has: the creator; else their device on the staff list, or the email they signed in with on the staff email list
create or replace function public.px_staff_role(p_uid text) returns text language sql stable security definer set search_path = public as $$
  select case when px_is_creator(p_uid) then 'owner' else (select case r when 'owner' then 'moderator' else r end from (select coalesce((select role from px_staff where uid = p_uid),
    (select e.role from px_staff_emails e join px_google g on lower(g.email) = lower(e.email) where g.uid = p_uid order by case e.role when 'owner' then 0 when 'moderator' then 1 else 2 end limit 1)) r) q) end $$;

-- the chat's rules for someone who isn't staff: online play off, the chat off, slow mode
create or replace function public.px_chat_rules(p_uid text, p_kind text) returns void language plpgsql security definer set search_path = public as $$
declare c px_mod_cfg;
begin
  select * into c from px_mod_cfg where id = 1; if not found then return; end if;
  if c.online_off then raise exception 'Online play is switched off right now'; end if;
  if p_kind = 'm' and c.chat_off then raise exception 'The chat is switched off right now'; end if;
  if p_kind = 'm' and c.chat_slow > 0 and exists (select 1 from px_msgs where uid = p_uid and kind = 'm' and at > now() - make_interval(secs => c.chat_slow)) then raise exception 'slow down'; end if;
end $$;
-- a word on the admins' own list (whole words, any case)
create or replace function public.px_word_hit(x text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from unnest(coalesce((select words from px_mod_cfg where id = 1), '{}')) w
    where length(btrim(w)) >= 2 and regexp_replace(lower(coalesce(x, '')), '[^a-z0-9\s]', '', 'g') ~ ('\y' || regexp_replace(lower(btrim(w)), '[^a-z0-9 ]', '', 'g') || '\y')) $$;

-- the panel PIN: set it (or change it: the old one is needed), then open a session with it (12 hours, this device only)
create or replace function public.px_staff_set_pin(p_uid text, p_key text, p_old text, p_new text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl px_players; st px_staff; rl text; salt text;
begin
  select * into pl from px_players where uid = p_uid and keyhash = md5(coalesce(p_key, '') || ':pxk');
  if not found then return jsonb_build_object('err', 'wrong'); end if;
  rl := px_staff_role(p_uid); if rl is null then return jsonb_build_object('err', 'wrong'); end if;
  insert into px_staff (uid, role, name) values (p_uid, rl, pl.name) on conflict (uid) do nothing;
  select * into st from px_staff where uid = p_uid;
  if p_new is null or p_new !~ '^[0-9]{4,8}$' then return jsonb_build_object('err', 'A PIN is 4 to 8 numbers.'); end if;
  if st.pin_hash is not null then
    if st.pin_locked is not null and st.pin_locked > now() then return jsonb_build_object('err', 'locked'); end if;
    if encode(sha256(convert_to(st.pin_salt || coalesce(p_old, ''), 'utf8')), 'hex') <> st.pin_hash then
      update px_staff set pin_locked = case when pin_fails + 1 >= 5 then now() + interval '15 minutes' end, pin_fails = case when pin_fails + 1 >= 5 then 0 else pin_fails + 1 end where uid = p_uid;
      insert into px_sec_log (act, uid, name, iph) values ('wrong PIN (changing it)', p_uid, pl.name, px_net_tag());
      return jsonb_build_object('err', 'The old PIN is wrong.');
    end if;
  end if;
  salt := md5(gen_random_uuid()::text);
  update px_staff set pin_salt = salt, pin_hash = encode(sha256(convert_to(salt || p_new, 'utf8')), 'hex'), pin_fails = 0, pin_locked = null where uid = p_uid;
  delete from px_staff_sessions where uid = p_uid;   -- (every open panel of this person closes)
  insert into px_sec_log (act, uid, name, iph) values (case when st.pin_hash is null then 'set a panel PIN' else 'changed their panel PIN' end, p_uid, pl.name, px_net_tag());
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_staff_unlock(p_uid text, p_key text, p_pin text, p_dev text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl px_players; st px_staff; tok text;
begin
  select * into pl from px_players where uid = p_uid and keyhash = md5(coalesce(p_key, '') || ':pxk');
  if not found or px_staff_role(p_uid) is null then return jsonb_build_object('err', 'wrong'); end if;
  select * into st from px_staff where uid = p_uid;
  if not found or st.pin_hash is null then return jsonb_build_object('err', 'needpin'); end if;
  if st.pin_locked is not null and st.pin_locked > now() then return jsonb_build_object('err', 'locked', 'until', px_ms(st.pin_locked)); end if;
  if encode(sha256(convert_to(st.pin_salt || coalesce(p_pin, ''), 'utf8')), 'hex') <> st.pin_hash then
    update px_staff set pin_fails = case when pin_fails + 1 >= 5 then 0 else pin_fails + 1 end, pin_locked = case when pin_fails + 1 >= 5 then now() + interval '15 minutes' end where uid = p_uid;
    insert into px_sec_log (act, uid, name, note, iph) values ('wrong panel PIN', p_uid, pl.name, case when st.pin_fails + 1 >= 5 then 'locked for 15 minutes' else (st.pin_fails + 1) || ' in a row' end, px_net_tag());
    return jsonb_build_object('err', case when st.pin_fails + 1 >= 5 then 'locked' else 'wrongpin' end, 'left', greatest(0, 4 - st.pin_fails));
  end if;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  update px_staff set pin_fails = 0, pin_locked = null where uid = p_uid;
  insert into px_staff_sessions (token_hash, uid, expires, dev, iph) values (encode(sha256(convert_to(tok, 'utf8')), 'hex'), p_uid, now() + interval '12 hours', left(coalesce(p_dev, ''), 60), px_net_tag());
  delete from px_staff_sessions where expires < now() - interval '1 day';
  return jsonb_build_object('ok', true, 'token', tok);
end $$;

-- the admins' security page: who has the panel open where, what happened, the admin emails, the switches
create or replace function public.px_mod_sec(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object(
    'sessions', coalesce((select jsonb_agg(jsonb_build_object('uid', s.uid, 'n', coalesce(p.name, '?'), 'at', px_ms(s.at), 'exp', px_ms(s.expires), 'dev', s.dev, 'me', s.token_hash = current_setting('px.tok', true)) order by s.at desc) from px_staff_sessions s left join px_players p on p.uid = s.uid where s.expires > now()), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', px_ms(at), 'act', act, 'uid', uid, 'n', name, 'note', note, 'net', iph) order by id desc) from (select * from px_sec_log order by id desc limit 80) q), '[]'::jsonb),
    'emails', coalesce((select jsonb_agg(jsonb_build_object('email', email, 'role', role, 'by', added_by, 'at', px_ms(at)) order by at) from px_staff_emails), '[]'::jsonb),
    'pins', coalesce((select jsonb_agg(jsonb_build_object('uid', s.uid, 'n', coalesce(p.name, s.name, '?'), 'rank', case s.role when 'owner' then 'admin' else s.role end, 'pin', s.pin_hash is not null, 'last', px_ms(s.last_login))) from px_staff s left join px_players p on p.uid = s.uid), '[]'::jsonb),
    'req_pin', (select req_pin from px_mod_cfg where id = 1), 'has_pw', (select pwhash is not null from px_mod_cfg where id = 1),
    'online_off', (select online_off from px_mod_cfg where id = 1), 'online_msg', (select online_msg from px_mod_cfg where id = 1),
    'chat_off', (select chat_off from px_mod_cfg where id = 1), 'chat_slow', (select chat_slow from px_mod_cfg where id = 1), 'words', (select to_jsonb(words) from px_mod_cfg where id = 1));
end $$;
-- close the panel on every other device (or one person's)
create or replace function public.px_mod_sec_revoke(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); n int;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  delete from px_staff_sessions where (p_uid is null or uid = p_uid) and token_hash is distinct from nullif(current_setting('px.tok', true), '');
  get diagnostics n = row_count;
  insert into px_sec_log (act, uid, note, iph) values ('closed open panels', p_uid, n || ' session(s), by ' || coalesce(nullif(current_setting('px.hname', true), ''), 'an admin'), px_net_tag());
  return jsonb_build_object('ok', true, 'n', n);
end $$;
create or replace function public.px_mod_req_pin(p_pw text, p_on boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if coalesce(p_on, false) and (select pin_hash from px_staff where uid = nullif(current_setting('px.suid', true), '')) is null and position('|' in coalesce(p_pw, '')) > 0 then return jsonb_build_object('err', 'Set your own PIN first.'); end if;
  update px_mod_cfg set req_pin = coalesce(p_on, false) where id = 1;
  insert into px_sec_log (act, note, iph) values (case when p_on then 'PIN required for all staff' else 'PIN no longer required' end, 'by ' || coalesce(nullif(current_setting('px.hname', true), ''), 'an admin'), px_net_tag());
  return jsonb_build_object('ok', true);
end $$;
-- staff by Google account: whoever signs in with this email has this rank on any device
create or replace function public.px_mod_staff_email(p_pw text, p_email text, p_role text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); e text := lower(btrim(coalesce(p_email, '')));
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 120 then return jsonb_build_object('err', 'That isn''t an email address.'); end if;
  if p_role is null or p_role in ('', 'none') then
    delete from px_staff_emails where email = e;
  elsif p_role in ('owner', 'admin') then
    return jsonb_build_object('err', 'Only the creator has the owner panel. Pick Moderator for staff.');
  elsif p_role in ('moderator', 'helper') then
    insert into px_staff_emails (email, role, added_by) values (e, p_role, coalesce(nullif(current_setting('px.hname', true), ''), 'admin'))
      on conflict (email) do update set role = excluded.role;
  else return jsonb_build_object('err', 'bad rank'); end if;
  insert into px_sec_log (act, note, iph) values ('staff email ' || coalesce(nullif(p_role, ''), 'removed'), e, px_net_tag());
  return jsonb_build_object('ok', true);
end $$;
-- the creator password (the spare key that makes any device an admin): change it from the panel
create or replace function public.px_mod_password(p_pw text, p_old text, p_new text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); c px_mod_cfg; ns text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select * into c from px_mod_cfg where id = 1 for update;
  if c.pwhash is not null and encode(sha256(convert_to(c.salt || coalesce(p_old, ''), 'utf8')), 'hex') <> c.pwhash then
    insert into px_sec_log (act, note, iph) values ('wrong creator password', 'while changing it', px_net_tag());
    return jsonb_build_object('err', 'The old password is wrong.');
  end if;
  if p_new is null or length(p_new) < 10 or length(p_new) > 64 then return jsonb_build_object('err', 'The new password needs 10 to 64 characters.'); end if;
  ns := md5(gen_random_uuid()::text);
  update px_mod_cfg set salt = ns, pwhash = encode(sha256(convert_to(ns || p_new, 'utf8')), 'hex'), fails = 0, strikes = 0, locked_until = null where id = 1;
  insert into px_sec_log (act, note, iph) values ('creator password changed', 'by ' || coalesce(nullif(current_setting('px.hname', true), ''), 'an admin'), px_net_tag());
  return jsonb_build_object('ok', true);
end $$;
-- the big switches: online play off (with a message for everyone), the chat off, slow mode, blocked words
create or replace function public.px_mod_online(p_pw text, p_off boolean, p_msg text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_mod_cfg set online_off = coalesce(p_off, false), online_msg = left(nullif(btrim(coalesce(p_msg, '')), ''), 120) where id = 1;
  if coalesce(p_off, false) then delete from px_queue; end if;
  insert into px_mod_log (act, note) values (case when p_off then 'online play OFF' else 'online play ON' end, coalesce(p_msg, ''));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_mod_chat_cfg(p_pw text, p_off boolean, p_slow int, p_words text[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  update px_mod_cfg set chat_off = coalesce(p_off, chat_off), chat_slow = least(greatest(coalesce(p_slow, chat_slow), 0), 120),
    words = coalesce((select array(select distinct left(lower(btrim(w)), 30) from unnest(p_words) w where length(btrim(w)) >= 2 limit 200)), words) where id = 1;
  insert into px_mod_log (act, note) values ('chat rules', 'off: ' || coalesce(p_off::text, '-') || ' · slow: ' || coalesce(p_slow::text, '-') || ' s · words: ' || coalesce(array_length(p_words, 1), 0));
  return jsonb_build_object('ok', true);
end $$;
-- give a player cash (their game picks it up the next time it checks in)
create or replace function public.px_mod_give(p_pw text, p_uid text, p_cash int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); nm text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select name into nm from px_players where uid = p_uid; if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  if p_cash is null or p_cash = 0 or abs(p_cash) > 100000 then return jsonb_build_object('err', 'Between 1 and 100000.'); end if;
  insert into px_edits (uid, edit) values (p_uid, jsonb_build_object('cash', p_cash));
  insert into px_mod_log (act, target, note) values ('gave cash', p_uid || ' (' || nm || ')', p_cash::text);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.px_staff_role(text), public.px_chat_rules(text, text), public.px_word_hit(text) from public, anon, authenticated;
grant execute on function public.px_staff_set_pin(text, text, text, text), public.px_staff_unlock(text, text, text, text), public.px_mod_sec(text), public.px_mod_sec_revoke(text, text), public.px_mod_req_pin(text, boolean),
  public.px_mod_staff_email(text, text, text), public.px_mod_password(text, text, text), public.px_mod_online(text, boolean, text), public.px_mod_chat_cfg(text, boolean, int, text[]), public.px_mod_give(text, text, int) to anon, authenticated;

-- (these two come last: they use the tables and columns above)
create or replace function public.px_staff_rank(p_uid text) returns text language sql stable security definer set search_path = public as $$
  select case r when 'owner' then 'creator' else r end from (select px_staff_role(p_uid) r) q $$;
create or replace function public.px_pub_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('reqg', coalesce((select req_game from px_mod_cfg where id = 1), false), 'upd', coalesce((select upd_until > now() from px_mod_cfg where id = 1), false), 'dm', coalesce((select dm_mode from px_mod_cfg where id = 1), 'all'), 'minv', (select nullif(min_ver, 0) from px_mod_cfg where id = 1), 'by', (select byline from px_mod_cfg where id = 1), 'fb', coalesce((select football_public from px_mod_cfg where id = 1), false)) || coalesce((select jsonb_build_object('off', online_off, 'offmsg', online_msg, 'chatoff', chat_off, 'slow', chat_slow) from px_mod_cfg where id = 1), '{}'::jsonb) $$;

-- ===== v27: the creator is the only admin =====
-- every other admin becomes a moderator (on the staff list and on the email list). Safe to run again.
update public.px_staff set role = 'moderator' where role = 'owner' and not px_is_creator(uid);
update public.px_staff_emails set role = 'moderator' where role = 'owner' and encode(sha256(convert_to(lower(btrim(email)), 'utf8')), 'hex') <> (select email_hash from public.px_creator where id = 1);

-- ===== v27: "Pay Nathan at school" for the Online Shop =====
-- A player picks a shop item, a school day, a time after school and a place. The creator sees it in the panel (Pay at school),
-- confirms it, and once they've paid in person presses Paid: the item goes into px_purchases like a card payment, and the
-- player's game picks it up by itself. Nothing here takes money; it only books the meeting.
create table if not exists public.px_meets (id bigserial primary key, at timestamptz not null default now(), uid text not null, name text,
  item_id text not null, item_name text not null, kind text not null default 'other', amount int not null default 0, ref text not null default '', price numeric not null default 0,
  day date not null, slot text not null, place text not null, note text, status text not null default 'new', done_at timestamptz);   -- status: new · ok (confirmed) · paid · no (can't) · cancelled (by the player)
create index if not exists px_meets_uid on public.px_meets (uid, at desc);
alter table public.px_meets enable row level security; revoke all on public.px_meets from anon, authenticated;
create or replace function public.px_meet_request(p_uid text, p_key text, p_item text, p_name text, p_kind text, p_amount int, p_ref text, p_price numeric, p_day date, p_slot text, p_place text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; nm text; open_n int;
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  if p_day is null or p_day < current_date or p_day > current_date + 14 or extract(isodow from p_day) > 5 then return jsonb_build_object('err', 'Pick a school day in the next two weeks.'); end if;
  if p_slot is null or p_slot not in ('Before school', 'Lunch', 'Right after school', '15 min after school', '30 min after school') then return jsonb_build_object('err', 'Pick a time.'); end if;
  if p_place is null or length(btrim(p_place)) < 2 then return jsonb_build_object('err', 'Say where to meet.'); end if;
  select count(*) into open_n from px_meets where uid = p_uid and status in ('new', 'ok');
  if open_n >= 3 then return jsonb_build_object('err', 'You already have 3 meetings booked. Cancel one first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and at > now() - interval '10 minutes') >= 5 then return jsonb_build_object('err', 'Slow down a little.'); end if;
  -- the item as the shop lists it (the creator's list); the game's built-in list if the creator never changed it
  select x into it from jsonb_array_elements(coalesce((select shop from px_mod_cfg where id = 1), '[]'::jsonb)) x where x ->> 'id' = p_item limit 1;
  select name into nm from px_players where uid = p_uid;
  insert into px_meets (uid, name, item_id, item_name, kind, amount, ref, price, day, slot, place, note)
  values (p_uid, nm, left(p_item, 40), left(coalesce(it ->> 'name', p_name, p_item), 60), left(coalesce(it ->> 'kind', p_kind, 'other'), 12),
    least(coalesce((it ->> 'amount')::int, p_amount, 0), 100000), left(coalesce(it ->> 'ref', p_ref, ''), 40), coalesce((it ->> 'price')::numeric, p_price, 0),
    p_day, p_slot, left(btrim(p_place), 60), nullif(left(btrim(coalesce(p_note, '')), 140), ''));
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_meet_mine(p_uid text, p_key text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_name, 'price', price, 'day', day, 'slot', slot, 'place', place, 'st', status) order by at desc)
    from (select * from px_meets where uid = p_uid order by at desc limit 10) q), '[]'::jsonb));
end $$;
create or replace function public.px_meet_cancel(p_uid text, p_key text, p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  update px_meets set status = 'cancelled', done_at = now() where id = p_id and uid = p_uid and status in ('new', 'ok');
  return jsonb_build_object('ok', true);
end $$;
-- the creator's list and buttons (only the creator: it's money)
create or replace function public.px_mod_meets(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', coalesce((select name from px_players p where p.uid = m.uid), m.name, '?'), 'item', item_name, 'price', price, 'kind', kind, 'amount', amount,
      'day', day, 'slot', slot, 'place', place, 'note', note, 'st', status, 'at', px_ms(at)) order by (case status when 'new' then 0 when 'ok' then 1 else 2 end), day, at)
    from (select * from px_meets where status in ('new', 'ok') or at > now() - interval '30 days' order by at desc limit 120) m), '[]'::jsonb),
    'open', (select count(*) from px_meets where status = 'new'));
end $$;
create or replace function public.px_mod_meet_set(p_pw text, p_id bigint, p_status text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); m px_meets;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_status not in ('ok', 'paid', 'no', 'new') then return jsonb_build_object('err', 'bad status'); end if;
  select * into m from px_meets where id = p_id for update; if not found then return jsonb_build_object('err', 'nobody'); end if;
  if m.status = 'paid' then return jsonb_build_object('err', 'Already paid and given.'); end if;
  update px_meets set status = p_status, done_at = case when p_status in ('paid', 'no') then now() else done_at end where id = p_id;
  if p_status = 'paid' then -- the item goes out the same way a card payment does: the player's game takes it by itself
    insert into px_purchases (uid, item_id, name, kind, amount, ref, price, provider, provider_ref, status)
    values (m.uid, m.item_id, m.item_name, m.kind, m.amount, m.ref, m.price, 'school', 'meet-' || m.id, 'paid') on conflict (provider_ref) do nothing;
  end if;
  insert into px_mod_log (act, target, note) values ('pay at school: ' || p_status, m.uid || ' (' || coalesce(m.name, '?') || ')', m.item_name || ' $' || m.price);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_meet_request(text, text, text, text, text, int, text, numeric, date, text, text, text), public.px_meet_mine(text, text), public.px_meet_cancel(text, text, bigint),
  public.px_mod_meets(text), public.px_mod_meet_set(text, bigint, text) to anon, authenticated;

-- ===== v27: catching fighters edited in the browser =====
-- Every check-in reports the fighter being played (level, rebirth, stats, unspent points). Numbers the game itself can never
-- reach mean someone edited their save with the browser's tools: that player is flagged for the mods, kept off the
-- leaderboard, and their ranked games and Turf fights don't count. Nothing is deleted; a mod edit clears the flag.
alter table public.px_players add column if not exists cheat text;
alter table public.px_players add column if not exists free_ok boolean not null default false;   -- (the creator gave this player stats past the cap)
create or replace function public.px_num(t text) returns numeric language sql immutable as $$ select case when t ~ '^-?[0-9]{1,9}(\.[0-9]+)?$' then t::numeric end $$;
create or replace function public.px_cheat_why(i jsonb, free boolean) returns text language sql immutable set search_path = public as $$
  select case
    when i is null or jsonb_typeof(i -> 'fs') is distinct from 'object' then null
    when coalesce(px_num(i -> 'fs' ->> 'r'), 0) > 10 or coalesce(px_num(i -> 'fs' ->> 'r'), 0) < 0 then 'rebirth ' || (i -> 'fs' ->> 'r') || ' (the most is 10)'
    when coalesce(px_num(i -> 'fs' ->> 'l'), 1) > 300 then 'level ' || (i -> 'fs' ->> 'l') || ' (the most is 300)'
    when free then null
    when jsonb_typeof(i -> 'fs' -> 's') = 'array' and exists (select 1 from jsonb_array_elements_text(i -> 'fs' -> 's') v where coalesce(px_num(v), 0) > 20 + 2 * coalesce(px_num(i -> 'fs' ->> 'r'), 0))
      then 'a stat above the cap for rebirth ' || coalesce(i -> 'fs' ->> 'r', '0')
    when jsonb_typeof(i -> 'fs' -> 's') = 'array' and (select coalesce(sum(greatest(0, coalesce(px_num(v), 0) - (2 + coalesce(px_num(i -> 'fs' ->> 'r'), 0)))), 0) from jsonb_array_elements_text(i -> 'fs' -> 's') v)
      + greatest(0, coalesce(px_num(i -> 'fs' ->> 'p'), 0)) > (coalesce(px_num(i -> 'fs' ->> 'l'), 1) - 1) * 3 + 6 then 'more stat points than level ' || coalesce(i -> 'fs' ->> 'l', '1') || ' gives'
    else null end $$;
create or replace function public.px_cheat_trg() returns trigger language plpgsql set search_path = public as $$
begin
  if new.info is distinct from old.info then
    new.cheat := coalesce(px_cheat_why(new.info, new.free_ok), case when old.cheat is not null and new.info is not distinct from old.info then old.cheat end);
    if new.cheat is not null and old.cheat is null then insert into px_mod_log (act, target, note) values ('edited fighter?', new.uid || ' (' || coalesce(new.name, '?') || ')', new.cheat); end if;
  end if;
  return new;
end $$;
drop trigger if exists px_cheat_check on public.px_players;
create trigger px_cheat_check before update of info on public.px_players for each row execute function public.px_cheat_trg();
revoke all on function public.px_cheat_why(jsonb, boolean), public.px_cheat_trg() from public, anon, authenticated;

-- ===== v27: the fundraiser =====
-- The creator sets a goal and how much has come in so far; every player can open the Fundraiser screen and see the bar fill.
-- Only the creator can change it (helpers and moderators can't). Safe to run again.
alter table public.px_mod_cfg add column if not exists fund_on boolean not null default false;
alter table public.px_mod_cfg add column if not exists fund_title text;
alter table public.px_mod_cfg add column if not exists fund_note text;
alter table public.px_mod_cfg add column if not exists fund_goal numeric not null default 0;
alter table public.px_mod_cfg add column if not exists fund_raised numeric not null default 0;
alter table public.px_mod_cfg add column if not exists fund_at timestamptz;
create or replace function public.px_fund_pub() returns jsonb language sql stable security definer set search_path = public as $$
  select case when fund_title is null and fund_goal = 0 then null else jsonb_build_object('on', fund_on, 't', fund_title, 'n', fund_note, 'g', fund_goal, 'r', fund_raised, 'at', px_ms(fund_at)) end
  from px_mod_cfg where id = 1 $$;
create or replace function public.px_mod_fund(p_pw text, p_on boolean, p_title text, p_note text, p_goal numeric, p_raised numeric) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); g numeric := round(least(greatest(coalesce(p_goal, 0), 0), 10000000), 2); r numeric := round(least(greatest(coalesce(p_raised, 0), 0), 10000000), 2);
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can change the fundraiser.' else v end); end if;
  update px_mod_cfg set fund_on = coalesce(p_on, false), fund_title = left(nullif(btrim(coalesce(p_title, '')), ''), 80), fund_note = left(nullif(btrim(coalesce(p_note, '')), ''), 600),
    fund_goal = g, fund_raised = r, fund_at = now() where id = 1;
  insert into px_mod_log (act, note) values ('fundraiser', case when coalesce(p_on, false) then 'on' else 'off' end || ' · $' || r || ' of $' || g);
  return jsonb_build_object('ok', true, 'fund', px_fund_pub());
end $$;
revoke all on function public.px_fund_pub() from public, anon, authenticated;
grant execute on function public.px_mod_fund(text, boolean, text, text, numeric, numeric) to anon, authenticated;
-- (the public settings every game gets on each check-in, now with the fundraiser: this one replaces the copy above)
-- (moved to the end of the file: it now also carries the coin)

-- ===== v27: fighters that level up faster than the game allows =====
-- Each check-in says which fighter is being played and its level. The most a real fighter can gain is two levels a fight,
-- so if the level jumps further than the time since the last check-in allows (plus anything given: Online Shop levels,
-- staff-given levels, the Thank Nathan coin, gift codes), the save was edited. The flag stays until a staff edit clears it.
alter table public.px_players add column if not exists prog jsonb not null default '{}'::jsonb;   -- fighter id → { r, l, at } as last seen
alter table public.px_players add column if not exists lv_grant int not null default 0;            -- levels handed out that the next check-ins may show
create or replace function public.px_b36(t text) returns bigint language plpgsql immutable as $$
declare n bigint := 0; c int;
begin
  if t is null or t !~ '^[0-9a-z]{1,12}$' then return null; end if;
  for i in 1 .. length(t) loop c := ascii(substr(t, i, 1)); n := n * 36 + case when c <= 57 then c - 48 else c - 87 end; end loop;
  return n;
end $$;
create or replace function public.px_cheat_trg() returns trigger language plpgsql set search_path = public as $$
declare fs jsonb := new.info -> 'fs'; fid text; r int; l int; pv jsonb; secs real; jump int; nat int; why text; born bigint; nowms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  if new.info is distinct from old.info then
    -- how fast it levelled (only from games new enough to say which fighter it is)
    if fs is not null and coalesce(fs ->> 'id', '') ~ '^f[0-9a-z]{6,16}$' and not new.free_ok then
      fid := fs ->> 'id'; r := coalesce(px_num(fs ->> 'r'), 0)::int; l := coalesce(px_num(fs ->> 'l'), 1)::int;
      pv := coalesce(old.prog, '{}'::jsonb) -> fid;
      if pv is null and coalesce(old.prog, '{}'::jsonb) ? '*' then null; -- (just after a staff edit: whatever it shows now is the new starting point)
      elsif pv is null then -- a fighter we haven't seen: it can't be further along than its age allows (the id carries when it was made)
        born := px_b36(substr(fid, 2, 8));
        if born is not null and born between 1577836800000 and nowms + 60000 and nowms - born < 7200000 then
          secs := greatest(0, (nowms - born) / 1000.0); jump := l - 1 + r * 30;
        end if;
      else
        secs := extract(epoch from now()) - (case when (pv ->> 'at') ~ '^[0-9]{1,15}$' then (pv ->> 'at')::bigint else 0 end) / 1000.0;
        if r = coalesce(px_num(pv ->> 'r'), 0) then jump := l - coalesce(px_num(pv ->> 'l'), 1)::int;
        elsif r = coalesce(px_num(pv ->> 'r'), 0) + 1 then jump := l - 1;
        elsif r > coalesce(px_num(pv ->> 'r'), 0) + 1 then jump := (r - coalesce(px_num(pv ->> 'r'), 0)::int - 1) * 30 + l;
        end if; -- (fewer rebirths than before: a staff edit or a restored backup; start again from here)
      end if;
      if jump is not null and jump > 0 then
        nat := 2 * ceil(greatest(secs, 0) / 10.0)::int + 16;   -- (two levels a fight at the very most, plus room for claiming a few rewards at once)
        if jump > nat + new.lv_grant then why := 'levelled up too fast: +' || jump || ' levels in ' || round(greatest(secs, 0)) || 's'; end if;
        new.lv_grant := greatest(0, new.lv_grant - greatest(0, jump - nat));
      end if;
      new.prog := (case when jsonb_typeof(old.prog) = 'object' and (select count(*) from jsonb_object_keys(old.prog)) < 20 then old.prog - '*' else '{}'::jsonb end)
        || jsonb_build_object(fid, jsonb_build_object('r', r, 'l', l, 'at', nowms));
    end if;
    new.cheat := coalesce(px_cheat_why(new.info, new.free_ok), why, case when old.cheat like 'levelled up too fast%' then old.cheat end);
    if new.cheat is not null and old.cheat is null then insert into px_mod_log (act, target, note) values ('edited fighter?', new.uid || ' (' || coalesce(new.name, '?') || ')', new.cheat); end if;
  end if;
  return new;
end $$;
-- levels given out count as allowed; a staff edit of the fighter starts the tracking again
create or replace function public.px_grant_trg() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_table_name = 'px_edits' then
    if new.edit ? 'addlv' then update px_players set lv_grant = least(100000, lv_grant + greatest(0, coalesce(px_num(new.edit ->> 'addlv'), 0))::int) where uid = new.uid;
    elsif new.edit ? 'lv' or new.edit ? 'rb' or new.edit ? 'st' then update px_players set prog = '{"*": 1}'::jsonb where uid = new.uid; end if;
  elsif new.kind = 'levels' and new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid') then
    update px_players set lv_grant = least(100000, lv_grant + greatest(0, new.amount)) where uid = new.uid;
  end if;
  return new;
end $$;
drop trigger if exists px_grant_edits on public.px_edits;
create trigger px_grant_edits after insert on public.px_edits for each row execute function public.px_grant_trg();
drop trigger if exists px_grant_buys on public.px_purchases;
create trigger px_grant_buys after insert or update of status on public.px_purchases for each row execute function public.px_grant_trg();
revoke all on function public.px_b36(text), public.px_cheat_trg(), public.px_grant_trg() from public, anon, authenticated;

-- ===== v27: ranked games can't be farmed =====
-- Win-trading with a friend (or your own second account) doesn't pay: only the first 3 ranked games a day between the same
-- two players move their Elo, and a game that ends in under 20 seconds doesn't count.
create or replace function public.px_settle(m public.px_matches)
returns void language plpgsql security definer set search_path = public as $$
declare pa px_players; pb px_players; r_a int; r_b int; ga int; gb int; e_a real; k real; perf real; d int; aw boolean; same int;
begin
  if m.done then return; end if;
  if m.ra is null or m.rb is null or m.ra = m.rb then update px_matches set done = true where id = m.id; return; end if; -- no winner both agree on
  if extract(epoch from coalesce(m.ended_at, now()) - m.at) < 20 then update px_matches set done = true, da = 0, db = 0 where id = m.id; return; end if;
  select count(*) into same from px_matches x where x.id <> m.id and x.done and coalesce(x.da, 0) <> 0 and x.at > now() - interval '24 hours' and x.game = m.game
    and ((x.a = m.a and x.b = m.b) or (x.a = m.b and x.b = m.a));
  if same >= 3 then update px_matches set done = true, da = 0, db = 0 where id = m.id; return; end if;
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
revoke all on function public.px_settle(public.px_matches) from public, anon, authenticated;

-- ===== v27: the Thank Nathan coin =====
-- A little coin turns up somewhere on the menus. Pressing it gives levels (5 unless the creator changes it), once per
-- player, per device and per fighter. The creator can switch it off, change the levels, or start a new round so
-- everyone can find it again.
alter table public.px_mod_cfg add column if not exists coin_on boolean not null default true;
alter table public.px_mod_cfg add column if not exists coin_round int not null default 1;
alter table public.px_mod_cfg add column if not exists coin_lv int not null default 5;
create table if not exists public.px_coin (round int not null, uid text not null, fid text, dev text, lv int not null default 5, at timestamptz not null default now(), primary key (round, uid));
create index if not exists px_coin_fid on public.px_coin (round, fid);
create index if not exists px_coin_dev on public.px_coin (round, dev);
alter table public.px_coin enable row level security; revoke all on public.px_coin from anon, authenticated;
-- once a week: the coin's key is this week (Monday to Sunday, New York time) plus the creator's extra rounds, so it comes
-- back by itself every Monday and each player can take it once that week
create or replace function public.px_coin_key() returns int language sql stable security definer set search_path = public as $$
  select coalesce((select coin_round from px_mod_cfg where id = 1), 1) * 10000 + floor(extract(epoch from date_trunc('week', now() at time zone 'America/New_York')) / 604800)::int $$;
create or replace function public.px_coin_next() returns bigint language sql stable as $$
  select (extract(epoch from ((date_trunc('week', now() at time zone 'America/New_York') + interval '7 days') at time zone 'America/New_York')) * 1000)::bigint $$;
revoke all on function public.px_coin_key(), public.px_coin_next() from public, anon, authenticated;
create or replace function public.px_coin_claim(p_uid text, p_key text, p_fid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare c px_mod_cfg; pl px_players; dv text; v_fid text := left(coalesce(p_fid, ''), 20); rk int := px_coin_key();
begin
  pl := px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  select * into c from px_mod_cfg where id = 1;
  if not coalesce(c.coin_on, true) then return jsonb_build_object('err', 'off'); end if;
  dv := nullif(left(coalesce(pl.info -> 'dev' ->> 'id', ''), 20), '');
  if exists (select 1 from px_coin x where x.round = rk and x.uid = p_uid) then return jsonb_build_object('err', 'already'); end if;
  if v_fid <> '' and exists (select 1 from px_coin x where x.round = rk and x.fid = v_fid) then return jsonb_build_object('err', 'already'); end if;
  if dv is not null and exists (select 1 from px_coin x where x.round = rk and x.dev = dv) then return jsonb_build_object('err', 'already'); end if;
  insert into px_coin (round, uid, fid, dev, lv) values (rk, p_uid, v_fid, dv, c.coin_lv) on conflict do nothing;
  if not found then return jsonb_build_object('err', 'already'); end if;
  update px_players set lv_grant = least(100000, lv_grant + c.coin_lv) where uid = p_uid;   -- (so the anti-cheat knows these levels are real)
  return jsonb_build_object('ok', true, 'lv', c.coin_lv, 'round', rk);
end $$;
grant execute on function public.px_coin_claim(text, text, text) to anon, authenticated;
create or replace function public.px_coin_pub() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('on', coin_on, 'r', px_coin_key(), 'lv', coin_lv, 'next', px_coin_next()) from px_mod_cfg where id = 1 $$;
revoke all on function public.px_coin_pub() from public, anon, authenticated;
create or replace function public.px_mod_coin(p_pw text, p_on boolean, p_lv int, p_new_round boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); c px_mod_cfg;
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can change the coin.' else v end); end if;
  update px_mod_cfg set coin_on = coalesce(p_on, coin_on), coin_lv = least(greatest(coalesce(p_lv, coin_lv), 1), 50),
    coin_round = coin_round + case when coalesce(p_new_round, false) then 1 else 0 end where id = 1 returning * into c;
  insert into px_mod_log (act, note) values ('thank nathan coin', case when c.coin_on then 'on' else 'off' end || ' · +' || c.coin_lv || ' levels · round ' || c.coin_round);
  return jsonb_build_object('ok', true, 'coin', px_coin_pub(), 'found', (select count(*) from px_coin where round = px_coin_key()));
end $$;
create or replace function public.px_mod_coin_get(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); c px_mod_cfg;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select * into c from px_mod_cfg where id = 1;
  return jsonb_build_object('coin', px_coin_pub(), 'found', (select count(*) from px_coin where round = px_coin_key()), 'total', (select count(*) from px_coin),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('uid', x.uid, 'n', p.name, 'at', px_ms(x.at), 'lv', x.lv) order by x.at desc) from (select * from px_coin where round = px_coin_key() order by at desc limit 15) x left join px_players p on p.uid = x.uid), '[]'::jsonb));
end $$;
grant execute on function public.px_mod_coin(text, boolean, int, boolean), public.px_mod_coin_get(text) to anon, authenticated;



-- ===== v27: owner tools: clearing a flag, Double XP, gift codes =====
-- clear an anti-cheat flag (creator and moderators): the fighter's level now becomes the starting point
create or replace function public.px_mod_cheat_clear(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); nm text; why text;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_rank() = 'helper' then return jsonb_build_object('err', 'owner only'); end if;
  select name, cheat into nm, why from px_players where uid = p_uid; if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  update px_players set cheat = null, prog = '{"*": 1}'::jsonb where uid = p_uid;
  insert into px_mod_log (act, target, note) values ('cleared flag', p_uid || ' (' || nm || ')', coalesce(why, ''));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_cheat_clear(text, text) to anon, authenticated;

-- Double XP (or 1.5x, 3x) for a few hours, for everyone
alter table public.px_mod_cfg add column if not exists xp_mul real not null default 1;
alter table public.px_mod_cfg add column if not exists xp_until timestamptz;
create or replace function public.px_xp_pub() returns jsonb language sql stable security definer set search_path = public as $$
  select case when xp_until > now() and xp_mul > 1 then jsonb_build_object('m', xp_mul, 'until', px_ms(xp_until)) end from px_mod_cfg where id = 1 $$;
revoke all on function public.px_xp_pub() from public, anon, authenticated;
create or replace function public.px_mod_xp(p_pw text, p_mul real, p_hours real) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); m real := least(greatest(coalesce(p_mul, 1), 1), 3); h real := least(greatest(coalesce(p_hours, 0), 0), 72);
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can start an XP event.' else v end); end if;
  update px_mod_cfg set xp_mul = m, xp_until = case when m > 1 and h > 0 then now() + make_interval(secs => h * 3600) end where id = 1;
  insert into px_mod_log (act, note) values ('xp event', case when m > 1 and h > 0 then m || 'x XP for ' || h || 'h' else 'stopped' end);
  return jsonb_build_object('ok', true, 'xpx', px_xp_pub());
end $$;
grant execute on function public.px_mod_xp(text, real, real) to anon, authenticated;

-- gift codes: the creator makes a code (levels and/or cash, how many people can use it, until when); players type it in Settings
create table if not exists public.px_codes (code text primary key, lv int not null default 0, cash int not null default 0, max_uses int not null default 100, uses int not null default 0,
  until timestamptz, on_ boolean not null default true, note text, at timestamptz not null default now());
create table if not exists public.px_code_use (code text not null, uid text not null, dev text, at timestamptz not null default now(), primary key (code, uid));
create table if not exists public.px_code_fail (uid text not null, at timestamptz not null default now());
create index if not exists px_code_fail_uid on public.px_code_fail (uid, at);
alter table public.px_codes enable row level security; alter table public.px_code_use enable row level security; alter table public.px_code_fail enable row level security;
revoke all on public.px_codes, public.px_code_use, public.px_code_fail from anon, authenticated;
alter table public.px_code_use add column if not exists fid text;
create index if not exists px_code_use_fid on public.px_code_use (code, fid);
drop function if exists public.px_code_redeem(text, text, text);
create or replace function public.px_code_redeem(p_uid text, p_key text, p_code text, p_fid text default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl px_players; k px_codes; cd text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); dv text;
begin
  pl := px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  if (select count(*) from px_code_fail where uid = p_uid and at > now() - interval '1 hour') >= 10 then return jsonb_build_object('err', 'slow'); end if;   -- (no guessing codes)
  select * into k from px_codes where code = cd for update;
  if k.code is null or not k.on_ or (k.until is not null and k.until < now()) then
    insert into px_code_fail (uid) values (p_uid); if random() < 0.05 then delete from px_code_fail where at < now() - interval '1 day'; end if;
    return jsonb_build_object('err', case when k.code is not null then 'expired' else 'bad' end);
  end if;
  if k.uses >= k.max_uses then return jsonb_build_object('err', 'used up'); end if;
  dv := nullif(left(coalesce(pl.info -> 'dev' ->> 'id', ''), 20), '');
  if exists (select 1 from px_code_use u where u.code = cd and (u.uid = p_uid or (dv is not null and u.dev = dv) or (coalesce(p_fid, '') <> '' and u.fid = left(p_fid, 20)))) then return jsonb_build_object('err', 'already'); end if;
  insert into px_code_use (code, uid, dev, fid) values (cd, p_uid, dv, nullif(left(coalesce(p_fid, ''), 20), ''));
  update px_codes set uses = uses + 1 where code = cd;
  if k.lv > 0 then update px_players set lv_grant = least(100000, lv_grant + k.lv) where uid = p_uid; end if;
  return jsonb_build_object('ok', true, 'lv', k.lv, 'cash', k.cash, 'code', cd);
end $$;
grant execute on function public.px_code_redeem(text, text, text, text) to anon, authenticated;
create or replace function public.px_mod_codes(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'lv', lv, 'cash', cash, 'max', max_uses, 'uses', uses, 'until', px_ms(until), 'on', on_, 'note', note, 'at', px_ms(at)) order by at desc) from px_codes), '[]'::jsonb));
end $$;
create or replace function public.px_mod_code_save(p_pw text, p_code text, p_lv int, p_cash int, p_max int, p_days real, p_on boolean, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); cd text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can make gift codes.' else v end); end if;
  if length(cd) < 4 or length(cd) > 20 then return jsonb_build_object('err', 'A code is 4 to 20 letters and numbers.'); end if;
  if coalesce(p_lv, 0) <= 0 and coalesce(p_cash, 0) <= 0 then return jsonb_build_object('err', 'Give it some levels or cash.'); end if;
  insert into px_codes (code, lv, cash, max_uses, until, on_, note) values (cd, least(greatest(coalesce(p_lv, 0), 0), 50), least(greatest(coalesce(p_cash, 0), 0), 100000),
    least(greatest(coalesce(p_max, 100), 1), 100000), case when coalesce(p_days, 0) > 0 then now() + make_interval(secs => least(p_days, 365) * 86400) end, coalesce(p_on, true), left(nullif(btrim(coalesce(p_note, '')), ''), 80))
  on conflict (code) do update set lv = excluded.lv, cash = excluded.cash, max_uses = excluded.max_uses, until = excluded.until, on_ = excluded.on_, note = excluded.note;
  insert into px_mod_log (act, target, note) values ('gift code', cd, '+' || least(greatest(coalesce(p_lv, 0), 0), 50) || ' lv, $' || least(greatest(coalesce(p_cash, 0), 0), 100000) || ', ' || coalesce(p_max, 100) || ' uses');
  return jsonb_build_object('ok', true, 'code', cd);
end $$;
create or replace function public.px_mod_code_set(p_pw text, p_code text, p_on boolean, p_delete boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if coalesce(p_delete, false) then delete from px_code_use where code = p_code; delete from px_codes where code = p_code; else update px_codes set on_ = coalesce(p_on, on_) where code = p_code; end if;
  insert into px_mod_log (act, target, note) values ('gift code', p_code, case when p_delete then 'deleted' when p_on then 'on' else 'off' end);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_codes(text), public.px_mod_code_save(text, text, int, int, int, real, boolean, text), public.px_mod_code_set(text, text, boolean, boolean) to anon, authenticated;

-- (the public settings every game gets on each check-in: fundraiser, coin and XP event included; this copy replaces the ones above)
create or replace function public.px_pub_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('reqg', coalesce((select req_game from px_mod_cfg where id = 1), false), 'upd', coalesce((select upd_until > now() from px_mod_cfg where id = 1), false), 'dm', coalesce((select dm_mode from px_mod_cfg where id = 1), 'all'), 'minv', (select nullif(min_ver, 0) from px_mod_cfg where id = 1), 'by', (select byline from px_mod_cfg where id = 1), 'fb', coalesce((select football_public from px_mod_cfg where id = 1), false), 'fund', px_fund_pub(), 'coin', px_coin_pub(), 'xpx', px_xp_pub()) || coalesce((select jsonb_build_object('off', online_off, 'offmsg', online_msg, 'chatoff', chat_off, 'slow', chat_slow) from px_mod_cfg where id = 1), '{}'::jsonb) $$;
-- how many players the anti-cheat has flagged (the badge on the panel's Players tab)
create or replace function public.px_mod_flagged_n(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('n', (select count(*) from px_players where cheat is not null and seen > now() - interval '30 days'));
end $$;
grant execute on function public.px_mod_flagged_n(text) to anon, authenticated;

-- ===== v27: the fundraiser's donors =====
-- The creator writes down who gave what; players see the top donors on the Fundraiser screen. Adding a donor can also
-- add their gift to the total (and taking one off can take it back off).
create table if not exists public.px_fund_donors (id bigserial primary key, name text not null, amount numeric not null default 0, note text, at timestamptz not null default now());
alter table public.px_fund_donors enable row level security; revoke all on public.px_fund_donors from anon, authenticated;
create or replace function public.px_fund_top() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_agg(jsonb_build_object('n', name, 'a', amount) order by amount desc, at) from (select min(name) name, sum(amount) amount, min(at) at from px_fund_donors group by lower(btrim(name)) order by sum(amount) desc, min(at) limit 10) q), '[]'::jsonb) $$;
create or replace function public.px_fund_pub() returns jsonb language sql stable security definer set search_path = public as $$
  select case when fund_title is null and fund_goal = 0 then null else jsonb_build_object('on', fund_on, 't', fund_title, 'n', fund_note, 'g', fund_goal, 'r', fund_raised, 'at', px_ms(fund_at),
    'top', px_fund_top(), 'dn', (select count(distinct lower(btrim(name))) from px_fund_donors)) end
  from px_mod_cfg where id = 1 $$;
create or replace function public.px_mod_fund_donor(p_pw text, p_name text, p_amount numeric, p_note text, p_add boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); nm text := left(btrim(coalesce(p_name, '')), 40); a numeric := round(least(greatest(coalesce(p_amount, 0), 0), 1000000), 2);
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can change the fundraiser.' else v end); end if;
  if length(nm) < 1 then return jsonb_build_object('err', 'Write who gave it (or "Anonymous").'); end if;
  if a <= 0 then return jsonb_build_object('err', 'How much did they give?'); end if;
  insert into px_fund_donors (name, amount, note) values (nm, a, left(nullif(btrim(coalesce(p_note, '')), ''), 80));
  if coalesce(p_add, true) then update px_mod_cfg set fund_raised = least(10000000, fund_raised + a), fund_at = now() where id = 1; end if;
  insert into px_mod_log (act, target, note) values ('fund donor', nm, '$' || a || case when coalesce(p_add, true) then ' (added to the total)' else '' end);
  return jsonb_build_object('ok', true, 'fund', px_fund_pub());
end $$;
create or replace function public.px_mod_fund_donor_del(p_pw text, p_id bigint, p_sub boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); d px_fund_donors;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  delete from px_fund_donors where id = p_id returning * into d; if d.id is null then return jsonb_build_object('err', 'nobody'); end if;
  if coalesce(p_sub, false) then update px_mod_cfg set fund_raised = greatest(0, fund_raised - d.amount), fund_at = now() where id = 1; end if;
  insert into px_mod_log (act, target, note) values ('fund donor removed', d.name, '$' || d.amount);
  return jsonb_build_object('ok', true, 'fund', px_fund_pub());
end $$;
create or replace function public.px_mod_fund_donors(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'n', name, 'a', amount, 'note', note, 'at', px_ms(at)) order by at desc) from (select * from px_fund_donors order by at desc limit 100) q), '[]'::jsonb));
end $$;
revoke all on function public.px_fund_top() from public, anon, authenticated;
grant execute on function public.px_mod_fund_donor(text, text, numeric, text, boolean), public.px_mod_fund_donor_del(text, bigint, boolean), public.px_mod_fund_donors(text) to anon, authenticated;

-- ===== v27: backups are never lost =====
-- Every time a backup is replaced, the old one is kept (the last 10 for each account), so a save that got reset or
-- overwritten can be brought back from Settings > Earlier saves. The creator can look up anyone's backups by email.
create table if not exists public.px_cloud_hist (id bigserial primary key, sub text not null, at timestamptz not null, uid text, data jsonb not null, bytes int, saved timestamptz not null default now());
create index if not exists px_cloud_hist_sub on public.px_cloud_hist (sub, id desc);
alter table public.px_cloud_hist enable row level security; revoke all on public.px_cloud_hist from anon, authenticated;
create or replace function public.px_cloud_keep() returns trigger language plpgsql set search_path = public as $$
begin
  if old.data is distinct from new.data then
    insert into px_cloud_hist (sub, at, uid, data, bytes) values (old.sub, old.at, old.uid, old.data, old.bytes);
    delete from px_cloud_hist where sub = old.sub and id not in (select id from px_cloud_hist where sub = old.sub order by id desc limit 10);
  end if;
  return new;
end $$;
drop trigger if exists px_cloud_keep on public.px_cloud;
create trigger px_cloud_keep before update on public.px_cloud for each row execute function public.px_cloud_keep();
create or replace function public.px_cloud_fsum(d jsonb) returns jsonb language sql immutable as $$
  select coalesce((select jsonb_agg(jsonb_build_object('n', x ->> 'name', 'lv', x -> 'level', 'rb', x -> 'rebirths', 'xp', x -> 'xp')) from jsonb_array_elements(coalesce(d -> 'save' -> 'fighters', '[]'::jsonb)) x), '[]'::jsonb) $$;
create or replace function public.px_cloud_hist_list() returns jsonb language plpgsql security definer set search_path = public as $$
declare sb text := px_jwt() ->> 'sub';
begin
  if sb is null or px_google_email() is null then return jsonb_build_object('err', 'signin'); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', px_ms(at), 'f', px_cloud_fsum(data)) order by id desc) from px_cloud_hist where sub = sb), '[]'::jsonb));
end $$;
create or replace function public.px_cloud_hist_get(p_id bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare sb text := px_jwt() ->> 'sub'; h px_cloud_hist;
begin
  if sb is null or px_google_email() is null then return jsonb_build_object('err', 'signin'); end if;
  select * into h from px_cloud_hist where id = p_id and sub = sb; if not found then return jsonb_build_object('has', false); end if;
  return jsonb_build_object('has', true, 'at', px_ms(h.at), 'data', h.data);
end $$;
create or replace function public.px_mod_cloud(p_pw text, p_email text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); em text := lower(btrim(coalesce(p_email, ''))); c px_cloud;
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can look at backups.' else v end); end if;
  select * into c from px_cloud where lower(email) = em order by at desc limit 1;
  if not found then return jsonb_build_object('has', false); end if;
  return jsonb_build_object('has', true, 'email', c.email, 'uid', c.uid, 'now', jsonb_build_object('at', px_ms(c.at), 'f', px_cloud_fsum(c.data)),
    'hist', coalesce((select jsonb_agg(jsonb_build_object('at', px_ms(at), 'f', px_cloud_fsum(data)) order by id desc) from px_cloud_hist where sub = c.sub), '[]'::jsonb));
end $$;
revoke all on function public.px_cloud_keep(), public.px_cloud_fsum(jsonb) from public, anon, authenticated;
grant execute on function public.px_cloud_hist_list(), public.px_cloud_hist_get(bigint), public.px_mod_cloud(text, text) to anon, authenticated;

-- ===== v27: Online Shop purchases need the player's secret key =====
-- Before, knowing a player's id (it shows on the leaderboard) was enough to list and take their paid purchases.
-- Now both calls check the id AND its secret key, like every other player call.
drop function if exists public.px_shop_claims(text);
drop function if exists public.px_shop_claim(text, bigint[]);
create or replace function public.px_shop_claims(p_uid text, p_key text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  return jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'name', name, 'kind', kind, 'amount', amount, 'ref', ref) order by id)
    from px_purchases where uid = p_uid and status = 'paid'), '[]'::jsonb));
end $$;
create or replace function public.px_shop_claim(p_uid text, p_key text, p_ids bigint[]) returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  perform px_auth(p_uid, p_key);
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 50 then return jsonb_build_object('items', '[]'::jsonb); end if;
  with c as (update px_purchases set status = 'claimed', claimed_at = now() where uid = p_uid and status = 'paid' and id = any (p_ids)
    returning id, item_id, name, kind, amount, ref)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'item', item_id, 'name', name, 'kind', kind, 'amount', amount, 'ref', ref) order by id), '[]'::jsonb) into res from c;
  return jsonb_build_object('items', res);
end $$;
grant execute on function public.px_shop_claims(text, text), public.px_shop_claim(text, text, bigint[]) to anon, authenticated;

-- ======================================================================================================================
-- v28 · fair play online: leaving an online match, or doing nothing for 10 seconds while it's on, is an offense.
-- 3 offenses (since the last one of these bans) = banned from online play (not the whole game) for 1 day; each ban after
-- that is longer: 2 days, 4, a week, 2 weeks, then a month. A ranked one also costs 15 Elo on top of the loss.
-- The game reports its own offenses (as they happen, or the next time it opens if the tab was closed). For ranked
-- matches the server also catches it by itself: the other side reported the end, this side never did and went offline.
alter table public.px_players add column if not exists quits int not null default 0;    -- offenses since the last quit ban
alter table public.px_players add column if not exists qbans int not null default 0;    -- quit bans so far
create table if not exists public.px_quits (
  uid text not null, match text not null, game text not null, why text not null, at timestamptz not null default now(),
  primary key (uid, match)
);
create index if not exists px_quits_at on public.px_quits (uid, at desc);
alter table public.px_quits enable row level security;
revoke all on public.px_quits from anon, authenticated;
create or replace function public.px_quit_add(p_uid text, p_match text, p_game text, p_why text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl px_players; hrs int; till timestamptz;
begin
  insert into px_quits (uid, match, game, why) values (p_uid, left(p_match, 48), p_game, p_why) on conflict do nothing;
  if not found then   -- (already counted: the page-close report and the next-start report are the same offense)
    select * into pl from px_players where uid = p_uid;
    return jsonb_build_object('ok', true, 'dup', true, 'n', coalesce(pl.quits, 0), 'bans', coalesce(pl.qbans, 0),
      'ban', (select px_ms(until) from px_bans where uid = p_uid and kind = 'ban' and not "full" and "by" = 'auto' and until > now()));
  end if;
  update px_players set quits = quits + 1,
    elo_f = case when p_game = 'f' then greatest(100, elo_f - 15) else elo_f end,
    elo_h = case when p_game = 'h' then greatest(100, elo_h - 15) else elo_h end
    where uid = p_uid returning * into pl;
  if not found then return jsonb_build_object('err', 'nobody'); end if;
  if pl.quits >= 3 then
    hrs := (array[24, 48, 96, 168, 336, 720])[least(pl.qbans + 1, 6)]; till := now() + make_interval(hours => hrs);
    -- (an online ban never shortens a ban a mod already gave, and never touches a whole-game ban)
    insert into px_bans (uid, kind, name, reason, at, until, "full", "by", by_name) values (p_uid, 'ban', pl.name, 'Left or went AFK in 3 online matches', now(), till, false, 'auto', 'Fair play')
      on conflict (uid, kind) do update set reason = excluded.reason, at = excluded.at, until = excluded.until, "by" = 'auto', by_name = 'Fair play'
      where not px_bans."full" and px_bans.until is not null and px_bans.until < excluded.until;
    update px_players set quits = 0, qbans = qbans + 1 where uid = p_uid;
    insert into px_mod_log (act, note) values ('online ban (fair play)', coalesce(pl.name, p_uid) || ' · left or went AFK 3 times · ' || hrs || ' h');
    return jsonb_build_object('ok', true, 'n', 3, 'bans', pl.qbans + 1, 'ban', px_ms((select until from px_bans where uid = p_uid and kind = 'ban')), 'hrs', hrs);
  end if;
  return jsonb_build_object('ok', true, 'n', pl.quits, 'bans', pl.qbans);
end $$;
revoke all on function public.px_quit_add(text, text, text, text) from public, anon, authenticated;
-- the game telling on itself (it can only ever add an offense to its own player)
create or replace function public.px_quit(p_uid text, p_key text, p_game text, p_match text, p_why text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  if p_game not in ('f', 'h', 't', 'b', 'r') or p_why not in ('left', 'afk') or coalesce(p_match, '') = '' or length(p_match) > 48 then return jsonb_build_object('err', 'bad'); end if;
  if (select count(*) from px_quits where uid = p_uid and at > now() - interval '1 minute') >= 5 then return jsonb_build_object('err', 'slow'); end if;
  return px_quit_add(p_uid, p_match, p_game, p_why);
end $$;
grant execute on function public.px_quit(text, text, text, text, text) to anon, authenticated;
-- the sweep from before, plus: a ranked match where the other side reported the end and this side never did and is
-- offline (closed the game mid-match) is an offense too. Someone still online is never blamed this way, so a player
-- can't get someone else in trouble by reporting a fake early end.
create or replace function public.px_sweep(p_uid text)
returns void language plpgsql security definer set search_path = public as $$
declare m px_matches; gone text;
begin
  for m in select * from px_matches where done = false and (a = p_uid or b = p_uid) and (ea or eb) and not (ea and eb) and ended_at < now() - interval '45 seconds' for update skip locked loop
    gone := case when m.ea then m.b else m.a end;
    if exists (select 1 from px_players where uid = gone and seen < now() - interval '30 seconds') then perform px_quit_add(gone, m.id, m.game, 'left'); end if;
    perform px_settle(m);
  end loop;
  update px_matches set done = true where done = false and not ea and not eb and at < now() - interval '1 hour' and (a = p_uid or b = p_uid);
end $$;
revoke all on function public.px_sweep(text) from public, anon, authenticated;
-- staff: a player's offenses, and clearing them (moderators and the creator; it also lifts a fair-play ban)
create or replace function public.px_mod_quits(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); pl px_players;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  select * into pl from px_players where uid = p_uid; if not found then return jsonb_build_object('err', 'nobody'); end if;
  return jsonb_build_object('n', pl.quits, 'bans', pl.qbans, 'total', (select count(*) from px_quits where uid = p_uid),
    'ban', (select px_ms(until) from px_bans where uid = p_uid and kind = 'ban' and "by" = 'auto' and until > now()),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('g', game, 'why', why, 'at', px_ms(at)) order by at desc) from (select * from px_quits where uid = p_uid order by at desc limit 8) q), '[]'::jsonb));
end $$;
create or replace function public.px_mod_quits_clear(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); nm text;
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only moderators and the creator can clear these.' else v end); end if;
  update px_players set quits = 0, qbans = 0 where uid = p_uid returning name into nm;
  if not found then return jsonb_build_object('err', 'nobody'); end if;
  delete from px_bans where uid = p_uid and kind = 'ban' and "by" = 'auto';
  insert into px_mod_log (act, note) values ('cleared fair-play offenses', coalesce(nm, p_uid));
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_quits(text, text), public.px_mod_quits_clear(text, text) to anon, authenticated;

-- ======================================================================================================================
-- v29 · the log names the real person behind every action
-- Every staff action now records the player name and id of whoever did it (the creator too). Things the game does by itself
-- (fair-play bans and so on) say "Automatic". Anything done with the old creator password says so in red, with a network tag.
alter table public.px_mod_log add column if not exists by_uid text;
alter table public.px_mod_log add column if not exists by_net text;
create or replace function public.px_mod_log_who() returns trigger language plpgsql as $$
declare w text := coalesce(current_setting('px.who', true), ''); r text := coalesce(current_setting('px.rank', true), '');
  su text := nullif(current_setting('px.suid', true), ''); hn text := nullif(current_setting('px.hname', true), '');
begin
  new.by_uid := su;
  new.who := case when w = 'helper' then (case when r = 'moderator' then 'moderator' else 'helper' end)
                  when w = 'owner' and su is not null then 'owner'
                  when w = 'owner' then 'password'      -- (no player behind it: the old creator password was used)
                  else 'system' end;
  new.by_name := case when new.who = 'system' then 'Automatic' when new.who = 'password' then 'old creator password' else coalesce(hn, 'Staff') end;
  new.by_email := px_google_email();
  if new.who = 'password' then new.by_net := px_net_tag(); end if;
  return new;
end $$;
drop trigger if exists px_mod_log_who on public.px_mod_log;
create trigger px_mod_log_who before insert on public.px_mod_log for each row execute function public.px_mod_log_who();
create or replace function public.px_mod_log(p_pw text, p_limit int) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check_h(p_pw); rows jsonb;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if px_is_helper() and px_rank() <> 'moderator' then return jsonb_build_object('err', 'owner only'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('at', px_ms(at), 'act', act, 'target', target, 'note', note, 'who', who, 'by', by_name, 'em', by_email, 'bu', by_uid, 'net', by_net) order by id desc), '[]') into rows
    from (select * from px_mod_log order by id desc limit least(greatest(coalesce(p_limit, 60), 1), 200)) q;
  return jsonb_build_object('rows', rows);
end $$;
-- the old creator password is switched off for good: it gets a random value nobody knows. Staff (the creator included) open
-- the panel by who they are, so nothing they do needs it. (Run this file again any time: it stays off.)
update public.px_mod_cfg set salt = md5(gen_random_uuid()::text), pwhash = encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'utf8')), 'hex'), fails = 0, strikes = 0, locked_until = null where id = 1;

-- v29 · the anti-cheat only FLAGS now. A flagged account still plays ranked, shows on the leaderboard and fights for turf;
-- the flag just puts it on the Flagged list (and the 'edited fighter?' line in the log) so the creator can look and decide.
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


-- ======================================================================================================================
-- v29 · paying with Cash App or Venmo, and the $5 Custom Move
-- The creator types their Cash App and Venmo usernames into the panel (Money tab). A player picks an item, picks Cash App
-- or Venmo, and gets a short code (like PX7K2Q) to put in the payment note. The creator sees the request with its code,
-- checks the money came in, and presses "They paid: give it" — the same button as Pay at school, so the item arrives the
-- same way. The Custom Move ($5) asks the player to describe the move; the creator sees what they wrote.
alter table public.px_mod_cfg add column if not exists pay_cash text;
alter table public.px_mod_cfg add column if not exists pay_venmo text;
alter table public.px_meets add column if not exists method text not null default 'school';
alter table public.px_meets add column if not exists code text;
create or replace function public.px_pay_pub() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('c', pay_cash, 'v', pay_venmo)) from px_mod_cfg where id = 1 $$;
revoke all on function public.px_pay_pub() from public, anon, authenticated;
create or replace function public.px_mod_pay_set(p_pw text, p_cash text, p_venmo text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); c text := nullif(btrim(coalesce(p_cash, '')), ''); w text := nullif(btrim(coalesce(p_venmo, '')), '');
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can change where money goes.' else v end); end if;
  if c is not null then c := '$' || ltrim(c, '$'); if c !~ '^\$[A-Za-z][A-Za-z0-9_-]{0,19}$' then return jsonb_build_object('err', 'That doesn''t look like a Cash App $cashtag.'); end if; end if;
  if w is not null then w := '@' || ltrim(w, '@'); if w !~ '^@[A-Za-z0-9_-]{2,30}$' then return jsonb_build_object('err', 'That doesn''t look like a Venmo @username.'); end if; end if;
  update px_mod_cfg set pay_cash = c, pay_venmo = w where id = 1;
  insert into px_mod_log (act, note) values ('payment usernames', coalesce(c, 'no Cash App') || ' · ' || coalesce(w, 'no Venmo'));
  return jsonb_build_object('ok', true, 'pay', px_pay_pub());
end $$;
create or replace function public.px_pay_request(p_uid text, p_key text, p_item text, p_name text, p_kind text, p_amount int, p_ref text, p_price numeric, p_method text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; nm text; c px_mod_cfg; code text; cm boolean := (p_item = 'custom_move'); nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  select * into c from px_mod_cfg where id = 1;
  if p_method not in ('cashapp', 'venmo', 'school') then return jsonb_build_object('err', 'Pick how you''ll pay.'); end if;
  if p_method = 'cashapp' and c.pay_cash is null or p_method = 'venmo' and c.pay_venmo is null then return jsonb_build_object('err', 'That way of paying isn''t set up yet.'); end if;
  if cm and (nt is null or length(nt) < 15) then return jsonb_build_object('err', 'Describe your move in a bit more detail first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and status in ('new', 'ok')) >= 3 then return jsonb_build_object('err', 'You already have 3 orders waiting. Cancel one first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and at > now() - interval '10 minutes') >= 5 then return jsonb_build_object('err', 'Slow down a little.'); end if;
  select x into it from jsonb_array_elements(coalesce(c.shop, '[]'::jsonb)) x where x ->> 'id' = p_item limit 1;
  select name into nm from px_players where uid = p_uid;
  code := 'PX' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
  insert into px_meets (uid, name, item_id, item_name, kind, amount, ref, price, day, slot, place, note, method, code)
  values (p_uid, nm, left(p_item, 40),
    case when cm then 'Custom Move' else left(coalesce(it ->> 'name', p_name, p_item), 60) end,
    case when cm then 'custom' else left(coalesce(it ->> 'kind', p_kind, 'other'), 12) end,
    case when cm then 0 else least(coalesce((it ->> 'amount')::int, p_amount, 0), 100000) end,
    case when cm then '' else left(coalesce(it ->> 'ref', p_ref, ''), 40) end,
    case when cm then 5 else coalesce((it ->> 'price')::numeric, p_price, 0) end,
    current_date, case p_method when 'cashapp' then 'Cash App' when 'venmo' then 'Venmo' else 'At school' end,
    case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo else 'ask Nathan' end,
    left(nt, case when cm then 600 else 140 end), p_method, code);
  return jsonb_build_object('ok', true, 'code', code, 'to', case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo end);
end $$;
grant execute on function public.px_pay_request(text, text, text, text, text, int, text, numeric, text, text), public.px_mod_pay_set(text, text, text) to anon, authenticated;
create or replace function public.px_meet_mine(p_uid text, p_key text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform px_auth(p_uid, p_key);
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item', item_name, 'price', price, 'day', day, 'slot', slot, 'place', place, 'st', status, 'm', method, 'code', code) order by at desc)
    from (select * from px_meets where uid = p_uid order by at desc limit 10) q), '[]'::jsonb));
end $$;
create or replace function public.px_mod_meets(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', coalesce((select name from px_players p where p.uid = m.uid), m.name, '?'), 'item', item_name, 'price', price, 'kind', kind, 'amount', amount,
      'day', day, 'slot', slot, 'place', place, 'note', note, 'st', status, 'at', px_ms(at), 'm', method, 'code', code) order by (case status when 'new' then 0 when 'ok' then 1 else 2 end), day, at)
    from (select * from px_meets where status in ('new', 'ok') or at > now() - interval '30 days' order by at desc limit 120) m), '[]'::jsonb),
    'open', (select count(*) from px_meets where status = 'new'), 'pay', px_pay_pub());
end $$;
create or replace function public.px_pub_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('reqg', coalesce((select req_game from px_mod_cfg where id = 1), false), 'upd', coalesce((select upd_until > now() from px_mod_cfg where id = 1), false), 'dm', coalesce((select dm_mode from px_mod_cfg where id = 1), 'all'), 'minv', (select nullif(min_ver, 0) from px_mod_cfg where id = 1), 'by', (select byline from px_mod_cfg where id = 1), 'fb', coalesce((select football_public from px_mod_cfg where id = 1), false), 'fund', px_fund_pub(), 'coin', px_coin_pub(), 'xpx', px_xp_pub(), 'pay', px_pay_pub()) || coalesce((select jsonb_build_object('off', online_off, 'offmsg', online_msg, 'chatoff', chat_off, 'slow', chat_slow) from px_mod_cfg where id = 1), '{}'::jsonb) $$;


-- ======================================================================================================================
-- v29b · security round: the server decides what every item is, how much of it you get and what it costs
-- Before this, an order only looked the item up in the creator's own list; with no list saved it believed the price and
-- the amount the player's game sent, so a doctored game could order "5 levels" with 100000 levels for $0.01 and, if the
-- creator pressed "They paid", get them. Now the item comes only from the creator's list or the built-in list below
-- (the same one the game shows), an item that isn't on either is refused, and nothing a game sends about price,
-- amount or name is used. The Custom Move is always $5 and gives no levels or cash.
create or replace function public.px_shop_items() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select shop from px_mod_cfg where id = 1), '[
    {"id":"lv5","kind":"levels","amount":5,"ref":"","price":5,"name":"5 levels"},
    {"id":"lv10","kind":"levels","amount":10,"ref":"","price":10,"name":"10 levels"},
    {"id":"lv15","kind":"levels","amount":15,"ref":"","price":15,"name":"15 levels"},
    {"id":"cl1","kind":"clothes","amount":0,"ref":"set_neon","price":5,"name":"Neon Street Jacket"},
    {"id":"cl2","kind":"clothes","amount":0,"ref":"set_shadow","price":5,"name":"Shadow Ninja Hoodie"},
    {"id":"cl3","kind":"clothes","amount":0,"ref":"set_dragon","price":8,"name":"Dragon Fire Gi"},
    {"id":"cl4","kind":"clothes","amount":0,"ref":"set_gold","price":10,"name":"Champion''s Gold Robe"}
  ]'::jsonb) $$;
revoke all on function public.px_shop_items() from public, anon, authenticated;
create or replace function public.px_pay_request(p_uid text, p_key text, p_item text, p_name text, p_kind text, p_amount int, p_ref text, p_price numeric, p_method text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; nm text; c px_mod_cfg; code text; cm boolean := (p_item = 'custom_move'); nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  select * into c from px_mod_cfg where id = 1;
  if p_method not in ('cashapp', 'venmo', 'school') then return jsonb_build_object('err', 'Pick how you''ll pay.'); end if;
  if p_method = 'cashapp' and c.pay_cash is null or p_method = 'venmo' and c.pay_venmo is null then return jsonb_build_object('err', 'That way of paying isn''t set up yet.'); end if;
  if cm and (nt is null or length(nt) < 15) then return jsonb_build_object('err', 'Describe your move in a bit more detail first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and status in ('new', 'ok')) >= 3 then return jsonb_build_object('err', 'You already have 3 orders waiting. Cancel one first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and at > now() - interval '10 minutes') >= 5 then return jsonb_build_object('err', 'Slow down a little.'); end if;
  if not cm then
    select x into it from jsonb_array_elements(px_shop_items()) x where x ->> 'id' = p_item limit 1;
    if it is null then return jsonb_build_object('err', 'That isn''t for sale.'); end if;
  end if;
  select name into nm from px_players where uid = p_uid;
  code := 'PX' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
  insert into px_meets (uid, name, item_id, item_name, kind, amount, ref, price, day, slot, place, note, method, code)
  values (p_uid, nm, left(p_item, 40),
    case when cm then 'Custom Move' else left(coalesce(it ->> 'name', p_item), 60) end,
    case when cm then 'custom' else left(coalesce(it ->> 'kind', 'other'), 12) end,
    case when cm then 0 else greatest(0, least(coalesce((it ->> 'amount')::int, 0), 100000)) end,
    case when cm then '' else left(coalesce(it ->> 'ref', ''), 40) end,
    case when cm then 5 else greatest(0, coalesce((it ->> 'price')::numeric, 0)) end,
    current_date, case p_method when 'cashapp' then 'Cash App' when 'venmo' then 'Venmo' else 'At school' end,
    case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo else 'ask Nathan' end,
    left(nt, case when cm then 600 else 140 end), p_method, code);
  return jsonb_build_object('ok', true, 'code', code, 'to', case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo end);
end $$;
-- the same for "Pay Nathan at school" (it had the same gap)
create or replace function public.px_meet_request(p_uid text, p_key text, p_item text, p_name text, p_kind text, p_amount int, p_ref text, p_price numeric, p_day date, p_slot text, p_place text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; nm text; open_n int;
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  if p_day is null or p_day < current_date or p_day > current_date + 14 or extract(isodow from p_day) > 5 then return jsonb_build_object('err', 'Pick a school day in the next two weeks.'); end if;
  if p_slot is null or p_slot not in ('Before school', 'Lunch', 'Right after school', '15 min after school', '30 min after school') then return jsonb_build_object('err', 'Pick a time.'); end if;
  if p_place is null or length(btrim(p_place)) < 2 then return jsonb_build_object('err', 'Say where to meet.'); end if;
  select count(*) into open_n from px_meets where uid = p_uid and status in ('new', 'ok');
  if open_n >= 3 then return jsonb_build_object('err', 'You already have 3 meetings booked. Cancel one first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and at > now() - interval '10 minutes') >= 5 then return jsonb_build_object('err', 'Slow down a little.'); end if;
  select x into it from jsonb_array_elements(px_shop_items()) x where x ->> 'id' = p_item limit 1;
  if it is null then return jsonb_build_object('err', 'That isn''t for sale.'); end if;
  select name into nm from px_players where uid = p_uid;
  insert into px_meets (uid, name, item_id, item_name, kind, amount, ref, price, day, slot, place, note)
  values (p_uid, nm, left(p_item, 40), left(coalesce(it ->> 'name', p_item), 60), left(coalesce(it ->> 'kind', 'other'), 12),
    greatest(0, least(coalesce((it ->> 'amount')::int, 0), 100000)), left(coalesce(it ->> 'ref', ''), 40), greatest(0, coalesce((it ->> 'price')::numeric, 0)),
    p_day, p_slot, left(btrim(p_place), 60), nullif(left(btrim(coalesce(p_note, '')), 140), ''));
  return jsonb_build_object('ok', true);
end $$;
-- and "They paid" can never hand out a Custom Move as levels or cash: it has no amount, and a custom order only ever sends a note to the creator
create or replace function public.px_mod_meet_set(p_pw text, p_id bigint, p_status text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); m px_meets;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_status not in ('ok', 'paid', 'no', 'new') then return jsonb_build_object('err', 'bad status'); end if;
  select * into m from px_meets where id = p_id for update; if not found then return jsonb_build_object('err', 'nobody'); end if;
  if m.status = 'paid' then return jsonb_build_object('err', 'Already paid and given.'); end if;
  update px_meets set status = p_status, done_at = case when p_status in ('paid', 'no') then now() else done_at end where id = p_id;
  if p_status = 'paid' and m.kind <> 'custom' then
    insert into px_purchases (uid, item_id, name, kind, amount, ref, price, provider, provider_ref, status)
    values (m.uid, m.item_id, m.item_name, m.kind, m.amount, m.ref, m.price, case when m.method in ('cashapp', 'venmo') then m.method else 'school' end, 'meet-' || m.id, 'paid') on conflict (provider_ref) do nothing;
  end if;
  insert into px_mod_log (act, target, note) values ('pay at school: ' || p_status, m.uid || ' (' || coalesce(m.name, '?') || ')', m.item_name || ' $' || m.price);
  return jsonb_build_object('ok', true);
end $$;

-- v29c · fair ranked results: same-device accounts can't trade wins, and mismatched results leave a line in the log
create or replace function public.px_settle(m public.px_matches)
returns void language plpgsql security definer set search_path = public as $$
declare pa px_players; pb px_players; r_a int; r_b int; ga int; gb int; e_a real; k real; perf real; d int; aw boolean; same int;
begin
  if m.done then return; end if;
  if m.ra is null or m.rb is null then update px_matches set done = true where id = m.id; return; end if;
  if m.ra = m.rb then -- both said they won (or both lost): no rating change, but staff can see it (a few of these is a lost connection, a lot is somebody editing the game)
    insert into px_mod_log (act, target, note) values ('ranked result mismatch', m.a || ' vs ' || m.b, 'both reported ' || m.ra || ' in a ' || (case when m.game = 'f' then 'fight' else 'Hoops game' end));
    update px_matches set done = true, da = 0, db = 0 where id = m.id; return;
  end if;
  if extract(epoch from coalesce(m.ended_at, now()) - m.at) < 20 then update px_matches set done = true, da = 0, db = 0 where id = m.id; return; end if;
  select count(*) into same from px_matches x where x.id <> m.id and x.done and coalesce(x.da, 0) <> 0 and x.at > now() - interval '24 hours' and x.game = m.game
    and ((x.a = m.a and x.b = m.b) or (x.a = m.b and x.b = m.a));
  if same >= 3 then update px_matches set done = true, da = 0, db = 0 where id = m.id; return; end if;
  aw := m.ra = 'W';
  select * into pa from px_players where uid = m.a for update;
  select * into pb from px_players where uid = m.b for update;
  if pa.uid is null or pb.uid is null then update px_matches set done = true where id = m.id; return; end if;
  -- two accounts on the same device (or the same crew of one person) can't trade wins: the match is played but nobody's rating moves
  if nullif(pa.info -> 'dev' ->> 'id', '') is not null and (pa.info -> 'dev' ->> 'id') = (pb.info -> 'dev' ->> 'id') then
    update px_matches set done = true, da = 0, db = 0 where id = m.id; return;
  end if;
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
revoke all on function public.px_settle(public.px_matches) from public, anon, authenticated;


-- ======================================================================================================================
-- v29d · ONLY THE CREATOR GETS INTO THE CREATOR PANEL, and it takes three things at once:
--   1. the creator's own device key (the game sends it),
--   2. the creator's email signed in on that device RIGHT NOW (Supabase's signed login token; the database checks it,
--      the game can't fake it, and only someone who can open the creator's inbox can get one),
--   3. the creator PIN (always needed for the creator, 6 to 8 numbers; 5 wrong tries lock it for an hour).
-- The old ways in are gone: a "creator device" flag no longer counts and the old creator password opens nothing.
-- A creator session lasts 4 hours (staff: 12). Forgot the PIN? In the SQL Editor: select px_creator_pin_reset();
-- then sign in with the email and make a new one.
update public.px_staff set creator_dev = false where creator_dev;
drop function if exists public.px_mod_make_creator(text);
-- who the creator IS: the player id the creator's email was signed in on (for showing the rank and protecting the account)
create or replace function public.px_is_creator(p_uid text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from px_google g, px_creator c where g.uid = p_uid and encode(sha256(convert_to(lower(btrim(g.email)), 'utf8')), 'hex') = c.email_hash) $$;
-- is it the creator asking, right now? (the email in this request's own login token, belonging to this same player id)
create or replace function public.px_creator_live(p_uid text) returns boolean language sql stable security definer set search_path = public as $$
  select px_is_creator(p_uid) and px_google_email() is not null
    and encode(sha256(convert_to(px_google_email(), 'utf8')), 'hex') = (select email_hash from px_creator where id = 1)
    and exists (select 1 from px_google g where g.uid = p_uid and g.sub = px_jwt() ->> 'sub') $$;
-- a rank nobody set is no rank (it used to fall back to 'creator')
create or replace function public.px_rank() returns text language sql stable security definer set search_path = public as $$ select coalesce(nullif(current_setting('px.rank', true), ''), 'none') $$;
create or replace function public.px_mod_check(p_pw text) returns text language plpgsql security definer set search_path = public as $$
declare c px_mod_cfg; su text; sk text; tk text; pl px_players; st px_staff; rl text;
begin
  perform set_config('px.who', '', true); perform set_config('px.hname', '', true); perform set_config('px.rank', '', true); perform set_config('px.suid', '', true); perform set_config('px.tok', '', true);
  -- staff (helper, moderator, admin) are known by who they are, not by a password: "<player id>|<their secret key>" and, once they
  -- have a panel PIN, "|<the session the PIN opened>"
  if p_pw is not null and position('|' in p_pw) > 0 and length(p_pw) <= 200 then
    su := split_part(p_pw, '|', 1); sk := split_part(p_pw, '|', 2); tk := nullif(split_part(p_pw, '|', 3), '');
    select * into pl from px_players where uid = su and keyhash = md5(sk || ':pxk');
    if not found then return 'wrong'; end if;
    rl := px_staff_role(su);
    if rl is null then return 'wrong'; end if;
    insert into px_staff (uid, role, name) values (su, rl, pl.name) on conflict (uid) do nothing;   -- (staff by Google account: this device joins the list)
    select * into st from px_staff where uid = su;
    -- (v29d) THE CREATOR: the creator's email has to be signed in on this device right now, and the creator PIN is always needed
    if px_is_creator(su) then
      if not px_creator_live(su) then
        insert into px_sec_log (act, uid, name, iph) select 'creator panel refused: email not signed in', su, pl.name, px_net_tag()
          where not exists (select 1 from px_sec_log where act = 'creator panel refused: email not signed in' and uid = su and at > now() - interval '2 minutes');
        return 'email';
      end if;
      if st.pin_hash is null then return 'needpin'; end if;
      if tk is null or not exists (select 1 from px_staff_sessions s where s.uid = su and s.token_hash = encode(sha256(convert_to(tk, 'utf8')), 'hex') and s.expires > now()) then return 'pin'; end if;
      perform set_config('px.tok', encode(sha256(convert_to(tk, 'utf8')), 'hex'), true);
      perform set_config('px.hname', coalesce(pl.name, 'Creator'), true); perform set_config('px.suid', su, true);
      perform set_config('px.who', 'owner', true); perform set_config('px.rank', 'creator', true); return 'ok';
    end if;
    -- the panel PIN: needed once a staff member has set one, and by everyone when an admin switched that on
    if st.pin_hash is not null or coalesce((select req_pin from px_mod_cfg where id = 1), false) then
      if st.pin_hash is null then return 'needpin'; end if;
      if tk is null or not exists (select 1 from px_staff_sessions s where s.uid = su and s.token_hash = encode(sha256(convert_to(tk, 'utf8')), 'hex') and s.expires > now()) then return 'pin'; end if;
      perform set_config('px.tok', encode(sha256(convert_to(tk, 'utf8')), 'hex'), true);
    end if;
    perform set_config('px.hname', coalesce(pl.name, 'Staff'), true); perform set_config('px.suid', su, true);
    perform set_config('px.who', 'helper', true); perform set_config('px.rank', case when st.role in ('moderator', 'owner') then 'moderator' else 'helper' end, true);   -- (an old admin who isn't the creator: a moderator)
    return 'helper';
  end if;
  -- (v29d) the old creator password is switched off: it never opens anything any more (tries are still logged, at most once a minute)
  if p_pw is not null then
    insert into px_sec_log (act, iph) select 'creator password tried (it is switched off)', px_net_tag()
      where not exists (select 1 from px_sec_log where act = 'creator password tried (it is switched off)' and at > now() - interval '1 minute');
  end if;
  return 'wrong';
end $$;
create or replace function public.px_staff_set_pin(p_uid text, p_key text, p_old text, p_new text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl px_players; st px_staff; rl text; salt text;
begin
  select * into pl from px_players where uid = p_uid and keyhash = md5(coalesce(p_key, '') || ':pxk');
  if not found then return jsonb_build_object('err', 'wrong'); end if;
  rl := px_staff_role(p_uid); if rl is null then return jsonb_build_object('err', 'wrong'); end if;
  if px_is_creator(p_uid) and not px_creator_live(p_uid) then return jsonb_build_object('err', 'email'); end if;   -- (v29d: the creator's PIN can only be set with the creator's email signed in)
  insert into px_staff (uid, role, name) values (p_uid, rl, pl.name) on conflict (uid) do nothing;
  select * into st from px_staff where uid = p_uid;
  if p_new is null or p_new !~ '^[0-9]{4,8}$' then return jsonb_build_object('err', 'A PIN is 4 to 8 numbers.'); end if;
  if px_is_creator(p_uid) and p_new !~ '^[0-9]{6,8}$' then return jsonb_build_object('err', 'The creator PIN has to be 6 to 8 numbers.'); end if;
  if st.pin_hash is not null then
    if st.pin_locked is not null and st.pin_locked > now() then return jsonb_build_object('err', 'locked'); end if;
    if encode(sha256(convert_to(st.pin_salt || coalesce(p_old, ''), 'utf8')), 'hex') <> st.pin_hash then
      update px_staff set pin_locked = case when pin_fails + 1 >= 5 then now() + interval '15 minutes' end, pin_fails = case when pin_fails + 1 >= 5 then 0 else pin_fails + 1 end where uid = p_uid;
      insert into px_sec_log (act, uid, name, iph) values ('wrong PIN (changing it)', p_uid, pl.name, px_net_tag());
      return jsonb_build_object('err', 'The old PIN is wrong.');
    end if;
  end if;
  salt := md5(gen_random_uuid()::text);
  update px_staff set pin_salt = salt, pin_hash = encode(sha256(convert_to(salt || p_new, 'utf8')), 'hex'), pin_fails = 0, pin_locked = null where uid = p_uid;
  delete from px_staff_sessions where uid = p_uid;   -- (every open panel of this person closes)
  insert into px_sec_log (act, uid, name, iph) values (case when st.pin_hash is null then 'set a panel PIN' else 'changed their panel PIN' end, p_uid, pl.name, px_net_tag());
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.px_staff_unlock(p_uid text, p_key text, p_pin text, p_dev text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl px_players; st px_staff; tok text;
begin
  select * into pl from px_players where uid = p_uid and keyhash = md5(coalesce(p_key, '') || ':pxk');
  if not found or px_staff_role(p_uid) is null then return jsonb_build_object('err', 'wrong'); end if;
  if px_is_creator(p_uid) and not px_creator_live(p_uid) then return jsonb_build_object('err', 'email'); end if;   -- (v29d: no PIN guessing for the creator without the creator's email)
  select * into st from px_staff where uid = p_uid;
  if not found or st.pin_hash is null then return jsonb_build_object('err', 'needpin'); end if;
  if st.pin_locked is not null and st.pin_locked > now() then return jsonb_build_object('err', 'locked', 'until', px_ms(st.pin_locked)); end if;
  if encode(sha256(convert_to(st.pin_salt || coalesce(p_pin, ''), 'utf8')), 'hex') <> st.pin_hash then
    update px_staff set pin_fails = case when pin_fails + 1 >= 5 then 0 else pin_fails + 1 end, pin_locked = case when pin_fails + 1 >= 5 then now() + (case when px_is_creator(p_uid) then interval '1 hour' else interval '15 minutes' end) end where uid = p_uid;
    insert into px_sec_log (act, uid, name, note, iph) values ('wrong panel PIN', p_uid, pl.name, case when st.pin_fails + 1 >= 5 then 'locked for 15 minutes' else (st.pin_fails + 1) || ' in a row' end, px_net_tag());
    return jsonb_build_object('err', case when st.pin_fails + 1 >= 5 then 'locked' else 'wrongpin' end, 'left', greatest(0, 4 - st.pin_fails));
  end if;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  update px_staff set pin_fails = 0, pin_locked = null where uid = p_uid;
  insert into px_staff_sessions (token_hash, uid, expires, dev, iph) values (encode(sha256(convert_to(tok, 'utf8')), 'hex'), p_uid, now() + (case when px_is_creator(p_uid) then interval '4 hours' else interval '12 hours' end), left(coalesce(p_dev, ''), 60), px_net_tag());
  delete from px_staff_sessions where expires < now() - interval '1 day';
  return jsonb_build_object('ok', true, 'token', tok);
end $$;
-- forgot the creator PIN: run this in the SQL Editor, then sign in with the creator email and pick a new one
create or replace function public.px_creator_pin_reset() returns text language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update px_staff set pin_hash = null, pin_salt = null, pin_fails = 0, pin_locked = null where px_is_creator(uid); get diagnostics n = row_count;
  delete from px_staff_sessions where px_is_creator(uid);
  insert into px_sec_log (act, note) values ('creator PIN reset (SQL Editor)', n || ' account(s)');
  return 'Done: sign in with your email in the game and make a new PIN.';
end $$;
revoke all on function public.px_is_creator(text), public.px_creator_live(text), public.px_rank(), public.px_creator_pin_reset() from public, anon, authenticated;
-- every creator session that was opened before this update has to be opened again (with the email and the PIN)
delete from public.px_staff_sessions where public.px_is_creator(uid);


-- ======================================================================================================================
-- v29e · THE INVESTIGATION CREW
-- When a player gets flagged (an edited-looking fighter, results that keep disagreeing, a pile of reports from other players)
-- the crew sweeps everything the database knows about them and writes a report onto their profile in the staff panel.
-- Staff can also send the crew in by hand from the player's page ("Investigate"), and say what looks wrong: the crew
-- reads it, digs deepest where it points, and says what it found for each thing that was asked.
-- The crew only REPORTS. Nothing happens to a player because of a report: a person decides.
--
-- THE CREW AND THEIR INSTRUCTIONS (each one's checklist; a "deep" sweep looks further back and lists the rows it found)
--  1. The Progress Detective: levels, rebirths and stats
--     - how far the fighter is (rebirths x 30 + level) against how long they've actually played; levels given by staff,
--       coins and codes are taken off first
--     - the anti-cheat's flag and why; whether the fighter breaks the rules right now (stats past the cap, more points
--       than the level gives); fighters "levelled up too fast" before
--     - the save history (signed-in players): the biggest jump between two saves, and how fast it came
--     - more knockouts than wins, an old or a downloaded copy of the game, staff edits to the fighter
--  2. The Match Referee: ranked fights and Hoops
--     - record, win rate, games that ended suspiciously fast, results both players claimed
--     - the same opponent over and over (win trading), Elo won from accounts on the same device or network
--     - quitting and going AFK, connection drops during games (a lag switch looks like this)
--  3. The Link Tracker: other accounts
--     - accounts on the same device, on the same network (a school network is shared, so that alone means little),
--       on the same email; any of them banned (ban evasion); old names
--     - the weekly coin or a code taken on several accounts from one device
--  4. The Rewards Auditor: things that give levels, cash or items
--     - code guessing, coins, codes used, purchases and orders (and prank orders), Turf Wars wins that were too fast
--       to be real (with the replays to watch)
--  5. The Conduct Officer: how they treat people
--     - chat and messages: slurs and banned words, spamming, reports from other players, past bans and mutes,
--       staff notes, tries at the staff panel
-- ======================================================================================================================
create table if not exists public.px_investigations (
  id bigserial primary key, at timestamptz not null default now(), uid text not null, name text,
  trig text not null default 'staff', focus text, by_uid text, by_name text,
  score int not null default 0, verdict text not null default 'clean', report jsonb not null,
  status text not null default 'open', outcome text, closed_by text, closed_at timestamptz
);
create index if not exists px_investigations_uid on public.px_investigations (uid, id desc);
create index if not exists px_investigations_open on public.px_investigations (status, id desc);
alter table public.px_investigations enable row level security; revoke all on public.px_investigations from anon, authenticated;

-- which crew members a staff member's words point at (the rest still do a quick sweep)
create or replace function public.px_inv_areas(p_focus text) returns text[] language sql immutable as $$
  select array_remove(array[
    case when f ~ '(level|lvl|xp|rebirth|stat|point|strong|overpower|\yop\y|fast|hack|mod menu|edit|inspect|devtool|console|cheat|engine|exploit|glitch|god)' then 'progress' end,
    case when f ~ '(rank|elo|win|los[es]|match|fight|boost|trad|throw|threw|afk|quit|leav|lag|ping|disconnect|hoop|leaderboard)' then 'matches' end,
    case when f ~ '(\yalts?\y|account|smurf|device|same (person|guy|kid)|evad|evasion|sibling|brother|sister|friend|network|wifi)' then 'links' end,
    case when f ~ '(buy|bought|money|cash|venmo|paid|pay|purchase|order|coin|code|free|turf|block|glory|reward|shop|item)' then 'rewards' end,
    case when f ~ '(chat|swear|curs|slur|bull|spam|name|rude|threat|\ydms?\y|message|harass|toxic|racis|report|panel|staff)' then 'conduct' end
  ], null) from (select lower(coalesce(p_focus, '')) f) q $$;

-- the sweep itself: everything the crew finds about one player, as a report
create or replace function public.px_inv_sweep(p_uid text, p_focus text) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  pl px_players; fo text[] := px_inv_areas(p_focus); deep_all boolean := coalesce(btrim(p_focus), '') = '' or cardinality(px_inv_areas(p_focus)) = 0;
  vdev text; fs jsonb; eff int; given int := 0; play_h numeric; lph numeric; wins int; losses int; kos int; vwhy text; days int;
  areas jsonb := '[]'::jsonb; finds jsonb; facts jsonb; deep boolean; total int := 0; cnt int; cnt2 int; rw record; t text; sev int; worst int := 0; asked jsonb := '[]'::jsonb;
  k text;
begin
  select * into pl from px_players where uid = p_uid; if not found then return null; end if;
  vdev := nullif(pl.info -> 'dev' ->> 'id', ''); fs := pl.info -> 'fs';

  -- ---------------- 1. the Progress Detective ----------------
  deep := deep_all or 'progress' = any (fo); days := case when deep then 365 else 60 end; finds := '[]'; facts := '[]';
  eff := coalesce(px_num(fs ->> 'r'), 0)::int * 30 + coalesce(px_num(fs ->> 'l'), 1)::int - 1;
  given := coalesce((select sum(px_levels.n) from px_levels where uid = p_uid), 0) + coalesce((select sum(lv) from px_coin where uid = p_uid), 0)
         + coalesce((select sum(c.lv) from px_code_use u join px_codes c on c.code = u.code where u.uid = p_uid), 0);
  play_h := round(coalesce(px_num(pl.info ->> 'play'), 0) / 3600.0, 1);
  wins := coalesce(px_num(pl.info ->> 'w'), 0)::int; losses := coalesce(px_num(pl.info ->> 'l'), 0)::int; kos := coalesce(px_num(pl.info ->> 'k'), 0)::int;
  facts := facts || jsonb_build_array(jsonb_build_array('Fighter', coalesce(fs ->> 'n', '?') || ' · rebirth ' || coalesce(fs ->> 'r', '0') || ', level ' || coalesce(fs ->> 'l', '1')),
    jsonb_build_array('Time played', play_h || ' hours'), jsonb_build_array('Levels given (staff, coins, codes)', given),
    jsonb_build_array('Record (all fighters)', wins || ' W, ' || losses || ' L, ' || kos || ' KOs'), jsonb_build_array('Game', 'v' || coalesce(pl.info ->> 'ver', '?') || ' · ' || coalesce(pl.info ->> 'via', '?')),
    jsonb_build_array('Account made', to_char(pl.created, 'Mon DD YYYY')));
  if pl.cheat is not null then finds := finds || jsonb_build_object('s', 2, 't', 'The anti-cheat flagged them: ' || pl.cheat || '.'); end if;
  vwhy := px_cheat_why(pl.info, pl.free_ok);
  if vwhy is not null then finds := finds || jsonb_build_object('s', 3, 't', 'Right now their fighter breaks the rules: ' || vwhy || '. A normal game can''t do that, so the save was edited.'); end if;
  if pl.free_ok then finds := finds || jsonb_build_object('s', 0, 't', 'The creator gave this player "no limits" stats, so stats past the cap are allowed.'); end if;
  if eff - given > 40 and coalesce(px_num(pl.info ->> 'play'), 0) < 900 then
    finds := finds || jsonb_build_object('s', 3, 't', (eff - given) || ' levels of progress with only ' || round(coalesce(px_num(pl.info ->> 'play'), 0) / 60.0) || ' minutes played. That isn''t possible by playing.');
  elsif play_h >= 0.5 then
    lph := round((eff - given) / play_h, 1);
    facts := facts || jsonb_build_array(jsonb_build_array('Levels per hour played', lph));
    if lph > 150 then finds := finds || jsonb_build_object('s', 3, 't', 'They gained ' || lph || ' levels per hour played. Even a very good player gets nowhere near that.');
    elsif lph > 60 then finds := finds || jsonb_build_object('s', 2, 't', lph || ' levels per hour played is very fast. Worth a look at their fights.'); end if;
  end if;
  if kos > wins + 5 then finds := finds || jsonb_build_object('s', 2, 't', 'More knockouts (' || kos || ') than wins (' || wins || '). Every KO is a win, so the numbers were changed.'); end if;
  select count(*) into cnt from px_mod_log where act = 'edited fighter?' and target like p_uid || ' (%' and at > now() - make_interval(days => days);
  if cnt > 1 then finds := finds || jsonb_build_object('s', 2, 't', 'Flagged ' || cnt || ' times for an edited-looking fighter.'); end if;
  if deep then
    for rw in select at, note from px_mod_log where act = 'edited fighter?' and target like p_uid || ' (%' order by id desc limit 8 loop
      facts := facts || jsonb_build_array(jsonb_build_array('Flag ' || to_char(rw.at, 'Mon DD HH24:MI'), rw.note)); end loop;
  end if;
  -- the save history: the biggest jump between two saves in a row
  select max(j), (array_agg(note order by j desc))[1] into cnt, t from (
    select e - lag(e) over (order by at) j, to_char(lag(at) over (order by at), 'Mon DD HH24:MI') || ' → ' || to_char(at, 'Mon DD HH24:MI') || ' (' || round(extract(epoch from at - lag(at) over (order by at)) / 60) || ' min)' note
    from (select h.at, (select max(coalesce(px_num(f ->> 'rebirths'), 0) * 30 + coalesce(px_num(f ->> 'level'), 1)) from jsonb_array_elements(case when jsonb_typeof(h.data -> 'fighters') = 'array' then h.data -> 'fighters' else '[]'::jsonb end) f)::int e
          from px_cloud_hist h where h.uid = p_uid and h.at > now() - make_interval(days => days)) s) q where j is not null;
  if cnt is not null then
    facts := facts || jsonb_build_array(jsonb_build_array('Biggest jump between two saves', cnt || ' levels, ' || t));
    if cnt > 60 then finds := finds || jsonb_build_object('s', 2, 't', 'Their saved game jumped ' || cnt || ' levels between two saves (' || t || ').'); end if;
  end if;
  select count(*) into cnt from px_edits where uid = p_uid; if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Staff edits to the fighter', cnt)); end if;
  if pl.info ->> 'via' = 'file' then finds := finds || jsonb_build_object('s', 1, 't', 'They play a downloaded copy of the game (the file on their computer). That copy is easier to edit, but plenty of honest players use it too.'); end if;
  areas := areas || jsonb_build_object('k', 'progress', 'crew', 'Progress Detective', 'title', 'Levels, rebirths and stats', 'deep', deep, 'finds', finds, 'facts', facts);

  -- ---------------- 2. the Match Referee ----------------
  deep := deep_all or 'matches' = any (fo); days := case when deep then 90 else 30 end; finds := '[]'; facts := '[]';
  select count(*), count(*) filter (where (a = p_uid and ra = 'W') or (b = p_uid and rb = 'W')), count(*) filter (where ended_at is not null and extract(epoch from ended_at - at) < 20),
         count(*) filter (where done and ra is not null and ra = rb)
    into cnt, cnt2, wins, losses from px_matches where (a = p_uid or b = p_uid) and at > now() - make_interval(days => days);
  facts := facts || jsonb_build_array(jsonb_build_array('Ranked games (' || days || ' days)', cnt || ' (' || cnt2 || ' reported as wins)'), jsonb_build_array('Elo', 'fights ' || pl.elo_f || ' (' || pl.gf || ' games), Hoops ' || pl.elo_h || ' (' || pl.gh || ' games)'));
  if wins >= 3 then finds := finds || jsonb_build_object('s', 1, 't', wins || ' ranked games ended in under 20 seconds.'); end if;
  if losses >= 3 then finds := finds || jsonb_build_object('s', 2, 't', 'In ' || losses || ' ranked games both players said they won. One side was lying (or their game was edited).');
  elsif losses > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Games where both claimed the win', losses)); end if;
  if cnt >= 5 then
    select o, c into t, cnt2 from (select case when a = p_uid then b else a end o, count(*) c from px_matches where (a = p_uid or b = p_uid) and at > now() - make_interval(days => days) group by 1 order by 2 desc limit 1) q;
    if cnt2 * 100 / cnt >= 40 then
      finds := finds || jsonb_build_object('s', case when exists (select 1 from px_players o where o.uid = t and ((vdev is not null and o.info -> 'dev' ->> 'id' = vdev) or (o.iph is not null and o.iph = pl.iph))) then 3 else 2 end,
        't', cnt2 || ' of their ' || cnt || ' ranked games were against the same player (' || coalesce((select name from px_players where uid = t), t) || ')' ||
          case when exists (select 1 from px_players o where o.uid = t and vdev is not null and o.info -> 'dev' ->> 'id' = vdev) then ', who plays on the SAME DEVICE. That is win trading with a second account.'
               when exists (select 1 from px_players o where o.uid = t and o.iph is not null and o.iph = pl.iph) then ', on the same network. Could be win trading, or two friends at school.' else '. Could be win trading.' end);
    end if;
  end if;
  select count(*) into cnt from px_matches m join px_players o on o.uid = case when m.a = p_uid then m.b else m.a end
    where (m.a = p_uid or m.b = p_uid) and m.done and coalesce(case when m.a = p_uid then m.da else m.db end, 0) > 0 and vdev is not null and o.info -> 'dev' ->> 'id' = vdev;
  if cnt > 0 then finds := finds || jsonb_build_object('s', 3, 't', 'They won Elo ' || cnt || ' times from an account on their own device.'); end if;
  select count(*), count(*) filter (where why = 'afk') into cnt, cnt2 from px_quits where uid = p_uid and at > now() - make_interval(days => days);
  if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Online games quit or left AFK', cnt || ' (' || cnt2 || ' AFK) · online bans so far: ' || coalesce(pl.qbans, 0))); end if;
  if cnt >= 5 then finds := finds || jsonb_build_object('s', 1, 't', 'Quit or went AFK in ' || cnt || ' online games.'); end if;
  begin
    select count(*), round(avg(rtt)), count(*) filter (where loss >= 20) into cnt, cnt2, wins from px_netlog where uid = p_uid and at > now() - make_interval(days => days);
    if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Connection (' || cnt || ' games)', 'average ping ' || coalesce(cnt2, 0) || ' ms, ' || wins || ' games with big packet loss')); end if;
    if wins >= 5 and wins * 100 / greatest(cnt, 1) >= 40 then finds := finds || jsonb_build_object('s', 1, 't', 'Big packet loss in ' || wins || ' of ' || cnt || ' games. Usually just bad Wi-Fi, but a lag switch looks the same: compare it with their wins.'); end if;
  exception when others then null; end;
  if deep then
    for rw in select m.at, case when m.a = p_uid then m.b else m.a end o, case when m.a = p_uid then m.ra else m.rb end mine, case when m.a = p_uid then m.rb else m.ra end theirs,
               round(extract(epoch from coalesce(m.ended_at, m.at) - m.at)) secs, case when m.a = p_uid then m.da else m.db end d
             from px_matches m where (m.a = p_uid or m.b = p_uid) order by m.at desc limit 10 loop
      facts := facts || jsonb_build_array(jsonb_build_array('Game ' || to_char(rw.at, 'Mon DD HH24:MI'), 'vs ' || coalesce((select name from px_players where uid = rw.o), rw.o) || ': said ' || coalesce(rw.mine, '?') || ', they said ' || coalesce(rw.theirs, '?') || ', ' || rw.secs || 's, Elo ' || coalesce(rw.d, 0)));
    end loop;
  end if;
  areas := areas || jsonb_build_object('k', 'matches', 'crew', 'Match Referee', 'title', 'Ranked games and online play', 'deep', deep, 'finds', finds, 'facts', facts);

  -- ---------------- 3. the Link Tracker ----------------
  deep := deep_all or 'links' = any (fo); finds := '[]'; facts := '[]';
  if vdev is not null then
    select count(*), string_agg(name || case when px_is_banned(uid) then ' (BANNED)' else '' end, ', ') into cnt, t from (select uid, name from px_players where info -> 'dev' ->> 'id' = vdev and uid <> p_uid order by seen desc limit case when deep then 25 else 8 end) q;
    if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Other accounts on the same device', t)); end if;
    if exists (select 1 from px_players where info -> 'dev' ->> 'id' = vdev and uid <> p_uid and px_is_banned(uid)) then
      finds := finds || jsonb_build_object('s', 3, 't', 'Shares a device with a banned account. This is very likely the same person getting round a ban.');
    elsif cnt >= 1 then finds := finds || jsonb_build_object('s', 1, 't', case when cnt = 1 then 'Another account plays on the same device (' || t || ').' else cnt || ' other accounts play on the same device (' || t || ').' end || ' Could be a brother or sister on a family computer, or an alt: check whether they ever play each other.'); end if;
  end if;
  if pl.iph is not null then
    select count(*) into cnt from px_players where iph = pl.iph and uid <> p_uid;
    facts := facts || jsonb_build_array(jsonb_build_array('Accounts on the same network', cnt || ' (a school network is shared by lots of players)'));
    select count(*) into cnt from px_players where iph = pl.iph and uid <> p_uid and px_is_banned(uid);
    if cnt > 0 then finds := finds || jsonb_build_object('s', 1, 't', cnt || ' banned account(s) use the same network. On a school network that''s normal; on a home network it isn''t.'); end if;
  end if;
  select string_agg(distinct g2.uid, ', ') into t from px_google g join px_google g2 on g2.sub = g.sub and g2.uid <> g.uid where g.uid = p_uid;
  if t is not null then facts := facts || jsonb_build_array(jsonb_build_array('Other player ids on the same email', t)); end if;
  if vdev is not null then
    select count(distinct uid) into cnt from px_coin where px_coin.dev = vdev and uid <> p_uid;
    if cnt > 0 then finds := finds || jsonb_build_object('s', 2, 't', 'The weekly coin was taken on ' || cnt || ' other account(s) from this same device.'); end if;
    select count(distinct u2.uid) into cnt from px_code_use u join px_code_use u2 on u2.code = u.code and u2.dev = u.dev and u2.uid <> u.uid where u.uid = p_uid and u.dev is not null;
    if cnt > 0 then finds := finds || jsonb_build_object('s', 2, 't', 'A code they used was also used on ' || cnt || ' other account(s) from the same device.'); end if;
  end if;
  if coalesce(array_to_string(pl.prev, ', '), '') <> '' then facts := facts || jsonb_build_array(jsonb_build_array('Old names', array_to_string(pl.prev, ', '))); end if;
  areas := areas || jsonb_build_object('k', 'links', 'crew', 'Link Tracker', 'title', 'Other accounts and ban evasion', 'deep', deep, 'finds', finds, 'facts', facts);

  -- ---------------- 4. the Rewards Auditor ----------------
  deep := deep_all or 'rewards' = any (fo); days := case when deep then 90 else 30 end; finds := '[]'; facts := '[]';
  select count(*) into cnt from px_code_fail where uid = p_uid and at > now() - interval '7 days';
  if cnt >= 10 then finds := finds || jsonb_build_object('s', 2, 't', 'Typed ' || cnt || ' wrong codes this week. That''s guessing codes.'); elsif cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Wrong codes this week', cnt)); end if;
  select count(*) into cnt from px_coin where uid = p_uid; select count(*) into cnt2 from px_code_use where uid = p_uid;
  facts := facts || jsonb_build_array(jsonb_build_array('Coins / codes used', cnt || ' / ' || cnt2));
  select count(*), coalesce(sum(price), 0) into cnt, cnt2 from px_purchases where uid = p_uid; if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Things bought', cnt || ' ($' || cnt2 || ')')); end if;
  select count(*), count(*) filter (where status in ('no', 'cancelled')) into cnt, cnt2 from px_meets where uid = p_uid and at > now() - make_interval(days => days);
  if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Shop orders', cnt || ' (' || cnt2 || ' cancelled or turned down)')); end if;
  if cnt2 >= 4 then finds := finds || jsonb_build_object('s', 1, 't', cnt2 || ' shop orders cancelled or turned down. Prank orders?'); end if;
  begin
    select count(*), min(secs) into cnt, cnt2 from px_turf_log where uid = p_uid and won and at > now() - make_interval(days => days);
    if cnt > 0 then
      facts := facts || jsonb_build_array(jsonb_build_array('Turf Wars wins', cnt || ' (fastest ' || cnt2 || 's)'));
      select count(*) into cnt from px_turf_log where uid = p_uid and won and at > now() - make_interval(days => days)
        and secs < 0.3 * coalesce((select percentile_cont(0.5) within group (order by secs) from px_turf_log where won and secs > 0), 0);
      if cnt >= 2 then finds := finds || jsonb_build_object('s', 2, 't', cnt || ' Turf Wars wins came in less than a third of the usual time. Watch the replays (Turf tab).'); end if;
      select count(*) into cnt from px_replays where uid = p_uid; if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Turf replays saved', cnt)); end if;
    end if;
  exception when others then null; end;
  areas := areas || jsonb_build_object('k', 'rewards', 'crew', 'Rewards Auditor', 'title', 'Codes, coins, the shop and turf', 'deep', deep, 'finds', finds, 'facts', facts);

  -- ---------------- 5. the Conduct Officer ----------------
  deep := deep_all or 'conduct' = any (fo); days := case when deep then 90 else 30 end; finds := '[]'; facts := '[]';
  select count(*), count(*) filter (where px_slur(x) or px_word_hit(x)) into cnt, cnt2 from px_msgs where uid = p_uid and kind = 'm' and at > now() - make_interval(days => days);
  facts := facts || jsonb_build_array(jsonb_build_array('Chat messages (' || days || ' days)', cnt));
  if cnt2 >= 3 then finds := finds || jsonb_build_object('s', 2, 't', cnt2 || ' chat messages had slurs or banned words.'); elsif cnt2 > 0 then finds := finds || jsonb_build_object('s', 1, 't', cnt2 || ' chat message(s) had a slur or a banned word.'); end if;
  begin
    select count(*) into cnt from px_tmsgs where uid = p_uid and (px_slur(x) or px_word_hit(x)) and at > now() - make_interval(days => days);
    if cnt > 0 then finds := finds || jsonb_build_object('s', 2, 't', cnt || ' private message(s) had slurs or banned words.'); end if;
  exception when others then null; end;
  select max(c) into cnt from (select count(*) c from px_msgs where uid = p_uid and at > now() - make_interval(days => days) group by date_trunc('minute', at)) q;
  if coalesce(cnt, 0) >= 15 then finds := finds || jsonb_build_object('s', 1, 't', 'Sent ' || cnt || ' messages in one minute (spamming).'); end if;
  select count(*), count(distinct reporter) into cnt, cnt2 from px_dm_reports where target = p_uid and at > now() - make_interval(days => days);
  if cnt > 0 then finds := finds || jsonb_build_object('s', case when cnt2 >= 3 then 2 else 1 end, 't', 'Reported ' || cnt || ' time(s) by ' || cnt2 || ' different player(s).'); end if;
  select count(*) into cnt from px_bans where uid = p_uid; if cnt > 0 then facts := facts || jsonb_build_array(jsonb_build_array('Bans and mutes on record', cnt)); end if;
  select count(*) into cnt from px_sec_log where uid = p_uid and act in ('someone who isn''t staff tried the panel', 'creator panel refused: email not signed in', 'wrong panel PIN') and at > now() - make_interval(days => days)
    and not exists (select 1 from px_staff s where s.uid = p_uid);
  if cnt > 0 then finds := finds || jsonb_build_object('s', 3, 't', 'Tried to get into the staff panel ' || cnt || ' time(s) without being staff.'); end if;
  for rw in select at, by_name, x from px_notes where uid = p_uid order by id desc limit case when deep then 10 else 3 end loop
    facts := facts || jsonb_build_array(jsonb_build_array('Staff note ' || to_char(rw.at, 'Mon DD'), coalesce(rw.by_name, 'staff') || ': ' || left(rw.x, 160))); end loop;
  if deep then
    for rw in select at, x from px_msgs where uid = p_uid and kind = 'm' and (px_slur(x) or px_word_hit(x)) order by id desc limit 6 loop
      facts := facts || jsonb_build_array(jsonb_build_array('Message ' || to_char(rw.at, 'Mon DD HH24:MI'), left(rw.x, 140))); end loop;
  end if;
  areas := areas || jsonb_build_object('k', 'conduct', 'crew', 'Conduct Officer', 'title', 'Chat, reports and behaviour', 'deep', deep, 'finds', finds, 'facts', facts);

  -- ---------------- the verdict ----------------
  for rw in select (f.v ->> 's')::int s from jsonb_array_elements(areas) a(v), jsonb_array_elements(a.v -> 'finds') f(v) loop
    total := total + case rw.s when 3 then 5 when 2 then 2 when 1 then 1 else 0 end; worst := greatest(worst, rw.s); end loop;
  -- what was asked: say which crew member took it and what they found
  if not deep_all then
    foreach k in array fo loop
      asked := asked || jsonb_build_object('k', k, 'n', (select jsonb_array_length(a.v -> 'finds') from jsonb_array_elements(areas) a(v) where a.v ->> 'k' = k));
    end loop;
  end if;
  return jsonb_build_object('score', total, 'worst', worst,
    'verdict', case when worst >= 3 and total >= 7 then 'likely' when worst >= 3 or total >= 5 then 'suspicious' when total >= 2 then 'watch' else 'clean' end,
    'ask', nullif(btrim(coalesce(p_focus, '')), ''), 'asked', asked, 'all', deep_all, 'areas', areas, 'name', pl.name, 'seen', px_ms(pl.seen));
end $$;

-- run it and keep the report (the last 20 per player)
create or replace function public.px_inv_run(p_uid text, p_focus text, p_trig text, p_by_uid text, p_by_name text) returns bigint language plpgsql security definer set search_path = public as $$
declare r jsonb := px_inv_sweep(p_uid, p_focus); nid bigint;
begin
  if r is null then return null; end if;
  insert into px_investigations (uid, name, trig, focus, by_uid, by_name, score, verdict, report)
    values (p_uid, r ->> 'name', left(p_trig, 120), left(nullif(btrim(coalesce(p_focus, '')), ''), 600), p_by_uid, p_by_name, (r ->> 'score')::int, r ->> 'verdict', r) returning px_investigations.id into nid;
  delete from px_investigations p where p.uid = p_uid and p.id not in (select q.id from px_investigations q where q.uid = p_uid order by q.id desc limit 20);
  return nid;
end $$;
-- sent in by itself (at most once every 6 hours per player); never gets in the way of the game if something goes wrong
create or replace function public.px_inv_auto(p_uid text, p_why text) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_uid is null or exists (select 1 from px_investigations where uid = p_uid and trig like 'auto%' and at > now() - interval '6 hours') then return; end if;
  perform px_inv_run(p_uid, null, 'auto: ' || p_why, null, 'Investigation crew');
exception when others then
  insert into px_mod_log (act, target, note) values ('investigation crew error', p_uid, left(sqlerrm, 200));
end $$;
-- the triggers: flagged by the anti-cheat; results that keep disagreeing; reported by several players
create or replace function public.px_inv_trg_flag() returns trigger language plpgsql security definer set search_path = public as $$
begin if new.cheat is not null and old.cheat is null then perform px_inv_auto(new.uid, 'flagged by the anti-cheat (' || left(new.cheat, 80) || ')'); end if; return null; end $$;
drop trigger if exists px_inv_flag on public.px_players;
create trigger px_inv_flag after update of cheat on public.px_players for each row execute function public.px_inv_trg_flag();
create or replace function public.px_inv_trg_log() returns trigger language plpgsql security definer set search_path = public as $$
declare u text;
begin
  if new.act = 'ranked result mismatch' and new.target like '% vs %' then
    foreach u in array array[split_part(new.target, ' vs ', 1), split_part(new.target, ' vs ', 2)] loop
      if (select count(*) from px_mod_log where act = 'ranked result mismatch' and at > now() - interval '7 days' and (target like u || ' vs %' or target like '% vs ' || u)) >= 3 then
        perform px_inv_auto(u, 'ranked results that keep disagreeing');
      end if;
    end loop;
  end if;
  return null;
end $$;
drop trigger if exists px_inv_log on public.px_mod_log;
create trigger px_inv_log after insert on public.px_mod_log for each row execute function public.px_inv_trg_log();
create or replace function public.px_inv_trg_report() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.target is not null and (select count(distinct reporter) from px_dm_reports where target = new.target and at > now() - interval '7 days') >= 3 then perform px_inv_auto(new.target, 'reported by 3 or more players this week'); end if;
  return null;
end $$;
drop trigger if exists px_inv_report on public.px_dm_reports;
create trigger px_inv_report after insert on public.px_dm_reports for each row execute function public.px_inv_trg_report();

-- a player who isn't staff trying to open the staff panel leaves a line in the security log (once a minute at most)
create or replace function public.px_inv_note_panel_try(p_uid text) returns void language sql security definer set search_path = public as $$
  insert into px_sec_log (act, uid, name, iph) select 'someone who isn''t staff tried the panel', p_uid, (select name from px_players where uid = p_uid), px_net_tag()
   where exists (select 1 from px_players where uid = p_uid) and not exists (select 1 from px_sec_log where act = 'someone who isn''t staff tried the panel' and uid = p_uid and at > now() - interval '1 minute') $$;

-- (the panel check, the same as before plus that line)
create or replace function public.px_mod_check(p_pw text) returns text language plpgsql security definer set search_path = public as $$
declare c px_mod_cfg; su text; sk text; tk text; pl px_players; st px_staff; rl text;
begin
  perform set_config('px.who', '', true); perform set_config('px.hname', '', true); perform set_config('px.rank', '', true); perform set_config('px.suid', '', true); perform set_config('px.tok', '', true);
  -- staff (helper, moderator, admin) are known by who they are, not by a password: "<player id>|<their secret key>" and, once they
  -- have a panel PIN, "|<the session the PIN opened>"
  if p_pw is not null and position('|' in p_pw) > 0 and length(p_pw) <= 200 then
    su := split_part(p_pw, '|', 1); sk := split_part(p_pw, '|', 2); tk := nullif(split_part(p_pw, '|', 3), '');
    select * into pl from px_players where uid = su and keyhash = md5(sk || ':pxk');
    if not found then return 'wrong'; end if;
    rl := px_staff_role(su);
    if rl is null then perform px_inv_note_panel_try(su); return 'wrong'; end if;   -- (v29e: written down for the investigation crew)
    insert into px_staff (uid, role, name) values (su, rl, pl.name) on conflict (uid) do nothing;   -- (staff by Google account: this device joins the list)
    select * into st from px_staff where uid = su;
    -- (v29d) THE CREATOR: the creator's email has to be signed in on this device right now, and the creator PIN is always needed
    if px_is_creator(su) then
      if not px_creator_live(su) then
        insert into px_sec_log (act, uid, name, iph) select 'creator panel refused: email not signed in', su, pl.name, px_net_tag()
          where not exists (select 1 from px_sec_log where act = 'creator panel refused: email not signed in' and uid = su and at > now() - interval '2 minutes');
        return 'email';
      end if;
      if st.pin_hash is null then return 'needpin'; end if;
      if tk is null or not exists (select 1 from px_staff_sessions s where s.uid = su and s.token_hash = encode(sha256(convert_to(tk, 'utf8')), 'hex') and s.expires > now()) then return 'pin'; end if;
      perform set_config('px.tok', encode(sha256(convert_to(tk, 'utf8')), 'hex'), true);
      perform set_config('px.hname', coalesce(pl.name, 'Creator'), true); perform set_config('px.suid', su, true);
      perform set_config('px.who', 'owner', true); perform set_config('px.rank', 'creator', true); return 'ok';
    end if;
    -- the panel PIN: needed once a staff member has set one, and by everyone when an admin switched that on
    if st.pin_hash is not null or coalesce((select req_pin from px_mod_cfg where id = 1), false) then
      if st.pin_hash is null then return 'needpin'; end if;
      if tk is null or not exists (select 1 from px_staff_sessions s where s.uid = su and s.token_hash = encode(sha256(convert_to(tk, 'utf8')), 'hex') and s.expires > now()) then return 'pin'; end if;
      perform set_config('px.tok', encode(sha256(convert_to(tk, 'utf8')), 'hex'), true);
    end if;
    perform set_config('px.hname', coalesce(pl.name, 'Staff'), true); perform set_config('px.suid', su, true);
    perform set_config('px.who', 'helper', true); perform set_config('px.rank', case when st.role in ('moderator', 'owner') then 'moderator' else 'helper' end, true);   -- (an old admin who isn't the creator: a moderator)
    return 'helper';
  end if;
  -- (v29d) the old creator password is switched off: it never opens anything any more (tries are still logged, at most once a minute)
  if p_pw is not null then
    insert into px_sec_log (act, iph) select 'creator password tried (it is switched off)', px_net_tag()
      where not exists (select 1 from px_sec_log where act = 'creator password tried (it is switched off)' and at > now() - interval '1 minute');
  end if;
  return 'wrong';
end $$;

-- ---------- the staff panel ----------
-- send the crew in (moderators and the creator), with what looks wrong in your own words
create or replace function public.px_mod_investigate(p_pw text, p_uid text, p_focus text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); nid bigint; me text := nullif(current_setting('px.suid', true), ''); nm text := nullif(current_setting('px.hname', true), '');
begin
  if v not in ('ok', 'helper') then return jsonb_build_object('err', v); end if;
  if v = 'helper' and px_rank() <> 'moderator' then return jsonb_build_object('err', 'Only moderators and the creator can send the crew in. You can read the reports.'); end if;
  if (select count(*) from px_investigations where by_uid = me and at > now() - interval '1 hour') >= 20 then return jsonb_build_object('err', 'That''s a lot of investigations this hour. Give it a little while.'); end if;
  if length(coalesce(p_focus, '')) > 600 then return jsonb_build_object('err', 'Keep it under 600 characters.'); end if;
  nid := px_inv_run(p_uid, p_focus, 'staff', me, coalesce(nm, case when v = 'ok' then 'The creator' else 'A moderator' end));
  if nid is null then return jsonb_build_object('err', 'nobody'); end if;
  insert into px_mod_log (act, target, note) values ('sent the investigation crew', p_uid || ' (' || coalesce((select name from px_players where uid = p_uid), '?') || ')', left(coalesce(p_focus, 'a full sweep'), 140));
  return jsonb_build_object('ok', true, 'id', nid);
end $$;
-- the reports on one player (every staff rank can read them)
create or replace function public.px_mod_investigations(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v not in ('ok', 'helper') then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', px_ms(at), 'trig', trig, 'focus', focus, 'by', by_name, 'score', score, 'verdict', verdict, 'r', report,
    'status', status, 'outcome', outcome, 'closed_by', closed_by, 'closed_at', px_ms(closed_at)) order by id desc) from (select * from px_investigations where uid = p_uid order by id desc limit 10) q), '[]'::jsonb));
end $$;
-- the case list: open reports, the worst first
create or replace function public.px_mod_inv_cases(p_pw text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v not in ('ok', 'helper') then return jsonb_build_object('err', v); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'uid', uid, 'n', name, 'at', px_ms(at), 'trig', trig, 'by', by_name, 'verdict', verdict, 'score', score, 'status', status, 'outcome', outcome) order by (status = 'open') desc, score desc, id desc)
    from (select distinct on (uid) * from px_investigations order by uid, id desc) q where status = 'open' or at > now() - interval '14 days'), '[]'::jsonb));
end $$;
-- close a case with what was decided (moderators and the creator)
create or replace function public.px_mod_inv_close(p_pw text, p_id bigint, p_outcome text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); u text;
begin
  if v not in ('ok', 'helper') then return jsonb_build_object('err', v); end if;
  if v = 'helper' and px_rank() <> 'moderator' then return jsonb_build_object('err', 'Only moderators and the creator can close a case.'); end if;
  update px_investigations set status = 'closed', outcome = left(btrim(coalesce(p_outcome, 'closed')), 200), closed_by = coalesce(nullif(current_setting('px.hname', true), ''), 'staff'), closed_at = now() where id = p_id returning uid into u;
  if u is null then return jsonb_build_object('err', 'nobody'); end if;
  insert into px_mod_log (act, target, note) values ('closed an investigation', u || ' (' || coalesce((select name from px_players where uid = u), '?') || ')', left(coalesce(p_outcome, ''), 140));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.px_inv_areas(text), public.px_inv_sweep(text, text), public.px_inv_run(text, text, text, text, text), public.px_inv_auto(text, text),
  public.px_inv_trg_flag(), public.px_inv_trg_log(), public.px_inv_trg_report(), public.px_inv_note_panel_try(text) from public, anon, authenticated;
grant execute on function public.px_mod_investigate(text, text, text), public.px_mod_investigations(text, text), public.px_mod_inv_cases(text), public.px_mod_inv_close(text, bigint, text) to anon, authenticated;


-- ======================================================================================================================
-- v29f · STRIPE (card payments) in the Online Shop
-- Ordinary items already sell through Stripe payment links (v21: a link per item in the creator panel, the stripe-webhook
-- function writes the payment, the game hands it over). Two changes:
--  - the webhook now finds items in px_shop_items(), the same list the prices are checked against (it used to read only a
--    list the creator had saved, so with the built-in list a real payment came out "unmatched")
--  - the Custom Move ($5) can be paid by card: the player describes the move first (an order with a code, like Cash App), the
--    game opens the Custom Move's payment link with "<player id>-custom_move_<code>" on it, and when Stripe confirms the payment
--    the webhook marks that order paid (px_stripe_custom_paid). Nothing a game sends can mark it paid.
alter table public.px_mod_cfg add column if not exists pay_stripe_cm text;
create or replace function public.px_pay_pub() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('c', pay_cash, 'v', pay_venmo, 's', case when not coalesce(shop_dev, true) then pay_stripe_cm end, 'sl', pay_stripe_cm)) from px_mod_cfg where id = 1 $$;
revoke all on function public.px_pay_pub() from public, anon, authenticated;
-- the creator sets the Custom Move's Stripe payment link (from Stripe → Payment links; $5, no quantity)
create or replace function public.px_mod_pay_stripe_set(p_pw text, p_link text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); l text := nullif(btrim(coalesce(p_link, '')), '');
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can do that.' else v end); end if;
  if l is not null and l !~ '^https://buy\.stripe\.com/[A-Za-z0-9_]{6,120}$' then return jsonb_build_object('err', 'That isn''t a Stripe payment link (it starts with https://buy.stripe.com/).'); end if;
  update px_mod_cfg set pay_stripe_cm = l where id = 1;
  insert into px_mod_log (act, note) values ('Custom Move card payments', case when l is null then 'turned off' else 'link set' end);
  return jsonb_build_object('ok', true, 'pay', px_pay_pub());
end $$;
grant execute on function public.px_mod_pay_stripe_set(text, text) to anon, authenticated;
create or replace function public.px_pay_request(p_uid text, p_key text, p_item text, p_name text, p_kind text, p_amount int, p_ref text, p_price numeric, p_method text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; nm text; c px_mod_cfg; code text; cm boolean := (p_item = 'custom_move'); nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  select * into c from px_mod_cfg where id = 1;
  if p_method not in ('cashapp', 'venmo', 'school', 'stripe') then return jsonb_build_object('err', 'Pick how you''ll pay.'); end if;
  if p_method = 'cashapp' and c.pay_cash is null or p_method = 'venmo' and c.pay_venmo is null then return jsonb_build_object('err', 'That way of paying isn''t set up yet.'); end if;
  if p_method = 'stripe' and (not cm or c.pay_stripe_cm is null or coalesce(c.shop_dev, true)) then return jsonb_build_object('err', 'Paying by card isn''t set up for this yet.'); end if;   -- (v29f: card payments through Stripe, for the Custom Move)
  if cm and (nt is null or length(nt) < 15) then return jsonb_build_object('err', 'Describe your move in a bit more detail first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and status in ('new', 'ok')) >= 3 then return jsonb_build_object('err', 'You already have 3 orders waiting. Cancel one first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and at > now() - interval '10 minutes') >= 5 then return jsonb_build_object('err', 'Slow down a little.'); end if;
  if not cm then
    select x into it from jsonb_array_elements(px_shop_items()) x where x ->> 'id' = p_item limit 1;
    if it is null then return jsonb_build_object('err', 'That isn''t for sale.'); end if;
  end if;
  select name into nm from px_players where uid = p_uid;
  code := 'PX' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
  insert into px_meets (uid, name, item_id, item_name, kind, amount, ref, price, day, slot, place, note, method, code)
  values (p_uid, nm, left(p_item, 40),
    case when cm then 'Custom Move' else left(coalesce(it ->> 'name', p_item), 60) end,
    case when cm then 'custom' else left(coalesce(it ->> 'kind', 'other'), 12) end,
    case when cm then 0 else greatest(0, least(coalesce((it ->> 'amount')::int, 0), 100000)) end,
    case when cm then '' else left(coalesce(it ->> 'ref', ''), 40) end,
    case when cm then 5 else greatest(0, coalesce((it ->> 'price')::numeric, 0)) end,
    current_date, case p_method when 'cashapp' then 'Cash App' when 'venmo' then 'Venmo' when 'stripe' then 'Card (Stripe)' else 'At school' end,
    case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo when 'stripe' then 'Stripe' else 'ask Nathan' end,
    left(nt, case when cm then 600 else 140 end), p_method, code);
  return jsonb_build_object('ok', true, 'code', code, 'to', case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo end, 'link', case when p_method = 'stripe' then c.pay_stripe_cm end);
end $$;
-- called only by the stripe-webhook function (with the server key) once Stripe says a Custom Move was paid
create or replace function public.px_stripe_custom_paid(p_uid text, p_code text, p_paid numeric, p_ref text) returns jsonb language plpgsql security definer set search_path = public as $$
declare m px_meets;
begin
  select * into m from px_meets where uid = p_uid and code = p_code and kind = 'custom' for update;
  if not found then return jsonb_build_object('ok', false, 'why', 'no such order'); end if;
  if coalesce(p_paid, 0) + 0.001 < 5 then return jsonb_build_object('ok', false, 'why', 'paid too little'); end if;
  if m.status <> 'paid' then
    update px_meets set status = 'paid', done_at = now() where id = m.id;
    insert into px_mod_log (act, target, note) values ('Custom Move paid by card (Stripe)', m.uid || ' (' || coalesce(m.name, '?') || ')', left(coalesce(m.note, ''), 140));
  end if;
  insert into px_purchases (uid, item_id, name, kind, amount, ref, price, provider, provider_ref, status)
    values (p_uid, 'custom_move', 'Custom Move', 'custom', 0, '', p_paid, 'stripe', p_ref, 'claimed') on conflict (provider_ref) do nothing;   -- (for the money list; there's nothing to hand over)
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.px_stripe_custom_paid(text, text, numeric, text) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.px_shop_items(), public.px_stripe_custom_paid(text, text, numeric, text) to service_role;
  end if;
end $$;


-- ======================================================================================================================
-- v29g · PAYPAL next to Cash App (no Stripe)
-- Players pay the creator on Cash App or PayPal (or at school): each order gets a short code for the payment note, and the
-- creator presses "They paid: give it" when the money arrives. Stripe is off (its card option and links are gone from the game).
-- The creator's usernames are filled in below the first time; change them any time in the panel (Pay at school tab).
alter table public.px_mod_cfg add column if not exists pay_paypal text;
insert into public.px_mod_cfg (id, salt, pwhash) values (1, md5(gen_random_uuid()::text), encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'utf8')), 'hex')) on conflict (id) do nothing;   -- (the settings row, if a brand-new database doesn't have it yet; the old password in it opens nothing)
update public.px_mod_cfg set pay_cash = coalesce(pay_cash, '$NathanRocourt'), pay_paypal = coalesce(pay_paypal, '@Nathan-Rocourt'), pay_stripe_cm = null where id = 1;
create or replace function public.px_pay_pub() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('c', pay_cash, 'v', pay_venmo, 'p', pay_paypal)) from px_mod_cfg where id = 1 $$;
revoke all on function public.px_pay_pub() from public, anon, authenticated;
create or replace function public.px_mod_pay_set(p_pw text, p_cash text, p_venmo text, p_paypal text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); c text := nullif(btrim(coalesce(p_cash, '')), ''); w text := nullif(btrim(coalesce(p_venmo, '')), ''); pp text := nullif(btrim(coalesce(p_paypal, '')), '');
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can change where money goes.' else v end); end if;
  if c is not null then c := '$' || ltrim(c, '$'); if c !~ '^\$[A-Za-z][A-Za-z0-9_-]{0,19}$' then return jsonb_build_object('err', 'That doesn''t look like a Cash App $cashtag.'); end if; end if;
  if w is not null then w := '@' || ltrim(w, '@'); if w !~ '^@[A-Za-z0-9_-]{2,30}$' then return jsonb_build_object('err', 'That doesn''t look like a Venmo @username.'); end if; end if;
  if pp is not null then pp := regexp_replace(pp, '^https?://(www\.)?(paypal\.me|paypal\.com/paypalme)/', '', 'i'); pp := '@' || ltrim(pp, '@'); if pp !~ '^@[A-Za-z0-9_.-]{2,30}$' then return jsonb_build_object('err', 'That doesn''t look like a PayPal @username.'); end if; end if;
  update px_mod_cfg set pay_cash = c, pay_venmo = w, pay_paypal = pp where id = 1;
  insert into px_mod_log (act, note) values ('payment usernames', coalesce(c, 'no Cash App') || ' · ' || coalesce(pp, 'no PayPal') || ' · ' || coalesce(w, 'no Venmo'));
  return jsonb_build_object('ok', true, 'pay', px_pay_pub());
end $$;
grant execute on function public.px_mod_pay_set(text, text, text, text) to anon, authenticated;
create or replace function public.px_pay_request(p_uid text, p_key text, p_item text, p_name text, p_kind text, p_amount int, p_ref text, p_price numeric, p_method text, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; nm text; c px_mod_cfg; code text; cm boolean := (p_item = 'custom_move'); nt text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform px_auth(p_uid, p_key);
  if px_is_banned(p_uid) then return jsonb_build_object('err', 'banned'); end if;
  select * into c from px_mod_cfg where id = 1;
  if p_method not in ('cashapp', 'venmo', 'paypal', 'school', 'stripe') then return jsonb_build_object('err', 'Pick how you''ll pay.'); end if;
  if p_method = 'cashapp' and c.pay_cash is null or p_method = 'venmo' and c.pay_venmo is null or p_method = 'paypal' and c.pay_paypal is null then return jsonb_build_object('err', 'That way of paying isn''t set up yet.'); end if;
  if p_method = 'stripe' and (not cm or c.pay_stripe_cm is null or coalesce(c.shop_dev, true)) then return jsonb_build_object('err', 'Paying by card isn''t set up for this yet.'); end if;   -- (v29f: card payments through Stripe, for the Custom Move)
  if cm and (nt is null or length(nt) < 15) then return jsonb_build_object('err', 'Describe your move in a bit more detail first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and status in ('new', 'ok')) >= 3 then return jsonb_build_object('err', 'You already have 3 orders waiting. Cancel one first.'); end if;
  if (select count(*) from px_meets where uid = p_uid and at > now() - interval '10 minutes') >= 5 then return jsonb_build_object('err', 'Slow down a little.'); end if;
  if not cm then
    select x into it from jsonb_array_elements(px_shop_items()) x where x ->> 'id' = p_item limit 1;
    if it is null then return jsonb_build_object('err', 'That isn''t for sale.'); end if;
  end if;
  select name into nm from px_players where uid = p_uid;
  code := 'PX' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
  insert into px_meets (uid, name, item_id, item_name, kind, amount, ref, price, day, slot, place, note, method, code)
  values (p_uid, nm, left(p_item, 40),
    case when cm then 'Custom Move' else left(coalesce(it ->> 'name', p_item), 60) end,
    case when cm then 'custom' else left(coalesce(it ->> 'kind', 'other'), 12) end,
    case when cm then 0 else greatest(0, least(coalesce((it ->> 'amount')::int, 0), 100000)) end,
    case when cm then '' else left(coalesce(it ->> 'ref', ''), 40) end,
    case when cm then 5 else greatest(0, coalesce((it ->> 'price')::numeric, 0)) end,
    current_date, case p_method when 'cashapp' then 'Cash App' when 'venmo' then 'Venmo' when 'paypal' then 'PayPal' when 'stripe' then 'Card (Stripe)' else 'At school' end,
    case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo when 'paypal' then c.pay_paypal when 'stripe' then 'Stripe' else 'ask Nathan' end,
    left(nt, case when cm then 600 else 140 end), p_method, code);
  return jsonb_build_object('ok', true, 'code', code, 'to', case p_method when 'cashapp' then c.pay_cash when 'venmo' then c.pay_venmo when 'paypal' then c.pay_paypal end, 'link', case when p_method = 'stripe' then c.pay_stripe_cm end);
end $$;
create or replace function public.px_mod_meet_set(p_pw text, p_id bigint, p_status text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); m px_meets;
begin
  if v <> 'ok' then return jsonb_build_object('err', v); end if;
  if p_status not in ('ok', 'paid', 'no', 'new') then return jsonb_build_object('err', 'bad status'); end if;
  select * into m from px_meets where id = p_id for update; if not found then return jsonb_build_object('err', 'nobody'); end if;
  if m.status = 'paid' then return jsonb_build_object('err', 'Already paid and given.'); end if;
  update px_meets set status = p_status, done_at = case when p_status in ('paid', 'no') then now() else done_at end where id = p_id;
  if p_status = 'paid' and m.kind <> 'custom' then
    insert into px_purchases (uid, item_id, name, kind, amount, ref, price, provider, provider_ref, status)
    values (m.uid, m.item_id, m.item_name, m.kind, m.amount, m.ref, m.price, case when m.method in ('cashapp', 'venmo', 'paypal') then m.method else 'school' end, 'meet-' || m.id, 'paid') on conflict (provider_ref) do nothing;
  end if;
  insert into px_mod_log (act, target, note) values ('pay at school: ' || p_status, m.uid || ' (' || coalesce(m.name, '?') || ')', m.item_name || ' $' || m.price);
  return jsonb_build_object('ok', true);
end $$;

-- ======================================================================================================================
-- v29h · the creator can see and tune a player's AI clone; the creator panel while email codes can't be sent
-- A clone (the Fight DNA the game learns from how someone fights) lives on that player's device. The game now sends a short
-- summary of the active fighter's clone (px_clone_put), so the creator can see it on the player's page and change it:
-- reaction times (block / dodge / counter), how aggressive, how often it chains attacks, how far it stands, how hard it presses,
-- how often it blocks / dodges / counters, how often it punishes a miss, how often it whiffs. A change goes to the player's game
-- (like a fighter edit) and is pinned there, so learning from new fights doesn't undo it; it also changes their Turf defenders
-- straight away. "Back to how they really fight" removes the pins.
alter table public.px_players add column if not exists clone jsonb;
alter table public.px_players add column if not exists clone_pin jsonb;
alter table public.px_players add column if not exists clone_at timestamptz;
-- the keys a clone summary / a change can have, and what they mean in the Fight DNA
create or replace function public.px_clone_keys() returns jsonb language sql immutable as $$
  select '{"rb":["react","block",0.04,1.2],"rd":["react","dodge",0.04,1.2],"rc":["react","counter",0.04,1.2],"ag":["aggr",null,0,2],"ch":["chain",null,0,1],"rg":["range",null,0.6,3],"pr":["pressure",null,0,1],"bl":["def","block",0,1],"dg":["def","dodge",0,1],"ct":["def","counter",0,1],"pu":["punish",null,0,1],"wh":["whiff",null,0,1]}'::jsonb $$;
-- the game sends its clone summary (small numbers only; anything else is dropped)
create or replace function public.px_clone_put(p_uid text, p_key text, p_cl jsonb) returns void language plpgsql security definer set search_path = public as $$
declare k text; r jsonb := '{}'::jsonb; x numeric; spec jsonb;
begin
  perform px_auth(p_uid, p_key);
  if p_cl is null or jsonb_typeof(p_cl) <> 'object' or length(p_cl::text) > 1500 then return; end if;
  for k, spec in select key, value from jsonb_each(px_clone_keys()) loop
    x := px_num(p_cl ->> k); if x is not null then r := r || jsonb_build_object(k, trim_scale(round(least(greatest(x, (spec ->> 2)::numeric), (spec ->> 3)::numeric), 3))); end if;
  end loop;
  r := r || jsonb_strip_nulls(jsonb_build_object('n', least(greatest(coalesce(px_num(p_cl ->> 'n'), 0), 0), 100000)::int, 'fid', left(coalesce(p_cl ->> 'fid', ''), 20), 'fn', left(coalesce(p_cl ->> 'fn', ''), 16)));
  update px_players set clone = r, clone_at = now() where uid = p_uid;
end $$;
grant execute on function public.px_clone_put(text, text, jsonb) to anon, authenticated;
-- a change applied to a full Fight DNA (used on the Turf copies)
create or replace function public.px_clone_apply(d jsonb, patch jsonb) returns jsonb language plpgsql immutable as $$
declare k text; spec jsonb; v jsonb;
begin
  if d is null or jsonb_typeof(d) <> 'object' then return d; end if;
  for k, spec in select key, value from jsonb_each(px_clone_keys()) loop
    v := patch -> k; if v is null then continue; end if;
    if spec ->> 1 is null then d := jsonb_set(d, array[spec ->> 0], v, true);
    else d := jsonb_set(d, array[spec ->> 0], coalesce(d -> (spec ->> 0), '{}'::jsonb) || jsonb_build_object(spec ->> 1, v), true); end if;
  end loop;
  return jsonb_set(d, '{ovr}', coalesce(d -> 'ovr', '{}'::jsonb) || patch, true);
end $$;
-- the creator's view of a player's clone
create or replace function public.px_mod_clone_get(p_pw text, p_uid text) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw);
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can see and change clones.' else v end); end if;
  return (select jsonb_build_object('cl', clone, 'pin', clone_pin, 'at', px_ms(clone_at), 'turf', (select count(*) from turf where owner_uid = p_uid)) from px_players where uid = p_uid);
end $$;
-- the creator changes it (p_patch: the numbers to pin, or {"reset": true} to go back to how they really fight)
create or replace function public.px_mod_clone_set(p_pw text, p_uid text, p_patch jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := px_mod_check(p_pw); k text; spec jsonb; x numeric; clean jsonb := '{}'::jsonb; reset boolean := coalesce((p_patch ->> 'reset')::boolean, false); nm text;
begin
  if v <> 'ok' then return jsonb_build_object('err', case when v = 'helper' then 'Only the creator can see and change clones.' else v end); end if;
  select name into nm from px_players where uid = p_uid; if nm is null then return jsonb_build_object('err', 'nobody'); end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or length(p_patch::text) > 800 then return jsonb_build_object('err', 'bad change'); end if;
  if not reset then
    for k, spec in select key, value from jsonb_each(px_clone_keys()) loop
      if not p_patch ? k then continue; end if;
      x := px_num(p_patch ->> k);
      if x is null or x < (spec ->> 2)::numeric or x > (spec ->> 3)::numeric then return jsonb_build_object('err', 'bad value for ' || k); end if;
      clean := clean || jsonb_build_object(k, trim_scale(round(x, 3)));
    end loop;
    if clean = '{}'::jsonb then return jsonb_build_object('err', 'nothing to change'); end if;
  end if;
  insert into px_edits (uid, edit) values (p_uid, jsonb_build_object('dna', case when reset then jsonb_build_object('reset', true) else clean end));
  update px_players set clone_pin = case when reset then null else coalesce(clone_pin, '{}'::jsonb) || clean end, clone = case when reset then clone else coalesce(clone, '{}'::jsonb) || clean end where uid = p_uid;
  if not reset then update turf set dna = px_clone_apply(dna, clean) where owner_uid = p_uid and dna is not null;
  else update turf set dna = dna - 'ovr' where owner_uid = p_uid and dna is not null; end if;
  insert into px_mod_log (act, target, note) values ('tuned an AI clone', p_uid || ' (' || nm || ')', case when reset then 'back to how they really fight' else left(clean::text, 180) end);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.px_mod_clone_get(text, text), public.px_mod_clone_set(text, text, jsonb) to anon, authenticated;
revoke all on function public.px_clone_apply(jsonb, jsonb) from public, anon, authenticated;

-- ---------- the creator panel while email codes can't be sent ----------
-- With the email sender broken the creator couldn't sign in with their email, so the panel would be shut for good. Until the
-- creator switches the email check on (select px_creator_require_email(true); in the SQL Editor, once codes arrive), the creator
-- panel needs: the creator's own device (signed in with the creator's email once, or linked from the SQL Editor), its secret key,
-- and the creator PIN (always; 6 to 8 numbers; 5 wrong tries lock it for an hour). Nothing typed in the game links a device.
alter table public.px_mod_cfg add column if not exists creator_email boolean not null default false;
create table if not exists public.px_creator_devs (uid text primary key, at timestamptz not null default now());
alter table public.px_creator_devs enable row level security; revoke all on public.px_creator_devs from anon, authenticated;
create or replace function public.px_is_creator(p_uid text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from px_google g, px_creator c where g.uid = p_uid and encode(sha256(convert_to(lower(btrim(g.email)), 'utf8')), 'hex') = c.email_hash)
      or exists (select 1 from px_creator_devs d where d.uid = p_uid) $$;
create or replace function public.px_creator_live(p_uid text) returns boolean language sql stable security definer set search_path = public as $$
  select px_is_creator(p_uid) and (not coalesce((select creator_email from px_mod_cfg where id = 1), false) or (
    px_google_email() is not null and encode(sha256(convert_to(px_google_email(), 'utf8')), 'hex') = (select email_hash from px_creator where id = 1)
    and exists (select 1 from px_google g where g.uid = p_uid and g.sub = px_jwt() ->> 'sub'))) $$;
-- SQL Editor only: make this device the creator's (your player id is on the Settings screen in the game)
create or replace function public.px_creator_link(p_uid text) returns text language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  select name into nm from px_players where uid = btrim(p_uid);
  if nm is null then return 'No player has that id. In the game open Settings, copy the id shown there exactly, and try again.'; end if;
  insert into px_creator_devs (uid) values (btrim(p_uid)) on conflict do nothing;
  insert into px_staff (uid, role, name) values (btrim(p_uid), 'owner', nm) on conflict (uid) do update set role = 'owner';
  insert into px_sec_log (act, uid, name, note) values ('creator device linked (SQL Editor)', btrim(p_uid), nm, null);
  return 'Done: ' || nm || ' is the creator''s device. Open the panel in the game and make your PIN (6 to 8 numbers).';
end $$;
-- SQL Editor only: once email codes work, require the creator's email on every panel visit (true), or not (false)
create or replace function public.px_creator_require_email(p_on boolean) returns text language plpgsql security definer set search_path = public as $$
begin
  update px_mod_cfg set creator_email = coalesce(p_on, true) where id = 1;
  insert into px_sec_log (act, note) values ('creator panel email check', case when p_on then 'on' else 'off' end);
  return case when p_on then 'On: the creator panel also needs your email signed in.' else 'Off: your device, its key and your PIN open the creator panel.' end;
end $$;
revoke all on function public.px_creator_link(text), public.px_creator_require_email(boolean), public.px_is_creator(text), public.px_creator_live(text) from public, anon, authenticated;
