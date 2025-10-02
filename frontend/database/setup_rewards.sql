-- Supabase Rewards Table Setup
-- Run this SQL in Supabase SQL editor or psql

-- 1. Create the rewards table
CREATE TABLE IF NOT EXISTS public.rewards (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text NOT NULL,
    description text,
    cost integer NOT NULL,
    stock integer NOT NULL DEFAULT 0,
    active boolean NOT NULL DEFAULT true,
    category_id uuid
);

-- 2. Enable Row Level Security
ALTER TABLE public.rewards ENABLE ROW LEVEL SECURITY;

-- 3. Permissive RLS policy for testing (allow all inserts/updates/deletes)
CREATE POLICY rewards_full_access ON public.rewards
    FOR ALL
    USING (true)
    WITH CHECK (true);

-- 4. Grant permissions to authenticated users (for frontend)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.rewards TO authenticated;

-- 5. (Optional) Grant permissions to service_role for backend/admin
GRANT ALL ON public.rewards TO service_role;

-- 6. (Optional) Add example item
INSERT INTO public.rewards (name, description, cost, stock, active)
VALUES ('Sample Item', 'This is a test item', 100, 50, true);

-- Now your frontend should be able to add items to the rewards table.
