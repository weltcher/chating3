package models

import (
	"encoding/json"
	"time"
)

// Message 消息模型
type Message struct {
	ID                   int        `json:"id" db:"id"`
	SenderID             int        `json:"sender_id" db:"sender_id"`
	ReceiverID           int        `json:"receiver_id" db:"receiver_id"`
	SenderName           string     `json:"sender_name" db:"sender_name"`
	ReceiverName         string     `json:"receiver_name" db:"receiver_name"`
	SenderAvatar         *string    `json:"sender_avatar,omitempty" db:"sender_avatar"`     // 发送者头像
	ReceiverAvatar       *string    `json:"receiver_avatar,omitempty" db:"receiver_avatar"` // 接收者头像
	Content              string     `json:"content" db:"content"`
	MessageType          string     `json:"message_type" db:"message_type"`                               // text, image, file等
	FileName             *string    `json:"file_name,omitempty" db:"file_name"`                           // 文件名（用于file类型）
	QuotedMessageID      *int       `json:"quoted_message_id,omitempty" db:"quoted_message_id"`           // 被引用的消息ID
	QuotedMessageContent *string    `json:"quoted_message_content,omitempty" db:"quoted_message_content"` // 被引用的消息内容
	CallType             *string    `json:"call_type,omitempty" db:"call_type"`                           // 通话类型（voice/video，仅通话类型消息使用）
	VoiceDuration        *int       `json:"voice_duration,omitempty" db:"voice_duration"`                 // 语音消息时长（秒）
	Status               string     `json:"status" db:"status"`                                           // 消息状态：normal-正常, recalled-已撤回
	DeletedByUsers       string     `json:"deleted_by_users" db:"deleted_by_users"`                       // 删除该消息的用户ID列表（逗号分隔）
	IsRead               bool       `json:"is_read" db:"is_read"`
	CreatedAt            time.Time  `json:"-" db:"created_at"`                              // 🔴 不直接序列化，使用 MarshalJSON 方法
	ReadAt               *time.Time `json:"read_at,omitempty" db:"read_at"`
}

// MarshalJSON 自定义 JSON 序列化，确保 CreatedAt 使用 UTC 时间
func (m Message) MarshalJSON() ([]byte, error) {
	type Alias Message
	return json.Marshal(&struct {
		Alias
		CreatedAt string `json:"created_at"`
	}{
		Alias:     Alias(m),
		CreatedAt: m.CreatedAt.UTC().Format(time.RFC3339Nano),
	})
}

// CreateMessageRequest 创建消息请求
type CreateMessageRequest struct {
	ReceiverID           int    `json:"receiver_id" binding:"required"`
	Content              string `json:"content" binding:"required"`
	MessageType          string `json:"message_type"`
	FileName             string `json:"file_name,omitempty"`
	QuotedMessageID      int    `json:"quoted_message_id,omitempty"`
	QuotedMessageContent string `json:"quoted_message_content,omitempty"`
	CallType             string `json:"call_type,omitempty"`
	VoiceDuration        int    `json:"voice_duration,omitempty"`
}

// WSMessage WebSocket消息格式
type WSMessage struct {
	Type       string      `json:"type"` // message, read_receipt, typing等
	Data       interface{} `json:"data"`
	ReceiverID int         `json:"receiver_id,omitempty"`
}

// WSMessageData WebSocket消息数据
type WSMessageData struct {
	ID                   int       `json:"id"`
	SenderID             int       `json:"sender_id"`
	ReceiverID           int       `json:"receiver_id"`
	SenderName           string    `json:"sender_name"`
	ReceiverName         string    `json:"receiver_name"`
	SenderAvatar         *string   `json:"sender_avatar,omitempty"`
	ReceiverAvatar       *string   `json:"receiver_avatar,omitempty"`
	Content              string    `json:"content"`
	MessageType          string    `json:"message_type"`
	FileName             *string   `json:"file_name,omitempty"`
	QuotedMessageID      *int      `json:"quoted_message_id,omitempty"`
	QuotedMessageContent *string   `json:"quoted_message_content,omitempty"`
	CallType             *string   `json:"call_type,omitempty"`
	VoiceDuration        *int      `json:"voice_duration,omitempty"`
	IsRead               bool      `json:"is_read"`
	CreatedAt            time.Time `json:"-"` // 🔴 不直接序列化，使用 MarshalJSON 方法
}

// MarshalJSON 自定义 JSON 序列化，确保 CreatedAt 使用 UTC 时间格式
func (m WSMessageData) MarshalJSON() ([]byte, error) {
	type Alias WSMessageData
	return json.Marshal(&struct {
		Alias
		CreatedAt string `json:"created_at"`
	}{
		Alias:     Alias(m),
		CreatedAt: m.CreatedAt.UTC().Format(time.RFC3339Nano),
	})
}

// MarkReadRequest 标记消息已读请求
type MarkReadRequest struct {
	SenderID int `json:"sender_id" binding:"required"` // 消息发送者ID，用于标记与该用户的所有未读消息
}
