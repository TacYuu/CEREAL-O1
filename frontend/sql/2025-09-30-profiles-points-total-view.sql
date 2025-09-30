-- View for total points across all profiles
create or replace view public.profiles_points_total as
select sum(points) as total_points from public.profiles;
