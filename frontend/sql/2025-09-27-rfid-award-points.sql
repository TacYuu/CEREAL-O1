-- Seed initial users from Arduino sketch & provide RFID award RPC
-- Run after base schema (database.sql). Safe to re-run (idempotent inserts by rfid_uid uniqueness).

-- 1. Ensure rfid_uid column & uniqueness (already added earlier but add index/constraint)
create unique index if not exists profiles_rfid_uid_unique on public.profiles (rfid_uid) where rfid_uid is not null;

-- 2. Temporary staging table for initial Arduino users (does not require auth.users linkage yet)
create table if not exists public._arduino_user_seed (
  rfid_uid text primary key,
  display_name text not null,
  initial_points integer not null default 10
);

-- 3. Upsert Arduino seed data (from sketch)
insert into public._arduino_user_seed (rfid_uid, display_name, initial_points) values
  ('f382825', 'Rein Moratalla', 10),
  ('f3dddf19', 'Asley Masujer', 10),
  ('235bf519', 'Danah Camba', 10)
  on conflict (rfid_uid) do update set display_name = excluded.display_name;

-- 4. Helper view to see which seeds are linked to real auth users (by rfid_uid)
create or replace view public.rfid_seed_link_status as
select s.rfid_uid, s.display_name, p.id as profile_id, p.email, p.points
from public._arduino_user_seed s
left join public.profiles p on p.rfid_uid = s.rfid_uid;

-- 5. After you manually create auth users and know their UUID + email, link RFID:
-- Example (adjust uuid & email):
-- update public.profiles set rfid_uid = 'f382825' where id = '00000000-0000-0000-0000-000000000000';
-- update public.profiles set rfid_uid = 'f3dddf19' where id = '11111111-1111-1111-1111-111111111111';
-- update public.profiles set rfid_uid = '235bf519' where id = '22222222-2222-2222-2222-222222222222';

-- 6. RFID award function: called by device backend (SECURITY DEFINER). Adds points & logs transaction.
--    Uses rfid_uid only (no auth context) and a shared secret to prevent abuse.

create or replace function public.device_award_points(
  in_rfid_uid text,
  in_points integer,
  in_reason text default 'device_award',
  in_device_secret text default null
) returns jsonb
language plpgsql
security definer
set search_path = public as $$
declare
  profile_id uuid;
  new_points integer;
  device_secret_constant text := current_setting('app.device_secret', true); -- configure via ALTER DATABASE ... SET
begin
  if in_points = 0 then
    return jsonb_build_object('status','noop','message','points is zero');
  end if;
  if in_points > 100 or in_points < -100 then
    raise exception 'Point delta out of safe range';
  end if;
  if device_secret_constant is null then
    raise exception 'Device secret not configured (app.device_secret)';
  end if;
  if in_device_secret is distinct from device_secret_constant then
    raise exception 'Invalid device secret';
  end if;

  select id into profile_id from public.profiles where rfid_uid = in_rfid_uid;
  if profile_id is null then
    return jsonb_build_object('status','error','message','Unknown RFID UID');
  end if;

  update public.profiles set points = points + in_points where id = profile_id returning points into new_points;
  insert into public.point_transactions(user_id, amount, type, metadata)
    values (profile_id, in_points, 'rfid_award', jsonb_build_object('reason', in_reason, 'rfid_uid', in_rfid_uid));
  insert into public.logs(user_id, action_type, message)
    values (profile_id, 'RFID Award', concat(case when in_points >= 0 then '+' else '' end, in_points, ' pts via RFID (', in_reason, ')'));

  return jsonb_build_object('status','ok','profile_id', profile_id, 'new_points', new_points);
end; $$;

-- 7. Security policy: allow only service role or admins to call? Function is SECURITY DEFINER; restrict via RLS + revoke.
-- Revoke public execute then grant only to service role. In Supabase SQL Editor you can do:
-- revoke execute on function public.device_award_points(text, integer, text, text) from public;
-- grant execute on function public.device_award_points(text, integer, text, text) to service_role;

-- 8. Configure device secret (choose a strong random string):
-- alter database postgres set app.device_secret = 'YOUR_LONG_RANDOM_SECRET_HERE';
-- (Or per session: select set_config('app.device_secret','YOUR_LONG_RANDOM_SECRET_HERE', false);)

-- 9. Example call:
-- select public.device_award_points('f382825', 5, 'recycle_drop', 'YOUR_LONG_RANDOM_SECRET_HERE');

-- 10. OPTIONAL: initial points sync
-- After linking RFID to profiles, if you want to ensure starting points at least the seed value:
-- update public.profiles p
--   set points = greatest(p.points, s.initial_points)
-- from public._arduino_user_seed s
-- where p.rfid_uid = s.rfid_uid;
