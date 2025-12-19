package controllers

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"youdu-server/db"
	"youdu-server/models"
	"youdu-server/utils"
	ws "youdu-server/websocket"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true // 允许所有来源，生产环境应该限制
	},
}

// MessageController 消息控制器
type MessageController struct {
	Hub         *ws.Hub
	userRepo    *models.UserRepository
	contactRepo *models.ContactRepository
	groupRepo   *models.GroupRepository
}

// NewMessageController 创建消息控制器
func NewMessageController(hub *ws.Hub) *MessageController {
	mc := &MessageController{
		Hub:         hub,
		userRepo:    models.NewUserRepository(db.DB),
		contactRepo: models.NewContactRepository(db.DB),
		groupRepo:   models.NewGroupRepository(db.DB),
	}

	// 设置离线通知回调
	hub.OnUserOffline = mc.sendOfflineNotification

	return mc
}

// HandleWebSocket 处理WebSocket连接
func (mc *MessageController) HandleWebSocket(c *gin.Context) {
	// 从查询参数或header中获取token
	token := c.Query("token")
	if token == "" {
		token = c.GetHeader("Authorization")
	}

	if token == "" {
		utils.LogDebug("❌ [WebSocket] 未提供token")
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "未提供token"})
		return
	}

	// 验证token
	claims, err := utils.ParseToken(token)
	if err != nil {
		utils.LogDebug("❌ [WebSocket] token验证失败: %v, token: %s", err, token[:20]+"...")
		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "无效的token"})
		return
	}

	userID := claims.UserID
	utils.LogDebug("✅ [WebSocket] token验证成功 - UserID: %d", userID)

	// 升级HTTP连接为WebSocket
	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		utils.LogDebug("❌ [WebSocket] 升级失败: %v", err)
		return
	}
	utils.LogDebug("✅ [WebSocket] 连接升级成功 - UserID: %d", userID)

	// 创建客户端
	wsConn := ws.NewConn(conn)
	client := &ws.Client{
		UserID: userID,
		Conn:   wsConn,
		Send:   make(chan []byte, 256),
	}

	// 注册客户端
	mc.Hub.Register <- client

	// 发送离线消息
	go mc.sendOfflineMessages(client)

	// 发送上线通知给联系人
	go mc.sendOnlineNotification(client)

	// 启动读写协程
	go wsConn.WritePump(client, mc.Hub)
	go wsConn.ReadPump(client, mc.Hub, mc.handleMessage)
}

// handleMessage 处理接收到的消息
func (mc *MessageController) handleMessage(client *ws.Client, message []byte) {
	var wsMsg models.WSMessage
	if err := json.Unmarshal(message, &wsMsg); err != nil {
		utils.LogDebug("解析消息失败: %v", err)
		return
	}

	switch wsMsg.Type {
	case "message":
		// 处理私聊消息发送
		mc.handleSendMessage(client, wsMsg)
	case "group_message_send":
		// 处理群组消息发送
		mc.handleSendGroupMessage(client, wsMsg)
	case "read_receipt":
		// 处理已读回执
		mc.handleReadReceipt(client, wsMsg)
	case "ping":
		// 处理心跳消息
		mc.handlePing(client)
	case "status_change":
		// 处理状态变更
		mc.handleStatusChange(client, wsMsg)
	case "typing_indicator":
		// 处理正在输入指示器
		mc.handleTypingIndicator(client, wsMsg)
	case "offer", "answer", "ice-candidate", "call-request", "call-accepted", "call-rejected", "call-ended":
		// 处理WebRTC信令
		mc.handleWebRTCSignal(client, wsMsg)
	case "message_recall":
		// 处理消息撤回（通过WebSocket）
		mc.handleMessageRecall(client, wsMsg)
	default:
		utils.LogDebug("未知消息类型: %s", wsMsg.Type)
	}
}

// handleSendGroupMessage 处理发送群组消息
func (mc *MessageController) handleSendGroupMessage(client *ws.Client, wsMsg models.WSMessage) {
	// 解析消息数据
	dataBytes, err := json.Marshal(wsMsg.Data)
	if err != nil {
		utils.LogDebug("群组消息数据序列化失败: %v", err)
		return
	}

	var msgData models.CreateGroupMessageRequest
	if err := json.Unmarshal(dataBytes, &msgData); err != nil {
		utils.LogDebug("解析群组消息数据失败: %v", err)
		return
	}

	// 首先检查群组是否已解散
	disbandedManager := models.GetDisbandedGroupsManager()
	if disbandedManager.IsGroupDisbanded(msgData.GroupID) {
		utils.LogDebug("群组 %d 已被群主解散，拒绝发送消息", msgData.GroupID)
		// 发送错误响应给发送者
		errorMsg := models.WSMessage{
			Type: "group_message_error",
			Data: gin.H{
				"error": "该群组已被群主解散",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		return
	}

	// 验证用户是否是群组成员
	_, err = mc.groupRepo.GetUserGroupRole(msgData.GroupID, client.UserID)
	if err != nil {
		utils.LogDebug("用户 %d 不是群组 %d 的成员或验证失败: %v", client.UserID, msgData.GroupID, err)
		// 发送错误响应给发送者
		errorMsg := models.WSMessage{
			Type: "group_message_error",
			Data: gin.H{
				"error": "您不是该群组成员",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		return
	}

	// 检查用户是否被禁言
	isMuted, err := mc.groupRepo.IsGroupMemberMuted(msgData.GroupID, client.UserID)
	if err != nil {
		utils.LogDebug("检查禁言状态失败: %v", err)
	}

	if isMuted {
		utils.LogDebug("用户 %d 在群组 %d 中被禁言", client.UserID, msgData.GroupID)
		// 发送错误响应给发送者
		errorMsg := models.WSMessage{
			Type: "group_message_error",
			Data: gin.H{
				"error": "你已被群主禁言",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		return
	}

	// 获取发送者在群组中的完整信息（群昵称、全名、用户名、头像）
	nickname, fullName, username, avatar, err := mc.groupRepo.GetGroupMemberInfo(msgData.GroupID, client.UserID)
	if err != nil {
		utils.LogDebug("获取用户群组信息失败: %v，尝试使用全局信息", err)
		// 如果获取群组信息失败，回退到使用用户的全局信息
		user, err := mc.userRepo.FindByID(client.UserID)
		if err != nil {
			utils.LogDebug("获取用户信息失败: %v", err)
			return
		}
		username = user.Username
		fullName = user.FullName
		if user.Avatar != "" {
			avatar = &user.Avatar
		}
	}

	// 确定显示名称（群昵称 > 全名 > 用户名）
	senderName := username
	if fullName != nil && *fullName != "" {
		senderName = *fullName
	}
	if nickname != nil && *nickname != "" {
		senderName = *nickname
	}

	utils.LogDebug("✅ 用户 %d 在群组 %d 中 - 显示昵称: %s, 群昵称: %v, 全名: %v", client.UserID, msgData.GroupID, senderName, nickname, fullName)

	// 保存群组消息到数据库（传入完整信息）
	message, err := mc.groupRepo.CreateGroupMessage(&msgData, client.UserID, senderName, nickname, fullName, avatar)
	if err != nil {
		utils.LogDebug("保存群组消息失败: %v", err)
		return
	}

	// 获取群组所有成员ID
	memberIDs, err := mc.groupRepo.GetGroupMemberIDs(msgData.GroupID)
	if err != nil {
		utils.LogDebug("获取群组成员ID列表失败: %v", err)
		return
	}

	// 将字符串格式的 mentioned_user_ids 转换为整数数组
	var mentionedUserIds []int
	if message.MentionedUserIDs != nil && *message.MentionedUserIDs != "" {
		ids := strings.Split(*message.MentionedUserIDs, ",")
		for _, idStr := range ids {
			idStr = strings.TrimSpace(idStr)
			if idStr != "" {
				if id, err := strconv.Atoi(idStr); err == nil {
					mentionedUserIds = append(mentionedUserIds, id)
				}
			}
		}
	}

	// 构建WebSocket消息
	wsGroupMsg := models.WSGroupMessage{
		Type:    "group_message",
		GroupID: message.GroupID,
		Data: models.WSGroupMessageData{
			ID:                   message.ID,
			GroupID:              message.GroupID,
			SenderID:             message.SenderID,
			SenderName:           message.SenderName,
			SenderAvatar:         message.SenderAvatar,
			Content:              message.Content,
			MessageType:          message.MessageType,
			FileName:             message.FileName,
			QuotedMessageID:      message.QuotedMessageID,
			QuotedMessageContent: message.QuotedMessageContent,
			MentionedUserIds:     mentionedUserIds,
			Mentions:             message.Mentions,
			VoiceDuration:        message.VoiceDuration,
			CreatedAt:            message.CreatedAt,
		},
	}

	msgBytes, err := json.Marshal(wsGroupMsg)
	if err != nil {
		utils.LogDebug("序列化群组消息失败: %v", err)
		return
	}

	// 向所有群组成员发送消息（不包括发送者自己）
	sentCount := 0
	for _, memberID := range memberIDs {
		if memberID != client.UserID {
			mc.Hub.SendToUser(memberID, msgBytes)
			sentCount++
		}
	}

	utils.LogDebug("群组消息已通过WebSocket广播 - GroupID: %d, MessageID: %d, 发送者: %d, 接收者数量: %d",
		message.GroupID, message.ID, client.UserID, sentCount)

	// 给发送者发送确认消息（发送者不会收到group_message推送，只收到这个确认）
	confirmMsg := models.WSMessage{
		Type: "group_message_sent",
		Data: gin.H{
			"message_id": message.ID,
			"group_id":   message.GroupID,
			"status":     "sent",
		},
	}
	confirmMsgBytes, _ := json.Marshal(confirmMsg)
	client.Send <- confirmMsgBytes
	utils.LogDebug("✅ [群组消息] 发送确认已发送给发送者 - 发送者ID: %d, MessageID: %d, GroupID: %d (发送者不会收到group_message推送)", client.UserID, message.ID, message.GroupID)
}

// handleSendMessage 处理发送私聊消息
func (mc *MessageController) handleSendMessage(client *ws.Client, wsMsg models.WSMessage) {
	// 解析消息数据
	dataBytes, err := json.Marshal(wsMsg.Data)
	if err != nil {
		utils.LogDebug("消息数据序列化失败: %v", err)
		return
	}

	var msgData models.CreateMessageRequest
	if err := json.Unmarshal(dataBytes, &msgData); err != nil {
		utils.LogDebug("解析消息数据失败: %v", err)
		return
	}

	// 根据消息类型决定是否打印内容
	var contentLog string
	switch msgData.MessageType {
	case "image":
		contentLog = "[图片]"
	case "video":
		contentLog = "[视频]"
	case "file":
		if msgData.FileName != "" {
			contentLog = "[文件: " + msgData.FileName + "]"
		} else {
			contentLog = "[文件]"
		}
	case "audio":
		contentLog = "[语音]"
	default:
		// 对于文本消息，限制打印长度
		if len(msgData.Content) > 100 {
			contentLog = msgData.Content[:100] + "..."
		} else {
			contentLog = msgData.Content
		}
	}

	utils.LogDebug("📨 [消息路由] 收到私聊消息 - 发送者ID: %d, 接收者ID: %d, 类型: %s, 内容: %s", client.UserID, msgData.ReceiverID, msgData.MessageType, contentLog)

	// 检查好友关系状态（approval_status）
	approvalStatus, err := mc.contactRepo.CheckContactApprovalStatus(client.UserID, msgData.ReceiverID)
	if err != nil {
		utils.LogDebug("检查好友关系状态失败: %v", err)
		// 如果检查失败，继续发送消息（不拦截）
	} else if approvalStatus == "rejected" {
		// 好友申请已被拒绝，拦截消息并返回提示
		errorMsg := models.WSMessage{
			Type: "message_error",
			Data: gin.H{
				"error":   "已被拒绝",
				"message": "您的好友申请已被拒绝，无法发送消息",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		utils.LogDebug("🚫 [消息拦截] 好友申请被拒绝 - 发送者 %d -> 接收者 %d，消息被拦截", client.UserID, msgData.ReceiverID)
		return
	} else if approvalStatus == "pending" {
		// 好友申请待审核，拦截消息并返回提示
		errorMsg := models.WSMessage{
			Type: "message_error",
			Data: gin.H{
				"error":   "待审核",
				"message": "您的好友申请待对方审核，暂时无法发送消息",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		utils.LogDebug("🚫 [消息拦截] 好友申请待审核 - 发送者 %d -> 接收者 %d，消息被拦截", client.UserID, msgData.ReceiverID)
		return
	}

	// 检查双向拉黑状态
	// 1. 检查接收者是否拉黑了发送者
	isBlockedByReceiver, err := mc.contactRepo.CheckContactBlocked(msgData.ReceiverID, client.UserID)
	if err != nil {
		utils.LogDebug("检查接收者拉黑状态失败: %v", err)
		// 如果检查失败，继续发送消息（不拦截）
	} else if isBlockedByReceiver {
		// 接收者已拉黑发送者，拦截消息并返回提示
		errorMsg := models.WSMessage{
			Type: "message_error",
			Data: gin.H{
				"error":   "已被加入黑名单",
				"message": "该联系人已将您加入黑名单，无法发送消息",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		utils.LogDebug("🚫 [消息拦截] 接收者 %d 已拉黑发送者 %d，消息被拦截", msgData.ReceiverID, client.UserID)
		return
	}

	// 2. 检查发送者是否拉黑了接收者
	isBlockedBySender, err := mc.contactRepo.CheckContactBlocked(client.UserID, msgData.ReceiverID)
	if err != nil {
		utils.LogDebug("检查发送者拉黑状态失败: %v", err)
		// 如果检查失败，继续发送消息（不拦截）
	} else if isBlockedBySender {
		// 发送者已拉黑接收者，拦截消息并返回提示
		errorMsg := models.WSMessage{
			Type: "message_error",
			Data: gin.H{
				"error":   "已拉黑该联系人",
				"message": "您已将该联系人加入黑名单，无法发送消息",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		utils.LogDebug("🚫 [消息拦截] 发送者 %d 已拉黑接收者 %d，消息被拦截", client.UserID, msgData.ReceiverID)
		return
	}

	// 检查好友关系是否存在（硬删除检查）
	relationExists, err := mc.contactRepo.CheckRelationExists(client.UserID, msgData.ReceiverID)
	if err != nil {
		utils.LogDebug("检查好友关系存在性失败: %v", err)
		// 如果检查失败，继续后续检查
	} else if !relationExists {
		// 好友关系不存在（已被硬删除），拦截消息
		errorMsg := models.WSMessage{
			Type: "message_error",
			Data: gin.H{
				"error":   "好友关系不存在",
				"message": "您与该联系人不是好友关系，无法发送消息",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		utils.LogDebug("🚫 [消息拦截] 好友关系不存在 - 发送者 %d -> 接收者 %d，消息被拦截", client.UserID, msgData.ReceiverID)
		return
	}

	// 检查双向删除状态（软删除检查，暂时保留以兼容旧数据）
	// 1. 检查接收者是否删除了发送者
	isDeletedByReceiver, err := mc.contactRepo.CheckContactDeleted(msgData.ReceiverID, client.UserID)
	if err != nil {
		utils.LogDebug("检查接收者删除状态失败: %v", err)
		// 如果检查失败，继续发送消息（不拦截）
	} else if isDeletedByReceiver {
		// 接收者已删除发送者，拦截消息并返回提示
		errorMsg := models.WSMessage{
			Type: "message_error",
			Data: gin.H{
				"error":   "已被删除",
				"message": "该联系人已将您删除，无法发送消息",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		utils.LogDebug("🚫 [消息拦截] 接收者 %d 已删除发送者 %d，消息被拦截", msgData.ReceiverID, client.UserID)
		return
	}

	// 2. 检查发送者是否删除了接收者
	isDeletedBySender, err := mc.contactRepo.CheckContactDeleted(client.UserID, msgData.ReceiverID)
	if err != nil {
		utils.LogDebug("检查发送者删除状态失败: %v", err)
		// 如果检查失败，继续发送消息（不拦截）
	} else if isDeletedBySender {
		// 发送者已删除接收者，拦截消息并返回提示
		errorMsg := models.WSMessage{
			Type: "message_error",
			Data: gin.H{
				"error":   "已删除该联系人",
				"message": "您已删除该联系人，无法发送消息",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		utils.LogDebug("🚫 [消息拦截] 发送者 %d 已删除接收者 %d，消息被拦截", client.UserID, msgData.ReceiverID)
		return
	}

	// 通话结束消息专用去重：如果最近已存在相同的 call_ended/call_ended_video，则复用已有记录
	if msgData.MessageType == "call_ended" || msgData.MessageType == "call_ended_video" {
		cutoff := time.Now().UTC().Add(-10 * time.Second)
		query := `
			SELECT id
			FROM messages
			WHERE ((sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1))
			  AND message_type = $3
			  AND content = $4
			  AND created_at >= $5
			ORDER BY created_at ASC
			LIMIT 1
		`

		var existingID int
		err := db.DB.QueryRow(query, client.UserID, msgData.ReceiverID, msgData.MessageType, msgData.Content, cutoff).Scan(&existingID)
		if err == nil {
			utils.LogDebug("⏭️ [消息路由] 检测到重复的通话结束消息，复用已有记录 - MessageID: %d", existingID)
			// 仍然给发送者发送确认，让前端更新本地状态，但不再转发新消息给对方
			confirmMsg := models.WSMessage{
				Type: "message_sent",
				Data: gin.H{
					"message_id": existingID,
					"status":     "sent",
				},
			}
			confirmMsgBytes, _ := json.Marshal(confirmMsg)
			client.Send <- confirmMsgBytes
			utils.LogDebug("✉️ [消息路由] 通话结束去重后仅发送确认给发送者 - 发送者ID: %d, MessageID: %d", client.UserID, existingID)
			return
		}
		if err != sql.ErrNoRows {
			utils.LogDebug("⚠️ [消息路由] 通话结束去重查询失败，继续正常写入: %v", err)
		}
	}

	// 保存消息到数据库
	msg, err := mc.saveMessage(client.UserID, msgData.ReceiverID, msgData.Content, msgData.MessageType, msgData.FileName, msgData.QuotedMessageID, msgData.QuotedMessageContent, msgData.CallType, msgData.VoiceDuration)
	if err != nil {
		utils.LogDebug("保存消息失败: %v", err)
		return
	}
	utils.LogDebug("💾 [消息路由] 消息已保存到数据库 - MessageID: %d, VoiceDuration: %v", msg.ID, msg.VoiceDuration)

	// 构造发送给接收者的消息
	receiverMsg := models.WSMessage{
		Type: "message",
		Data: models.WSMessageData{
			ID:                   msg.ID,
			SenderID:             msg.SenderID,
			ReceiverID:           msg.ReceiverID,
			SenderName:           msg.SenderName,
			ReceiverName:         msg.ReceiverName,
			SenderAvatar:         msg.SenderAvatar,
			ReceiverAvatar:       msg.ReceiverAvatar,
			Content:              msg.Content,
			MessageType:          msg.MessageType,
			FileName:             msg.FileName,
			QuotedMessageID:      msg.QuotedMessageID,
			QuotedMessageContent: msg.QuotedMessageContent,
			VoiceDuration:        msg.VoiceDuration,
			IsRead:               msg.IsRead, // 包含已读状态（新消息默认为false）
			CreatedAt:            msg.CreatedAt,
		},
	}

	receiverMsgBytes, _ := json.Marshal(receiverMsg)

	// 尝试发送给在线用户
	utils.LogDebug("📤 [消息路由] 准备发送消息给接收者 - 接收者ID: %d", msgData.ReceiverID)
	isOnline := mc.Hub.SendToUser(msgData.ReceiverID, receiverMsgBytes)
	if isOnline {
		utils.LogDebug("✅ [消息路由] 消息已发送给在线用户 %d", msgData.ReceiverID)
	} else {
		utils.LogDebug("⚠️ [消息路由] 用户 %d 离线，消息已保存到数据库", msgData.ReceiverID)
	}

	// 给发送者发送确认
	confirmMsg := models.WSMessage{
		Type: "message_sent",
		Data: gin.H{
			"message_id": msg.ID,
			"status":     "sent",
		},
	}
	confirmMsgBytes, _ := json.Marshal(confirmMsg)
	client.Send <- confirmMsgBytes
	utils.LogDebug("✉️ [消息路由] 发送确认已发送给发送者 - 发送者ID: %d, MessageID: %d", client.UserID, msg.ID)

	// 🔴 已移除：不再向发送者回显完整消息（APP端发送时已保存到本地数据库）
	// 发送者只需要收到 message_sent 确认即可
}

// handleReadReceipt 处理已读回执
func (mc *MessageController) handleReadReceipt(client *ws.Client, wsMsg models.WSMessage) {
	dataMap, ok := wsMsg.Data.(map[string]interface{})
	if !ok {
		utils.LogDebug("已读回执数据格式错误")
		return
	}

	// 🔴 修复：支持两种格式的已读回执
	// 1. 单条消息已读：{"message_id": 123}
	// 2. 批量已读（按发送者）：{"sender_id": 456}
	if messageID, ok := dataMap["message_id"].(float64); ok {
		// 单条消息已读
		if err := mc.markMessageAsRead(int(messageID), client.UserID); err != nil {
			utils.LogDebug("标记消息已读失败: %v", err)
			return
		}
		utils.LogDebug("消息 %d 已标记为已读", int(messageID))
	} else if senderID, ok := dataMap["sender_id"].(float64); ok {
		// 🔴 批量标记某个发送者的所有未读消息为已读
		query := `
			UPDATE messages
			SET is_read = true, read_at = $1
			WHERE receiver_id = $2 AND sender_id = $3 AND is_read = false
		`
		result, err := db.DB.Exec(query, time.Now(), client.UserID, int(senderID))
		if err != nil {
			utils.LogDebug("❌ 批量标记消息已读失败: %v", err)
			return
		}
		rowsAffected, _ := result.RowsAffected()
		utils.LogDebug("✅ 已批量标记 %d 条消息为已读 - receiver_id: %d, sender_id: %d", rowsAffected, client.UserID, int(senderID))
		
		// 🔴 向发送者推送已读回执通知
		readReceiptNotification := models.WSMessage{
			Type: "read_receipt",
			Data: gin.H{
				"receiver_id": client.UserID, // 接收者（标记已读的用户）
			},
		}
		notificationBytes, _ := json.Marshal(readReceiptNotification)
		if mc.Hub.SendToUser(int(senderID), notificationBytes) {
			utils.LogDebug("✅ 已读回执通知已推送给发送者 %d", int(senderID))
		} else {
			utils.LogDebug("⚠️ 发送者 %d 离线，已读回执通知将在下次登录时推送", int(senderID))
		}
	} else {
		utils.LogDebug("⚠️ 已读回执数据格式错误：缺少 message_id 或 sender_id")
	}
}

// handlePing 处理心跳消息
func (mc *MessageController) handlePing(client *ws.Client) {
	// 重置客户端的心跳计数器
	client.ResetPingCounter()

	// 回复pong消息
	pongMsg := models.WSMessage{
		Type: "pong",
		Data: gin.H{
			"timestamp": time.Now().Unix(),
		},
	}
	pongMsgBytes, _ := json.Marshal(pongMsg)
	client.Send <- pongMsgBytes
}

// handleStatusChange 处理状态变更
func (mc *MessageController) handleStatusChange(client *ws.Client, wsMsg models.WSMessage) {
	// 解析状态数据
	dataMap, ok := wsMsg.Data.(map[string]interface{})
	if !ok {
		utils.LogDebug("状态变更数据格式错误")
		return
	}

	status, ok := dataMap["status"].(string)
	if !ok || status == "" {
		utils.LogDebug("状态值格式错误或为空")
		return
	}

	// 验证状态值是否有效
	validStatuses := map[string]bool{
		"online":  true,
		"busy":    true,
		"away":    true,
		"offline": true,
	}
	if !validStatuses[status] {
		utils.LogDebug("无效的状态值: %s", status)
		return
	}

	// 更新数据库中的用户状态
	err := mc.userRepo.UpdateStatus(client.UserID, status)
	if err != nil {
		utils.LogDebug("更新用户状态失败: %v", err)
		// 发送错误响应给客户端
		errorMsg := models.WSMessage{
			Type: "status_change_error",
			Data: gin.H{
				"error": "更新状态失败",
			},
		}
		errorMsgBytes, _ := json.Marshal(errorMsg)
		client.Send <- errorMsgBytes
		return
	}

	utils.LogDebug("✅ 用户 %d 状态通过WebSocket更新为: %s", client.UserID, status)

	// 获取当前用户信息（用于发送通知）
	user, err := mc.userRepo.FindByID(client.UserID)
	if err != nil {
		utils.LogDebug("⚠️ 获取用户信息失败，无法发送状态变更通知: %v", err)
		return
	}

	// 获取用户的所有联系人
	contacts, err := mc.contactRepo.GetContactsByUserID(client.UserID)
	if err != nil {
		utils.LogDebug("⚠️ 获取联系人列表失败，无法发送状态变更通知: %v", err)
		return
	}

	// 构造状态变更消息
	statusChangeMsg := models.WSMessage{
		Type: "status_change",
		Data: gin.H{
			"user_id":   client.UserID,
			"username":  user.Username,
			"full_name": user.FullName,
			"status":    status,
		},
	}

	msgBytes, err := json.Marshal(statusChangeMsg)
	if err != nil {
		utils.LogDebug("⚠️ 序列化状态变更消息失败: %v", err)
		return
	}

	// 向所有联系人推送状态变更消息
	notifiedCount := 0
	for _, contact := range contacts {
		if mc.Hub.SendToUser(contact.FriendID, msgBytes) {
			notifiedCount++
		}
	}

	utils.LogDebug("📤 WebSocket状态变更通知已发送，共 %d/%d 个联系人在线", notifiedCount, len(contacts))

	// 发送成功确认给发送者
	confirmMsg := models.WSMessage{
		Type: "status_change_success",
		Data: gin.H{
			"status": status,
		},
	}
	confirmMsgBytes, _ := json.Marshal(confirmMsg)
	client.Send <- confirmMsgBytes
}

// handleTypingIndicator 处理正在输入指示器
func (mc *MessageController) handleTypingIndicator(client *ws.Client, wsMsg models.WSMessage) {
	// 解析正在输入数据
	dataMap, ok := wsMsg.Data.(map[string]interface{})
	if !ok {
		utils.LogDebug("正在输入指示器数据格式错误")
		return
	}

	// 获取接收者ID
	var receiverID int
	if receiverIDFloat, ok := dataMap["receiver_id"].(float64); ok {
		receiverID = int(receiverIDFloat)
	} else if receiverIDInt, ok := dataMap["receiver_id"].(int); ok {
		receiverID = receiverIDInt
	} else {
		utils.LogDebug("正在输入指示器缺少接收者ID")
		return
	}

	// 获取是否正在输入
	isTyping, ok := dataMap["is_typing"].(bool)
	if !ok {
		utils.LogDebug("正在输入指示器缺少is_typing字段")
		return
	}

	utils.LogDebug("⌨️ 收到正在输入指示器 - 发送者: %d, 接收者: %d, 正在输入: %v", client.UserID, receiverID, isTyping)

	// 构造转发给接收者的消息
	typingMsg := models.WSMessage{
		Type: "typing_indicator",
		Data: gin.H{
			"sender_id": client.UserID,
			"is_typing": isTyping,
		},
	}

	msgBytes, err := json.Marshal(typingMsg)
	if err != nil {
		utils.LogDebug("序列化正在输入指示器失败: %v", err)
		return
	}

	// 转发给接收者
	isOnline := mc.Hub.SendToUser(receiverID, msgBytes)
	if isOnline {
		utils.LogDebug("✅ 正在输入指示器已发送给用户 %d", receiverID)
	} else {
		utils.LogDebug("⚠️ 用户 %d 离线，无法接收正在输入指示器", receiverID)
	}
}

// handleWebRTCSignal 处理WebRTC信令
func (mc *MessageController) handleWebRTCSignal(client *ws.Client, wsMsg models.WSMessage) {
	// 解析信令数据
	dataMap, ok := wsMsg.Data.(map[string]interface{})
	if !ok {
		utils.LogDebug("WebRTC信令数据格式错误")
		return
	}

	// 获取目标用户ID
	var targetUserID int
	if targetUserIDFloat, ok := dataMap["targetUserId"].(float64); ok {
		targetUserID = int(targetUserIDFloat)
	} else if targetUserIDInt, ok := dataMap["targetUserId"].(int); ok {
		targetUserID = targetUserIDInt
	} else {
		utils.LogDebug("WebRTC信令缺少目标用户ID")
		return
	}

	utils.LogDebug("📞 收到WebRTC信令: %s，发送者: %d，接收者: %d", wsMsg.Type, client.UserID, targetUserID)

	// 构造转发消息
	forwardMsg := models.WSMessage{
		Type: wsMsg.Type,
		Data: dataMap,
	}

	// 添加发送者信息
	if dataMapCopy, ok := forwardMsg.Data.(map[string]interface{}); ok {
		dataMapCopy["fromUserId"] = client.UserID
		forwardMsg.Data = dataMapCopy
	}

	msgBytes, err := json.Marshal(forwardMsg)
	if err != nil {
		utils.LogDebug("序列化WebRTC信令失败: %v", err)
		return
	}

	// 转发给目标用户
	isOnline := mc.Hub.SendToUser(targetUserID, msgBytes)
	if isOnline {
		utils.LogDebug("📞 WebRTC信令已转发给用户 %d", targetUserID)
	} else {
		utils.LogDebug("📞 用户 %d 离线，无法转发WebRTC信令", targetUserID)

		// 如果是通话请求且对方离线，通知发起者
		if wsMsg.Type == "call-request" {
			offlineMsg := models.WSMessage{
				Type: "call-failed",
				Data: gin.H{
					"reason": "用户离线",
				},
			}
			offlineMsgBytes, _ := json.Marshal(offlineMsg)
			client.Send <- offlineMsgBytes
		}
	}
}

// saveMessage 保存消息到数据库
func (mc *MessageController) saveMessage(senderID, receiverID int, content, messageType, fileName string, quotedMessageID int, quotedMessageContent string, callType string, voiceDuration int) (*models.Message, error) {
	if messageType == "" {
		messageType = "text"
	}

	// 通话结束系统消息去重：避免同一次通话在极短时间内多次写入相同的 call_ended / call_ended_video
	// 这里按「用户对 + 消息类型 + 内容」在最近 10 秒内去重
	if messageType == "call_ended" || messageType == "call_ended_video" {
		cutoff := time.Now().UTC().Add(-10 * time.Second)
		query := `
			SELECT id, sender_id, receiver_id, sender_name, receiver_name,
			       sender_avatar, receiver_avatar, content, message_type,
			       file_name, quoted_message_id, quoted_message_content,
			       call_type, is_read, created_at
			FROM messages
			WHERE ((sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1))
			  AND message_type = $3
			  AND content = $4
			  AND created_at >= $5
			ORDER BY created_at ASC
			LIMIT 1
		`

		msg := &models.Message{}
		if err := db.DB.QueryRow(query, senderID, receiverID, messageType, content, cutoff).Scan(
			&msg.ID,
			&msg.SenderID,
			&msg.ReceiverID,
			&msg.SenderName,
			&msg.ReceiverName,
			&msg.SenderAvatar,
			&msg.ReceiverAvatar,
			&msg.Content,
			&msg.MessageType,
			&msg.FileName,
			&msg.QuotedMessageID,
			&msg.QuotedMessageContent,
			&msg.CallType,
			&msg.IsRead,
			&msg.CreatedAt,
		); err == nil {
			utils.LogDebug("⏭️ [通话结束去重] 复用已有通话结束消息 - MessageID: %d", msg.ID)
			return msg, nil
		} else if err != sql.ErrNoRows {
			// 查询异常仅记录日志，不影响正常消息写入
			utils.LogDebug("⚠️ [通话结束去重] 查询已有通话结束消息失败: %v", err)
		}
	}

	// 查询发送者和接收者的用户名和头像
	// 优先使用 full_name，如果为空则使用 username
	var senderName, receiverName string
	var senderAvatar, receiverAvatar sql.NullString
	var senderFullName, receiverFullName sql.NullString

	err := db.DB.QueryRow("SELECT username, full_name, avatar FROM users WHERE id = $1", senderID).Scan(&senderName, &senderFullName, &senderAvatar)
	if err != nil {
		return nil, err
	}
	// 如果有 full_name 则使用 full_name，否则使用 username
	if senderFullName.Valid && senderFullName.String != "" {
		senderName = senderFullName.String
	}

	err = db.DB.QueryRow("SELECT username, full_name, avatar FROM users WHERE id = $1", receiverID).Scan(&receiverName, &receiverFullName, &receiverAvatar)
	if err != nil {
		return nil, err
	}
	// 如果有 full_name 则使用 full_name，否则使用 username
	if receiverFullName.Valid && receiverFullName.String != "" {
		receiverName = receiverFullName.String
	}

	query := `
		INSERT INTO messages (sender_id, receiver_id, sender_name, receiver_name, sender_avatar, receiver_avatar, content, message_type, file_name, quoted_message_id, quoted_message_content, call_type, voice_duration, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
		RETURNING id, sender_id, receiver_id, sender_name, receiver_name, sender_avatar, receiver_avatar, content, message_type, file_name, quoted_message_id, quoted_message_content, call_type, voice_duration, is_read, created_at
	`

	msg := &models.Message{}
	now := time.Now().UTC() // 🔴 使用 UTC 时间，客户端会转换为本地时间显示

	var fileNamePtr *string
	if fileName != "" {
		fileNamePtr = &fileName
	}

	var quotedIDPtr *int
	if quotedMessageID > 0 {
		quotedIDPtr = &quotedMessageID
	}

	var quotedContentPtr *string
	if quotedMessageContent != "" {
		quotedContentPtr = &quotedMessageContent
	}

	var callTypePtr *string
	if callType != "" {
		callTypePtr = &callType
	}

	var voiceDurationPtr *int
	if voiceDuration > 0 {
		voiceDurationPtr = &voiceDuration
	}

	var senderAvatarPtr *string
	if senderAvatar.Valid {
		senderAvatarPtr = &senderAvatar.String
	}

	var receiverAvatarPtr *string
	if receiverAvatar.Valid {
		receiverAvatarPtr = &receiverAvatar.String
	}

	err = db.DB.QueryRow(query, senderID, receiverID, senderName, receiverName, senderAvatarPtr, receiverAvatarPtr, content, messageType, fileNamePtr, quotedIDPtr, quotedContentPtr, callTypePtr, voiceDurationPtr, now).Scan(
		&msg.ID,
		&msg.SenderID,
		&msg.ReceiverID,
		&msg.SenderName,
		&msg.ReceiverName,
		&msg.SenderAvatar,
		&msg.ReceiverAvatar,
		&msg.Content,
		&msg.MessageType,
		&msg.FileName,
		&msg.QuotedMessageID,
		&msg.QuotedMessageContent,
		&msg.CallType,
		&msg.VoiceDuration,
		&msg.IsRead,
		&msg.CreatedAt,
	)

	if err != nil {
		return nil, err
	}

	return msg, nil
}

// sendOnlineNotification 发送上线通知给所有联系人
func (mc *MessageController) sendOnlineNotification(client *ws.Client) {
	// 获取当前用户信息
	user, err := mc.userRepo.FindByID(client.UserID)
	if err != nil {
		utils.LogDebug("⚠️ 获取用户信息失败，无法发送上线通知: %v", err)
		return
	}

	// 获取用户的所有联系人
	contacts, err := mc.contactRepo.GetContactsByUserID(client.UserID)
	if err != nil {
		utils.LogDebug("⚠️ 获取联系人列表失败，无法发送上线通知: %v", err)
		return
	}

	// 构造上线通知消息
	onlineNotificationMsg := models.WSMessage{
		Type: "online_notification",
		Data: gin.H{
			"user_id":     client.UserID,
			"username":    user.Username,
			"full_name":   user.FullName,
			"avatar":      user.Avatar,
			"online_time": time.Now().Unix(),
		},
	}

	msgBytes, err := json.Marshal(onlineNotificationMsg)
	if err != nil {
		utils.LogDebug("⚠️ 序列化上线通知消息失败: %v", err)
		return
	}

	// 向所有联系人推送上线通知消息
	notifiedCount := 0
	for _, contact := range contacts {
		if mc.Hub.SendToUser(contact.FriendID, msgBytes) {
			notifiedCount++
		}
	}

	utils.LogDebug("📢 用户 %d (%s) 上线通知已发送，共 %d/%d 个联系人在线",
		client.UserID, user.Username, notifiedCount, len(contacts))
}

// sendOfflineNotification 发送离线通知给所有联系人
func (mc *MessageController) sendOfflineNotification(userID int) {
	// 更新数据库中的用户状态为离线
	err := mc.userRepo.UpdateStatus(userID, "offline")
	if err != nil {
		utils.LogDebug("⚠️ 更新用户 %d 离线状态失败: %v", userID, err)
		// 即使更新失败，仍然继续发送离线通知
	}

	// 获取用户信息
	user, err := mc.userRepo.FindByID(userID)
	if err != nil {
		utils.LogDebug("⚠️ 获取用户信息失败，无法发送离线通知: %v", err)
		return
	}

	// 获取用户的所有联系人
	contacts, err := mc.contactRepo.GetContactsByUserID(userID)
	if err != nil {
		utils.LogDebug("⚠️ 获取联系人列表失败，无法发送离线通知: %v", err)
		return
	}

	// 构造离线通知消息
	offlineNotificationMsg := models.WSMessage{
		Type: "offline_notification",
		Data: gin.H{
			"user_id":      userID,
			"username":     user.Username,
			"full_name":    user.FullName,
			"avatar":       user.Avatar,
			"offline_time": time.Now().Unix(),
		},
	}

	msgBytes, err := json.Marshal(offlineNotificationMsg)
	if err != nil {
		utils.LogDebug("⚠️ 序列化离线通知消息失败: %v", err)
		return
	}

	// 向所有联系人推送离线通知消息
	notifiedCount := 0
	for _, contact := range contacts {
		if mc.Hub.SendToUser(contact.FriendID, msgBytes) {
			notifiedCount++
		}
	}

	utils.LogDebug("📤 用户 %d (%s) 离线通知已发送，共 %d/%d 个联系人在线",
		userID, user.Username, notifiedCount, len(contacts))
}

// sendOfflineMessages 发送离线消息
// 使用 private_message_synced 表记录已同步的消息，避免重复推送
func (mc *MessageController) sendOfflineMessages(client *ws.Client) {
	// 确保 private_message_synced 表存在
	mc.ensurePrivateMessageSyncedTableExists()

	userIDStr := strconv.Itoa(client.UserID)

	// 查询未同步的离线消息（排除已同步的消息）
	query := `
		SELECT id, sender_id, receiver_id, sender_name, receiver_name, sender_avatar, receiver_avatar, content, message_type, file_name, quoted_message_id, quoted_message_content, is_read, created_at
		FROM messages
		WHERE receiver_id = $1 
			AND is_read = false
			AND status != 'recalled'
			AND (deleted_by_users = '' OR deleted_by_users NOT LIKE '%' || $2 || '%')
			AND id NOT IN (SELECT message_id FROM private_message_synced WHERE user_id = $1)
		ORDER BY created_at ASC
	`

	rows, err := db.DB.Query(query, client.UserID, userIDStr)
	if err != nil {
		utils.LogDebug("查询离线消息失败: %v", err)
		return
	}
	defer rows.Close()

	var messages []models.Message
	var messageIDs []int
	for rows.Next() {
		var msg models.Message
		err := rows.Scan(
			&msg.ID,
			&msg.SenderID,
			&msg.ReceiverID,
			&msg.SenderName,
			&msg.ReceiverName,
			&msg.SenderAvatar,
			&msg.ReceiverAvatar,
			&msg.Content,
			&msg.MessageType,
			&msg.FileName,
			&msg.QuotedMessageID,
			&msg.QuotedMessageContent,
			&msg.IsRead,
			&msg.CreatedAt,
		)
		if err != nil {
			utils.LogDebug("扫描离线消息失败: %v", err)
			continue
		}
		messages = append(messages, msg)
		messageIDs = append(messageIDs, msg.ID)
	}

	if len(messages) > 0 {
		// 发送离线消息列表
		offlineMsg := models.WSMessage{
			Type: "offline_messages",
			Data: messages,
		}
		msgBytes, _ := json.Marshal(offlineMsg)
		client.Send <- msgBytes
		utils.LogDebug("已向用户 %d 发送 %d 条离线消息", client.UserID, len(messages))

		// 记录已同步的消息ID，避免下次重复推送
		mc.markPrivateMessagesSynced(client.UserID, messageIDs)
	}

	// 发送离线群聊消息
	mc.sendOfflineGroupMessages(client)
}

// ensurePrivateMessageSyncedTableExists 确保 private_message_synced 表存在
func (mc *MessageController) ensurePrivateMessageSyncedTableExists() {
	createTableQuery := `
		CREATE TABLE IF NOT EXISTS private_message_synced (
			id SERIAL PRIMARY KEY,
			message_id INTEGER NOT NULL,
			user_id INTEGER NOT NULL,
			synced_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			UNIQUE(message_id, user_id)
		)
	`
	_, err := db.DB.Exec(createTableQuery)
	if err != nil {
		utils.LogDebug("创建 private_message_synced 表失败: %v", err)
	}
}

// markPrivateMessagesSynced 记录已同步的私聊消息
func (mc *MessageController) markPrivateMessagesSynced(userID int, messageIDs []int) {
	if len(messageIDs) == 0 {
		return
	}

	// 批量插入已同步记录
	for _, msgID := range messageIDs {
		insertQuery := `
			INSERT INTO private_message_synced (message_id, user_id)
			VALUES ($1, $2)
			ON CONFLICT (message_id, user_id) DO NOTHING
		`
		_, err := db.DB.Exec(insertQuery, msgID, userID)
		if err != nil {
			utils.LogDebug("记录已同步消息失败: message_id=%d, user_id=%d, error=%v", msgID, userID, err)
		}
	}
	utils.LogDebug("已记录 %d 条私聊消息为已同步 (user_id=%d)", len(messageIDs), userID)
}

// sendOfflineGroupMessages 发送离线群聊消息
func (mc *MessageController) sendOfflineGroupMessages(client *ws.Client) {
	// 1. 获取用户所属的所有群组
	groupQuery := `
		SELECT group_id FROM group_members WHERE user_id = $1
	`
	groupRows, err := db.DB.Query(groupQuery, client.UserID)
	if err != nil {
		utils.LogDebug("查询用户群组失败: %v", err)
		return
	}
	defer groupRows.Close()

	var groupIDs []int
	for groupRows.Next() {
		var groupID int
		if err := groupRows.Scan(&groupID); err != nil {
			continue
		}
		groupIDs = append(groupIDs, groupID)
	}

	if len(groupIDs) == 0 {
		utils.LogDebug("用户 %d 没有加入任何群组，跳过离线群聊消息推送", client.UserID)
		return
	}

	utils.LogDebug("用户 %d 所属群组: %v，开始查询离线群聊消息", client.UserID, groupIDs)

	// 2. 对每个群组查询未读消息
	userIDStr := strconv.Itoa(client.UserID)
	for _, groupID := range groupIDs {
		// 查询该群组中用户未读的消息（排除自己发送的消息和已删除的消息）
		msgQuery := `
			SELECT gm.id, gm.group_id, gm.sender_id, gm.sender_name, gm.sender_nickname, 
			       gm.sender_full_name, gm.sender_avatar, gm.content, gm.message_type, 
			       gm.file_name, gm.quoted_message_id, gm.quoted_message_content,
			       gm.mentioned_user_ids, gm.mentions, gm.voice_duration, gm.status, gm.created_at
			FROM group_messages gm
			WHERE gm.group_id = $1
				AND gm.sender_id != $2
				AND gm.status != 'recalled'
				AND (gm.deleted_by_users = '' OR gm.deleted_by_users NOT LIKE '%' || $3 || '%')
				AND gm.id NOT IN (
					SELECT group_message_id FROM group_message_reads WHERE user_id = $2
				)
			ORDER BY gm.created_at ASC
		`

		msgRows, err := db.DB.Query(msgQuery, groupID, client.UserID, userIDStr)
		if err != nil {
			utils.LogDebug("查询群组 %d 离线消息失败: %v", groupID, err)
			continue
		}

		var messages []map[string]interface{}
		for msgRows.Next() {
			var (
				id                   int
				gid                  int
				senderID             int
				senderName           string
				senderNickname       sql.NullString
				senderFullName       sql.NullString
				senderAvatar         sql.NullString
				content              string
				messageType          string
				fileName             sql.NullString
				quotedMessageID      sql.NullInt64
				quotedMessageContent sql.NullString
				mentionedUserIDs     sql.NullString
				mentions             sql.NullString
				voiceDuration        sql.NullInt64
				status               string
				createdAt            time.Time
			)

			err := msgRows.Scan(
				&id, &gid, &senderID, &senderName, &senderNickname,
				&senderFullName, &senderAvatar, &content, &messageType,
				&fileName, &quotedMessageID, &quotedMessageContent,
				&mentionedUserIDs, &mentions, &voiceDuration, &status, &createdAt,
			)
			if err != nil {
				utils.LogDebug("扫描群组消息失败: %v", err)
				continue
			}

			msg := map[string]interface{}{
				"id":           id,
				"group_id":     gid,
				"sender_id":    senderID,
				"sender_name":  senderName,
				"content":      content,
				"message_type": messageType,
				"status":       status,
				"created_at":   createdAt.Format(time.RFC3339),
				"is_read":      false,
			}

			if senderNickname.Valid {
				msg["sender_nickname"] = senderNickname.String
			}
			if senderFullName.Valid {
				msg["sender_full_name"] = senderFullName.String
			}
			if senderAvatar.Valid {
				msg["sender_avatar"] = senderAvatar.String
			}
			if fileName.Valid {
				msg["file_name"] = fileName.String
			}
			if quotedMessageID.Valid {
				msg["quoted_message_id"] = quotedMessageID.Int64
			}
			if quotedMessageContent.Valid {
				msg["quoted_message_content"] = quotedMessageContent.String
			}
			if mentionedUserIDs.Valid {
				msg["mentioned_user_ids"] = mentionedUserIDs.String
			}
			if mentions.Valid {
				msg["mentions"] = mentions.String
			}
			if voiceDuration.Valid {
				msg["voice_duration"] = voiceDuration.Int64
			}

			messages = append(messages, msg)
		}
		msgRows.Close()

		if len(messages) > 0 {
			// 发送该群组的离线消息
			offlineGroupMsg := models.WSMessage{
				Type: "offline_group_messages",
				Data: map[string]interface{}{
					"group_id": groupID,
					"messages": messages,
				},
			}
			msgBytes, _ := json.Marshal(offlineGroupMsg)
			client.Send <- msgBytes
			utils.LogDebug("已向用户 %d 发送群组 %d 的 %d 条离线消息", client.UserID, groupID, len(messages))
		}
	}
}

// markMessageAsRead 标记单条消息为已读
func (mc *MessageController) markMessageAsRead(messageID, userID int) error {
	// ...
	query := `
		UPDATE messages
		SET is_read = true, read_at = $1
		WHERE id = $2 AND receiver_id = $3
	`

	_, err := db.DB.Exec(query, time.Now(), messageID, userID)
	return err
}

// MarkMessagesAsRead 标记与某个用户的所有未读消息为已读（HTTP API）
func (mc *MessageController) MarkMessagesAsRead(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.LogDebug("❌ 获取当前用户ID失败")
		utils.Unauthorized(c, "未授权")
		return
	}

	// 解析请求体
	var req models.MarkReadRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "无效的请求参数")
		return
	}

	// 标记与该发送者的所有未读消息为已读
	query := `
		UPDATE messages
		SET is_read = true, read_at = $1
		WHERE receiver_id = $2 AND sender_id = $3 AND is_read = false
	`

	result, err := db.DB.Exec(query, time.Now(), userID, req.SenderID)
	if err != nil {
		utils.LogDebug("❌ 标记消息已读失败: %v", err)
		utils.InternalServerError(c, "标记消息已读失败")
		return
	}

	rowsAffected, _ := result.RowsAffected()
	utils.LogDebug("✅ 已标记 %d 条消息为已读", rowsAffected)

	utils.Success(c, gin.H{
		"message":       "标记成功",
		"rows_affected": rowsAffected,
	})
}

// MarkGroupMessagesAsRead 标记群组的所有未读消息为已读（HTTP API）
func (mc *MessageController) MarkGroupMessagesAsRead(c *gin.Context) {
	// 获取当前用户ID
	userID, exists := c.Get("user_id")
	if !exists {
		utils.LogDebug("❌ 获取当前用户ID失败")
		utils.Unauthorized(c, "未授权")
		return
	}

	// 解析请求体
	var req struct {
		GroupID int `json:"group_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		utils.BadRequest(c, "无效的请求参数")
		return
	}

	utils.LogDebug("📝 标记群组消息为已读: 用户ID=%v, 群组ID=%d", userID, req.GroupID)

	// 查询该群组中该用户尚未标记为已读的消息（排除用户自己发送的消息）
	query := `
		INSERT INTO group_message_reads (group_message_id, user_id, read_at)
		SELECT gm.id, $1, $2
		FROM group_messages gm
		WHERE gm.group_id = $3
			AND gm.sender_id != $1
			AND gm.id NOT IN (
				SELECT group_message_id 
				FROM group_message_reads 
				WHERE user_id = $1
			)
	`

	result, err := db.DB.Exec(query, userID, time.Now(), req.GroupID)
	if err != nil {
		utils.LogDebug("❌ 标记群组消息已读失败: %v", err)
		utils.InternalServerError(c, "标记群组消息已读失败")
		return
	}

	rowsAffected, _ := result.RowsAffected()
	utils.LogDebug("✅ 已标记群组 %d 的 %d 条消息为已读", req.GroupID, rowsAffected)

	utils.Success(c, gin.H{
		"message":       "标记成功",
		"rows_affected": rowsAffected,
	})
}

// GetMessageHistory 获取消息历史记录
func (mc *MessageController) GetMessageHistory(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		utils.LogDebug("❌ 获取当前用户ID失败")
		utils.Unauthorized(c, "未授权")
		return
	}

	otherUserIDStr := c.Param("user_id")
	otherUserID, err := strconv.Atoi(otherUserIDStr)
	if err != nil {
		utils.BadRequest(c, "无效的用户ID")
		return
	}

	utils.LogDebug("📜 查询消息历史: 当前用户=%v, 对方用户=%d", userID, otherUserID)

	// 获取分页参数
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "50"))
	offset := (page - 1) * pageSize

	// 获取当前用户ID字符串，用于过滤已删除的消息
	currentUserID := userID.(int)
	userIDStr := strconv.Itoa(currentUserID)

	// 查询两个用户之间的消息，排除已被当前用户删除的消息
	query := `
		SELECT id, sender_id, receiver_id, sender_name, receiver_name, sender_avatar, receiver_avatar, content, message_type, file_name, quoted_message_id, quoted_message_content, call_type, voice_duration, status, is_read, created_at, read_at
		FROM messages
		WHERE ((sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1))
			AND (deleted_by_users = '' OR deleted_by_users NOT LIKE '%' || $5 || '%')
		ORDER BY created_at DESC
		LIMIT $3 OFFSET $4
	`

	rows, err := db.DB.Query(query, currentUserID, otherUserID, pageSize, offset, userIDStr)
	if err != nil {
		utils.InternalServerError(c, "查询消息失败")
		return
	}
	defer rows.Close()

	var messages []models.Message
	for rows.Next() {
		var msg models.Message
		err := rows.Scan(
			&msg.ID,
			&msg.SenderID,
			&msg.ReceiverID,
			&msg.SenderName,
			&msg.ReceiverName,
			&msg.SenderAvatar,
			&msg.ReceiverAvatar,
			&msg.Content,
			&msg.MessageType,
			&msg.FileName,
			&msg.QuotedMessageID,
			&msg.QuotedMessageContent,
			&msg.CallType,
			&msg.VoiceDuration,
			&msg.Status,
			&msg.IsRead,
			&msg.CreatedAt,
			&msg.ReadAt,
		)
		if err != nil {
			continue
		}
		messages = append(messages, msg)
	}

	// 反转消息顺序（从旧到新）
	for i, j := 0, len(messages)-1; i < j; i, j = i+1, j-1 {
		messages[i], messages[j] = messages[j], messages[i]
	}

	utils.Success(c, gin.H{
		"messages":  messages,
		"page":      page,
		"page_size": pageSize,
		"total":     len(messages),
	})
}

// GetConversations 获取会话列表
func (mc *MessageController) GetConversations(c *gin.Context) {
	userID, _ := c.Get("userID")

	query := `
		WITH latest_messages AS (
			SELECT DISTINCT ON (
				CASE
					WHEN sender_id = $1 THEN receiver_id
					ELSE sender_id
				END
			)
			id,
			sender_id,
			receiver_id,
			content,
			message_type,
			created_at,
			CASE
				WHEN sender_id = $1 THEN receiver_id
				ELSE sender_id
			END as other_user_id
			FROM messages
			WHERE sender_id = $1 OR receiver_id = $1
			ORDER BY other_user_id, created_at DESC
		)
		SELECT
			lm.other_user_id,
			lm.content as last_message,
			lm.created_at as last_message_time,
			u.username,
			u.full_name,
			u.avatar,
			u.status,
			COALESCE(unread.count, 0) as unread_count
		FROM latest_messages lm
		JOIN users u ON u.id = lm.other_user_id
		LEFT JOIN (
			SELECT sender_id, COUNT(*) as count
			FROM messages
			WHERE receiver_id = $1 AND is_read = false
			GROUP BY sender_id
		) unread ON unread.sender_id = lm.other_user_id
		ORDER BY lm.created_at DESC
	`

	rows, err := db.DB.Query(query, userID)
	if err != nil {
		utils.InternalServerError(c, "查询会话列表失败")
		return
	}
	defer rows.Close()

	type Conversation struct {
		OtherUserID     int       `json:"other_user_id"`
		LastMessage     string    `json:"last_message"`
		LastMessageTime time.Time `json:"last_message_time"`
		Username        string    `json:"username"`
		FullName        *string   `json:"full_name"`
		Avatar          string    `json:"avatar"`
		Status          string    `json:"status"`
		UnreadCount     int       `json:"unread_count"`
	}

	var conversations []Conversation
	for rows.Next() {
		var conv Conversation
		err := rows.Scan(
			&conv.OtherUserID,
			&conv.LastMessage,
			&conv.LastMessageTime,
			&conv.Username,
			&conv.FullName,
			&conv.Avatar,
			&conv.Status,
			&conv.UnreadCount,
		)
		if err != nil {
			continue
		}
		conversations = append(conversations, conv)
	}

	utils.Success(c, gin.H{
		"conversations": conversations,
	})
}

// formatMessageTime 格式化消息时间（只显示月-日）
func formatMessageTime(t time.Time) string {
	now := time.Now()

	// 判断是否是今天
	if t.Year() == now.Year() && t.YearDay() == now.YearDay() {
		return "今天"
	}

	// 判断是否是昨天
	yesterday := now.AddDate(0, 0, -1)
	if t.Year() == yesterday.Year() && t.YearDay() == yesterday.YearDay() {
		return "昨天"
	}

	// 其他日期，返回月-日格式
	return t.Format("01-02")
}

// formatFullMessageTime 格式化消息时间（完整的年月日和时间）
func formatFullMessageTime(t time.Time) string {
	now := time.Now()

	// 判断是否是今天
	if t.Year() == now.Year() && t.YearDay() == now.YearDay() {
		return "今天 " + t.Format("15:04:05")
	}

	// 判断是否是昨天
	yesterday := now.AddDate(0, 0, -1)
	if t.Year() == yesterday.Year() && t.YearDay() == yesterday.YearDay() {
		return "昨天 " + t.Format("15:04:05")
	}

	// 其他日期，返回完整的年月日和时间
	return t.Format("2006-01-02 15:04:05")
}

// RecentContact 最近联系人结构
type RecentContact struct {
	Type            string  `json:"type"`                 // 类型：user 或 group
	UserID          int     `json:"user_id"`              // 用户ID或群组ID
	Username        string  `json:"username"`             // 用户名
	FullName        string  `json:"full_name"`            // 全名或群组名
	Avatar          string  `json:"avatar,omitempty"`     // 用户头像URL
	LastMessageTime string  `json:"last_message_time"`    // 最后消息时间
	LastMessage     string  `json:"last_message"`         // 最后消息内容
	UnreadCount     int     `json:"unread_count"`         // 未读消息数量
	Status          string  `json:"status"`               // 用户状态：online, busy, away, offline（群组固定为online）
	GroupID         int     `json:"group_id,omitempty"`   // 群组ID（仅群组类型）
	GroupName       string  `json:"group_name,omitempty"` // 群组名称（仅群组类型）
	Remark          *string `json:"remark,omitempty"`     // 用户对群组的备注（仅群组类型）
	DoNotDisturb    bool    `json:"do_not_disturb"`       // 消息免打扰（仅群组类型）
}

// GetRecentContacts 获取最近30个联系人列表
func (mc *MessageController) GetRecentContacts(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		utils.LogDebug("❌ 获取用户ID失败")
		utils.Unauthorized(c, "未授权")
		return
	}
	utils.LogDebug("✅ 获取用户ID成功: %v", userID)

	// 查询列表1：用户作为发送者的最近联系人
	query1 := `
		SELECT 
			u.username,
			COALESCE(u.full_name, '') as full_name,
			COALESCE(u.avatar, '') as avatar,
			m.created_at,
			m.content
		FROM (
			SELECT 
				receiver_id,
				MAX(created_at) as created_at
			FROM messages
			WHERE sender_id = $1
			GROUP BY receiver_id
			ORDER BY created_at DESC
			LIMIT 30
		) AS latest
		JOIN messages m ON m.receiver_id = latest.receiver_id 
			AND m.created_at = latest.created_at 
			AND m.sender_id = $1
		JOIN users u ON u.id = latest.receiver_id
	`

	// 查询列表2：用户作为接收者的最近联系人
	query2 := `
		SELECT 
			u.username,
			COALESCE(u.full_name, '') as full_name,
			COALESCE(u.avatar, '') as avatar,
			m.created_at,
			m.content
		FROM (
			SELECT 
				sender_id,
				MAX(created_at) as created_at
			FROM messages
			WHERE receiver_id = $1
			GROUP BY sender_id
			ORDER BY created_at DESC
			LIMIT 30
		) AS latest
		JOIN messages m ON m.sender_id = latest.sender_id 
			AND m.created_at = latest.created_at 
			AND m.receiver_id = $1
		JOIN users u ON u.id = latest.sender_id
	`

	// 执行第一个查询
	rows1, err := db.DB.Query(query1, userID)
	if err != nil {
		utils.LogDebug("查询发送者联系人列表失败: %v", err)
		utils.InternalServerError(c, "查询联系人列表失败")
		return
	}
	defer rows1.Close()

	contactsMap := make(map[string]*RecentContact)

	for rows1.Next() {
		var username, fullName, avatar, content string
		var createdAt time.Time

		err := rows1.Scan(&username, &fullName, &avatar, &createdAt, &content)
		if err != nil {
			utils.LogDebug("扫描数据失败: %v", err)
			continue
		}

		contactsMap[username] = &RecentContact{
			Username:        username,
			FullName:        fullName,
			Avatar:          avatar,
			LastMessageTime: formatMessageTime(createdAt),
			LastMessage:     content,
		}
	}

	// 执行第二个查询
	rows2, err := db.DB.Query(query2, userID)
	if err != nil {
		utils.LogDebug("查询接收者联系人列表失败: %v", err)
		utils.InternalServerError(c, "查询联系人列表失败")
		return
	}
	defer rows2.Close()

	type ContactWithTime struct {
		Contact   RecentContact
		Timestamp time.Time
	}

	var contactsWithTime []ContactWithTime

	for rows2.Next() {
		var username, fullName, avatar, content string
		var createdAt time.Time

		err := rows2.Scan(&username, &fullName, &avatar, &createdAt, &content)
		if err != nil {
			utils.LogDebug("扫描数据失败: %v", err)
			continue
		}

		contact := RecentContact{
			Username:        username,
			FullName:        fullName,
			Avatar:          avatar,
			LastMessageTime: formatMessageTime(createdAt),
			LastMessage:     content,
		}

		// 如果这个用户在列表1中已存在，比较时间，保留更新的
		if existingContact, exists := contactsMap[username]; exists {
			// 需要重新查询时间戳进行比较
			// 这里我们简单处理，把两个列表都加入，后面统一排序去重
			contactsWithTime = append(contactsWithTime, ContactWithTime{
				Contact:   *existingContact,
				Timestamp: time.Time{}, // 需要存储原始时间
			})
			delete(contactsMap, username)
		}

		contactsWithTime = append(contactsWithTime, ContactWithTime{
			Contact:   contact,
			Timestamp: createdAt,
		})
	}

	// 将列表1中剩余的联系人加入
	for _, contact := range contactsMap {
		contactsWithTime = append(contactsWithTime, ContactWithTime{
			Contact:   *contact,
			Timestamp: time.Time{}, // 需要存储原始时间
		})
	}

	// 合并私聊和群聊的查询，使用统一的WITH子句
	// 获取当前用户ID字符串，用于过滤已删除的消息
	currentUserID := userID.(int)
	userIDStr := strconv.Itoa(currentUserID)

	finalQuery := `
		WITH user_contacts AS (
			-- 私聊联系人（排除已被当前用户删除的消息）
			SELECT 
				CASE 
					WHEN sender_id = $1 THEN receiver_id
					ELSE sender_id
				END as contact_id,
				MAX(created_at) as last_time
			FROM messages
			WHERE (sender_id = $1 OR receiver_id = $1)
				AND (deleted_by_users = '' OR deleted_by_users NOT LIKE '%' || $2 || '%')
			GROUP BY contact_id
		),
		user_groups AS (
			-- 用户所在的群组
			SELECT DISTINCT gm.group_id
			FROM group_members gm
			WHERE gm.user_id = $1
		),
		group_last_messages AS (
			-- 每个群组的最后一条消息（排除已被当前用户删除的消息）
			SELECT 
				gm2.group_id,
				MAX(gm2.created_at) as last_time
			FROM group_messages gm2
			WHERE gm2.group_id IN (SELECT group_id FROM user_groups)
				AND (gm2.deleted_by_users = '' OR gm2.deleted_by_users NOT LIKE '%' || $2 || '%')
			GROUP BY gm2.group_id
		),
		private_contacts AS (
			-- 私聊联系人详情
			SELECT 
				'user' as type,
				uc.contact_id as id,
				u.username,
				COALESCE(u.full_name, '') as full_name,
				COALESCE(u.avatar, '') as avatar,
				uc.last_time,
				m.content,
				m.message_type,
				m.status as message_status,
				COALESCE(unread.count, 0) as unread_count,
				COALESCE(u.status, 'offline') as status,
				NULL::integer as group_id,
				NULL::text as group_name,
				NULL::text as remark,
				false as do_not_disturb
			FROM user_contacts uc
			JOIN users u ON u.id = uc.contact_id
			JOIN messages m ON (
				(m.sender_id = uc.contact_id AND m.receiver_id = $1) OR
				(m.sender_id = $1 AND m.receiver_id = uc.contact_id)
			) AND m.created_at = uc.last_time
				AND (m.deleted_by_users = '' OR m.deleted_by_users NOT LIKE '%' || $2 || '%')
			LEFT JOIN (
				SELECT sender_id, COUNT(*) as count
				FROM messages
				WHERE receiver_id = $1 AND is_read = false
					AND (deleted_by_users = '' OR deleted_by_users NOT LIKE '%' || $2 || '%')
				GROUP BY sender_id
			) unread ON unread.sender_id = uc.contact_id
		),
		group_contacts AS (
			-- 群组联系人详情
			SELECT
				'group' as type,
				g.id,
				'' as username,
				g.name as full_name,
				'' as avatar,
				glm.last_time,
				gm2.content,
				gm2.message_type,
				gm2.status as message_status,
				COALESCE(
					(SELECT COUNT(*)
					FROM group_messages gm3
					WHERE gm3.group_id = g.id
						AND gm3.sender_id != $1
						AND (gm3.deleted_by_users = '' OR gm3.deleted_by_users NOT LIKE '%' || $2 || '%')
						AND gm3.id NOT IN (
							SELECT group_message_id
							FROM group_message_reads
							WHERE user_id = $1
						)
					), 0
				) as unread_count,
				'online' as status,
				g.id as group_id,
				g.name as group_name,
				gmem.remark as remark,
				COALESCE(gmem.do_not_disturb, false) as do_not_disturb
			FROM group_last_messages glm
			JOIN groups g ON g.id = glm.group_id AND g.deleted_at IS NULL
			JOIN group_messages gm2 ON gm2.group_id = glm.group_id
				AND gm2.created_at = glm.last_time
				AND (gm2.deleted_by_users = '' OR gm2.deleted_by_users NOT LIKE '%' || $2 || '%')
			LEFT JOIN group_members gmem ON gmem.group_id = g.id AND gmem.user_id = $1
		)
		-- 合并私聊和群聊，并按时间排序
		SELECT * FROM private_contacts
		UNION ALL
		SELECT * FROM group_contacts
		ORDER BY last_time DESC
		LIMIT 30
	`

	rows, err := db.DB.Query(finalQuery, currentUserID, userIDStr)
	if err != nil {
		utils.LogDebug("查询最近联系人失败: %v", err)
		utils.InternalServerError(c, "查询联系人列表失败")
		return
	}
	defer rows.Close()

	var contacts []RecentContact
	for rows.Next() {
		var contactType string
		var id int
		var username, fullName, avatar, content, messageType, messageStatus, status string
		var createdAt time.Time
		var unreadCount int
		var groupID sql.NullInt64
		var groupName sql.NullString
		var remark sql.NullString
		var doNotDisturb bool

		err := rows.Scan(&contactType, &id, &username, &fullName, &avatar, &createdAt, &content, &messageType, &messageStatus, &unreadCount, &status, &groupID, &groupName, &remark, &doNotDisturb)
		if err != nil {
			utils.LogDebug("扫描数据失败: %v", err)
			continue
		}

		// 如果消息已被撤回，显示"此消息已被撤销"
		if messageStatus == "recalled" {
			contact := RecentContact{
				Type:            contactType,
				UserID:          id,
				Username:        username,
				FullName:        fullName,
				Avatar:          avatar,
				LastMessageTime: formatMessageTime(createdAt),
				LastMessage:     "此消息已被撤销",
				UnreadCount:     unreadCount,
				Status:          status,
				DoNotDisturb:    doNotDisturb,
			}

			// 如果是群组类型，设置群组相关字段
			if contactType == "group" && groupID.Valid {
				contact.GroupID = int(groupID.Int64)
				if groupName.Valid {
					contact.GroupName = groupName.String
				}
				// 设置备注（如果有）
				if remark.Valid && remark.String != "" {
					remarkStr := remark.String
					contact.Remark = &remarkStr
				}
			}

			contacts = append(contacts, contact)
			continue
		}

		// 根据消息类型格式化显示内容
		var displayContent string
		switch messageType {
		case "image":
			displayContent = "[图片]"
		case "video":
			displayContent = "[视频]"
		case "file":
			displayContent = "[文件]"
		default:
			displayContent = content
		}

		contact := RecentContact{
			Type:            contactType,
			UserID:          id,
			Username:        username,
			FullName:        fullName,
			Avatar:          avatar,
			LastMessageTime: formatMessageTime(createdAt),
			LastMessage:     displayContent,
			UnreadCount:     unreadCount,
			Status:          status,
			DoNotDisturb:    doNotDisturb,
		}

		// 如果是群组类型，设置群组相关字段
		if contactType == "group" && groupID.Valid {
			contact.GroupID = int(groupID.Int64)
			if groupName.Valid {
				contact.GroupName = groupName.String
			}
			// 设置备注（如果有）
			if remark.Valid && remark.String != "" {
				remarkStr := remark.String
				contact.Remark = &remarkStr
			}
		}

		contacts = append(contacts, contact)
	}

	// 如果没有联系人，返回空数组而不是null
	if contacts == nil {
		contacts = []RecentContact{}
	}

	// 注意：文件助手由前端固定显示，不在后端返回的联系人列表中

	utils.LogDebug("返回最近联系人列表，共 %d 个联系人（包含私聊和群聊）", len(contacts))
	utils.Success(c, gin.H{
		"contacts": contacts,
	})
}

// ConversationMessage 对话消息结构
type ConversationMessage struct {
	SentTime     string `json:"sent_time"`
	Content      string `json:"content"`
	SenderName   string `json:"sender_name"`
	ReceiverName string `json:"receiver_name"`
}

// GetConversationMessages 查询联系人的对话记录（分页）
func (mc *MessageController) GetConversationMessages(c *gin.Context) {
	// 从上下文中获取用户ID（需要认证中间件）
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	// 获取联系人ID
	contactIDStr := c.Param("contact_id")
	contactID, err := strconv.Atoi(contactIDStr)
	if err != nil {
		utils.BadRequest(c, "无效的联系人ID")
		return
	}

	// 获取分页参数，默认第1页，每页30条
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "30"))

	// 限制每页最多30条
	if pageSize > 30 {
		pageSize = 30
	}

	offset := (page - 1) * pageSize

	// 获取当前用户ID字符串，用于过滤已删除的消息
	currentUserID := userID.(int)
	userIDStr := strconv.Itoa(currentUserID)

	// 查询两个用户之间的消息，按时间倒序，排除已被当前用户删除的消息
	query := `
		SELECT 
			created_at,
			content,
			sender_name,
			receiver_name
		FROM messages
		WHERE ((sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1))
			AND (deleted_by_users = '' OR deleted_by_users NOT LIKE '%' || $5 || '%')
		ORDER BY created_at DESC
		LIMIT $3 OFFSET $4
	`

	rows, err := db.DB.Query(query, currentUserID, contactID, pageSize, offset, userIDStr)
	if err != nil {
		utils.LogDebug("查询对话记录失败: %v", err)
		utils.InternalServerError(c, "查询对话记录失败")
		return
	}
	defer rows.Close()

	var messages []ConversationMessage
	for rows.Next() {
		var msg ConversationMessage
		var createdAt time.Time

		err := rows.Scan(
			&createdAt,
			&msg.Content,
			&msg.SenderName,
			&msg.ReceiverName,
		)
		if err != nil {
			utils.LogDebug("扫描消息数据失败: %v", err)
			continue
		}

		// 格式化时间
		msg.SentTime = formatFullMessageTime(createdAt)
		messages = append(messages, msg)
	}

	if err = rows.Err(); err != nil {
		utils.LogDebug("查询对话记录出错: %v", err)
		utils.InternalServerError(c, "查询对话记录失败")
		return
	}

	// 如果没有消息，返回空数组而不是null
	if messages == nil {
		messages = []ConversationMessage{}
	}

	// 查询总消息数（排除已删除的消息）
	var total int
	countQuery := `
		SELECT COUNT(*)
		FROM messages
		WHERE ((sender_id = $1 AND receiver_id = $2) OR (sender_id = $2 AND receiver_id = $1))
			AND (deleted_by_users = '' OR deleted_by_users NOT LIKE '%' || $3 || '%')
	`
	err = db.DB.QueryRow(countQuery, currentUserID, contactID, userIDStr).Scan(&total)
	if err != nil {
		utils.LogDebug("查询消息总数失败: %v", err)
		total = 0
	}

	utils.Success(c, gin.H{
		"messages":  messages,
		"page":      page,
		"page_size": pageSize,
		"total":     total,
	})
}

// handleMessageRecall 处理WebSocket消息撤回请求
func (mc *MessageController) handleMessageRecall(client *ws.Client, wsMsg models.WSMessage) {
	// 解析撤回请求数据
	dataMap, ok := wsMsg.Data.(map[string]interface{})
	if !ok {
		utils.LogDebug("❌ [消息撤回] 数据格式错误")
		return
	}

	// 获取消息ID
	var messageID int
	if messageIDFloat, ok := dataMap["messageId"].(float64); ok {
		messageID = int(messageIDFloat)
	} else if messageIDInt, ok := dataMap["messageId"].(int); ok {
		messageID = messageIDInt
	} else {
		utils.LogDebug("❌ [消息撤回] 缺少消息ID")
		return
	}

	// 获取是否是群组消息
	isGroup := false
	if isGroupBool, ok := dataMap["isGroup"].(bool); ok {
		isGroup = isGroupBool
	}

	currentUserID := client.UserID
	utils.LogDebug("📤 [消息撤回] 收到撤回请求 - 用户ID: %d, 消息ID: %d, 是否群组: %v", currentUserID, messageID, isGroup)

	if isGroup {
		// 处理群组消息撤回
		mc.handleGroupMessageRecall(client, messageID, currentUserID)
	} else {
		// 处理私聊消息撤回
		mc.handlePrivateMessageRecall(client, messageID, currentUserID)
	}
}

// handleGroupMessageRecall 处理群组消息撤回
func (mc *MessageController) handleGroupMessageRecall(client *ws.Client, messageID int, currentUserID int) {
	// 查询群组消息
	var groupMessage models.GroupMessage
	groupQuery := `SELECT id, group_id, sender_id, created_at, status FROM group_messages WHERE id = $1`
	err := db.DB.QueryRow(groupQuery, messageID).Scan(
		&groupMessage.ID,
		&groupMessage.GroupID,
		&groupMessage.SenderID,
		&groupMessage.CreatedAt,
		&groupMessage.Status,
	)

	if err != nil {
		utils.LogDebug("❌ [群组消息撤回] 消息不存在: %v", err)
		mc.sendRecallError(client, "消息不存在")
		return
	}

	// 检查消息状态
	if groupMessage.Status == "recalled" {
		utils.LogDebug("⚠️ [群组消息撤回] 消息已被撤回")
		mc.sendRecallError(client, "消息已被撤回")
		return
	}

	// 检查是否在3分钟内
	now := time.Now()
	diff := now.Sub(groupMessage.CreatedAt)
	if diff.Minutes() > 3 {
		utils.LogDebug("⚠️ [群组消息撤回] 超过3分钟，无法撤回")
		mc.sendRecallError(client, "超过3分钟，无法撤回")
		return
	}

	// 检查当前用户是否是群主或管理员
	role, err := mc.groupRepo.GetUserGroupRole(groupMessage.GroupID, currentUserID)
	if err != nil {
		utils.LogDebug("❌ [群组消息撤回] 用户不是群组成员: %v", err)
		mc.sendRecallError(client, "您不是该群组成员")
		return
	}

	// 如果是发送者本人，或者群主/管理员，允许撤回
	if groupMessage.SenderID != currentUserID && role != "owner" && role != "admin" {
		utils.LogDebug("❌ [群组消息撤回] 无权撤回此消息")
		mc.sendRecallError(client, "只能撤回自己发送的消息，或需要群主/管理员权限")
		return
	}

	// 更新群组消息状态为已撤回
	updateQuery := `UPDATE group_messages SET status = 'recalled' WHERE id = $1`
	_, err = db.DB.Exec(updateQuery, messageID)
	if err != nil {
		utils.LogDebug("❌ [群组消息撤回] 更新数据库失败: %v", err)
		mc.sendRecallError(client, "撤回消息失败")
		return
	}

	utils.LogDebug("✅ [群组消息撤回] 用户 %d 撤回了群组消息 %d (群组ID: %d)", currentUserID, messageID, groupMessage.GroupID)

	// 获取群组所有成员ID
	memberIDs, err := mc.groupRepo.GetGroupMemberIDs(groupMessage.GroupID)
	if err != nil {
		utils.LogDebug("⚠️ [群组消息撤回] 获取群组成员ID列表失败: %v", err)
	} else {
		// 通过WebSocket实时通知所有群组成员消息被撤回
		recallNotification := models.WSMessage{
			Type: "message_recalled",
			Data: gin.H{
				"message_id": messageID,
				"sender_id":  currentUserID,
				"group_id":   groupMessage.GroupID,
			},
		}
		recallNotificationBytes, _ := json.Marshal(recallNotification)

		// 发送给所有群组成员（包括发送者自己，用于确认撤回成功）
		sentCount := 0
		for _, memberID := range memberIDs {
			if mc.Hub.SendToUser(memberID, recallNotificationBytes) {
				sentCount++
			}
		}
		utils.LogDebug("✅ [群组消息撤回] 撤回通知已发送给群组 %d 的 %d 个成员", groupMessage.GroupID, sentCount)
	}

	// 发送撤回成功确认给发送者
	mc.sendRecallSuccess(client, messageID)
}

// handlePrivateMessageRecall 处理私聊消息撤回
func (mc *MessageController) handlePrivateMessageRecall(client *ws.Client, messageID int, currentUserID int) {
	// 查询私聊消息
	var message models.Message
	query := `SELECT id, sender_id, receiver_id, created_at, status FROM messages WHERE id = $1`
	err := db.DB.QueryRow(query, messageID).Scan(
		&message.ID,
		&message.SenderID,
		&message.ReceiverID,
		&message.CreatedAt,
		&message.Status,
	)

	if err != nil {
		utils.LogDebug("❌ [私聊消息撤回] 消息不存在: %v", err)
		mc.sendRecallError(client, "消息不存在")
		return
	}

	// 检查是否是发送者
	if message.SenderID != currentUserID {
		utils.LogDebug("❌ [私聊消息撤回] 只能撤回自己发送的消息")
		mc.sendRecallError(client, "只能撤回自己发送的消息")
		return
	}

	// 检查消息状态
	if message.Status == "recalled" {
		utils.LogDebug("⚠️ [私聊消息撤回] 消息已被撤回")
		mc.sendRecallError(client, "消息已被撤回")
		return
	}

	// 检查是否在3分钟内
	now := time.Now()
	diff := now.Sub(message.CreatedAt)
	if diff.Minutes() > 3 {
		utils.LogDebug("⚠️ [私聊消息撤回] 超过3分钟，无法撤回")
		mc.sendRecallError(client, "超过3分钟，无法撤回")
		return
	}

	// 更新消息状态为已撤回
	updateQuery := `UPDATE messages SET status = 'recalled' WHERE id = $1`
	_, err = db.DB.Exec(updateQuery, messageID)
	if err != nil {
		utils.LogDebug("❌ [私聊消息撤回] 更新数据库失败: %v", err)
		mc.sendRecallError(client, "撤回消息失败")
		return
	}

	utils.LogDebug("✅ [私聊消息撤回] 用户 %d 撤回了消息 %d", currentUserID, messageID)

	// 通过WebSocket实时通知接收者消息被撤回
	recallNotification := models.WSMessage{
		Type: "message_recalled",
		Data: gin.H{
			"message_id": messageID,
			"sender_id":  currentUserID,
		},
	}
	recallNotificationBytes, _ := json.Marshal(recallNotification)

	// 发送给接收者
	if mc.Hub.SendToUser(message.ReceiverID, recallNotificationBytes) {
		utils.LogDebug("✅ [私聊消息撤回] 撤回通知已发送给接收者 %d", message.ReceiverID)
	} else {
		utils.LogDebug("⚠️ [私聊消息撤回] 接收者 %d 离线，下次登录时将看到消息已撤回", message.ReceiverID)
	}

	// 发送撤回成功确认给发送者
	mc.sendRecallSuccess(client, messageID)
}

// sendRecallError 发送撤回错误消息
func (mc *MessageController) sendRecallError(client *ws.Client, errorMsg string) {
	response := models.WSMessage{
		Type: "recall_error",
		Data: gin.H{
			"error": errorMsg,
		},
	}
	responseBytes, _ := json.Marshal(response)
	client.Send <- responseBytes
}

// sendRecallSuccess 发送撤回成功消息
func (mc *MessageController) sendRecallSuccess(client *ws.Client, messageID int) {
	response := models.WSMessage{
		Type: "recall_success",
		Data: gin.H{
			"message_id": messageID,
			"message":    "消息已撤回",
		},
	}
	responseBytes, _ := json.Marshal(response)
	client.Send <- responseBytes
}

// RecallMessage 撤回消息（3分钟内）
func (mc *MessageController) RecallMessage(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	var req struct {
		MessageID int `json:"message_id" binding:"required"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "请求参数错误")
		return
	}

	currentUserID := userID.(int)

	// 首先检查是否是群组消息
	var groupMessage models.GroupMessage
	groupQuery := `SELECT id, group_id, sender_id, created_at, status FROM group_messages WHERE id = $1`
	err := db.DB.QueryRow(groupQuery, req.MessageID).Scan(
		&groupMessage.ID,
		&groupMessage.GroupID,
		&groupMessage.SenderID,
		&groupMessage.CreatedAt,
		&groupMessage.Status,
	)

	if err == nil {
		// 是群组消息
		// 检查消息状态
		if groupMessage.Status == "recalled" {
			utils.Error(c, http.StatusBadRequest, "消息已被撤回")
			return
		}

		// 检查是否在3分钟内
		now := time.Now()
		diff := now.Sub(groupMessage.CreatedAt)
		if diff.Minutes() > 3 {
			utils.Error(c, http.StatusBadRequest, "超过3分钟，无法撤回")
			return
		}

		// 检查当前用户是否是群主或管理员
		role, err := mc.groupRepo.GetUserGroupRole(groupMessage.GroupID, currentUserID)
		if err != nil {
			utils.Error(c, http.StatusForbidden, "您不是该群组成员")
			return
		}

		// 如果是发送者本人，或者群主/管理员，允许撤回
		if groupMessage.SenderID != currentUserID && role != "owner" && role != "admin" {
			utils.Error(c, http.StatusForbidden, "只能撤回自己发送的消息，或需要群主/管理员权限")
			return
		}

		// 更新群组消息状态为已撤回
		updateQuery := `UPDATE group_messages SET status = 'recalled' WHERE id = $1`
		_, err = db.DB.Exec(updateQuery, req.MessageID)
		if err != nil {
			utils.LogDebug("❌ 撤回群组消息失败: %v", err)
			utils.Error(c, http.StatusInternalServerError, "撤回消息失败")
			return
		}

		utils.LogDebug("✅ 用户 %d 撤回了群组消息 %d (群组ID: %d)", currentUserID, req.MessageID, groupMessage.GroupID)

		// 获取群组所有成员ID
		memberIDs, err := mc.groupRepo.GetGroupMemberIDs(groupMessage.GroupID)
		if err != nil {
			utils.LogDebug("获取群组成员ID列表失败: %v", err)
		} else {
			// 通过WebSocket实时通知所有群组成员消息被撤回
			recallNotification := models.WSMessage{
				Type: "message_recalled",
				Data: gin.H{
					"message_id": req.MessageID,
					"sender_id":  currentUserID,
				},
			}
			recallNotificationBytes, _ := json.Marshal(recallNotification)

			// 发送给所有群组成员
			sentCount := 0
			for _, memberID := range memberIDs {
				if mc.Hub.SendToUser(memberID, recallNotificationBytes) {
					sentCount++
				}
			}
			utils.LogDebug("✅ 撤回通知已发送给群组 %d 的 %d 个成员", groupMessage.GroupID, sentCount)
		}

		utils.Success(c, gin.H{"message": "消息已撤回"})
		return
	}

	// 不是群组消息，检查是否是私聊消息
	var message models.Message
	query := `SELECT id, sender_id, receiver_id, created_at, status FROM messages WHERE id = $1`
	err = db.DB.QueryRow(query, req.MessageID).Scan(
		&message.ID,
		&message.SenderID,
		&message.ReceiverID,
		&message.CreatedAt,
		&message.Status,
	)

	if err != nil {
		utils.Error(c, http.StatusNotFound, "消息不存在")
		return
	}

	// 检查是否是发送者
	if message.SenderID != currentUserID {
		utils.Error(c, http.StatusForbidden, "只能撤回自己发送的消息")
		return
	}

	// 检查消息状态
	if message.Status == "recalled" {
		utils.Error(c, http.StatusBadRequest, "消息已被撤回")
		return
	}

	// 检查是否在3分钟内
	now := time.Now()
	diff := now.Sub(message.CreatedAt)
	if diff.Minutes() > 3 {
		utils.Error(c, http.StatusBadRequest, "超过3分钟，无法撤回")
		return
	}

	// 更新消息状态为已撤回
	updateQuery := `UPDATE messages SET status = 'recalled' WHERE id = $1`
	_, err = db.DB.Exec(updateQuery, req.MessageID)
	if err != nil {
		utils.LogDebug("❌ 撤回消息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "撤回消息失败")
		return
	}

	utils.LogDebug("✅ 用户 %d 撤回了消息 %d", currentUserID, req.MessageID)

	// 通过WebSocket实时通知接收者消息被撤回
	recallNotification := models.WSMessage{
		Type: "message_recalled",
		Data: gin.H{
			"message_id": req.MessageID,
			"sender_id":  currentUserID,
		},
	}
	recallNotificationBytes, _ := json.Marshal(recallNotification)

	// 发送给接收者
	if mc.Hub.SendToUser(message.ReceiverID, recallNotificationBytes) {
		utils.LogDebug("✅ 撤回通知已发送给接收者 %d", message.ReceiverID)
	} else {
		utils.LogDebug("⚠️ 接收者 %d 离线，下次登录时将看到消息已撤回", message.ReceiverID)
	}

	utils.Success(c, gin.H{"message": "消息已撤回"})
}

// DeleteMessage 删除消息（仅当前用户不可见）
func (mc *MessageController) DeleteMessage(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	messageIDStr := c.Param("id")
	messageID, err := strconv.Atoi(messageIDStr)
	if err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的消息ID")
		return
	}

	currentUserID := userID.(int)
	userIDStr := strconv.Itoa(currentUserID)

	// 先从私聊消息表查询
	var message models.Message
	query := `SELECT id, sender_id, receiver_id, deleted_by_users FROM messages WHERE id = $1`
	err = db.DB.QueryRow(query, messageID).Scan(
		&message.ID,
		&message.SenderID,
		&message.ReceiverID,
		&message.DeletedByUsers,
	)

	// 如果在私聊消息表中找不到，尝试从群消息表查找
	if err == sql.ErrNoRows {
		utils.LogDebug("消息ID %d 不在 messages 表中，尝试从 group_messages 表查找", messageID)

		var groupMessage struct {
			ID             int
			GroupID        int
			SenderID       int
			DeletedByUsers string
		}

		groupQuery := `SELECT id, group_id, sender_id, deleted_by_users FROM group_messages WHERE id = $1`
		err = db.DB.QueryRow(groupQuery, messageID).Scan(
			&groupMessage.ID,
			&groupMessage.GroupID,
			&groupMessage.SenderID,
			&groupMessage.DeletedByUsers,
		)

		if err != nil {
			if err == sql.ErrNoRows {
				utils.LogError("消息ID %d 在 messages 和 group_messages 表中都不存在", messageID)
				utils.Error(c, http.StatusNotFound, "消息不存在")
			} else {
				utils.LogError("查询群组消息失败 (message_id: %d): %v", messageID, err)
				utils.Error(c, http.StatusInternalServerError, "查询消息失败")
			}
			return
		}

		// 验证用户是否是群成员
		var isMember bool
		memberQuery := `SELECT COUNT(*) > 0 FROM group_members WHERE group_id = $1 AND user_id = $2`
		err = db.DB.QueryRow(memberQuery, groupMessage.GroupID, currentUserID).Scan(&isMember)
		if err != nil {
			utils.LogError("检查群成员失败: %v", err)
			utils.Error(c, http.StatusInternalServerError, "检查权限失败")
			return
		}

		if !isMember {
			utils.Error(c, http.StatusForbidden, "无权删除此消息")
			return
		}

		// 检查是否已删除
		deletedUserIDs := strings.Split(groupMessage.DeletedByUsers, ",")
		for _, id := range deletedUserIDs {
			if strings.TrimSpace(id) == userIDStr {
				utils.Error(c, http.StatusBadRequest, "消息已被删除")
				return
			}
		}

		// 添加当前用户ID到删除列表
		var newDeletedByUsers string
		if groupMessage.DeletedByUsers == "" {
			newDeletedByUsers = userIDStr
		} else {
			newDeletedByUsers = groupMessage.DeletedByUsers + "," + userIDStr
		}

		// 更新群消息的deleted_by_users字段
		updateQuery := `UPDATE group_messages SET deleted_by_users = $1 WHERE id = $2`
		_, err = db.DB.Exec(updateQuery, newDeletedByUsers, messageID)
		if err != nil {
			utils.LogDebug("❌ 删除群消息失败: %v", err)
			utils.Error(c, http.StatusInternalServerError, "删除消息失败")
			return
		}

		utils.LogDebug("✅ 用户 %d 删除了群消息 %d", currentUserID, messageID)
		utils.Success(c, gin.H{"message": "消息已删除"})
		return

	} else if err != nil {
		// 查询私聊消息时出现其他错误
		utils.LogError("查询私聊消息失败 (message_id: %d): %v", messageID, err)
		utils.Error(c, http.StatusInternalServerError, "查询消息失败")
		return
	}

	// 处理私聊消息删除
	if message.SenderID != currentUserID && message.ReceiverID != currentUserID {
		utils.Error(c, http.StatusForbidden, "无权删除此消息")
		return
	}

	// 检查是否已删除
	deletedUserIDs := strings.Split(message.DeletedByUsers, ",")
	for _, id := range deletedUserIDs {
		if strings.TrimSpace(id) == userIDStr {
			utils.Error(c, http.StatusBadRequest, "消息已被删除")
			return
		}
	}

	// 添加当前用户ID到删除列表
	var newDeletedByUsers string
	if message.DeletedByUsers == "" {
		newDeletedByUsers = userIDStr
	} else {
		newDeletedByUsers = message.DeletedByUsers + "," + userIDStr
	}

	// 更新私聊消息的deleted_by_users字段
	updateQuery := `UPDATE messages SET deleted_by_users = $1 WHERE id = $2`
	_, err = db.DB.Exec(updateQuery, newDeletedByUsers, messageID)
	if err != nil {
		utils.LogDebug("❌ 删除消息失败: %v", err)
		utils.Error(c, http.StatusInternalServerError, "删除消息失败")
		return
	}

	utils.LogDebug("✅ 用户 %d 删除了消息 %d", currentUserID, messageID)
	utils.Success(c, gin.H{"message": "消息已删除"})
}

// BatchDeleteMessages 批量删除消息（仅当前用户不可见）
func (mc *MessageController) BatchDeleteMessages(c *gin.Context) {
	userID, exists := c.Get("user_id")
	if !exists {
		utils.Unauthorized(c, "未授权")
		return
	}

	// 解析请求体
	var req struct {
		MessageIDs []int `json:"message_ids" binding:"required"`
	}

	if err := c.ShouldBindJSON(&req); err != nil {
		utils.Error(c, http.StatusBadRequest, "无效的请求参数")
		return
	}

	if len(req.MessageIDs) == 0 {
		utils.Error(c, http.StatusBadRequest, "消息ID列表不能为空")
		return
	}

	currentUserID := userID.(int)
	userIDStr := strconv.Itoa(currentUserID)

	successCount := 0
	failedCount := 0
	var errors []string

	// 逐条处理每个消息
	for _, messageID := range req.MessageIDs {
		// 先从私聊消息表查询
		var message models.Message
		query := `SELECT id, sender_id, receiver_id, deleted_by_users FROM messages WHERE id = $1`
		err := db.DB.QueryRow(query, messageID).Scan(
			&message.ID,
			&message.SenderID,
			&message.ReceiverID,
			&message.DeletedByUsers,
		)

		// 如果在私聊消息表中找不到，尝试从群消息表查找
		if err == sql.ErrNoRows {
			var groupMessage struct {
				ID             int
				GroupID        int
				SenderID       int
				DeletedByUsers string
			}

			groupQuery := `SELECT id, group_id, sender_id, deleted_by_users FROM group_messages WHERE id = $1`
			err = db.DB.QueryRow(groupQuery, messageID).Scan(
				&groupMessage.ID,
				&groupMessage.GroupID,
				&groupMessage.SenderID,
				&groupMessage.DeletedByUsers,
			)

			if err != nil {
				failedCount++
				errors = append(errors, "消息 "+strconv.Itoa(messageID)+" 不存在")
				continue
			}

			// 验证用户是否是群成员
			var isMember bool
			memberQuery := `SELECT COUNT(*) > 0 FROM group_members WHERE group_id = $1 AND user_id = $2`
			err = db.DB.QueryRow(memberQuery, groupMessage.GroupID, currentUserID).Scan(&isMember)
			if err != nil || !isMember {
				failedCount++
				errors = append(errors, "无权删除消息 "+strconv.Itoa(messageID))
				continue
			}

			// 检查是否已删除
			deletedUserIDs := strings.Split(groupMessage.DeletedByUsers, ",")
			alreadyDeleted := false
			for _, id := range deletedUserIDs {
				if strings.TrimSpace(id) == userIDStr {
					alreadyDeleted = true
					break
				}
			}

			if alreadyDeleted {
				failedCount++
				errors = append(errors, "消息 "+strconv.Itoa(messageID)+" 已被删除")
				continue
			}

			// 添加当前用户ID到删除列表
			var newDeletedByUsers string
			if groupMessage.DeletedByUsers == "" {
				newDeletedByUsers = userIDStr
			} else {
				newDeletedByUsers = groupMessage.DeletedByUsers + "," + userIDStr
			}

			// 更新群消息的deleted_by_users字段
			updateQuery := `UPDATE group_messages SET deleted_by_users = $1 WHERE id = $2`
			_, err = db.DB.Exec(updateQuery, newDeletedByUsers, messageID)
			if err != nil {
				utils.LogDebug("❌ 批量删除群消息失败: %v", err)
				failedCount++
				errors = append(errors, "删除消息 "+strconv.Itoa(messageID)+" 失败")
				continue
			}

			successCount++
			continue
		} else if err != nil {
			failedCount++
			errors = append(errors, "查询消息 "+strconv.Itoa(messageID)+" 失败")
			continue
		}

		// 处理私聊消息删除
		// 检查是否是发送者或接收者
		if message.SenderID != currentUserID && message.ReceiverID != currentUserID {
			failedCount++
			errors = append(errors, "无权删除消息 "+strconv.Itoa(messageID))
			continue
		}

		// 检查是否已删除
		deletedUserIDs := strings.Split(message.DeletedByUsers, ",")
		alreadyDeleted := false
		for _, id := range deletedUserIDs {
			if strings.TrimSpace(id) == userIDStr {
				alreadyDeleted = true
				break
			}
		}

		if alreadyDeleted {
			failedCount++
			errors = append(errors, "消息 "+strconv.Itoa(messageID)+" 已被删除")
			continue
		}

		// 添加当前用户ID到删除列表
		var newDeletedByUsers string
		if message.DeletedByUsers == "" {
			newDeletedByUsers = userIDStr
		} else {
			newDeletedByUsers = message.DeletedByUsers + "," + userIDStr
		}

		// 更新私聊消息的deleted_by_users字段
		updateQuery := `UPDATE messages SET deleted_by_users = $1 WHERE id = $2`
		_, err = db.DB.Exec(updateQuery, newDeletedByUsers, messageID)
		if err != nil {
			utils.LogDebug("❌ 批量删除消息失败: %v", err)
			failedCount++
			errors = append(errors, "删除消息 "+strconv.Itoa(messageID)+" 失败")
			continue
		}

		successCount++
	}

	utils.LogDebug("✅ 用户 %d 批量删除了 %d 条消息，成功 %d 条，失败 %d 条", currentUserID, len(req.MessageIDs), successCount, failedCount)

	result := gin.H{
		"message":       "批量删除完成",
		"success_count": successCount,
		"failed_count":  failedCount,
		"total":         len(req.MessageIDs),
	}

	if len(errors) > 0 {
		result["errors"] = errors
	}

	utils.Success(c, result)
}
