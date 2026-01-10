-- Create scheduled messages table
CREATE TABLE IF NOT EXISTS scheduled_messages (
    id SERIAL PRIMARY KEY,
    sender_id INTEGER NOT NULL,                          -- Sender ID
    receiver_id INTEGER NOT NULL,                        -- Receiver ID (user ID for private chat, group ID for group chat)
    message_type VARCHAR(20) NOT NULL DEFAULT 'private', -- Type: private/group
    title VARCHAR(100) NOT NULL,                         -- Task title
    send_time VARCHAR(5) NOT NULL,                       -- Send time (HH:MM format)
    send_date VARCHAR(10),                               -- Send date (YYYY-MM-DD format, for once type only)
    send_type VARCHAR(20) NOT NULL DEFAULT 'once',       -- Send type: once/daily
    content TEXT NOT NULL,                               -- Message content (max 1000 characters)
    status VARCHAR(20) NOT NULL DEFAULT 'pending',       -- Task status: pending/sent/deleted
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_sender_id ON scheduled_messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_receiver_id ON scheduled_messages(receiver_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_send_time ON scheduled_messages(send_time);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_send_date ON scheduled_messages(send_date);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_status ON scheduled_messages(status);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_sender_receiver ON scheduled_messages(sender_id, receiver_id, message_type);

-- Add foreign key constraints (optional, if users table exists)
-- ALTER TABLE scheduled_messages ADD CONSTRAINT fk_scheduled_messages_sender FOREIGN KEY (sender_id) REFERENCES users(id);

COMMENT ON TABLE scheduled_messages IS 'Scheduled messages table';
COMMENT ON COLUMN scheduled_messages.id IS 'Primary key ID';
COMMENT ON COLUMN scheduled_messages.sender_id IS 'Sender ID';
COMMENT ON COLUMN scheduled_messages.receiver_id IS 'Receiver ID (user ID for private chat, group ID for group chat)';
COMMENT ON COLUMN scheduled_messages.message_type IS 'Type: private-private chat, group-group chat';
COMMENT ON COLUMN scheduled_messages.title IS 'Task title';
COMMENT ON COLUMN scheduled_messages.send_time IS 'Send time (HH:MM format)';
COMMENT ON COLUMN scheduled_messages.send_date IS 'Send date (YYYY-MM-DD format, for once type only)';
COMMENT ON COLUMN scheduled_messages.send_type IS 'Send type: once-single time, daily-daily';
COMMENT ON COLUMN scheduled_messages.content IS 'Message content (max 1000 characters)';
COMMENT ON COLUMN scheduled_messages.status IS 'Task status: pending-pending, sent-sent, deleted-deleted';
COMMENT ON COLUMN scheduled_messages.created_at IS 'Created time';
COMMENT ON COLUMN scheduled_messages.updated_at IS 'Updated time';
