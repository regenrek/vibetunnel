package session

import (
	"log"
	"sync"
	"time"

	"github.com/vibetunnel/linux/pkg/protocol"
	"github.com/vibetunnel/linux/pkg/terminal"
)

// BufferWriter implements io.Writer to send PTY output directly to a terminal buffer
// while also optionally recording to an asciinema file for persistence.
type BufferWriter struct {
	buffer         *terminal.TerminalBuffer
	streamWriter   *protocol.StreamWriter // Optional: for recording to file
	sessionID      string
	notifyCallback func(string) error // Callback to notify buffer changes
	subscribers    []chan []byte
	subMu          sync.RWMutex
	lastWrite      time.Time
	mu             sync.Mutex
}

// NewBufferWriter creates a new direct buffer writer
func NewBufferWriter(buffer *terminal.TerminalBuffer, streamWriter *protocol.StreamWriter, sessionID string, notifyCallback func(string) error) *BufferWriter {
	return &BufferWriter{
		buffer:         buffer,
		streamWriter:   streamWriter,
		sessionID:      sessionID,
		notifyCallback: notifyCallback,
		subscribers:    make([]chan []byte, 0),
		lastWrite:      time.Now(),
	}
}

// Write implements io.Writer, sending data directly to the terminal buffer
func (bw *BufferWriter) Write(p []byte) (n int, err error) {
	// Write to terminal buffer immediately for real-time updates
	if _, err := bw.buffer.Write(p); err != nil {
		log.Printf("[ERROR] BufferWriter: Failed to write to terminal buffer: %v", err)
		return 0, err
	}
	
	// Notify subscribers of buffer change if callback is set
	if bw.notifyCallback != nil {
		if err := bw.notifyCallback(bw.sessionID); err != nil {
			log.Printf("[ERROR] BufferWriter: Failed to notify buffer update: %v", err)
		}
	}

	// Optionally write to asciinema file for persistence
	if bw.streamWriter != nil {
		if err := bw.streamWriter.WriteOutput(p); err != nil {
			log.Printf("[ERROR] BufferWriter: Failed to write to stream file: %v", err)
			// Don't fail the write if recording fails
		}
	}

	// Notify subscribers of the raw output
	bw.notifySubscribers(p)

	// Update last write time
	bw.mu.Lock()
	bw.lastWrite = time.Now()
	bw.mu.Unlock()

	return len(p), nil
}

// WriteResize handles terminal resize events
func (bw *BufferWriter) WriteResize(width, height uint32) error {
	// Resize the terminal buffer
	bw.buffer.Resize(int(width), int(height))

	// Optionally record resize event
	if bw.streamWriter != nil {
		if err := bw.streamWriter.WriteResize(width, height); err != nil {
			log.Printf("[ERROR] BufferWriter: Failed to write resize event: %v", err)
			// Don't fail if recording fails
		}
	}
	
	// Notify subscribers of buffer change
	if bw.notifyCallback != nil {
		if err := bw.notifyCallback(bw.sessionID); err != nil {
			log.Printf("[ERROR] BufferWriter: Failed to notify resize update: %v", err)
		}
	}

	return nil
}

// Subscribe adds a subscriber to receive raw PTY output
func (bw *BufferWriter) Subscribe() <-chan []byte {
	bw.subMu.Lock()
	defer bw.subMu.Unlock()

	ch := make(chan []byte, 100) // Buffered to prevent blocking
	bw.subscribers = append(bw.subscribers, ch)
	return ch
}

// Unsubscribe removes a subscriber
func (bw *BufferWriter) Unsubscribe(ch <-chan []byte) {
	bw.subMu.Lock()
	defer bw.subMu.Unlock()

	for i, sub := range bw.subscribers {
		if sub == ch {
			close(sub)
			bw.subscribers = append(bw.subscribers[:i], bw.subscribers[i+1:]...)
			break
		}
	}
}

// notifySubscribers sends data to all subscribers
func (bw *BufferWriter) notifySubscribers(data []byte) {
	bw.subMu.RLock()
	defer bw.subMu.RUnlock()

	// Make a copy of the data to avoid race conditions
	dataCopy := make([]byte, len(data))
	copy(dataCopy, data)

	for _, sub := range bw.subscribers {
		select {
		case sub <- dataCopy:
		default:
			// Channel is full, skip this update
		}
	}
}

// GetLastWriteTime returns the time of the last write
func (bw *BufferWriter) GetLastWriteTime() time.Time {
	bw.mu.Lock()
	defer bw.mu.Unlock()
	return bw.lastWrite
}

// Close cleans up resources
func (bw *BufferWriter) Close() error {
	// Close all subscriber channels
	bw.subMu.Lock()
	for _, sub := range bw.subscribers {
		close(sub)
	}
	bw.subscribers = nil
	bw.subMu.Unlock()

	// Close stream writer if present
	if bw.streamWriter != nil {
		return bw.streamWriter.Close()
	}

	return nil
}

// Flush ensures any buffered data is written
func (bw *BufferWriter) Flush() error {
	// StreamWriter doesn't have a Flush method, but it writes immediately
	// so this is a no-op for compatibility
	return nil
}