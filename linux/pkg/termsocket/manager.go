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

	"github.com/fsnotify/fsnotify"
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
	shutdownCh     chan struct{}
	wg             sync.WaitGroup
}

// NewManager creates a new terminal socket manager
func NewManager(sessionManager *session.Manager) *Manager {
	return &Manager{
		sessionManager: sessionManager,
		buffers:        make(map[string]*SessionBuffer),
		subscribers:    make(map[string][]chan *terminal.BufferSnapshot),
		shutdownCh:     make(chan struct{}),
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
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		m.monitorSession(sessionID, sb)
	}()

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
	streamPath := sb.Session.StreamOutPath()
	lastPos := int64(0)

	// Try to use file watching
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Printf("Failed to create file watcher, using polling: %v", err)
		m.monitorSessionPolling(sessionID, sb)
		return
	}
	defer watcher.Close()

	// Wait for stream file to exist
	for i := 0; i < 50; i++ { // Wait up to 5 seconds
		if _, err := os.Stat(streamPath); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	// Add file to watcher
	if err := watcher.Add(streamPath); err != nil {
		log.Printf("Failed to watch file %s, using polling: %v", streamPath, err)
		m.monitorSessionPolling(sessionID, sb)
		return
	}

	// Read initial content
	if update, newPos, err := readStreamContent(streamPath, lastPos); err == nil && update != nil {
		if len(update.OutputData) > 0 || update.Resize != nil {
			sb.mu.Lock()
			if len(update.OutputData) > 0 {
				sb.Buffer.Write(update.OutputData)
			}
			if update.Resize != nil {
				sb.Buffer.Resize(update.Resize.Width, update.Resize.Height)
			}
			snapshot := sb.Buffer.GetSnapshot()
			sb.mu.Unlock()
			m.notifySubscribers(sessionID, snapshot)
			lastPos = newPos
		}
	}

	// Monitor for changes
	sessionCheckTicker := time.NewTicker(5 * time.Second)
	defer sessionCheckTicker.Stop()

	for {
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}

			if event.Op&fsnotify.Write == fsnotify.Write {
				// Read new content
				update, newPos, err := readStreamContent(streamPath, lastPos)
				if err != nil {
					log.Printf("Error reading stream content: %v", err)
					continue
				}

				if update != nil && (len(update.OutputData) > 0 || update.Resize != nil) {
					// Update buffer
					sb.mu.Lock()
					if len(update.OutputData) > 0 {
						sb.Buffer.Write(update.OutputData)
					}
					if update.Resize != nil {
						sb.Buffer.Resize(update.Resize.Width, update.Resize.Height)
					}
					snapshot := sb.Buffer.GetSnapshot()
					sb.mu.Unlock()

					// Notify subscribers
					m.notifySubscribers(sessionID, snapshot)
				}

				lastPos = newPos
			}

		case err, ok := <-watcher.Errors:
			if !ok {
				return
			}
			log.Printf("File watcher error: %v", err)

		case <-sessionCheckTicker.C:
			// Check if session is still alive
			if !sb.Session.IsAlive() {
				// Clean up when session ends
				m.mu.Lock()
				delete(m.buffers, sessionID)
				m.mu.Unlock()
				return
			}
			
		case <-m.shutdownCh:
			// Manager is shutting down
			return
		}
	}
}

// monitorSessionPolling is a fallback for when file watching isn't available
func (m *Manager) monitorSessionPolling(sessionID string, sb *SessionBuffer) {
	streamPath := sb.Session.StreamOutPath()
	lastPos := int64(0)

	for {
		select {
		case <-m.shutdownCh:
			// Manager is shutting down
			return
		default:
		}
		
		// Check if session is still alive
		if !sb.Session.IsAlive() {
			break
		}

		// Read new content from stream file
		update, newPos, err := readStreamContent(streamPath, lastPos)
		if err != nil && !os.IsNotExist(err) {
			log.Printf("Error reading stream content: %v", err)
		}

		if update != nil && (len(update.OutputData) > 0 || update.Resize != nil) {
			// Update buffer
			sb.mu.Lock()
			if len(update.OutputData) > 0 {
				sb.Buffer.Write(update.OutputData)
			}
			if update.Resize != nil {
				sb.Buffer.Resize(update.Resize.Width, update.Resize.Height)
			}
			snapshot := sb.Buffer.GetSnapshot()
			sb.mu.Unlock()

			// Notify subscribers
			m.notifySubscribers(sessionID, snapshot)
		}

		lastPos = newPos

		// Small delay to prevent busy waiting
		time.Sleep(50 * time.Millisecond)
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

// StreamUpdate represents an update from the stream file
type StreamUpdate struct {
	OutputData []byte
	Resize     *ResizeEvent
}

// ResizeEvent represents a terminal resize
type ResizeEvent struct {
	Width  int
	Height int
}

// readStreamContent reads new content from an asciinema stream file
func readStreamContent(path string, lastPos int64) (*StreamUpdate, int64, error) {
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
	update := &StreamUpdate{
		OutputData: []byte{},
	}
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
					update.OutputData = append(update.OutputData, []byte(data)...)
				}
			} else if eventType == "r" { // Resize event
				// Resize events have format: [timestamp, "r", "WIDTHxHEIGHT"]
				data, ok := event[2].(string)
				if ok {
					// Parse "WIDTHxHEIGHT" format
					var width, height int
					if _, err := fmt.Sscanf(data, "%dx%d", &width, &height); err == nil {
						update.Resize = &ResizeEvent{
							Width:  width,
							Height: height,
						}
					}
				}
			}
		}
	}

	return update, lastPos + int64(n), nil
}

// Shutdown gracefully shuts down the manager
func (m *Manager) Shutdown() {
	log.Println("Shutting down terminal buffer manager...")
	
	// Signal shutdown
	close(m.shutdownCh)
	
	// Wait for all monitors to finish
	m.wg.Wait()
	
	// Close all subscriber channels
	m.subMu.Lock()
	for _, subs := range m.subscribers {
		for _, ch := range subs {
			close(ch)
		}
	}
	m.subscribers = make(map[string][]chan *terminal.BufferSnapshot)
	m.subMu.Unlock()
	
	// Clear buffers
	m.mu.Lock()
	m.buffers = make(map[string]*SessionBuffer)
	m.mu.Unlock()
	
	log.Println("Terminal buffer manager shutdown complete")
}
