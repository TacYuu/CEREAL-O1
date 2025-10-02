alter table public.reward_categories enable row level security;
drop policy if exists reward_categories_read_all on public.reward_categories;
create policy reward_categories_read_all on public.reward_categories for select using (true);
drop policy if exists reward_categories_write_admin on public.reward_categories;
create policy reward_categories_write_admin on public.reward_categories for all using (
  EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
create table if not exists public.admins (
  user_id uuid primary key
);

-- RLS policies for profiles table
create table if not exists public.profiles (
  id uuid primary key
);
alter table public.profiles enable row level security;
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles for select using (
  id = auth.uid() OR EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update using (
  id = auth.uid() OR EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
) with check (
  id = auth.uid() OR EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
create table if not exists public.reward_categories (
  id bigserial primary key,
  name text
);
create table if not exists public.reward_claims (
  id bigserial primary key,
  user_id uuid
);
create table if not exists public.point_transactions (
  id bigserial primary key,
  user_id uuid
);
create table if not exists public.logs (
  id bigserial primary key,
  user_id uuid
);
create table if not exists public.recycling_logs (
  id bigserial primary key,
  user_id uuid
);
create table if not exists public.device_credentials (
  device_id text primary key
);
drop policy if exists claims_read_own on public.reward_claims;
create policy claims_read_own on public.reward_claims for select using (
  user_id = auth.uid() OR EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
alter table public.point_transactions enable row level security;
drop policy if exists tx_read_own on public.point_transactions;
create policy tx_read_own on public.point_transactions for select using (
  user_id = auth.uid() OR EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
drop policy if exists logs_read_own on public.logs;
create policy logs_read_own on public.logs for select using (
  user_id = auth.uid() OR EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
drop policy if exists recycling_insert_own on public.recycling_logs;
create policy recycling_insert_own on public.recycling_logs for insert with check (user_id = auth.uid());
drop policy if exists recycling_read_own on public.recycling_logs;
create policy recycling_read_own on public.recycling_logs for select using (
  user_id = auth.uid() OR EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
drop policy if exists device_admin_select on public.device_credentials;
create policy device_admin_select on public.device_credentials for select using (
  EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
create policy device_admin_insert on public.device_credentials for insert with check (
  EXISTS (SELECT 1 FROM admins a WHERE a.user_id = auth.uid())
);
