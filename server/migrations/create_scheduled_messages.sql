-- 创建定时消息表
CREATE TABLE IF NOT EXISTS scheduled_messages (
    id SERIAL PRIMARY KEY,
    sender_id INTEGER NOT NULL,                          -- 发送人ID
    receiver_id INTEGER NOT NULL,                        -- 接收人ID（私聊为用户ID，群聊为群组ID）
    message_type VARCHAR(20) NOT NULL DEFAULT 'private', -- 类型：private/group
    title VARCHAR(100) NOT NULL,                         -- 任务标题
    send_time VARCHAR(5) NOT NULL,                       -- 发送时间（HH:MM格式）
    send_type VARCHAR(20) NOT NULL DEFAULT 'once',       -- 发送类型：once/daily
    content TEXT NOT NULL,                               -- 消息内容（最多1000字）
    status VARCHAR(20) NOT NULL DEFAULT 'pending',       -- 任务状态：pending/sent/deleted
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_sender_id ON scheduled_messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_receiver_id ON scheduled_messages(receiver_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_send_time ON scheduled_messages(send_time);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_status ON scheduled_messages(status);
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_sender_receiver ON scheduled_messages(sender_id, receiver_id, message_type);

-- 添加外键约束（可选，如果users表存在）
-- ALTER TABLE scheduled_messages ADD CONSTRAINT fk_scheduled_messages_sender FOREIGN KEY (sender_id) REFERENCES users(id);

COMMENT ON TABLE scheduled_messages IS '定时消息表';
COMMENT ON COLUMN scheduled_messages.id IS '主键ID';
COMMENT ON COLUMN scheduled_messages.sender_id IS '发送人ID';
COMMENT ON COLUMN scheduled_messages.receiver_id IS '接收人ID（私聊为用户ID，群聊为群组ID）';
COMMENT ON COLUMN scheduled_messages.message_type IS '类型：private-私聊，group-群聊';
COMMENT ON COLUMN scheduled_messages.title IS '任务标题';
COMMENT ON COLUMN scheduled_messages.send_time IS '发送时间（HH:MM格式）';
COMMENT ON COLUMN scheduled_messages.send_type IS '发送类型：once-单次，daily-每日';
COMMENT ON COLUMN scheduled_messages.content IS '消息内容（最多1000字）';
COMMENT ON COLUMN scheduled_messages.status IS '任务状态：pending-待发送，sent-已发送，deleted-已删除';
COMMENT ON COLUMN scheduled_messages.created_at IS '创建时间';
COMMENT ON COLUMN scheduled_messages.updated_at IS '更新时间';
