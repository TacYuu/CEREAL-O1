-- Device credential management and per-device award function (v2)
-- Creates a table mapping device_id -> secret hash, enabling revocation and auditing.

create table if not exists public.device_credentials (
  device_id text primary key,
  secret_hash text not null,
  active boolean not null default true,
  last_seen timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.touch_device(device_id text)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.device_credentials set last_seen = now(), updated_at = now() where device_id = touch_device.device_id;
end;$$;

-- Helper to store hash: use sha256(secret || ':' || device_id)
-- Example insertion (DO NOT commit actual secrets):
-- insert into public.device_credentials(device_id, secret_hash)
-- values ('DEVICE_A', encode(digest('raw_secret_here'||':'||'DEVICE_A','sha256'),'hex'))
-- on conflict (device_id) do update set secret_hash = excluded.secret_hash, active = true;

-- V2 function validating device_id + secret hash.
-- NOTE: You still should restrict EXECUTE to service role or a dedicated role.

create or replace function public.device_award_points_v2(
  in_rfid_uid text,
  in_points integer,
  in_reason text default 'device_award',
  in_device_id text,
  in_device_secret text
) returns jsonb
language plpgsql
security definer
set search_path = public as $$
declare
  profile_id uuid;
  new_points integer;
  stored_hash text;
  computed_hash text;
  max_abs_points integer := 100;
begin
  if in_points = 0 then
    return jsonb_build_object('status','noop','message','points is zero');
  end if;
  if abs(in_points) > max_abs_points then
    raise exception 'Point delta out of safe range (%%)', in_points;
  end if;
  select secret_hash into stored_hash from public.device_credentials
    where device_id = in_device_id and active = true;
  if stored_hash is null then
    return jsonb_build_object('status','error','message','Unknown or inactive device');
  end if;
  -- Compute hash the same way as inserted: sha256(secret || ':' || device_id)
  computed_hash := encode(digest(in_device_secret || ':' || in_device_id, 'sha256'),'hex');
  if computed_hash <> stored_hash then
    return jsonb_build_object('status','error','message','Invalid device secret');
  end if;

  select id into profile_id from public.profiles where rfid_uid = in_rfid_uid;
  if profile_id is null then
    return jsonb_build_object('status','error','message','Unknown RFID UID');
  end if;

  update public.profiles set points = points + in_points where id = profile_id returning points into new_points;
  insert into public.point_transactions(user_id, amount, type, metadata)
    values (profile_id, in_points, 'rfid_award', jsonb_build_object('reason', in_reason, 'rfid_uid', in_rfid_uid, 'device_id', in_device_id));
  insert into public.logs(user_id, action_type, message)
    values (profile_id, 'RFID Award', concat(case when in_points >= 0 then '+' else '' end, in_points, ' pts via ', in_device_id, ' (', in_reason, ')'));

  perform public.touch_device(in_device_id);

  return jsonb_build_object('status','ok','profile_id', profile_id, 'new_points', new_points, 'device', in_device_id);
end; $$;

-- Permissions (example):
-- revoke execute on function public.device_award_points_v2(text, integer, text, text, text) from public;
-- grant execute on function public.device_award_points_v2(text, integer, text, text, text) to service_role;

-- Example provisioning snippet (replace raw_secret_here):
-- \set dev_id 'DEVICE_A'
-- \set raw_secret 'RAW_DEVICE_A_SECRET'
-- insert into public.device_credentials(device_id, secret_hash)
-- values (:'dev_id', encode(digest(:'raw_secret'||':'||:'dev_id','sha256'),'hex'))
-- on conflict (device_id) do update set secret_hash = excluded.secret_hash, active = true;

-- Example call:
-- select public.device_award_points_v2('f382825',5,'recycle_drop','DEVICE_A','RAW_DEVICE_A_SECRET');
