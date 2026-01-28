package websocket

import (
	"time"
	"youdu-server/utils"

	"github.com/gorilla/websocket"
)

const (
	// 允许向对端写入消息的时间
	writeWait = 10 * time.Second

	// 允许从对端读取下一个pong消息的时间
	pongWait = 60 * time.Second

	// 在此期间向对端发送ping消息，必须小于pongWait
	pingPeriod = (pongWait * 9) / 10

	// 允许的最大消息大小
	maxMessageSize = 512 * 1024 // 512KB
)

// Conn 封装websocket连接
type Conn struct {
	ws *websocket.Conn
}

// NewConn 创建新的连接
func NewConn(ws *websocket.Conn) *Conn {
	return &Conn{ws: ws}
}

// ReadPump 从WebSocket连接读取消息并发送到hub
func (c *Conn) ReadPump(client *Client, hub *Hub, handleMessage func(*Client, []byte)) {
	defer func() {
		hub.Unregister <- client
		c.ws.Close()
	}()

	c.ws.SetReadLimit(maxMessageSize)
	c.ws.SetReadDeadline(time.Now().Add(pongWait))
	c.ws.SetPongHandler(func(string) error {
		c.ws.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, message, err := c.ws.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				utils.LogDebug("WebSocket错误: %v", err)
			}
			break
		}

		// 🔴 收到任何消息都重置读取超时（支持应用层心跳）
		c.ws.SetReadDeadline(time.Now().Add(pongWait))

		// 🔴 将消息放入处理队列，由worker协程异步处理
		hub.EnqueueMessage(client, message)
	}
}

// WritePump 将消息从hub写入到WebSocket连接
func (c *Conn) WritePump(client *Client, hub *Hub) {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.ws.Close()
	}()

	for {
		select {
		case message, ok := <-client.Send:
			c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// Hub关闭了通道
				c.ws.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			w, err := c.ws.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			w.Write(message)

			// 将队列中的其他消息也一起发送
			n := len(client.Send)
			for i := 0; i < n; i++ {
				w.Write([]byte{'\n'})
				w.Write(<-client.Send)
			}

			if err := w.Close(); err != nil {
				return
			}

		case <-ticker.C:
			c.ws.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.ws.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
