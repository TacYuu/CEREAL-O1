-- Migration: add RFID UID to profiles for unified Users/Enrollment UI
-- Safe to run multiple times
alter table public.profiles add column if not exists rfid_uid text;
