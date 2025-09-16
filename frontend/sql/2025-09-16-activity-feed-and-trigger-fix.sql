-- Migration: Unified activity feed + trigger fix + RFID column
-- Safe to run multiple times
begin;

-- 1) Ensure RFID column exists for unified Users/Enrollment UI
alter table public.profiles add column if not exists rfid_uid text;

-- 2) Idempotent updated_at trigger on profiles
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

-- Drop/recreate trigger to avoid "already exists"
drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- 3) Unified activity feed RPC (logs + point_transactions + reward_claims + recycling_logs)
create or replace function public.activity_feed(limit_count integer default 20)
returns table(
  created_at timestamptz,
  action_type text,
  message text
) language sql security definer set search_path = public as $$
  with
  l as (
    select created_at, action_type, message from public.logs
  ),
  t as (
    select created_at, 'Points'::text as action_type,
           case when amount >= 0 then concat('+', amount, ' pts') else concat(amount, ' pts') end as message
    from public.point_transactions
  ),
  c as (
    select created_at, 'Reward Redeemed'::text as action_type,
           concat('Redeemed reward #', reward_id, ' for ', cost, ' pts') as message
    from public.reward_claims
  ),
  r as (
    select created_at, 'Recycle'::text as action_type,
           concat('+', points_awarded, ' pts for recycling ', material, ' x', quantity) as message
    from public.recycling_logs
  )
  select * from (
    select * from l
    union all
    select * from t
    union all
    select * from c
    union all
    select * from r
  ) all_events
  order by created_at desc
  limit greatest(1, limit_count);
$$;

-- Optional: allow clients to execute the RPC
grant execute on function public.activity_feed(integer) to anon, authenticated;

commit;