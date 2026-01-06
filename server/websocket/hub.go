package websocket

import (
	"sync"
	"time"
	"youdu-server/utils"
)

// Client 表示一个WebSocket客户端连接
type Client struct {
	UserID      int
	Conn        *Conn
	Send        chan []byte
	closed      bool       // 标记 Send channel 是否已关闭
	mu          sync.Mutex // 保护 closed 标志
	missedPings int        // 连续错过的ping消息次数
	pingMu      sync.Mutex // 保护 missedPings 计数器
	ConnectedAt time.Time  // 连接建立时间
}

// UserCallStatus 用户通话状态
type UserCallStatus struct {
	InCall       bool   // 是否在通话中
	CallType     string // 通话类型: voice/video
	TargetUserID int    // 一对一通话时的对方用户ID
	GroupID      int    // 群组通话时的群组ID
	StartTime    time.Time // 通话开始时间
}

// Hub 维护活动的客户端连接和消息广播
type Hub struct {
	// 已注册的客户端 (userID -> Client)
	clients map[int]*Client

	// 用户通话状态 (userID -> UserCallStatus)
	callStatuses map[int]*UserCallStatus
	callStatusMu sync.RWMutex

	// 客户端注册请求
	Register chan *Client

	// 客户端注销请求
	Unregister chan *Client

	// 消息广播
	Broadcast chan *BroadcastMessage

	// 互斥锁保护clients map
	mu sync.RWMutex

	// 离线通知回调函数
	OnUserOffline func(userID int)
}

// BroadcastMessage 广播消息结构
type BroadcastMessage struct {
	UserID  int    // 目标用户ID
	Message []byte // 消息内容
}

// NewHub 创建新的Hub
func NewHub() *Hub {
	return &Hub{
		clients:      make(map[int]*Client),
		callStatuses: make(map[int]*UserCallStatus),
		Register:     make(chan *Client),
		Unregister:   make(chan *Client),
		Broadcast:    make(chan *BroadcastMessage),
	}
}

// closeSend 安全地关闭客户端的 Send channel
func (c *Client) closeSend() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.closed {
		close(c.Send)
		c.closed = true
	}
}

// SafeSend 安全地向客户端发送消息，如果channel已关闭则返回false
func (c *Client) SafeSend(message []byte) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return false
	}
	select {
	case c.Send <- message:
		return true
	default:
		return false
	}
}

// IsClosed 检查Send channel是否已关闭
func (c *Client) IsClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closed
}

// ResetPingCounter 重置ping计数器（收到ping消息时调用）
func (c *Client) ResetPingCounter() {
	c.pingMu.Lock()
	defer c.pingMu.Unlock()
	c.missedPings = 0
}

// IncrementMissedPings 增加错过的ping次数
func (c *Client) IncrementMissedPings() int {
	c.pingMu.Lock()
	defer c.pingMu.Unlock()
	c.missedPings++
	return c.missedPings
}

// GetMissedPings 获取错过的ping次数
func (c *Client) GetMissedPings() int {
	c.pingMu.Lock()
	defer c.pingMu.Unlock()
	return c.missedPings
}

// Run 启动Hub
func (h *Hub) Run() {
	for {
		select {
		case client := <-h.Register:
			h.mu.Lock()
			// 🔴 如果用户已经有连接，发送踢下线通知后再替换
			if oldClient, ok := h.clients[client.UserID]; ok {
				utils.LogDebug("🔄 [Hub] 用户 %d 重新连接，向旧设备发送踢下线通知", client.UserID)

				// 🔴 关键修复：先注册新连接，再处理旧连接
				// 这样可以确保 forced_logout 不会发送到新连接
				h.clients[client.UserID] = client
				client.ConnectedAt = time.Now()
				
				h.mu.Unlock()

				// 🔴 向旧设备发送踢下线通知
				forceLogoutMsg := []byte(`{"type":"forced_logout","data":{"reason":"您的账号已在其他设备登录"},"message":"您的账号已在其他设备登录"}`)
				
				// 尝试发送踢下线通知（不阻塞）
				if oldClient.SafeSend(forceLogoutMsg) {
					utils.LogDebug("✅ [Hub] 已向用户 %d 的旧设备发送踢下线通知", client.UserID)
					// 给旧设备一点时间处理通知
					time.Sleep(100 * time.Millisecond)
				}
				
				// 关闭旧连接
				oldClient.closeSend()

				utils.LogDebug("✅ [Hub] 用户 %d 旧连接已关闭，新连接已注册", client.UserID)
			} else {
				// 没有旧连接，直接注册新连接
				client.ConnectedAt = time.Now()
				h.clients[client.UserID] = client
				h.mu.Unlock()
			}
			
			utils.LogDebug("✅ [Hub] 用户 %d 新设备已连接 (总连接数: %d)", client.UserID, len(h.clients))

			// 打印当前所有在线用户ID
			h.mu.RLock()
			var onlineUserIDs []int
			for userID := range h.clients {
				onlineUserIDs = append(onlineUserIDs, userID)
			}
			h.mu.RUnlock()
			utils.LogDebug("📊 [Hub] 当前在线用户ID列表: %v", onlineUserIDs)

		case client := <-h.Unregister:
			h.mu.Lock()
			// 检查要断开的连接是否真的是当前在线的连接
			// 避免误删新连接（旧连接断开时，新连接可能已经注册）
			if currentClient, ok := h.clients[client.UserID]; ok {
				// 只有当前连接和要断开的连接是同一个，才删除
				if currentClient == client {
					delete(h.clients, client.UserID)
					client.closeSend()
					utils.LogDebug("🔌 [Hub] 用户 %d 已断开连接 (总连接数: %d)", client.UserID, len(h.clients))

					// 调用离线通知回调（在锁外执行，避免死锁）
					userID := client.UserID
					h.mu.Unlock()
					if h.OnUserOffline != nil {
						go h.OnUserOffline(userID)
					}
				} else {
					// 这是旧连接断开，但新连接已经注册，忽略
					h.mu.Unlock()
					utils.LogDebug("ℹ️ [Hub] 用户 %d 的旧连接断开，新连接已接管", client.UserID)
				}
			} else {
				h.mu.Unlock()
				utils.LogDebug("⚠️ [Hub] 用户 %d 尝试断开但不在在线列表中", client.UserID)
			}

		case message := <-h.Broadcast:
			h.mu.RLock()
			client, ok := h.clients[message.UserID]
			totalOnlineUsers := len(h.clients)
			h.mu.RUnlock()

			utils.LogDebug("🔄 [Hub] 收到广播消息 - 目标用户ID: %d, 用户在线: %v, 当前在线总数: %d", message.UserID, ok, totalOnlineUsers)

			if ok {
				select {
				case client.Send <- message.Message:
					// 消息发送成功
					utils.LogDebug("✅ [Hub] 消息成功发送到用户 %d 的Send通道 (通道缓冲区可用)", message.UserID)
				default:
					// 发送失败，关闭连接
					h.mu.Lock()
					client.closeSend()
					delete(h.clients, client.UserID)
					h.mu.Unlock()
					utils.LogDebug("❌ [Hub] 用户 %d 消息发送失败，连接已关闭", client.UserID)
				}
			} else {
				utils.LogDebug("⚠️ [Hub] 用户 %d 不在线，无法发送消息", message.UserID)
			}
		}
	}
}

// IsUserOnline 检查用户是否在线
func (h *Hub) IsUserOnline(userID int) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[userID]
	return ok
}

// GetOnlineUserCount 获取在线用户数
func (h *Hub) GetOnlineUserCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

// SendToUser 向指定用户发送消息
func (h *Hub) SendToUser(userID int, message []byte) bool {
	h.Broadcast <- &BroadcastMessage{
		UserID:  userID,
		Message: message,
	}
	return h.IsUserOnline(userID)
}

// BroadcastToChannel 向频道中的所有在线用户广播消息（排除指定用户）
func (h *Hub) BroadcastToChannel(channelName string, message []byte, excludeUserID int) {
	utils.LogDebug("📢 [Hub] 开始向频道 %s 广播消息，排除用户 %d", channelName, excludeUserID)

	// 从频道名称中解析出相关的用户ID
	// 频道名称格式: group_call_${callerId}_${timestamp}
	// 我们需要一个更好的方式来跟踪频道中的用户，这里先实现一个简化版本

	h.mu.RLock()
	var sentCount int
	for userID, client := range h.clients {
		// 跳过排除的用户
		if userID == excludeUserID {
			continue
		}

		// 发送消息给所有其他在线用户（简化实现）
		// 在实际应用中，应该维护频道-用户的映射关系
		select {
		case client.Send <- message:
			sentCount++
			utils.LogDebug("✅ [Hub] 频道广播消息已发送给用户 %d", userID)
		default:
			utils.LogDebug("❌ [Hub] 向用户 %d 发送频道广播消息失败", userID)
		}
	}
	h.mu.RUnlock()

	utils.LogDebug("📢 [Hub] 频道 %s 广播完成，成功发送给 %d 个用户", channelName, sentCount)
}

// BroadcastToUsers 向指定的用户列表广播消息（排除指定用户）
func (h *Hub) BroadcastToUsers(userIDs []int, message []byte, excludeUserID int) {
	utils.LogDebug("📢 [Hub] 开始向用户列表广播消息，目标用户: %v，排除用户: %d", userIDs, excludeUserID)

	h.mu.RLock()
	var sentCount int
	for _, userID := range userIDs {
		// 跳过排除的用户
		if userID == excludeUserID {
			continue
		}

		// 检查用户是否在线
		if client, ok := h.clients[userID]; ok {
			select {
			case client.Send <- message:
				sentCount++
				utils.LogDebug("✅ [Hub] 广播消息已发送给用户 %d", userID)
			default:
				utils.LogDebug("❌ [Hub] 向用户 %d 发送广播消息失败", userID)
			}
		} else {
			utils.LogDebug("⚠️ [Hub] 用户 %d 不在线，跳过发送", userID)
		}
	}
	h.mu.RUnlock()

	utils.LogDebug("📢 [Hub] 用户列表广播完成，成功发送给 %d 个用户", sentCount)
}

// BroadcastGroupDisbanded 广播群组解散通知（占位方法）
// 实际的通知逻辑在控制器中处理
func (h *Hub) BroadcastGroupDisbanded(groupID int) {
	utils.LogDebug("📢 [Hub] 群组 %d 已被解散", groupID)
}

// ForceLogoutUser 强制用户下线（用于单设备登录限制）
// 向指定用户发送强制下线通知，并关闭其WebSocket连接
func (h *Hub) ForceLogoutUser(userID int, reason string) bool {
	h.mu.Lock()
	client, ok := h.clients[userID]
	if !ok {
		h.mu.Unlock()
		utils.LogDebug("⚠️ [Hub] 用户 %d 不在线，无需踢下线", userID)
		return false
	}
	h.mu.Unlock()

	// 构造强制下线消息
	forceLogoutMsg := []byte(`{"type":"forced_logout","data":{"reason":"` + reason + `"},"message":"` + reason + `"}`)

	// 发送踢下线通知
	if client.SafeSend(forceLogoutMsg) {
		utils.LogDebug("✅ [Hub] 已向用户 %d 发送强制下线通知: %s", userID, reason)
		// 给客户端一点时间处理通知
		time.Sleep(100 * time.Millisecond)
	}

	// 关闭连接
	h.mu.Lock()
	if currentClient, exists := h.clients[userID]; exists && currentClient == client {
		delete(h.clients, userID)
		client.closeSend()
		utils.LogDebug("✅ [Hub] 用户 %d 已被强制下线", userID)
	}
	h.mu.Unlock()

	// 触发离线回调
	if h.OnUserOffline != nil {
		go h.OnUserOffline(userID)
	}

	return true
}

// CheckHeartbeat 检查所有客户端的心跳状态
// 增加所有客户端的missedPings计数，如果达到2次则断开连接
func (h *Hub) CheckHeartbeat() {
	h.mu.Lock()
	var disconnectedClients []*Client

	for userID, client := range h.clients {
		missedPings := client.IncrementMissedPings()

		if missedPings >= 2 {
			disconnectedClients = append(disconnectedClients, client)
			delete(h.clients, userID)
		}
	}
	h.mu.Unlock()

	// 在锁外关闭连接并触发离线回调
	for _, client := range disconnectedClients {
		client.closeSend()

		if h.OnUserOffline != nil {
			go h.OnUserOffline(client.UserID)
		}
	}
}

// ========== 通话状态管理 ==========

// SetUserCallStatus 设置用户通话状态
func (h *Hub) SetUserCallStatus(userID int, inCall bool, callType string, targetUserID int, groupID int) {
	h.callStatusMu.Lock()
	defer h.callStatusMu.Unlock()

	if inCall {
		h.callStatuses[userID] = &UserCallStatus{
			InCall:       true,
			CallType:     callType,
			TargetUserID: targetUserID,
			GroupID:      groupID,
			StartTime:    time.Now(),
		}
		utils.LogDebug("📞 [Hub] 用户 %d 进入通话状态: callType=%s, targetUserID=%d, groupID=%d",
			userID, callType, targetUserID, groupID)
	} else {
		delete(h.callStatuses, userID)
		utils.LogDebug("📞 [Hub] 用户 %d 退出通话状态", userID)
	}
}

// IsUserInCall 检查用户是否在通话中
func (h *Hub) IsUserInCall(userID int) bool {
	h.callStatusMu.RLock()
	defer h.callStatusMu.RUnlock()

	status, ok := h.callStatuses[userID]
	return ok && status.InCall
}

// GetUserCallStatus 获取用户通话状态
func (h *Hub) GetUserCallStatus(userID int) *UserCallStatus {
	h.callStatusMu.RLock()
	defer h.callStatusMu.RUnlock()

	if status, ok := h.callStatuses[userID]; ok {
		// 返回副本，避免并发问题
		return &UserCallStatus{
			InCall:       status.InCall,
			CallType:     status.CallType,
			TargetUserID: status.TargetUserID,
			GroupID:      status.GroupID,
			StartTime:    status.StartTime,
		}
	}
	return nil
}

// ClearUserCallStatus 清除用户通话状态（用户离线时调用）
func (h *Hub) ClearUserCallStatus(userID int) {
	h.callStatusMu.Lock()
	defer h.callStatusMu.Unlock()

	if _, ok := h.callStatuses[userID]; ok {
		delete(h.callStatuses, userID)
		utils.LogDebug("📞 [Hub] 用户 %d 离线，已清除通话状态", userID)
	}
}
