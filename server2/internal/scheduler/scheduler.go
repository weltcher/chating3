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
	log.Println("[Scheduler] Started message resend scheduler (runs every 5 seconds)")
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
	ticker := time.NewTicker(5 * time.Second)
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

// resendMessagesForKey processes a single Redis key, resending its message to Server A
// Each key now stores a single message as a string value (not a hash map)
// Key format: 2-{senderID}-{receiverID}-{clientMessageID} or 3-{senderID}-{groupID}-{clientGroupMessageID}
// msgType: "message" for private chat, "group_message_send" for group chat
// Returns the number of messages resent (0 or 1)
func (s *Scheduler) resendMessagesForKey(key string, msgType string) int {

	// Validate key format (4 segments: type-senderID-receiverID/groupID-messageID)
	parts := strings.Split(key, "-")
	if len(parts) != 4 {
		log.Printf("[MessageResend] Invalid key format: %s", key)
		return 0
	}

	// Extract sender ID from key
	senderID, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		log.Printf("[MessageResend] Failed to parse sender ID from key %s: %v", key, err)
		return 0
	}

	// 🔴 关键修复：每次执行时重新从 Redis 读取最新数据
	// 防止竞态条件：KEYS 扫描到 key 后，Server A 可能已经通过 delete-saved-message 删除了该 key
	// 此时 GetMessage 会返回 redis.Nil 错误或空字符串，我们就跳过这条消息
	messageJSON, err := s.redisClient.GetMessage(key)
	if err != nil {
		// key 已被删除（redis.Nil）或其他错误，跳过
		log.Printf("[MessageResend] Key %s no longer exists or error reading: %v, skipping", key, err)
		return 0
	}

	if messageJSON == "" {
		// key 存在但值为空，跳过
		log.Printf("[MessageResend] Key %s has empty value, skipping", key)
		return 0
	}

	log.Printf("[MessageResend] Processing key %s (%s): senderID=%d", key, msgType, senderID)

	// Parse the stored message JSON to get the original data
	var messageData map[string]interface{}
	if err := json.Unmarshal([]byte(messageJSON), &messageData); err != nil {
		log.Printf("[MessageResend] Failed to parse message JSON for key=%s: %v", key, err)
		return 0
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
		return 0
	}

	// Send to Server A via WebSocket
	if err := s.wsClient.SendRawMessage(wsMessageBytes); err != nil {
		log.Printf("[MessageResend] Failed to send message to Server A: key=%s, error=%v", key, err)
		return 0
	}

	log.Printf("[MessageResend] Resent message: key=%s, type=%s", key, msgType)
	return 1
}
