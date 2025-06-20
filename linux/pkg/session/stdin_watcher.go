package session

import (
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"syscall"

	"github.com/fsnotify/fsnotify"
)

// StdinWatcher provides event-driven stdin handling like Node.js
type StdinWatcher struct {
	stdinPath   string
	ptyFile     *os.File
	watcher     *fsnotify.Watcher
	stdinFile   *os.File
	buffer      []byte
	mu          sync.Mutex
	stopChan    chan struct{}
	stoppedChan chan struct{}
}

// NewStdinWatcher creates a new stdin watcher
func NewStdinWatcher(stdinPath string, ptyFile *os.File) (*StdinWatcher, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("failed to create fsnotify watcher: %w", err)
	}

	sw := &StdinWatcher{
		stdinPath:   stdinPath,
		ptyFile:     ptyFile,
		watcher:     watcher,
		buffer:      make([]byte, 4096),
		stopChan:    make(chan struct{}),
		stoppedChan: make(chan struct{}),
	}

	// Open stdin pipe for reading
	stdinFile, err := os.OpenFile(stdinPath, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		watcher.Close()
		return nil, fmt.Errorf("failed to open stdin pipe: %w", err)
	}
	sw.stdinFile = stdinFile

	// Add stdin path to watcher
	if err := watcher.Add(stdinPath); err != nil {
		stdinFile.Close()
		watcher.Close()
		return nil, fmt.Errorf("failed to watch stdin pipe: %w", err)
	}

	return sw, nil
}

// Start begins watching for stdin input
func (sw *StdinWatcher) Start() {
	go sw.watchLoop()
}

// Stop stops the watcher
func (sw *StdinWatcher) Stop() {
	close(sw.stopChan)
	<-sw.stoppedChan
	sw.cleanup()
}

// watchLoop is the main event loop
func (sw *StdinWatcher) watchLoop() {
	defer close(sw.stoppedChan)

	for {
		select {
		case <-sw.stopChan:
			debugLog("[DEBUG] StdinWatcher: Stopping watch loop")
			return

		case event, ok := <-sw.watcher.Events:
			if !ok {
				debugLog("[DEBUG] StdinWatcher: Watcher events channel closed")
				return
			}

			// Handle write events (new data available)
			if event.Op&fsnotify.Write == fsnotify.Write {
				sw.handleStdinData()
			}

		case err, ok := <-sw.watcher.Errors:
			if !ok {
				debugLog("[DEBUG] StdinWatcher: Watcher errors channel closed")
				return
			}
			log.Printf("[ERROR] StdinWatcher: Watcher error: %v", err)
		}
	}
}

// handleStdinData reads available data and forwards it to the PTY
func (sw *StdinWatcher) handleStdinData() {
	sw.mu.Lock()
	defer sw.mu.Unlock()

	for {
		n, err := sw.stdinFile.Read(sw.buffer)
		if n > 0 {
			// Forward data to PTY immediately
			if _, writeErr := sw.ptyFile.Write(sw.buffer[:n]); writeErr != nil {
				log.Printf("[ERROR] StdinWatcher: Failed to write to PTY: %v", writeErr)
				return
			}
			debugLog("[DEBUG] StdinWatcher: Forwarded %d bytes to PTY", n)
		}

		if err != nil {
			if err == io.EOF || isEAGAIN(err) {
				// No more data available right now
				break
			}
			log.Printf("[ERROR] StdinWatcher: Failed to read from stdin: %v", err)
			return
		}

		// If we read a full buffer, there might be more data
		if n == len(sw.buffer) {
			continue
		}
		break
	}
}

// cleanup releases resources
func (sw *StdinWatcher) cleanup() {
	if sw.watcher != nil {
		sw.watcher.Close()
	}
	if sw.stdinFile != nil {
		sw.stdinFile.Close()
	}
}

// isEAGAIN checks if the error is EAGAIN (resource temporarily unavailable)
func isEAGAIN(err error) bool {
	if err == nil {
		return false
	}
	// Check for EAGAIN in the error string
	return err.Error() == "resource temporarily unavailable"
}
