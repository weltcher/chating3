-- Add send_date column to scheduled_messages table
-- This column is used for once-type scheduled messages to specify the exact date

-- Add the column if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'scheduled_messages' AND column_name = 'send_date'
    ) THEN
        ALTER TABLE scheduled_messages ADD COLUMN send_date VARCHAR(10);
        
        -- Create index for send_date
        CREATE INDEX IF NOT EXISTS idx_scheduled_messages_send_date ON scheduled_messages(send_date);
        
        -- Add comment
        COMMENT ON COLUMN scheduled_messages.send_date IS 'Send date (YYYY-MM-DD format, for once type only)';
        
        RAISE NOTICE 'Column send_date added successfully';
    ELSE
        RAISE NOTICE 'Column send_date already exists';
    END IF;
END $$;
