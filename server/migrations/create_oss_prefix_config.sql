-- Create OSS prefix domain configuration table
CREATE TABLE IF NOT EXISTS oss_prefix_config (
    id SERIAL PRIMARY KEY,
    old_prefix_domain VARCHAR(255) NOT NULL,             -- Old OSS prefix domain (e.g., https://xn--wxtp0q.cc)
    new_prefix_domain VARCHAR(255) NOT NULL,             -- New OSS prefix domain (e.g., https://yoududown.cc)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Insert default configuration (only one record needed)
INSERT INTO oss_prefix_config (old_prefix_domain, new_prefix_domain)
VALUES ('https://xn--wxtp0q.cc', 'https://yoududown.cc')
ON CONFLICT DO NOTHING;

COMMENT ON TABLE oss_prefix_config IS 'OSS prefix domain configuration table';
COMMENT ON COLUMN oss_prefix_config.id IS 'Primary key ID';
COMMENT ON COLUMN oss_prefix_config.old_prefix_domain IS 'Old OSS prefix domain';
COMMENT ON COLUMN oss_prefix_config.new_prefix_domain IS 'New OSS prefix domain';
COMMENT ON COLUMN oss_prefix_config.created_at IS 'Created time';
COMMENT ON COLUMN oss_prefix_config.updated_at IS 'Updated time';
