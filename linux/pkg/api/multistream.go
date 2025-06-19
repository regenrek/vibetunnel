package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/vibetunnel/linux/pkg/protocol"
	"github.com/vibetunnel/linux/pkg/session"
)

type MultiSSEStreamer struct {
	w          http.ResponseWriter
	manager    *session.Manager
	sessionIDs []string
	flusher    http.Flusher
	done       chan struct{}
	wg         sync.WaitGroup
}

func NewMultiSSEStreamer(w http.ResponseWriter, manager *session.Manager, sessionIDs []string) *MultiSSEStreamer {
	flusher, _ := w.(http.Flusher)
	return &MultiSSEStreamer{
		w:          w,
		manager:    manager,
		sessionIDs: sessionIDs,
		flusher:    flusher,
		done:       make(chan struct{}),
	}
}

func (m *MultiSSEStreamer) Stream() {
	m.w.Header().Set("Content-Type", "text/event-stream")
	m.w.Header().Set("Cache-Control", "no-cache")
	m.w.Header().Set("Connection", "keep-alive")
	m.w.Header().Set("X-Accel-Buffering", "no")

	// Start a goroutine for each session
	for _, sessionID := range m.sessionIDs {
		m.wg.Add(1)
		go m.streamSession(sessionID)
	}

	// Wait for all streams to complete
	m.wg.Wait()
}

func (m *MultiSSEStreamer) streamSession(sessionID string) {
	defer m.wg.Done()

	sess, err := m.manager.GetSession(sessionID)
	if err != nil {
		m.sendError(sessionID, fmt.Sprintf("Session not found: %v", err))
		return
	}

	streamPath := sess.StreamOutPath()
	file, err := os.Open(streamPath)
	if err != nil {
		m.sendError(sessionID, fmt.Sprintf("Failed to open stream: %v", err))
		return
	}
	defer file.Close()

	// Seek to end for live streaming
	file.Seek(0, io.SeekEnd)

	reader := protocol.NewStreamReader(file)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-m.done:
			return
		case <-ticker.C:
			for {
				event, err := reader.Next()
				if err != nil {
					if err != io.EOF {
						m.sendError(sessionID, fmt.Sprintf("Stream read error: %v", err))
						return
					}
					break
				}

				if err := m.sendEvent(sessionID, event); err != nil {
					return
				}

				if event.Type == "end" {
					return
				}
			}
		}
	}
}

func (m *MultiSSEStreamer) sendEvent(sessionID string, event *protocol.StreamEvent) error {
	data := map[string]interface{}{
		"session_id": sessionID,
		"event":      event,
	}

	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}

	if _, err := fmt.Fprintf(m.w, "data: %s\n\n", jsonData); err != nil {
		return err // Client disconnected
	}

	if m.flusher != nil {
		m.flusher.Flush()
	}

	return nil
}

func (m *MultiSSEStreamer) sendError(sessionID string, message string) error {
	event := &protocol.StreamEvent{
		Type:    "error",
		Message: message,
	}
	return m.sendEvent(sessionID, event)
}
