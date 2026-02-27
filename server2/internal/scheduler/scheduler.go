package scheduler

import (
	"encoding/json"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	"server2/internal/redis"
	"server2/internal/socket"
)

// Scheduler handles scheduled tasks
type Scheduler struct {
	redisClient *redis.Client
	wsClient    *socket.Client
	stopChan    chan struct{}
}

// NewScheduler creates a new scheduler instance
func NewScheduler(redisClient *redis.Client, wsClient *socket.Client) *Scheduler {
	return &Scheduler{
		redisClient: redisClient,
		wsClient:    wsClient,
		stopChan:    make(chan struct{}),
	}
}

// Start begins the scheduler
func (s *Scheduler) Start() {
	go s.runDailyCleanup()
	go s.runMessageResend()
	log.Println("[Scheduler] Started daily cleanup scheduler (runs at 01:30 AM)")
	log.Println("[Scheduler] Started message resend scheduler (runs every 15 seconds)")
}

// Stop stops the scheduler
func (s *Scheduler) Stop() {
	close(s.stopChan)
	log.Println("[Scheduler] Stopped")
}

// runDailyCleanup runs the cleanup task at 01:30 AM every day
func (s *Scheduler) runDailyCleanup() {
	for {
		// Calculate duration until next 01:30 AM
		now := time.Now()
		next := time.Date(now.Year(), now.Month(), now.Day(), 1, 30, 0, 0, now.Location())

		// If it's already past 01:30 today, schedule for tomorrow
		if now.After(next) {
			next = next.Add(24 * time.Hour)
		}

		duration := next.Sub(now)
		log.Printf("[Scheduler] Next cleanup scheduled at %s (in %v)", next.Format("2006-01-02 15:04:05"), duration)

		select {
		case <-time.After(duration):
			s.executeCleanup()
		case <-s.stopChan:
			return
		}
	}
}

// executeCleanup performs the actual cleanup task
func (s *Scheduler) executeCleanup() {
	log.Println("[Scheduler] Starting daily Redis queue cleanup...")
	startTime := time.Now()

	keysProcessed, messagesRemoved, err := s.redisClient.CleanupAllQueues()

	elapsed := time.Since(startTime)

	if err != nil {
		log.Printf("[Scheduler] Cleanup failed: %v", err)
		return
	}

	log.Printf("[Scheduler] Cleanup completed in %v: processed %d keys, removed %d old message IDs",
		elapsed, keysProcessed, messagesRemoved)
}

// RunCleanupNow executes the cleanup task immediately (for testing/manual trigger)
func (s *Scheduler) RunCleanupNow() {
	s.executeCleanup()
}

// runMessageResend runs the message resend task every 15 seconds
// Scans Redis for keys starting with "2-" (saved private messages) and "3-" (saved group messages)
// that haven't been stored by Server A yet, and resends them via WebSocket
func (s *Scheduler) runMessageResend() {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			s.executeMessageResend()
		case <-s.stopChan:
			return
		}
	}
}

// executeMessageResend scans Redis for unsaved messages and resends them to Server A concurrently
func (s *Scheduler) executeMessageResend() {
	// Check if WebSocket is connected to Server A
	if !s.wsClient.IsConnected() {
		return
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	totalResent := 0

	// Process private messages (2-*) and group messages (3-*) concurrently
	wg.Add(2)

	go func() {
		defer wg.Done()
		count := s.resendPrivateMessages()
		mu.Lock()
		totalResent += count
		mu.Unlock()
	}()

	go func() {
		defer wg.Done()
		count := s.resendGroupMessages()
		mu.Lock()
		totalResent += count
		mu.Unlock()
	}()

	wg.Wait()

	if totalResent > 0 {
		log.Printf("[MessageResend] Resend completed: %d messages resent", totalResent)
	}
}

// resendPrivateMessages scans Redis for saved private messages (2-*) and resends them
// Returns the number of messages resent
func (s *Scheduler) resendPrivateMessages() int {
	keys, err := s.redisClient.GetSavedPrivateKeys()
	if err != nil {
		log.Printf("[MessageResend] Failed to get saved private keys: %v", err)
		return 0
	}

	if len(keys) == 0 {
		return 0
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	resent := 0

	for _, key := range keys {
		wg.Add(1)
		go func(k string) {
			defer wg.Done()
			count := s.resendMessagesForKey(k, "message")
			mu.Lock()
			resent += count
			mu.Unlock()
		}(key)
	}

	wg.Wait()
	return resent
}

// resendGroupMessages scans Redis for saved group messages (3-*) and resends them
// Returns the number of messages resent
func (s *Scheduler) resendGroupMessages() int {
	keys, err := s.redisClient.GetSavedGroupKeys()
	if err != nil {
		log.Printf("[MessageResend] Failed to get saved group keys: %v", err)
		return 0
	}

	if len(keys) == 0 {
		return 0
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	resent := 0

	for _, key := range keys {
		wg.Add(1)
		go func(k string) {
			defer wg.Done()
			count := s.resendMessagesForKey(k, "group_message_send")
			mu.Lock()
			resent += count
			mu.Unlock()
		}(key)
	}

	wg.Wait()
	return resent
}

// resendMessagesForKey processes a single Redis key, resending all its messages to Server A
// msgType: "message" for private chat, "group_message_send" for group chat
// Returns the number of messages resent
func (s *Scheduler) resendMessagesForKey(key string, msgType string) int {
	// 🔴 防止竞争条件：只处理在 Redis 中存在超过 30 秒的消息
	// HSetMessage 每次写入都将 TTL 设为 7 天，如果 TTL 仍然接近 7 天，
	// 说明消息刚刚被客户端写入，正在通过正常流程发送给服务器A，此时跳过以避免重复
	const maxTTL = 7 * 24 * time.Hour
	const minAge = 30 * time.Second

	ttl, err := s.redisClient.GetKeyTTL(key)
	if err != nil {
		log.Printf("[MessageResend] Failed to get TTL for key %s: %v", key, err)
		return 0
	}
	// TTL > 0 且距离最大 TTL 不到 30 秒，说明刚写入不久
	if ttl > 0 && ttl > maxTTL-minAge {
		return 0
	}

	// Get all field-value pairs from the hash map
	fields, err := s.redisClient.HGetAll(key)
	if err != nil {
		log.Printf("[MessageResend] Failed to get fields for key %s: %v", key, err)
		return 0
	}

	// Skip empty keys
	if len(fields) == 0 {
		return 0
	}

	// Validate key format
	parts := strings.Split(key, "-")
	if len(parts) != 3 {
		log.Printf("[MessageResend] Invalid key format: %s", key)
		return 0
	}

	// Extract sender ID from key (format: 2-{senderID}-{receiverID} or 3-{senderID}-{groupID})
	senderID, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		log.Printf("[MessageResend] Failed to parse sender ID from key %s: %v", key, err)
		return 0
	}

	log.Printf("[MessageResend] Processing key %s (%s): %d messages to resend, senderID=%d", key, msgType, len(fields), senderID)

	resent := 0

	// Resend each message
	for field, messageJSON := range fields {
		// Parse the stored message JSON to get the original data
		var messageData map[string]interface{}
		if err := json.Unmarshal([]byte(messageJSON), &messageData); err != nil {
			log.Printf("[MessageResend] Failed to parse message JSON for key=%s, field=%s: %v", key, field, err)
			continue
		}

		// 🔴 注入 sender_id：Server B 的 WebSocket 连接 userID=0，
		// Server A 的 handleSendMessage 需要真实的 sender_id 来正确处理消息
		messageData["sender_id"] = senderID

		// Wrap as WebSocket message: {"type": "<msgType>", "data": {...}}
		wsMessage := map[string]interface{}{
			"type": msgType,
			"data": messageData,
		}

		wsMessageBytes, err := json.Marshal(wsMessage)
		if err != nil {
			log.Printf("[MessageResend] Failed to marshal WebSocket message: %v", err)
			continue
		}

		// Send to Server A via WebSocket
		if err := s.wsClient.SendRawMessage(wsMessageBytes); err != nil {
			log.Printf("[MessageResend] Failed to send message to Server A: key=%s, field=%s, error=%v", key, field, err)
			// Stop processing if WebSocket is disconnected
			break
		}

		resent++
		log.Printf("[MessageResend] Resent message: key=%s, field=%s, type=%s", key, field, msgType)
	}

	return resent
}
