package termsocket

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"time"

	"github.com/vibetunnel/linux/pkg/session"
	"github.com/vibetunnel/linux/pkg/terminal"
)

// SessionBuffer holds both the session and its terminal buffer
type SessionBuffer struct {
	Session *session.Session
	Buffer  *terminal.TerminalBuffer
	mu      sync.RWMutex
}

// Manager manages terminal buffers for sessions
type Manager struct {
	sessionManager *session.Manager
	buffers        map[string]*SessionBuffer
	mu             sync.RWMutex
	subscribers    map[string][]chan *terminal.BufferSnapshot
	subMu          sync.RWMutex
}

// NewManager creates a new terminal socket manager
func NewManager(sessionManager *session.Manager) *Manager {
	return &Manager{
		sessionManager: sessionManager,
		buffers:        make(map[string]*SessionBuffer),
		subscribers:    make(map[string][]chan *terminal.BufferSnapshot),
	}
}

// GetOrCreateBuffer gets or creates a terminal buffer for a session
func (m *Manager) GetOrCreateBuffer(sessionID string) (*SessionBuffer, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Check if buffer already exists
	if sb, exists := m.buffers[sessionID]; exists {
		return sb, nil
	}

	// Get session from session manager
	sess, err := m.sessionManager.GetSession(sessionID)
	if err != nil {
		return nil, fmt.Errorf("session not found: %w", err)
	}

	// Get session info to determine terminal size
	info := sess.GetInfo()

	// Create terminal buffer
	buffer := terminal.NewTerminalBuffer(info.Width, info.Height)

	sb := &SessionBuffer{
		Session: sess,
		Buffer:  buffer,
	}

	m.buffers[sessionID] = sb

	// Start monitoring the session's output
	go m.monitorSession(sessionID, sb)

	return sb, nil
}

// GetBufferSnapshot gets the current buffer snapshot for a session
func (m *Manager) GetBufferSnapshot(sessionID string) (*terminal.BufferSnapshot, error) {
	sb, err := m.GetOrCreateBuffer(sessionID)
	if err != nil {
		return nil, err
	}

	sb.mu.RLock()
	defer sb.mu.RUnlock()

	return sb.Buffer.GetSnapshot(), nil
}

// SubscribeToBufferChanges subscribes to buffer changes for a session
func (m *Manager) SubscribeToBufferChanges(sessionID string, callback func(string, *terminal.BufferSnapshot)) (func(), error) {
	// Ensure buffer exists
	_, err := m.GetOrCreateBuffer(sessionID)
	if err != nil {
		return nil, err
	}

	// Create subscription channel
	ch := make(chan *terminal.BufferSnapshot, 10)

	m.subMu.Lock()
	m.subscribers[sessionID] = append(m.subscribers[sessionID], ch)
	m.subMu.Unlock()

	// Start goroutine to handle callbacks
	done := make(chan struct{})
	go func() {
		for {
			select {
			case snapshot := <-ch:
				callback(sessionID, snapshot)
			case <-done:
				return
			}
		}
	}()

	// Return unsubscribe function
	return func() {
		close(done)
		m.subMu.Lock()
		defer m.subMu.Unlock()

		// Remove channel from subscribers
		subs := m.subscribers[sessionID]
		for i, sub := range subs {
			if sub == ch {
				m.subscribers[sessionID] = append(subs[:i], subs[i+1:]...)
				close(ch)
				break
			}
		}

		// Clean up if no more subscribers
		if len(m.subscribers[sessionID]) == 0 {
			delete(m.subscribers, sessionID)
		}
	}, nil
}

// monitorSession monitors a session's output and updates the terminal buffer
func (m *Manager) monitorSession(sessionID string, sb *SessionBuffer) {
	// This is a simplified version - in a real implementation, we would:
	// 1. Set up a file watcher on the session's stream-out file
	// 2. Parse new asciinema events as they arrive
	// 3. Feed the output data to the terminal buffer
	// 4. Notify subscribers of buffer changes

	// For now, we'll implement a basic polling approach
	streamPath := sb.Session.StreamOutPath()
	lastPos := int64(0)

	for {
		// Check if session is still alive
		if !sb.Session.IsAlive() {
			break
		}

		// Read new content from stream file
		data, newPos, err := readStreamContent(streamPath, lastPos)
		if err != nil {
			log.Printf("Error reading stream content: %v", err)
			continue
		}

		if len(data) > 0 {
			// Update buffer
			sb.mu.Lock()
			sb.Buffer.Write(data)
			snapshot := sb.Buffer.GetSnapshot()
			sb.mu.Unlock()

			// Notify subscribers
			m.notifySubscribers(sessionID, snapshot)
		}

		lastPos = newPos

		// Small delay to prevent busy waiting
		// In production, use file watching instead
		<-time.After(50 * time.Millisecond)
	}

	// Clean up when session ends
	m.mu.Lock()
	delete(m.buffers, sessionID)
	m.mu.Unlock()
}

// notifySubscribers sends buffer updates to all subscribers
func (m *Manager) notifySubscribers(sessionID string, snapshot *terminal.BufferSnapshot) {
	m.subMu.RLock()
	subs := m.subscribers[sessionID]
	m.subMu.RUnlock()

	for _, ch := range subs {
		select {
		case ch <- snapshot:
		default:
			// Channel full, skip
		}
	}
}

// readStreamContent reads new content from an asciinema stream file
func readStreamContent(path string, lastPos int64) ([]byte, int64, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, lastPos, err
	}
	defer file.Close()

	// Get current file size
	stat, err := file.Stat()
	if err != nil {
		return nil, lastPos, err
	}

	currentSize := stat.Size()
	if currentSize <= lastPos {
		// No new content
		return nil, lastPos, nil
	}

	// Seek to last position
	if _, err := file.Seek(lastPos, 0); err != nil {
		return nil, lastPos, err
	}

	// Read new content
	newContent := make([]byte, currentSize-lastPos)
	n, err := file.Read(newContent)
	if err != nil && err != io.EOF {
		return nil, lastPos, err
	}

	// Parse asciinema events and extract output data
	outputData := []byte{}
	decoder := json.NewDecoder(bytes.NewReader(newContent[:n]))
	
	// Skip header if at beginning of file
	if lastPos == 0 {
		var header map[string]interface{}
		if err := decoder.Decode(&header); err == nil {
			// Successfully decoded header, continue
		}
	}

	// Parse events
	for decoder.More() {
		var event []interface{}
		if err := decoder.Decode(&event); err != nil {
			// Incomplete event, return what we have so far
			break
		}

		// Asciinema format: [timestamp, event_type, data]
		if len(event) >= 3 {
			eventType, ok := event[1].(string)
			if !ok {
				continue
			}

			if eventType == "o" { // Output event
				data, ok := event[2].(string)
				if ok {
					outputData = append(outputData, []byte(data)...)
				}
			}
			// TODO: Handle resize events ("r" type)
		}
	}

	return outputData, lastPos + int64(n), nil
}
