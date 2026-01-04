-- Add is_overseas field to users table
-- 0: domestic user, 1: overseas user
-- Default value is 1 (overseas user)
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS is_overseas smallint DEFAULT 1;

-- Add field comment
COMMENT ON COLUMN public.users.is_overseas IS 'Whether overseas user: 0-domestic, 1-overseas, default 1';
