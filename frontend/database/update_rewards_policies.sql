-- Supabase Rewards Table Policy Update
-- Run this SQL in Supabase SQL editor or psql

-- Remove old policies if needed
DROP POLICY IF EXISTS rewards_full_access ON public.rewards;
DROP POLICY IF EXISTS rewards_read_all ON public.rewards;
DROP POLICY IF EXISTS rewards_write_admin ON public.rewards;

-- Create a new permissive policy for all actions (testing)
CREATE POLICY rewards_full_access ON public.rewards
    FOR ALL
    USING (true)
    WITH CHECK (true);

-- (Optional) For production, restrict write access to admins only:
-- CREATE POLICY rewards_write_admin ON public.rewards
--     FOR INSERT, UPDATE, DELETE
--     TO authenticated
--     USING (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin'))
--     WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin'));

-- Enable RLS if not already enabled
ALTER TABLE public.rewards ENABLE ROW LEVEL SECURITY;

-- Now your frontend should be able to add items to the rewards table.
