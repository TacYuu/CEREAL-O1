-- Supabase RLS policies for redeemables/rewards system
-- Add these in SQL editor or run as a migration

-- Allow authenticated users to insert their own reward claims
create policy if not exists claims_insert_own on public.reward_claims
for insert
with check (user_id = auth.uid());

-- Allow authenticated users to update their own points in profiles (for redemption)
create policy if not exists profiles_update_self on public.profiles
for update
using (id = auth.uid())
with check (id = auth.uid());

-- Allow stock update on rewards only for admins
create policy if not exists rewards_update_admin on public.rewards
for update
using (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
)
with check (
  exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- If you want users to redeem (decrement stock) via RPC, you may need to allow update for all, but restrict via function logic.
-- Uncomment below if needed:
-- create policy if not exists rewards_update_any on public.rewards
-- for update
-- using (true)
-- with check (true);

-- Make sure RLS is enabled on all relevant tables
alter table public.reward_claims enable row level security;
alter table public.profiles enable row level security;
alter table public.rewards enable row level security;
