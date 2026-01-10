package services

import (
	"encoding/json"
	"sync"
	"time"

	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/utils"
	ws "youdu-server/websocket"
)

// ScheduledMessageService 定时消息服务
type ScheduledMessageService struct {
	hub      *ws.Hub
	repo     *models.ScheduledMessageRepository
	userRepo *models.UserRepository
	groupRepo *models.GroupRepository
}

// NewScheduledMessageService 创建定时消息服务
func NewScheduledMessageService(hub *ws.Hub) *ScheduledMessageService {
	return &ScheduledMessageService{
		hub:      hub,
		repo:     models.NewScheduledMessageRepository(db.DB),
		userRepo: models.NewUserRepository(db.DB),
		groupRepo: models.NewGroupRepository(db.DB),
	}
}

// StartScheduler 启动定时任务调度器
func (s *ScheduledMessageService) StartScheduler() {
	utils.LogInfo("✅ 定时消息调度器已启动")
	
	go func() {
		for {
			// 计算到下一分钟0秒的时间
			now := time.Now()
			nextMinute := now.Truncate(time.Minute).Add(time.Minute)
			sleepDuration := nextMinute.Sub(now)
			
			// 等待到下一分钟0秒
			time.Sleep(sleepDuration)
			
			// 执行定时任务
			s.executeScheduledMessages()
		}
	}()
}

// executeScheduledMessages 执行定时消息发送
func (s *ScheduledMessageService) executeScheduledMessages() {
	// 获取当前时间（HH:MM格式）
	currentTime := time.Now().Format("15:04")
	utils.LogDebug("⏰ [定时消息] 开始执行定时任务，当前时间: %s", currentTime)
	
	// 查询待发送的消息
	messages, err := s.repo.GetPendingMessages(currentTime)
	if err != nil {
		utils.LogDebug("❌ [定时消息] 查询待发送消息失败: %v", err)
		return
	}
	
	if len(messages) == 0 {
		utils.LogDebug("📭 [定时消息] 当前时间没有待发送的消息")
		return
	}
	
	utils.LogDebug("📬 [定时消息] 找到 %d 条待发送消息", len(messages))
	
	// 并发发送消息
	var wg sync.WaitGroup
	for _, msg := range messages {
		wg.Add(1)
		go func(m *models.ScheduledMessage) {
			defer wg.Done()
			s.sendMessage(m)
		}(msg)
	}
	wg.Wait()
	
	utils.LogDebug("✅ [定时消息] 本轮定时任务执行完成")
}

// sendMessage 发送单条定时消息
func (s *ScheduledMessageService) sendMessage(msg *models.ScheduledMessage) {
	utils.LogDebug("📤 [定时消息] 开始发送消息 - ID: %d, 发送者: %d, 接收者: %d, 类型: %s", 
		msg.ID, msg.SenderID, msg.ReceiverID, msg.MessageType)
	
	var err error
	if msg.MessageType == models.ScheduledMessageTypePrivate {
		err = s.sendPrivateMessage(msg)
	} else {
		err = s.sendGroupMessage(msg)
	}
	
	if err != nil {
		utils.LogDebug("❌ [定时消息] 发送失败 - ID: %d, 错误: %v", msg.ID, err)
		return
	}
	
	// 如果是单次任务，标记为已发送
	if msg.SendType == models.ScheduledMessageSendTypeOnce {
		if err := s.repo.MarkAsSent(msg.ID); err != nil {
			utils.LogDebug("❌ [定时消息] 标记已发送失败 - ID: %d, 错误: %v", msg.ID, err)
		} else {
			utils.LogDebug("✅ [定时消息] 单次任务已标记为已发送 - ID: %d", msg.ID)
		}
	} else {
		utils.LogDebug("🔄 [定时消息] 每日任务保持待发送状态 - ID: %d", msg.ID)
	}
}

// sendPrivateMessage 发送私聊消息
func (s *ScheduledMessageService) sendPrivateMessage(msg *models.ScheduledMessage) error {
	// 获取发送者信息
	sender, err := s.userRepo.FindByID(msg.SenderID)
	if err != nil {
		return err
	}
	
	// 获取接收者信息
	receiver, err := s.userRepo.FindByID(msg.ReceiverID)
	if err != nil {
		return err
	}
	
	// 保存消息到数据库
	query := `
		INSERT INTO messages (sender_id, receiver_id, sender_name, receiver_name, sender_avatar, receiver_avatar, content, message_type, status, is_read, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, 'text', 'normal', false, $8)
		RETURNING id, created_at
	`
	
	var messageID int
	var createdAt time.Time
	senderName := sender.Username
	if sender.FullName != nil && *sender.FullName != "" {
		senderName = *sender.FullName
	}
	receiverName := receiver.Username
	if receiver.FullName != nil && *receiver.FullName != "" {
		receiverName = *receiver.FullName
	}
	
	err = db.DB.QueryRow(
		query,
		msg.SenderID,
		msg.ReceiverID,
		senderName,
		receiverName,
		sender.Avatar,
		receiver.Avatar,
		msg.Content,
		time.Now().UTC(),
	).Scan(&messageID, &createdAt)
	
	if err != nil {
		return err
	}
	
	// 构造WebSocket消息
	wsMsg := models.WSMessage{
		Type: "message",
		Data: models.WSMessageData{
			ID:           messageID,
			SenderID:     msg.SenderID,
			ReceiverID:   msg.ReceiverID,
			SenderName:   senderName,
			ReceiverName: receiverName,
			SenderAvatar: &sender.Avatar,
			ReceiverAvatar: &receiver.Avatar,
			Content:      msg.Content,
			MessageType:  "text",
			IsRead:       false,
			CreatedAt:    createdAt.UTC(),
		},
	}
	
	msgBytes, err := json.Marshal(wsMsg)
	if err != nil {
		return err
	}
	
	// 发送给接收者
	s.hub.SendToUser(msg.ReceiverID, msgBytes)
	
	utils.LogDebug("✅ [定时消息] 私聊消息发送成功 - MessageID: %d, 发送者: %s, 接收者: %s", 
		messageID, senderName, receiverName)
	
	return nil
}

// sendGroupMessage 发送群聊消息
func (s *ScheduledMessageService) sendGroupMessage(msg *models.ScheduledMessage) error {
	// 获取发送者信息
	sender, err := s.userRepo.FindByID(msg.SenderID)
	if err != nil {
		return err
	}
	
	// 获取发送者在群组中的昵称
	senderName := sender.Username
	if sender.FullName != nil && *sender.FullName != "" {
		senderName = *sender.FullName
	}
	
	// 尝试获取群昵称
	nickname, fullName, _, _, err := s.groupRepo.GetGroupMemberInfo(msg.ReceiverID, msg.SenderID)
	if err == nil {
		if nickname != nil && *nickname != "" {
			senderName = *nickname
		} else if fullName != nil && *fullName != "" {
			senderName = *fullName
		}
	}
	
	// 保存消息到数据库
	query := `
		INSERT INTO group_messages (group_id, sender_id, sender_name, sender_avatar, content, message_type, created_at)
		VALUES ($1, $2, $3, $4, $5, 'text', $6)
		RETURNING id, created_at
	`
	
	var messageID int
	var createdAt time.Time
	
	err = db.DB.QueryRow(
		query,
		msg.ReceiverID,
		msg.SenderID,
		senderName,
		sender.Avatar,
		msg.Content,
		time.Now().UTC(),
	).Scan(&messageID, &createdAt)
	
	if err != nil {
		return err
	}
	
	// 获取群组所有成员ID
	memberIDs, err := s.groupRepo.GetGroupMemberIDs(msg.ReceiverID)
	if err != nil {
		return err
	}
	
	// 构造WebSocket消息
	wsGroupMsg := map[string]interface{}{
		"type":     "group_message",
		"group_id": msg.ReceiverID,
		"data": map[string]interface{}{
			"id":           messageID,
			"group_id":     msg.ReceiverID,
			"sender_id":    msg.SenderID,
			"sender_name":  senderName,
			"sender_avatar": sender.Avatar,
			"content":      msg.Content,
			"message_type": "text",
			"is_read":      false,
			"created_at":   createdAt.UTC().Format(time.RFC3339Nano),
		},
	}
	
	msgBytes, err := json.Marshal(wsGroupMsg)
	if err != nil {
		return err
	}
	
	// 向所有群组成员发送消息（不包括发送者自己）
	sentCount := 0
	for _, memberID := range memberIDs {
		if memberID != msg.SenderID {
			if s.hub.SendToUser(memberID, msgBytes) {
				sentCount++
			}
		}
	}
	
	utils.LogDebug("✅ [定时消息] 群聊消息发送成功 - MessageID: %d, GroupID: %d, 发送者: %s, 在线接收者: %d", 
		messageID, msg.ReceiverID, senderName, sentCount)
	
	return nil
}
