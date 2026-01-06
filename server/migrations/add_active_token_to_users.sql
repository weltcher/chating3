-- Add active_token field for single device login restriction
-- Only allow one device to login at the same time, whether mobile or PC

-- Add active_token field to store current valid token
ALTER TABLE users ADD COLUMN IF NOT EXISTS active_token TEXT;

-- Add token_updated_at field to record token update time
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_updated_at TIMESTAMP WITH TIME ZONE;

-- Create index to accelerate token queries
CREATE INDEX IF NOT EXISTS idx_users_active_token ON users(active_token);

-- Add comments
COMMENT ON COLUMN users.active_token IS 'Current valid login token for single device login restriction';
COMMENT ON COLUMN users.token_updated_at IS 'Token update timestamp';
