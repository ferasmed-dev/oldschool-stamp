-- ============================================================
--  Digital stamp card — database setup for Supabase
--  Paste this whole file into Supabase > SQL Editor > Run.
--  Safe to run again (it only creates what is missing).
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tables ----------
create table if not exists public.bars (
  slug              text primary key,
  name              text not null,
  reward            text not null default 'Jarra gratis',
  stamps_needed     int  not null default 5  check (stamps_needed between 2 and 20),
  cooldown_minutes  int  not null default 180 check (cooldown_minutes between 0 and 1440),
  staff_pin_hash    text not null,
  owner_pin_hash    text not null,
  created_at        timestamptz not null default now()
);

create table if not exists public.cards (
  id                uuid primary key default gen_random_uuid(),
  bar_slug          text not null references public.bars(slug) on delete cascade,
  name              text not null,
  contact           text not null,
  marketing_opt_in  boolean not null default false,
  consent_at        timestamptz not null,
  stamps            int not null default 0,
  rewards_redeemed  int not null default 0,
  last_stamp_at     timestamptz,
  created_at        timestamptz not null default now(),
  unique (bar_slug, contact)
);

-- Every join / stamp / reward is logged here. One stamp = one visit.
create table if not exists public.events (
  id         bigserial primary key,
  bar_slug   text not null,
  card_id    uuid references public.cards(id) on delete cascade,
  kind       text not null check (kind in ('join','stamp','redeem')),
  created_at timestamptz not null default now()
);
create index if not exists events_bar_time on public.events (bar_slug, created_at);
create index if not exists events_card on public.events (card_id);

-- Wrong-PIN attempts, used to lock guessing.
create table if not exists public.pin_failures (
  id         bigserial primary key,
  bar_slug   text not null,
  created_at timestamptz not null default now()
);
create index if not exists pin_failures_bar_time on public.pin_failures (bar_slug, created_at);

-- Nobody reads or writes tables directly. Everything goes through the functions below.
alter table public.bars         enable row level security;
alter table public.cards        enable row level security;
alter table public.events       enable row level security;
alter table public.pin_failures enable row level security;
revoke all on public.bars, public.cards, public.events, public.pin_failures from anon, authenticated;

-- ---------- Internal helpers ----------
create or replace function public._check_pin(p_bar text, p_pin text, p_owner boolean)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare b public.bars; fails int; h text;
begin
  select * into b from public.bars where slug = p_bar;
  if not found then return 'no_bar'; end if;
  select count(*) into fails from public.pin_failures
   where bar_slug = p_bar and created_at > now() - interval '10 minutes';
  if fails >= 8 then return 'locked'; end if;
  h := case when p_owner then b.owner_pin_hash else b.staff_pin_hash end;
  if crypt(coalesce(p_pin, ''), h) = h then return 'ok'; end if;
  insert into public.pin_failures(bar_slug) values (p_bar);
  return 'bad_pin';
end $$;

create or replace function public._card_json(p_id uuid)
returns json language sql security definer set search_path = public as $$
  select json_build_object(
    'id', c.id, 'name', c.name, 'stamps', c.stamps,
    'stamps_needed', b.stamps_needed, 'reward', b.reward,
    'rewards_redeemed', c.rewards_redeemed, 'bar_name', b.name, 'bar', b.slug)
  from public.cards c join public.bars b on b.slug = c.bar_slug
  where c.id = p_id
$$;

create or replace function public._norm_contact(p text)
returns text language plpgsql immutable as $$
declare v text := trim(coalesce(p, ''));
begin
  if position('@' in v) > 0 then return lower(v); end if;
  v := regexp_replace(v, '[^0-9+]', '', 'g');
  if v like '0034%' then v := '+34' || substr(v, 5); end if;
  if v ~ '^[679][0-9]{8}$' then v := '+34' || v; end if;   -- Spanish numbers without prefix
  return v;
end $$;

-- ---------- Public functions (called by the web pages) ----------
create or replace function public.bar_info(p_bar text)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(
    (select json_build_object('ok', true, 'name', name, 'reward', reward, 'stamps_needed', stamps_needed)
       from public.bars where slug = p_bar),
    json_build_object('ok', false, 'error', 'no_bar'))
$$;

create or replace function public.join_card(p_bar text, p_name text, p_contact text,
                                            p_consent boolean, p_marketing boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_contact text; v_name text := trim(coalesce(p_name, ''));
begin
  if not exists (select 1 from public.bars where slug = p_bar) then
    return json_build_object('ok', false, 'error', 'no_bar'); end if;
  if not coalesce(p_consent, false) then
    return json_build_object('ok', false, 'error', 'consent'); end if;
  v_contact := public._norm_contact(p_contact);
  if char_length(v_contact) < 6 or char_length(v_contact) > 80 then
    return json_build_object('ok', false, 'error', 'contact'); end if;
  if char_length(v_name) < 1 or char_length(v_name) > 40 then
    return json_build_object('ok', false, 'error', 'name'); end if;

  select id into v_id from public.cards where bar_slug = p_bar and contact = v_contact;
  if v_id is null then
    insert into public.cards(bar_slug, name, contact, marketing_opt_in, consent_at)
    values (p_bar, v_name, v_contact, coalesce(p_marketing, false), now())
    returning id into v_id;
    insert into public.events(bar_slug, card_id, kind) values (p_bar, v_id, 'join');
  elsif coalesce(p_marketing, false) then
    update public.cards set marketing_opt_in = true where id = v_id;
  end if;
  return json_build_object('ok', true, 'card', public._card_json(v_id));
end $$;

create or replace function public.get_card(p_card uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare j json;
begin
  j := public._card_json(p_card);
  if j is null then return json_build_object('ok', false, 'error', 'not_found'); end if;
  return json_build_object('ok', true, 'card', j);
end $$;

create or replace function public.add_stamp(p_card uuid, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare c public.cards; b public.bars; chk text; mins int;
begin
  select * into c from public.cards where id = p_card for update;
  if not found then return json_build_object('ok', false, 'error', 'not_found'); end if;
  select * into b from public.bars where slug = c.bar_slug;
  chk := public._check_pin(c.bar_slug, p_pin, false);
  if chk <> 'ok' then return json_build_object('ok', false, 'error', chk); end if;
  if c.stamps >= b.stamps_needed then
    return json_build_object('ok', false, 'error', 'full', 'card', public._card_json(c.id)); end if;
  if c.last_stamp_at is not null
     and c.last_stamp_at > now() - make_interval(mins => b.cooldown_minutes) then
    mins := ceil(extract(epoch from (c.last_stamp_at + make_interval(mins => b.cooldown_minutes) - now())) / 60);
    return json_build_object('ok', false, 'error', 'cooldown', 'minutes_left', mins);
  end if;
  update public.cards set stamps = stamps + 1, last_stamp_at = now() where id = c.id;
  insert into public.events(bar_slug, card_id, kind) values (c.bar_slug, c.id, 'stamp');
  return json_build_object('ok', true, 'card', public._card_json(c.id));
end $$;

create or replace function public.redeem(p_card uuid, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare c public.cards; b public.bars; chk text;
begin
  select * into c from public.cards where id = p_card for update;
  if not found then return json_build_object('ok', false, 'error', 'not_found'); end if;
  select * into b from public.bars where slug = c.bar_slug;
  chk := public._check_pin(c.bar_slug, p_pin, false);
  if chk <> 'ok' then return json_build_object('ok', false, 'error', chk); end if;
  if c.stamps < b.stamps_needed then return json_build_object('ok', false, 'error', 'not_ready'); end if;
  update public.cards set stamps = 0, rewards_redeemed = rewards_redeemed + 1 where id = c.id;
  insert into public.events(bar_slug, card_id, kind) values (c.bar_slug, c.id, 'redeem');
  return json_build_object('ok', true, 'card', public._card_json(c.id));
end $$;

-- Owner dashboard numbers. A "night" runs until 6:00 Madrid time.
create or replace function public.owner_stats(p_bar text, p_pin text)
returns json language plpgsql stable security definer set search_path = public as $$
declare chk text; tz text := 'Europe/Madrid'; today date; r json;
begin
  chk := public._check_pin(p_bar, p_pin, true);
  if chk <> 'ok' then return json_build_object('ok', false, 'error', chk); end if;
  today := ((now() at time zone tz) - interval '6 hours')::date;
  select json_build_object(
    'ok', true,
    'bar', (select json_build_object('name', name, 'reward', reward, 'stamps_needed', stamps_needed,
                                     'cooldown_minutes', cooldown_minutes)
              from public.bars where slug = p_bar),
    'members',        (select count(*) from public.cards where bar_slug = p_bar),
    'opted_in',       (select count(*) from public.cards where bar_slug = p_bar and marketing_opt_in),
    'joins_7d',       (select count(*) from public.events where bar_slug = p_bar and kind = 'join'   and created_at > now() - interval '7 days'),
    'joins_30d',      (select count(*) from public.events where bar_slug = p_bar and kind = 'join'   and created_at > now() - interval '30 days'),
    'visits_tonight', (select count(*) from public.events where bar_slug = p_bar and kind = 'stamp' and created_at > now() - interval '12 hours'),
    'visits_7d',      (select count(*) from public.events where bar_slug = p_bar and kind = 'stamp' and created_at > now() - interval '7 days'),
    'visits_30d',     (select count(*) from public.events where bar_slug = p_bar and kind = 'stamp' and created_at > now() - interval '30 days'),
    'redeemed_30d',   (select count(*) from public.events where bar_slug = p_bar and kind = 'redeem' and created_at > now() - interval '30 days'),
    'returning',      (select count(*) from (select card_id from public.events where bar_slug = p_bar and kind = 'stamp'
                                              group by card_id having count(*) >= 2) x),
    'inactive_14d',   (select count(*) from public.cards c where c.bar_slug = p_bar
                         and coalesce(c.last_stamp_at, c.created_at) < now() - interval '14 days'),
    'daily', (select json_agg(json_build_object(
                'day', d::date,
                'visits', (select count(*) from public.events e where e.bar_slug = p_bar and e.kind = 'stamp'
                             and ((e.created_at at time zone tz) - interval '6 hours')::date = d::date),
                'joins',  (select count(*) from public.events e where e.bar_slug = p_bar and e.kind = 'join'
                             and ((e.created_at at time zone tz) - interval '6 hours')::date = d::date)
              ) order by d)
              from generate_series(today - 13, today, interval '1 day') d)
  ) into r;
  return r;
end $$;

-- Member list: who comes, how often, last visit. Contact shown only if they accepted offers.
create or replace function public.owner_members(p_bar text, p_pin text)
returns json language plpgsql stable security definer set search_path = public as $$
declare chk text;
begin
  chk := public._check_pin(p_bar, p_pin, true);
  if chk <> 'ok' then return json_build_object('ok', false, 'error', chk); end if;
  return json_build_object('ok', true, 'members', coalesce((
    select json_agg(json_build_object(
      'name', c.name,
      'contact', case when c.marketing_opt_in then c.contact else null end,
      'opted_in', c.marketing_opt_in,
      'joined', c.created_at,
      'last_visit', c.last_stamp_at,
      'visits', (select count(*) from public.events e where e.card_id = c.id and e.kind = 'stamp'),
      'stamps', c.stamps,
      'rewards', c.rewards_redeemed
    ) order by coalesce(c.last_stamp_at, c.created_at) desc)
    from public.cards c where c.bar_slug = p_bar), '[]'::json));
end $$;

create or replace function public.owner_update(p_bar text, p_pin text, p_reward text,
                                               p_stamps_needed int, p_new_staff_pin text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare chk text;
begin
  chk := public._check_pin(p_bar, p_pin, true);
  if chk <> 'ok' then return json_build_object('ok', false, 'error', chk); end if;
  if p_reward is not null and char_length(trim(p_reward)) between 2 and 60 then
    update public.bars set reward = trim(p_reward) where slug = p_bar; end if;
  if p_stamps_needed is not null and p_stamps_needed between 2 and 20 then
    update public.bars set stamps_needed = p_stamps_needed where slug = p_bar; end if;
  if p_new_staff_pin is not null and p_new_staff_pin <> '' then
    if p_new_staff_pin !~ '^[0-9]{4,6}$' then return json_build_object('ok', false, 'error', 'pin_format'); end if;
    update public.bars set staff_pin_hash = crypt(p_new_staff_pin, gen_salt('bf')) where slug = p_bar;
  end if;
  return json_build_object('ok', true);
end $$;

-- ---------- Permissions ----------
revoke execute on function public._check_pin(text, text, boolean) from public, anon, authenticated;
revoke execute on function public._card_json(uuid)                from public, anon, authenticated;
revoke execute on function public._norm_contact(text)             from public, anon, authenticated;
grant execute on function
  public.bar_info(text),
  public.join_card(text, text, text, boolean, boolean),
  public.get_card(uuid),
  public.add_stamp(uuid, text),
  public.redeem(uuid, text),
  public.owner_stats(text, text),
  public.owner_members(text, text),
  public.owner_update(text, text, text, int, text)
to anon;

-- ---------- First bar ----------
-- CHANGE BOTH PINS before going live: staff PIN (4–6 digits), owner PIN (6 digits).
insert into public.bars (slug, name, reward, stamps_needed, cooldown_minutes, staff_pin_hash, owner_pin_hash)
values ('old-school', 'Old School Pub', 'Jarra gratis', 5, 180,
        extensions.crypt('1234',   extensions.gen_salt('bf')),
        extensions.crypt('246810', extensions.gen_salt('bf')))
on conflict (slug) do nothing;

-- To add another bar later, copy the insert above with a new slug, name and PINs.
