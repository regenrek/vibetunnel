package api

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vibetunnel/linux/pkg/session"
	"github.com/vibetunnel/linux/pkg/terminal"
	"github.com/vibetunnel/linux/pkg/termsocket"
)

const (
	// Magic byte for binary messages
	BufferMagicByte = 0xbf

	// WebSocket timeouts
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = (pongWait * 9) / 10
	maxMessageSize = 512 * 1024 // 512KB
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		// Allow all origins for now
		return true
	},
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
}

type BufferWebSocketHandler struct {
	manager       *session.Manager
	bufferManager *termsocket.Manager
}

func NewBufferWebSocketHandler(manager *session.Manager) *BufferWebSocketHandler {
	return &BufferWebSocketHandler{
		manager:       manager,
		bufferManager: termsocket.NewManager(manager),
	}
}

// safeSend safely sends data to a channel, returning false if the channel is closed
func safeSend(send chan []byte, data []byte, done chan struct{}) bool {
	defer func() {
		if r := recover(); r != nil {
			// Channel send panicked (likely closed channel) - expected on disconnect
			log.Printf("Channel send panic (client likely disconnected): %v", r)
		}
	}()

	select {
	case send <- data:
		return true
	case <-done:
		return false
	}
}

func (h *BufferWebSocketHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[WebSocket] Failed to upgrade connection: %v", err)
		return
	}
	defer func() {
		if err := conn.Close(); err != nil {
			log.Printf("[WebSocket] Failed to close connection: %v", err)
		}
	}()

	// Set up connection parameters
	conn.SetReadLimit(maxMessageSize)
	if err := conn.SetReadDeadline(time.Now().Add(pongWait)); err != nil {
		log.Printf("[WebSocket] Failed to set read deadline: %v", err)
	}
	conn.SetPongHandler(func(string) error {
		if err := conn.SetReadDeadline(time.Now().Add(pongWait)); err != nil {
			log.Printf("[WebSocket] Failed to set read deadline in pong handler: %v", err)
		}
		return nil
	})

	// Start ping ticker
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()

	// Channel for writing messages
	send := make(chan []byte, 256)
	done := make(chan struct{})
	var closeOnce sync.Once

	// Helper function to safely close done channel
	closeOnceFunc := func() {
		closeOnce.Do(func() {
			close(done)
		})
	}

	// Start writer goroutine
	go h.writer(conn, send, ticker, done)

	// Handle incoming messages - remove busy loop
	for {
		messageType, message, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("[WebSocket] Error: %v", err)
			}
			closeOnceFunc()
			return
		}

		if messageType == websocket.TextMessage {
			h.handleTextMessage(conn, message, send, done, closeOnceFunc)
		}
	}
}

func (h *BufferWebSocketHandler) handleTextMessage(conn *websocket.Conn, message []byte, send chan []byte, done chan struct{}, closeFunc func()) {
	var msg map[string]interface{}
	if err := json.Unmarshal(message, &msg); err != nil {
		log.Printf("[WebSocket] Failed to parse message: %v", err)
		return
	}

	msgType, ok := msg["type"].(string)
	if !ok {
		return
	}

	switch msgType {
	case "ping":
		// Send pong response
		pong, _ := json.Marshal(map[string]string{"type": "pong"})
		if !safeSend(send, pong, done) {
			return
		}

	case "subscribe":
		sessionID, ok := msg["sessionId"].(string)
		if !ok {
			return
		}

		// Subscribe to buffer updates
		go h.subscribeToBuffer(sessionID, send, done)

	case "unsubscribe":
		// Currently we just close the connection when unsubscribing
		closeFunc()
	}
}

func (h *BufferWebSocketHandler) subscribeToBuffer(sessionID string, send chan []byte, done chan struct{}) {
	// Send initial buffer state
	snapshot, err := h.bufferManager.GetBufferSnapshot(sessionID)
	if err != nil {
		log.Printf("[WebSocket] Failed to get buffer snapshot: %v", err)
		errorMsg, _ := json.Marshal(map[string]string{
			"type":    "error",
			"message": fmt.Sprintf("Failed to get session buffer: %v", err),
		})
		safeSend(send, errorMsg, done)
		return
	}

	// Send initial snapshot
	msg := h.createBinaryBufferMessage(sessionID, snapshot)
	if !safeSend(send, msg, done) {
		return
	}

	// Subscribe to buffer changes
	unsubscribe, err := h.bufferManager.SubscribeToBufferChanges(sessionID, func(sid string, snapshot *terminal.BufferSnapshot) {
		msg := h.createBinaryBufferMessage(sid, snapshot)
		safeSend(send, msg, done)
	})
	
	if err != nil {
		log.Printf("[WebSocket] Failed to subscribe to buffer changes: %v", err)
		errorMsg, _ := json.Marshal(map[string]string{
			"type":    "error",
			"message": fmt.Sprintf("Failed to subscribe to buffer changes: %v", err),
		})
		safeSend(send, errorMsg, done)
		return
	}

	// Wait for done signal
	<-done
	
	// Unsubscribe when done
	unsubscribe()
}


func (h *BufferWebSocketHandler) createBinaryMessage(sessionID string, data []byte) []byte {
	// Binary message format:
	// [magic byte (1)] [session ID length (4, little endian)] [session ID] [data]

	sessionIDBytes := []byte(sessionID)
	totalLen := 1 + 4 + len(sessionIDBytes) + len(data)

	msg := make([]byte, totalLen)
	offset := 0

	// Magic byte
	msg[offset] = BufferMagicByte
	offset++

	// Session ID length (little endian)
	binary.LittleEndian.PutUint32(msg[offset:], uint32(len(sessionIDBytes)))
	offset += 4

	// Session ID
	copy(msg[offset:], sessionIDBytes)
	offset += len(sessionIDBytes)

	// Data
	copy(msg[offset:], data)

	return msg
}

func (h *BufferWebSocketHandler) createBinaryBufferMessage(sessionID string, snapshot *terminal.BufferSnapshot) []byte {
	// Serialize the buffer snapshot to binary format
	snapshotData := snapshot.SerializeToBinary()
	
	// Wrap it in our binary message format
	return h.createBinaryMessage(sessionID, snapshotData)
}

func (h *BufferWebSocketHandler) writer(conn *websocket.Conn, send chan []byte, ticker *time.Ticker, done chan struct{}) {
	defer close(send)

	for {
		select {
		case message, ok := <-send:
			if err := conn.SetWriteDeadline(time.Now().Add(writeWait)); err != nil {
				log.Printf("[WebSocket] Failed to set write deadline: %v", err)
				return
			}
			if !ok {
				if err := conn.WriteMessage(websocket.CloseMessage, []byte{}); err != nil {
					log.Printf("[WebSocket] Failed to write close message: %v", err)
				}
				return
			}

			// Check if it's a text message (JSON) or binary
			if len(message) > 0 && message[0] == '{' {
				// Text message
				if err := conn.WriteMessage(websocket.TextMessage, message); err != nil {
					return
				}
			} else {
				// Binary message
				if err := conn.WriteMessage(websocket.BinaryMessage, message); err != nil {
					return
				}
			}

		case <-ticker.C:
			if err := conn.SetWriteDeadline(time.Now().Add(writeWait)); err != nil {
				log.Printf("[WebSocket] Failed to set write deadline for ping: %v", err)
				return
			}
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}

		case <-done:
			return
		}
	}
}
