-- 修改 message_type 字段长度，支持更长的消息类型名称
-- 例如: group_video_call_initiated (24字符)

-- 修改 group_messages 表
ALTER TABLE group_messages 
ALTER COLUMN message_type TYPE character varying(50);

-- 修改 messages 表
ALTER TABLE messages 
ALTER COLUMN message_type TYPE character varying(50);

-- 修改 favorites 表
ALTER TABLE favorites 
ALTER COLUMN message_type TYPE character varying(50);

-- 修改 file_assistant_messages 表
ALTER TABLE file_assistant_messages 
ALTER COLUMN message_type TYPE character varying(50);
