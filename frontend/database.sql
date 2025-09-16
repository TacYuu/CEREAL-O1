-- CEREAL Supabase schema: ready to run in Supabase SQL editor
-- Safe to run multiple times due to IF NOT EXISTS checks where possible

-- Enable pgcrypto for UUIDs if needed
create extension if not exists "uuid-ossp";

-- Profiles table mirrors auth.users via trigger
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  name text,
  role text check (role in ('user','admin')) default 'user',
  avatar_url text,
  points integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Rewards catalog
create table if not exists public.reward_categories (
  id bigserial primary key,
  name text not null unique
);

create table if not exists public.rewards (
  id bigserial primary key,
  name text not null,
  description text,
  cost integer not null check (cost >= 0),
  stock integer not null default 0 check (stock >= 0),
  active boolean not null default true,
  category_id bigint references public.reward_categories(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Claims
create table if not exists public.reward_claims (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reward_id bigint not null references public.rewards(id) on delete restrict,
  cost integer not null,
  created_at timestamptz not null default now()
);

-- Points transactions (positive earn, negative spend)
create table if not exists public.point_transactions (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null,
  type text default 'misc',
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Activity logs
create table if not exists public.logs (
  id bigserial primary key,
  user_id uuid references public.profiles(id) on delete cascade,
  action_type text,
  message text,
  created_at timestamptz not null default now()
);

-- Recycling logs (from user UI)
create table if not exists public.recycling_logs (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  material text not null,
  quantity integer not null check (quantity > 0),
  points_awarded integer not null default 0,
  created_at timestamptz not null default now()
);

-- Earning opportunities shown in UI
create table if not exists public.earning_opportunities (
  id bigserial primary key,
  title text not null,
  description text,
  points integer not null check (points >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Maintain updated_at
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- On auth signup, ensure profile row
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, avatar_url, role)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data->>'name',
    new.raw_user_meta_data->>'avatar_url',
    case when new.email = 'seerealthesis@gmail.com' then 'admin' else 'user' end
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Award points when recycling_logs inserted
create or replace function public.award_points_on_recycling()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set points = points + new.points_awarded where id = new.user_id;
  insert into public.point_transactions(user_id, amount, type, metadata)
  values (new.user_id, new.points_awarded, 'recycle', jsonb_build_object('material', new.material, 'quantity', new.quantity));
  insert into public.logs(user_id, action_type, message)
  values (new.user_id, 'Recycle', concat('+', new.points_awarded, ' pts for recycling ', new.material));
  return new;
end; $$;

create trigger on_recycling_insert
  after insert on public.recycling_logs
  for each row execute function public.award_points_on_recycling();

-- RPC: admin adjust points
create or replace function public.admin_adjust_points(target_user uuid, delta integer, reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  caller uuid;
  caller_is_admin boolean;
  caller_email text;
begin
  select auth.uid() into caller;
  if caller is null then raise exception 'Not authenticated'; end if;
  select (role = 'admin'), email into caller_is_admin, caller_email from public.profiles where id = caller;
  if not (caller_is_admin or caller_email = 'seerealthesis@gmail.com') then
    raise exception 'Forbidden: admin only';
  end if;

  update public.profiles set points = points + delta where id = target_user;
  insert into public.point_transactions(user_id, amount, type, metadata)
  values (target_user, delta, 'admin_adjust', jsonb_build_object('reason', reason));
  insert into public.logs(user_id, action_type, message)
  values (target_user, 'Admin Adjust', concat('Points adjusted by ', delta, coalesce(' – '||reason,'')));
end; $$;

-- RPC: redeem reward atomically
create or replace function public.redeem_reward(reward_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  uid uuid;
  r record;
  current_points integer;
begin
  -- Authenticated user id
  select auth.uid() into uid;
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  select * into r from public.rewards where id = reward_id for update;
  if r is null or r.active = false then
    raise exception 'Reward unavailable';
  end if;
  if r.stock <= 0 then
    raise exception 'Out of stock';
  end if;

  select points into current_points from public.profiles where id = uid for update;
  if current_points < r.cost then
    raise exception 'Insufficient points';
  end if;

  update public.rewards set stock = stock - 1 where id = r.id;
  update public.profiles set points = points - r.cost where id = uid;
  insert into public.point_transactions(user_id, amount, type, metadata) values (uid, -r.cost, 'redeem', jsonb_build_object('reward_id', r.id));
  insert into public.reward_claims(user_id, reward_id, cost) values (uid, r.id, r.cost);
  insert into public.logs(user_id, action_type, message) values (uid, 'Reward Redeemed', concat('Redeemed reward (', r.name, ') for ', r.cost, ' pts'));
end; $$;

-- Leaderboard aggregate since timestamp
create or replace function public.points_leaderboard_since(since_ts timestamptz)
returns table(id uuid, name text, total_points bigint) language sql security definer set search_path = public as $$
  select p.id, coalesce(p.name, p.email) as name, sum(t.amount)::bigint as total_points
  from public.point_transactions t
  join public.profiles p on p.id = t.user_id
  where t.created_at >= since_ts
  group by p.id, coalesce(p.name, p.email)
  order by total_points desc
  limit 100;
$$;

-- RLS policies
alter table public.profiles enable row level security;
alter table public.rewards enable row level security;
alter table public.reward_categories enable row level security;
alter table public.reward_claims enable row level security;
alter table public.point_transactions enable row level security;
alter table public.logs enable row level security;
alter table public.recycling_logs enable row level security;
alter table public.earning_opportunities enable row level security;

-- Profiles: users can read themselves; admins can read all; users can update themselves (name, avatar)
create policy if not exists profiles_select_self on public.profiles for select using (
  id = auth.uid() or exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);
create policy if not exists profiles_update_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- Admins can update any profile (e.g., role changes)
create policy if not exists profiles_admin_update on public.profiles for update using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
) with check (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- Rewards and categories are readable by everyone; only admins can write
create policy if not exists rewards_read_all on public.rewards for select using (true);
create policy if not exists rewards_write_admin on public.rewards for all using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);
create policy if not exists reward_categories_read_all on public.reward_categories for select using (true);
create policy if not exists reward_categories_write_admin on public.reward_categories for all using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- Claims & transactions: users read own; insert via RPC/flows
create policy if not exists claims_read_own on public.reward_claims for select using (user_id = auth.uid());
create policy if not exists tx_read_own on public.point_transactions for select using (user_id = auth.uid());
-- Admins read all transactions and claims
create policy if not exists tx_read_admin on public.point_transactions for select using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);
create policy if not exists claims_read_admin on public.reward_claims for select using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- Logs: users read own
create policy if not exists logs_read_own on public.logs for select using (user_id = auth.uid());
create policy if not exists logs_read_admin on public.logs for select using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- Recycling logs: users can insert their own and read own
create policy if not exists recycling_insert_own on public.recycling_logs for insert with check (user_id = auth.uid());
create policy if not exists recycling_read_own on public.recycling_logs for select using (user_id = auth.uid());

-- Earning opportunities readable by all
create policy if not exists earning_ops_read_all on public.earning_opportunities for select using (true);
create policy if not exists earning_ops_write_admin on public.earning_opportunities for all using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- Helper: mark one email as admin in profile
-- Run once: update profiles set role='admin' where email = 'seerealthesis@gmail.com';
