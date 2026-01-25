package handlers

import (
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

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
			log.Printf("[SyncMessage] Failed to append message ID to Redis: key=%s, id=%d, error=%v", key, messageID, err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to store message"})
			return
		}

		// Set expiration for the key (7 days)
		h.redis.SetKeyExpiration(key, 7*24*time.Hour)

		// Keep only the last 1000 messages per conversation to prevent memory bloat
		h.redis.CleanupOldMessages(key, 1000)

		log.Printf("[SyncMessage] Stored message: key=%s, id=%d", key, messageID)
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
	NeedSync bool `json:"need_sync"`
}

// CheckSync handles the check-sync API (HTTP API 2)
// This is called periodically by the client to check if there are unsynchronized messages
// If there are, it triggers Server A to send those messages to the client
// If a key doesn't exist in Redis, it creates the key with the client's message IDs
func (h *Handler) CheckSync(c *gin.Context) {
	var req CheckSyncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request body"})
		return
	}

	if req.ReceiverID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "receiver_id is required"})
		return
	}

	// Collect unsynchronized message IDs
	var unsyncedPrivateIDs []int64
	var unsyncedGroupIDs []int64

	// Check private messages
	for key, clientIDs := range req.MessageIDs {
		// Check if key exists in Redis
		exists, err := h.redis.KeyExists(key)
		if err != nil {
			log.Printf("[CheckSync] Failed to check key existence: key=%s, error=%v", key, err)
			continue
		}

		// If key doesn't exist, create it with client's message IDs
		if !exists {
			if len(clientIDs) > 0 {
				if err := h.redis.BatchAppendMessageIDs(key, clientIDs); err != nil {
					log.Printf("[CheckSync] Failed to create key with client IDs: key=%s, error=%v", key, err)
				} else {
					// Set expiration for the key (7 days)
					h.redis.SetKeyExpiration(key, 7*24*time.Hour)
					log.Printf("[CheckSync] Created new key with client IDs: key=%s, ids=%v", key, clientIDs)
				}
			}
			continue // No need to check for unsynced messages since we just created the key
		}

		// Get the latest message ID from client
		var clientLatestID int64 = 0
		if len(clientIDs) > 0 {
			clientLatestID = clientIDs[len(clientIDs)-1]
		}

		// Get all message IDs from Redis that are greater than client's latest
		serverIDs, err := h.redis.GetMessageIDsGreaterThan(key, clientLatestID)
		if err != nil {
			log.Printf("[CheckSync] Failed to get message IDs from Redis: key=%s, error=%v", key, err)
			continue
		}

		if len(serverIDs) > 0 {
			unsyncedPrivateIDs = append(unsyncedPrivateIDs, serverIDs...)
			log.Printf("[CheckSync] Found unsynced private messages: key=%s, clientLatest=%d, unsynced=%v",
				key, clientLatestID, serverIDs)
		}
	}

	// Check group messages
	for key, clientIDs := range req.GroupMessageIDs {
		// Check if key exists in Redis
		exists, err := h.redis.KeyExists(key)
		if err != nil {
			log.Printf("[CheckSync] Failed to check key existence: key=%s, error=%v", key, err)
			continue
		}

		// Get the latest message ID from client
		// 🔴 Filter out 0 values (0 means client has no messages for this group)
		var clientLatestID int64 = 0
		if len(clientIDs) > 0 {
			clientLatestID = clientIDs[len(clientIDs)-1]
		}

		// If key doesn't exist, create it with client's message IDs (only if > 0)
		if !exists {
			// 🔴 Only create key with valid message IDs (> 0)
			// If clientLatestID is 0, it means client has no messages for this group
			// In this case, we don't create the key, but we still need to check for unsynced messages
			if clientLatestID > 0 {
				if err := h.redis.BatchAppendMessageIDs(key, clientIDs); err != nil {
					log.Printf("[CheckSync] Failed to create key with client IDs: key=%s, error=%v", key, err)
				} else {
					// Set expiration for the key (7 days)
					h.redis.SetKeyExpiration(key, 7*24*time.Hour)
					log.Printf("[CheckSync] Created new key with client IDs: key=%s, ids=%v", key, clientIDs)
				}
			}
			// If clientLatestID is 0, it means client has no messages for this group
			// and key doesn't exist - this is normal, just skip silently
			continue // No need to check for unsynced messages since we just created the key or key doesn't exist
		}

		// Get all message IDs from Redis that are greater than client's latest
		serverIDs, err := h.redis.GetMessageIDsGreaterThan(key, clientLatestID)
		if err != nil {
			log.Printf("[CheckSync] Failed to get group message IDs from Redis: key=%s, error=%v", key, err)
			continue
		}

		if len(serverIDs) > 0 {
			unsyncedGroupIDs = append(unsyncedGroupIDs, serverIDs...)
			log.Printf("[CheckSync] Found unsynced group messages: key=%s, clientLatest=%d, unsynced=%v",
				key, clientLatestID, serverIDs)
		}
	}

	// If there are no unsynchronized messages, return false
	if len(unsyncedPrivateIDs) == 0 && len(unsyncedGroupIDs) == 0 {
		c.JSON(http.StatusOK, CheckSyncResponse{NeedSync: false})
		return
	}

	// Send client_sync_message to Server A via WebSocket
	if err := h.wsClient.SendClientSyncMessage(req.ReceiverID, unsyncedPrivateIDs, unsyncedGroupIDs); err != nil {
		log.Printf("[CheckSync] Failed to send client_sync_message: %v", err)
		// Still return true to indicate sync is needed, client can retry
		c.JSON(http.StatusOK, CheckSyncResponse{NeedSync: true})
		return
	}

	log.Printf("[CheckSync] Triggered sync for receiver %d: privateIDs=%v, groupIDs=%v",
		req.ReceiverID, unsyncedPrivateIDs, unsyncedGroupIDs)

	c.JSON(http.StatusOK, CheckSyncResponse{NeedSync: true})
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
