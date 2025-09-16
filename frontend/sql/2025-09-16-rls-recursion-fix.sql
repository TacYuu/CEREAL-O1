-- Migration: Fix RLS infinite recursion by using an admins table instead of self-referencing profiles in policies
-- Safe to run multiple times
begin;

-- 1) Admins lookup table
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Seed known admin by email (adjust as needed)
insert into public.admins(user_id)
select u.id
from auth.users u
left join public.admins a on a.user_id = u.id
where u.email = 'seerealthesis@gmail.com' and a.user_id is null;

-- 2) Recreate policies to reference admins table (no self-reference to profiles)

-- Profiles
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles for select using (
  id = auth.uid() or exists(select 1 from public.admins a where a.user_id = auth.uid())
);

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update using (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
) with check (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
);

-- Rewards
drop policy if exists rewards_write_admin on public.rewards;
create policy rewards_write_admin on public.rewards for all using (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
);

-- Reward categories
drop policy if exists reward_categories_write_admin on public.reward_categories;
create policy reward_categories_write_admin on public.reward_categories for all using (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
);

-- Transactions and claims
drop policy if exists tx_read_admin on public.point_transactions;
create policy tx_read_admin on public.point_transactions for select using (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
);

drop policy if exists claims_read_admin on public.reward_claims;
create policy claims_read_admin on public.reward_claims for select using (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
);

-- Logs admin read
drop policy if exists logs_read_admin on public.logs;
create policy logs_read_admin on public.logs for select using (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
);

-- Earning opportunities write by admin
drop policy if exists earning_ops_write_admin on public.earning_opportunities;
create policy earning_ops_write_admin on public.earning_opportunities for all using (
  exists(select 1 from public.admins a where a.user_id = auth.uid())
);

commit;