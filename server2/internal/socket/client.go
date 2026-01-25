package socket

import (
	"crypto/tls"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"server2/internal/config"
)

// Client represents a WebSocket client that connects to Server A
type Client struct {
	cfg         config.ServerAConfig
	conn        *websocket.Conn
	mu          sync.Mutex
	isConnected bool
	reconnectCh chan struct{}
	stopCh      chan struct{} // 用于停止heartbeat和readMessages goroutine
}

// ClientSyncMessage represents the message format for client_sync_message
type ClientSyncMessage struct {
	Type string                `json:"type"`
	Data ClientSyncMessageData `json:"data"`
}

// ClientSyncMessageData represents the data payload for client_sync_message
type ClientSyncMessageData struct {
	ReceiverID      int64   `json:"receiver_id"`
	MessageIDs      []int64 `json:"message_ids"`
	GroupMessageIDs []int64 `json:"group_message_ids"`
}

// NewClient creates a new WebSocket client
func NewClient(cfg config.ServerAConfig) *Client {
	return &Client{
		cfg:         cfg,
		reconnectCh: make(chan struct{}, 1),
		stopCh:      make(chan struct{}),
	}
}

// Connect establishes a WebSocket connection to Server A
// 🔴 移除最大重连次数限制，一直尝试直到成功
func (c *Client) Connect() {
	retryCount := 0
	
	for {
		c.connect()
		
		// 如果连接成功，重置重试计数
		c.mu.Lock()
		isConnected := c.isConnected
		c.mu.Unlock()
		
		if isConnected {
			retryCount = 0 // 连接成功，重置计数
		} else {
			retryCount++
			log.Printf("[Socket] 连接服务器A失败，第%d次重试（持续重试直到成功）", retryCount)
		}
		
		// Wait for reconnect signal or timeout
		select {
		case <-c.reconnectCh:
			log.Println("[Socket] Reconnect signal received")
		case <-time.After(5 * time.Second):
			// Periodic reconnect attempt if disconnected
		}
	}
}

func (c *Client) connect() {
	c.mu.Lock()
	if c.isConnected {
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()

	// Build WebSocket URL with token
	wsURL := c.cfg.WSURL
	if c.cfg.Token != "" {
		wsURL += "?token=" + c.cfg.Token
	}

	log.Printf("[Socket] Connecting to Server A: %s", wsURL)

	// Create a dialer that skips TLS certificate verification
	// This allows connecting to servers with self-signed certificates
	dialer := websocket.Dialer{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
		},
	}

	conn, _, err := dialer.Dial(wsURL, nil)
	if err != nil {
		log.Printf("[Socket] Failed to connect to Server A: %v", err)
		return
	}

	// Set up ping handler to respond to Server A's protocol-level pings
	// This is critical: Server A sends WebSocket ping frames and expects pong responses
	conn.SetPingHandler(func(appData string) error {
		log.Println("[Socket] Received ping from Server A, sending pong")
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.conn != nil {
			// Send pong response with the same application data
			err := c.conn.WriteControl(websocket.PongMessage, []byte(appData), time.Now().Add(10*time.Second))
			if err != nil {
				log.Printf("[Socket] Failed to send pong: %v", err)
				return err
			}
		}
		return nil
	})

	c.mu.Lock()
	// 创建新的stopCh用于这次连接的goroutine
	c.stopCh = make(chan struct{})
	c.conn = conn
	c.isConnected = true
	stopCh := c.stopCh // 复制一份给goroutine使用
	c.mu.Unlock()

	log.Println("[Socket] Connected to Server A")

	// Start reading messages (for heartbeat/pong responses)
	go c.readMessages(stopCh)

	// Start heartbeat
	go c.heartbeat(stopCh)
}

func (c *Client) readMessages(stopCh chan struct{}) {
	// 添加recover保护，防止panic导致程序崩溃
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[Socket] readMessages panic recovered: %v", r)
			c.handleDisconnect()
		}
	}()

	for {
		select {
		case <-stopCh:
			log.Println("[Socket] readMessages goroutine stopped")
			return
		default:
		}

		c.mu.Lock()
		conn := c.conn
		c.mu.Unlock()

		if conn == nil {
			return
		}

		_, message, err := conn.ReadMessage()
		if err != nil {
			log.Printf("[Socket] Read error: %v", err)
			c.handleDisconnect()
			return
		}

		// Parse message
		var msg map[string]interface{}
		if err := json.Unmarshal(message, &msg); err != nil {
			continue
		}

		// Handle pong response
		if msgType, ok := msg["type"].(string); ok && msgType == "pong" {
			log.Println("[Socket] Received pong from Server A")
		}
	}
}

func (c *Client) heartbeat(stopCh chan struct{}) {
	// 添加recover保护，防止panic导致程序崩溃
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[Socket] heartbeat panic recovered: %v", r)
			c.handleDisconnect()
		}
	}()

	// 🔴 Server A runs CheckHeartbeat() every 15 seconds and disconnects clients
	// that miss 2 heartbeats. We need to send pings more frequently than 15 seconds
	// to ensure ResetPingCounter() is called before missedPings reaches 2.
	// Using 10 seconds to have a safety margin.
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	// 🔴 Send an immediate ping on connection to reset the ping counter
	c.sendPing()

	for {
		select {
		case <-stopCh:
			log.Println("[Socket] heartbeat goroutine stopped")
			return
		case <-ticker.C:
			if !c.sendPing() {
				return
			}
		}
	}
}

// sendPing sends an application-level ping message to Server A
// Returns true if successful, false if failed (connection should be closed)
func (c *Client) sendPing() bool {
	c.mu.Lock()
	conn := c.conn
	isConnected := c.isConnected
	c.mu.Unlock()

	if !isConnected || conn == nil {
		return false
	}

	// Send ping with mutex protection
	pingMsg := map[string]string{"type": "ping"}
	data, _ := json.Marshal(pingMsg)

	c.mu.Lock()
	// 再次检查conn是否为nil，防止在获取锁期间被关闭
	if c.conn == nil {
		c.mu.Unlock()
		return false
	}
	err := c.conn.WriteMessage(websocket.TextMessage, data)
	c.mu.Unlock()

	if err != nil {
		log.Printf("[Socket] Heartbeat failed: %v", err)
		c.handleDisconnect()
		return false
	}
	return true
}

func (c *Client) handleDisconnect() {
	c.mu.Lock()
	defer c.mu.Unlock()

	// 先关闭stopCh，通知所有goroutine停止
	if c.stopCh != nil {
		select {
		case <-c.stopCh:
			// 已经关闭了
		default:
			close(c.stopCh)
		}
	}

	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
	c.isConnected = false

	// Signal reconnect
	select {
	case c.reconnectCh <- struct{}{}:
	default:
	}
}

// SendClientSyncMessage sends a client_sync_message to Server A
// This notifies Server A to send unsynchronized messages to the specified receiver
func (c *Client) SendClientSyncMessage(receiverID int64, messageIDs, groupMessageIDs []int64) error {
	// 添加recover保护，防止panic导致程序崩溃
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[Socket] SendClientSyncMessage panic recovered: %v", r)
		}
	}()

	c.mu.Lock()
	conn := c.conn
	isConnected := c.isConnected
	c.mu.Unlock()

	if !isConnected || conn == nil {
		return ErrNotConnected
	}

	msg := ClientSyncMessage{
		Type: "client_sync_message",
		Data: ClientSyncMessageData{
			ReceiverID:      receiverID,
			MessageIDs:      messageIDs,
			GroupMessageIDs: groupMessageIDs,
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// 再次检查conn是否为nil，防止在获取锁期间被关闭
	if c.conn == nil {
		return ErrNotConnected
	}

	if err := c.conn.WriteMessage(websocket.TextMessage, data); err != nil {
		log.Printf("[Socket] Failed to send client_sync_message: %v", err)
		return err
	}

	log.Printf("[Socket] Sent client_sync_message: receiverID=%d, messageIDs=%v, groupMessageIDs=%v",
		receiverID, messageIDs, groupMessageIDs)

	return nil
}

// IsConnected returns whether the client is connected to Server A
func (c *Client) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.isConnected
}

// ErrNotConnected is returned when trying to send a message while not connected
var ErrNotConnected = &NotConnectedError{}

type NotConnectedError struct{}

func (e *NotConnectedError) Error() string {
	return "not connected to Server A"
}
