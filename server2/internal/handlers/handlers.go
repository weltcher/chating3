package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"server2/internal/logger"
	"server2/internal/redis"
	"server2/internal/socket"
)

// Handler holds dependencies for HTTP handlers
type Handler struct {
	redis    *redis.Client
	wsClient *socket.Client
}

// NewHandler creates a new Handler instance
func NewHandler(redisClient *redis.Client, wsClient *socket.Client) *Handler {
	return &Handler{
		redis:    redisClient,
		wsClient: wsClient,
	}
}

// SyncMessageRequest represents the request body for sync-message API
// Called after message_sent to store the new message ID in Redis
// Format for private chat: {"0-100-101": 31} (0-{receiverID}-{senderID})
// Format for group chat: {"1-901": 1001} (1-{groupID})
// 🔴 关键修复：群组消息的 key 格式改为 1-{群组ID}，不再包含用户ID
type SyncMessageRequest map[string]int64

// SyncMessage handles the sync-message API (HTTP API 1)
// This is called by the client after receiving message_sent from Server A
// It stores the message ID in Redis for later comparison
func (h *Handler) SyncMessage(c *gin.Context) {
	var req SyncMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request body"})
		return
	}

	if len(req) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No message data provided"})
		return
	}

	// Process each key-value pair
	for key, messageID := range req {
		// Append message ID to Redis list
		if err := h.redis.AppendMessageID(key, messageID); err != nil {
			logger.LogError("[SyncMessage] Failed to append message ID to Redis: key=%s, id=%d, error=%v", key, messageID, err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to store message"})
			return
		}

		// Set expiration for the key (7 days)
		h.redis.SetKeyExpiration(key, 7*24*time.Hour)

		// Keep only the last 1000 messages per conversation to prevent memory bloat
		h.redis.CleanupOldMessages(key, 1000)

		logger.LogInfo("[SyncMessage] Stored message: key=%s, id=%d", key, messageID)
	}

	c.JSON(http.StatusOK, gin.H{"success": true})
}

// CheckSyncRequest represents the request body for check-sync API
// Called periodically (every 5 seconds) by the client
// 🔴 关键修复：群组消息的 key 格式改为 1-{群组ID}，不再包含用户ID
type CheckSyncRequest struct {
	ReceiverID      int64                `json:"receiver_id"`
	MessageIDs      map[string][]int64   `json:"message_ids"`       // Private chat: {"0-100-101": [31,32]} (0-{receiverID}-{senderID})
	GroupMessageIDs map[string][]int64   `json:"group_message_ids"` // Group chat: {"1-901": [1001]} (1-{groupID})
}

// CheckSyncResponse represents the response for check-sync API
type CheckSyncResponse struct {
	NeedSync           bool    `json:"need_sync"`
	MissingPrivateIDs  []int64 `json:"missing_private_ids,omitempty"`  // 缺失的私聊消息ID列表
	MissingGroupIDs    []int64 `json:"missing_group_ids,omitempty"`    // 缺失的群组消息ID列表
}

// CheckSync handles the check-sync API (HTTP API 2)
// This is called periodically by the client to check if there are unsynchronized messages
// If there are, it triggers Server A to send those messages to the client
// If a key doesn't exist in Redis, it creates the key with the client's message IDs
func (h *Handler) CheckSync(c *gin.Context) {
	// 🔴 记录请求开始
	logger.LogInfo("═══════════════════════════════════════════════════════════")
	logger.LogInfo("[CheckSync] ========== 收到check-sync请求 ==========")
	logger.LogInfo("[CheckSync] 请求时间: %s", time.Now().Format("2006/01/02 15:04:05"))
	
	var req CheckSyncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		logger.LogError("[CheckSync] 请求体解析失败: %v", err)
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request body"})
		return
	}

	// 🔴 详细记录请求参数
	logger.LogInfo("[CheckSync] 接收者ID: %d", req.ReceiverID)
	logger.LogInfo("[CheckSync] 私聊消息ID数量: %d", len(req.MessageIDs))
	logger.LogInfo("[CheckSync] 群组消息ID数量: %d", len(req.GroupMessageIDs))
	
	// 记录请求体完整内容
	reqJSON, _ := json.Marshal(req)
	logger.LogInfo("[CheckSync] 请求体完整内容: %s", string(reqJSON))
	
	// 详细记录群组消息ID
	for key, ids := range req.GroupMessageIDs {
		logger.LogInfo("[CheckSync]   群组 %s: 最新消息ID=%v", key, ids)
		// 特别记录群组172
		if strings.Contains(key, "172") {
			logger.LogInfo("[CheckSync]   ⚠️⚠️⚠️ 群组172详细信息: key=%s, serverId=%v", key, ids)
		}
	}
	
	// 详细记录私聊消息ID
	for key, ids := range req.MessageIDs {
		logger.LogInfo("[CheckSync]   私聊 %s: 最新消息ID=%v", key, ids)
	}

	if req.ReceiverID == 0 {
		logger.LogError("[CheckSync] receiver_id为空")
		c.JSON(http.StatusBadRequest, gin.H{"error": "receiver_id is required"})
		return
	}

	// Collect unsynchronized message IDs
	var unsyncedPrivateIDs []int64
	var unsyncedGroupIDs []int64

	// 🔴 开始查询Redis
	logger.LogInfo("[CheckSync] ========== 开始查询Redis ==========")
	
	// Check private messages
	for key, clientIDs := range req.MessageIDs {
		// Get the latest message ID from client
		var clientLatestID int64 = 0
		if len(clientIDs) > 0 {
			clientLatestID = clientIDs[len(clientIDs)-1]
		}
		
		logger.LogInfo("[CheckSync] 查询私聊 %s: 客户端最新消息ID=%d", key, clientLatestID)
		
		// Check if key exists in Redis
		exists, err := h.redis.KeyExists(key)
		if err != nil {
			logger.LogError("[CheckSync] Failed to check key existence: key=%s, error=%v", key, err)
			continue
		}

		// If key doesn't exist, create it with client's message IDs
		if !exists {
			if len(clientIDs) > 0 {
				if err := h.redis.BatchAppendMessageIDs(key, clientIDs); err != nil {
					logger.LogError("[CheckSync] Failed to create key with client IDs: key=%s, error=%v", key, err)
				} else {
					// Set expiration for the key (7 days)
					h.redis.SetKeyExpiration(key, 7*24*time.Hour)
					logger.LogInfo("[CheckSync] Created new key with client IDs: key=%s, ids=%v", key, clientIDs)
				}
			}
			continue // No need to check for unsynced messages since we just created the key
		}

		// Get all message IDs from Redis that are greater than client's latest
		serverIDs, err := h.redis.GetMessageIDsGreaterThan(key, clientLatestID)
		if err != nil {
			logger.LogError("[CheckSync] Failed to get message IDs from Redis: key=%s, error=%v", key, err)
			continue
		}

		if len(serverIDs) > 0 {
			unsyncedPrivateIDs = append(unsyncedPrivateIDs, serverIDs...)
			logger.LogInfo("[CheckSync] Found unsynced private messages: key=%s, clientLatest=%d, unsynced=%v",
				key, clientLatestID, serverIDs)
		} else {
			logger.LogInfo("[CheckSync] 私聊 %s: 客户端已是最新", key)
		}
	}

	// Check group messages
	for key, clientIDs := range req.GroupMessageIDs {
		// Get the latest message ID from client
		// 🔴 Filter out 0 values (0 means client has no messages for this group)
		var clientLatestID int64 = 0
		if len(clientIDs) > 0 {
			clientLatestID = clientIDs[len(clientIDs)-1]
		}
		
		logger.LogInfo("[CheckSync] 查询群组 %s: 客户端最新消息ID=%d", key, clientLatestID)
		
		// Check if key exists in Redis
		exists, err := h.redis.KeyExists(key)
		if err != nil {
			logger.LogError("[CheckSync] Failed to check key existence: key=%s, error=%v", key, err)
			continue
		}

		// If key doesn't exist, create it with client's message IDs (only if > 0)
		if !exists {
			// 🔴 Only create key with valid message IDs (> 0)
			// If clientLatestID is 0, it means client has no messages for this group
			// In this case, we don't create the key, but we still need to check for unsynced messages
			if clientLatestID > 0 {
				if err := h.redis.BatchAppendMessageIDs(key, clientIDs); err != nil {
					logger.LogError("[CheckSync] Failed to create key with client IDs: key=%s, error=%v", key, err)
				} else {
					// Set expiration for the key (7 days)
					h.redis.SetKeyExpiration(key, 7*24*time.Hour)
					logger.LogInfo("[CheckSync] Created new key with client IDs: key=%s, ids=%v", key, clientIDs)
				}
			}
			// If clientLatestID is 0, it means client has no messages for this group
			// and key doesn't exist - this is normal, just skip silently
			continue // No need to check for unsynced messages since we just created the key or key doesn't exist
		}

		// Get all message IDs from Redis that are greater than client's latest
		serverIDs, err := h.redis.GetMessageIDsGreaterThan(key, clientLatestID)
		if err != nil {
			logger.LogError("[CheckSync] Failed to get group message IDs from Redis: key=%s, error=%v", key, err)
			continue
		}

		if len(serverIDs) > 0 {
			unsyncedGroupIDs = append(unsyncedGroupIDs, serverIDs...)
			logger.LogInfo("[CheckSync] Found unsynced group messages: key=%s, clientLatest=%d, unsynced=%v",
				key, clientLatestID, serverIDs)
			// 特别记录群组172
			if strings.Contains(key, "172") {
				logger.LogInfo("[CheckSync] ⚠️⚠️⚠️ 群组172检测到未同步消息: clientLatest=%d, unsynced=%v", clientLatestID, serverIDs)
			}
		} else {
			logger.LogInfo("[CheckSync] 群组 %s: 客户端已是最新", key)
			// 特别记录群组172
			if strings.Contains(key, "172") {
				logger.LogInfo("[CheckSync] ⚠️⚠️⚠️ 群组172: 客户端已是最新，clientLatest=%d", clientLatestID)
			}
		}
	}

	// 🔴 判断need_sync值
	logger.LogInfo("[CheckSync] ========== 判断need_sync值 ==========")
	logger.LogInfo("[CheckSync] missing_private_ids数量: %d", len(unsyncedPrivateIDs))
	logger.LogInfo("[CheckSync] missing_group_ids数量: %d", len(unsyncedGroupIDs))
	
	needSync := len(unsyncedPrivateIDs) > 0 || len(unsyncedGroupIDs) > 0
	
	if needSync {
		logger.LogInfo("[CheckSync] 存在缺失消息，设置need_sync=true")
	} else {
		logger.LogInfo("[CheckSync] 没有缺失消息，设置need_sync=false")
	}
	
	logger.LogInfo("[CheckSync] 最终need_sync值: %v", needSync)
	
	// 🔴 准备返回响应
	logger.LogInfo("[CheckSync] ========== 准备返回响应 ==========")
	response := CheckSyncResponse{
		NeedSync:          needSync,
		MissingPrivateIDs: unsyncedPrivateIDs,
		MissingGroupIDs:   unsyncedGroupIDs,
	}
	
	// 记录响应数据
	responseJSON, _ := json.Marshal(response)
	logger.LogInfo("[CheckSync] 响应体完整内容: %s", string(responseJSON))
	logger.LogInfo("[CheckSync] 响应体大小: %d字节", len(responseJSON))
	
	// 特别检查群组172的情况
	hasGroup172Missing := false
	for _, groupID := range unsyncedGroupIDs {
		// 检查这个ID是否属于群组172（需要从Redis查询，这里简化处理）
		// 由于unsyncedGroupIDs只是消息ID列表，无法直接判断属于哪个群组
		// 这里简化处理：如果有缺失消息，就认为可能包含群组172
		_ = groupID // 避免未使用变量警告
		hasGroup172Missing = true
		break
	}
	if hasGroup172Missing {
		logger.LogInfo("[CheckSync] ⚠️⚠️⚠️ 检测到缺失群组消息，可能包含群组172: %v", unsyncedGroupIDs)
	} else if len(unsyncedGroupIDs) > 0 {
		logger.LogInfo("[CheckSync] ⚠️⚠️⚠️ 群组172不在缺失消息列表中，但其他群组有缺失消息")
	}
	
	// If there are no unsynchronized messages, return false
	if !needSync {
		logger.LogInfo("[CheckSync] 返回need_sync=false")
		c.JSON(http.StatusOK, response)
		logger.LogInfo("═══════════════════════════════════════════════════════════")
		return
	}

	// 🔴 关键修改：不再通过WebSocket推送消息给服务器A
	// 原因：客户端收到need_sync=true和缺失消息ID列表后，会主动从服务器A拉取消息
	// 这样可以避免重复推送，提高效率，并确保客户端能够可靠地获取所有缺失的消息
	// 
	// 旧逻辑（已移除）：
	// if err := h.wsClient.SendClientSyncMessage(req.ReceiverID, unsyncedPrivateIDs, unsyncedGroupIDs); err != nil {
	//     logger.LogError("[CheckSync] Failed to send client_sync_message: %v", err)
	//     ...
	// }
	
	logger.LogInfo("[CheckSync] Found unsynchronized messages for receiver %d: privateIDs=%v, groupIDs=%v",
		req.ReceiverID, unsyncedPrivateIDs, unsyncedGroupIDs)
	logger.LogInfo("[CheckSync] Client will fetch these messages directly from Server A using the provided message IDs")

	// Return missing message IDs so client can fetch them directly from Server A
	logger.LogInfo("[CheckSync] 返回need_sync=true，包含缺失消息ID列表")
	c.JSON(http.StatusOK, response)
	logger.LogInfo("═══════════════════════════════════════════════════════════")
}

// ParseKey parses a Redis key and returns the type, receiverID, and senderID/groupID
// Format for private chat: {type}-{receiverID}-{senderID} (e.g., "0-100-101")
// Format for group chat: {type}-{groupID} (e.g., "1-901")
// type: 0 = private, 1 = group
//
// 🔴 关键修复：群组消息的 key 格式改为 1-{群组ID}，不再包含用户ID
// 这样所有群组成员都使用相同的 key
func ParseKey(key string) (keyType int, receiverID, otherID int64, err error) {
	parts := strings.Split(key, "-")
	
	// 至少需要2个部分
	if len(parts) < 2 {
		return 0, 0, 0, ErrInvalidKeyFormat{}
	}

	keyType, err = strconv.Atoi(parts[0])
	if err != nil {
		return 0, 0, 0, ErrInvalidKeyFormat{}
	}

	// 🔴 群组消息：格式为 1-{groupID}
	if keyType == 1 {
		if len(parts) != 2 {
			return 0, 0, 0, ErrInvalidKeyFormat{}
		}
		groupID, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			return 0, 0, 0, ErrInvalidKeyFormat{}
		}
		// 对于群组消息，receiverID 设为 0（不使用），otherID 为 groupID
		return keyType, 0, groupID, nil
	}

	// 🔴 私聊消息：格式为 0-{receiverID}-{senderID}
	if len(parts) != 3 {
		return 0, 0, 0, ErrInvalidKeyFormat{}
	}

	receiverID, err = strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return 0, 0, 0, ErrInvalidKeyFormat{}
	}

	otherID, err = strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return 0, 0, 0, ErrInvalidKeyFormat{}
	}

	return keyType, receiverID, otherID, nil
}

// ErrInvalidKeyFormat is returned when a key doesn't match the expected format
type ErrInvalidKeyFormat struct{}

func (e ErrInvalidKeyFormat) Error() string {
	return "invalid key format"
}

var _ error = ErrInvalidKeyFormat{}
