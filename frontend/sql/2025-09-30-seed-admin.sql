

-- Automatically seed all users with role 'admin' from profiles into admins table
insert into public.admins (user_id)
select id from public.profiles where role = 'admin'
on conflict (user_id) do nothing;


-- To allow all users to see all profiles, update the RLS policy:
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_all on public.profiles for select using (true);
