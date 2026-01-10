package models

import (
	"database/sql"
	"time"

	"youdu-server/db"
)

// ScheduledMessageType 定时消息类型
type ScheduledMessageType string

const (
	ScheduledMessageTypePrivate ScheduledMessageType = "private" // 私聊
	ScheduledMessageTypeGroup   ScheduledMessageType = "group"   // 群聊
)

// ScheduledMessageSendType 发送类型
type ScheduledMessageSendType string

const (
	ScheduledMessageSendTypeOnce  ScheduledMessageSendType = "once"  // 单次
	ScheduledMessageSendTypeDaily ScheduledMessageSendType = "daily" // 每日
)

// ScheduledMessageStatus 任务状态
type ScheduledMessageStatus string

const (
	ScheduledMessageStatusPending ScheduledMessageStatus = "pending" // 待发送
	ScheduledMessageStatusSent    ScheduledMessageStatus = "sent"    // 已发送
	ScheduledMessageStatusDeleted ScheduledMessageStatus = "deleted" // 已删除
)

// ScheduledMessage 定时消息模型
type ScheduledMessage struct {
	ID          int                      `json:"id" db:"id"`
	SenderID    int                      `json:"sender_id" db:"sender_id"`       // 发送人ID
	ReceiverID  int                      `json:"receiver_id" db:"receiver_id"`   // 接收人ID（私聊为用户ID，群聊为群组ID）
	MessageType ScheduledMessageType     `json:"message_type" db:"message_type"` // 类型：private/group
	Title       string                   `json:"title" db:"title"`               // 任务标题
	SendTime    string                   `json:"send_time" db:"send_time"`       // 发送时间（HH:MM格式）
	SendType    ScheduledMessageSendType `json:"send_type" db:"send_type"`       // 发送类型：once/daily
	Content     string                   `json:"content" db:"content"`           // 消息内容（最多1000字）
	Status      ScheduledMessageStatus   `json:"status" db:"status"`             // 任务状态
	CreatedAt   time.Time                `json:"created_at" db:"created_at"`     // 创建时间
	UpdatedAt   time.Time                `json:"updated_at" db:"updated_at"`     // 更新时间
}

// CreateScheduledMessageRequest 创建定时消息请求
type CreateScheduledMessageRequest struct {
	ReceiverID  int                      `json:"receiver_id" binding:"required"`
	MessageType ScheduledMessageType     `json:"message_type" binding:"required"`
	Title       string                   `json:"title" binding:"required,max=100"`
	SendTime    string                   `json:"send_time" binding:"required"` // HH:MM格式
	SendType    ScheduledMessageSendType `json:"send_type" binding:"required"`
	Content     string                   `json:"content" binding:"required,max=1000"`
}

// UpdateScheduledMessageRequest 更新定时消息请求
type UpdateScheduledMessageRequest struct {
	Title    string                   `json:"title" binding:"required,max=100"`
	SendTime string                   `json:"send_time" binding:"required"` // HH:MM格式
	SendType ScheduledMessageSendType `json:"send_type" binding:"required"`
	Content  string                   `json:"content" binding:"required,max=1000"`
}

// ScheduledMessageRepository 定时消息仓库
type ScheduledMessageRepository struct {
	db *sql.DB
}

// NewScheduledMessageRepository 创建定时消息仓库
func NewScheduledMessageRepository(database *sql.DB) *ScheduledMessageRepository {
	return &ScheduledMessageRepository{db: database}
}

// Create 创建定时消息
func (r *ScheduledMessageRepository) Create(senderID int, req *CreateScheduledMessageRequest) (*ScheduledMessage, error) {
	query := `
		INSERT INTO scheduled_messages (sender_id, receiver_id, message_type, title, send_time, send_type, content, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		RETURNING id, sender_id, receiver_id, message_type, title, send_time, send_type, content, status, created_at, updated_at
	`
	now := time.Now()
	msg := &ScheduledMessage{}
	err := r.db.QueryRow(
		query,
		senderID,
		req.ReceiverID,
		req.MessageType,
		req.Title,
		req.SendTime,
		req.SendType,
		req.Content,
		ScheduledMessageStatusPending,
		now,
		now,
	).Scan(
		&msg.ID,
		&msg.SenderID,
		&msg.ReceiverID,
		&msg.MessageType,
		&msg.Title,
		&msg.SendTime,
		&msg.SendType,
		&msg.Content,
		&msg.Status,
		&msg.CreatedAt,
		&msg.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return msg, nil
}

// Update 更新定时消息
func (r *ScheduledMessageRepository) Update(id, senderID int, req *UpdateScheduledMessageRequest) (*ScheduledMessage, error) {
	query := `
		UPDATE scheduled_messages
		SET title = $1, send_time = $2, send_type = $3, content = $4, updated_at = $5
		WHERE id = $6 AND sender_id = $7 AND status = $8
		RETURNING id, sender_id, receiver_id, message_type, title, send_time, send_type, content, status, created_at, updated_at
	`
	msg := &ScheduledMessage{}
	err := r.db.QueryRow(
		query,
		req.Title,
		req.SendTime,
		req.SendType,
		req.Content,
		time.Now(),
		id,
		senderID,
		ScheduledMessageStatusPending,
	).Scan(
		&msg.ID,
		&msg.SenderID,
		&msg.ReceiverID,
		&msg.MessageType,
		&msg.Title,
		&msg.SendTime,
		&msg.SendType,
		&msg.Content,
		&msg.Status,
		&msg.CreatedAt,
		&msg.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return msg, nil
}

// Delete 删除定时消息（软删除）
func (r *ScheduledMessageRepository) Delete(id, senderID int) error {
	query := `
		UPDATE scheduled_messages
		SET status = $1, updated_at = $2
		WHERE id = $3 AND sender_id = $4 AND status = $5
	`
	result, err := r.db.Exec(query, ScheduledMessageStatusDeleted, time.Now(), id, senderID, ScheduledMessageStatusPending)
	if err != nil {
		return err
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rowsAffected == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// GetByID 根据ID获取定时消息
func (r *ScheduledMessageRepository) GetByID(id, senderID int) (*ScheduledMessage, error) {
	query := `
		SELECT id, sender_id, receiver_id, message_type, title, send_time, send_type, content, status, created_at, updated_at
		FROM scheduled_messages
		WHERE id = $1 AND sender_id = $2 AND status != $3
	`
	msg := &ScheduledMessage{}
	err := r.db.QueryRow(query, id, senderID, ScheduledMessageStatusDeleted).Scan(
		&msg.ID,
		&msg.SenderID,
		&msg.ReceiverID,
		&msg.MessageType,
		&msg.Title,
		&msg.SendTime,
		&msg.SendType,
		&msg.Content,
		&msg.Status,
		&msg.CreatedAt,
		&msg.UpdatedAt,
	)
	if err != nil {
		return nil, err
	}
	return msg, nil
}

// GetListByReceiver 获取指定接收者的定时消息列表
func (r *ScheduledMessageRepository) GetListByReceiver(senderID, receiverID int, messageType ScheduledMessageType) ([]*ScheduledMessage, error) {
	query := `
		SELECT id, sender_id, receiver_id, message_type, title, send_time, send_type, content, status, created_at, updated_at
		FROM scheduled_messages
		WHERE sender_id = $1 AND receiver_id = $2 AND message_type = $3 AND status != $4
		ORDER BY created_at DESC
	`
	rows, err := r.db.Query(query, senderID, receiverID, messageType, ScheduledMessageStatusDeleted)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []*ScheduledMessage
	for rows.Next() {
		msg := &ScheduledMessage{}
		err := rows.Scan(
			&msg.ID,
			&msg.SenderID,
			&msg.ReceiverID,
			&msg.MessageType,
			&msg.Title,
			&msg.SendTime,
			&msg.SendType,
			&msg.Content,
			&msg.Status,
			&msg.CreatedAt,
			&msg.UpdatedAt,
		)
		if err != nil {
			return nil, err
		}
		messages = append(messages, msg)
	}
	return messages, nil
}

// GetPendingMessages 获取待发送的定时消息（当前时间匹配的）
func (r *ScheduledMessageRepository) GetPendingMessages(currentTime string) ([]*ScheduledMessage, error) {
	query := `
		SELECT id, sender_id, receiver_id, message_type, title, send_time, send_type, content, status, created_at, updated_at
		FROM scheduled_messages
		WHERE send_time = $1 AND status = $2
	`
	rows, err := r.db.Query(query, currentTime, ScheduledMessageStatusPending)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var messages []*ScheduledMessage
	for rows.Next() {
		msg := &ScheduledMessage{}
		err := rows.Scan(
			&msg.ID,
			&msg.SenderID,
			&msg.ReceiverID,
			&msg.MessageType,
			&msg.Title,
			&msg.SendTime,
			&msg.SendType,
			&msg.Content,
			&msg.Status,
			&msg.CreatedAt,
			&msg.UpdatedAt,
		)
		if err != nil {
			return nil, err
		}
		messages = append(messages, msg)
	}
	return messages, nil
}

// MarkAsSent 标记为已发送（单次任务）
func (r *ScheduledMessageRepository) MarkAsSent(id int) error {
	query := `
		UPDATE scheduled_messages
		SET status = $1, updated_at = $2
		WHERE id = $3
	`
	_, err := r.db.Exec(query, ScheduledMessageStatusSent, time.Now(), id)
	return err
}

// GetScheduledMessageRepository 获取定时消息仓库单例
func GetScheduledMessageRepository() *ScheduledMessageRepository {
	return NewScheduledMessageRepository(db.DB)
}
