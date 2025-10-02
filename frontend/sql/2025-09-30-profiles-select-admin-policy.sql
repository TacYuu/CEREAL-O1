-- Enable admin SELECT access to all profiles
-- Add this policy to allow users in the admins table to read all profiles

create policy profiles_select_admin on public.profiles
for select
using (
  EXISTS (
    SELECT 1 FROM admins a WHERE a.user_id = auth.uid()
  )
);

-- Optionally, combine with self-access in one policy:
-- create policy profiles_select_self_or_admin on public.profiles
-- for select
-- using (
--   id = auth.uid() OR EXISTS (
--     SELECT 1 FROM admins a WHERE a.user_id = auth.uid()
--   )
-- );

-- After running, reload your admin dashboard to verify all users are visible to admins.
