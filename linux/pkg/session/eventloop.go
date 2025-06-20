package session

import (
	"fmt"
	"io"
	"os"
	"syscall"
)

// EventType represents the type of event
type EventType uint32

const (
	EventRead  EventType = 1 << 0
	EventWrite EventType = 1 << 1
	EventError EventType = 1 << 2
	EventHup   EventType = 1 << 3
)

// Event represents an I/O event
type Event struct {
	FD     int
	Events EventType
	Data   interface{} // User data associated with the FD
}

// EventHandler is called when an event occurs
type EventHandler func(event Event)

// EventLoop provides platform-independent event-driven I/O
type EventLoop interface {
	// Add registers a file descriptor for event monitoring
	Add(fd int, events EventType, data interface{}) error
	
	// Remove unregisters a file descriptor
	Remove(fd int) error
	
	// Modify changes the events to monitor for a file descriptor
	Modify(fd int, events EventType) error
	
	// Run starts the event loop, blocking until Stop is called
	Run(handler EventHandler) error
	
	// RunOnce processes events once with optional timeout (-1 for blocking)
	RunOnce(handler EventHandler, timeoutMs int) error
	
	// Stop terminates the event loop
	Stop() error
	
	// Close releases all resources
	Close() error
}

// NewEventLoop creates a platform-specific event loop
func NewEventLoop() (EventLoop, error) {
	return newPlatformEventLoop()
}

// PTYEventHandler handles PTY I/O events using the event loop
type PTYEventHandler struct {
	pty          *PTY
	eventLoop    EventLoop
	outputBuffer []byte
	handlers     map[int]func(Event)
}

// NewPTYEventHandler creates a new event-driven PTY handler
func NewPTYEventHandler(pty *PTY) (*PTYEventHandler, error) {
	eventLoop, err := NewEventLoop()
	if err != nil {
		return nil, fmt.Errorf("failed to create event loop: %w", err)
	}
	
	handler := &PTYEventHandler{
		pty:          pty,
		eventLoop:    eventLoop,
		outputBuffer: make([]byte, 4096),
		handlers:     make(map[int]func(Event)),
	}
	
	// Register PTY for read events
	ptyFD := int(pty.pty.Fd())
	if err := eventLoop.Add(ptyFD, EventRead|EventHup, "pty"); err != nil {
		eventLoop.Close()
		return nil, fmt.Errorf("failed to add PTY to event loop: %w", err)
	}
	
	// Set up handlers
	handler.handlers[ptyFD] = handler.handlePTYEvent
	
	return handler, nil
}

// Run starts the event-driven I/O loop
func (h *PTYEventHandler) Run() error {
	return h.eventLoop.Run(func(event Event) {
		if handler, ok := h.handlers[event.FD]; ok {
			handler(event)
		}
	})
}

// handlePTYEvent processes PTY read events
func (h *PTYEventHandler) handlePTYEvent(event Event) {
	if event.Events&EventRead != 0 {
		// Data available for reading
		for {
			n, err := h.pty.pty.Read(h.outputBuffer)
			if n > 0 {
				// Write to stream immediately
				if err := h.pty.streamWriter.WriteOutput(h.outputBuffer[:n]); err != nil {
					debugLog("[ERROR] Failed to write PTY output: %v", err)
				}
			}
			
			if err != nil {
				if err == io.EOF || err == syscall.EAGAIN || err == syscall.EWOULDBLOCK {
					// No more data available
					break
				}
				// Real error
				debugLog("[ERROR] PTY read error: %v", err)
				h.eventLoop.Stop()
				break
			}
			
			// Continue reading if we filled the buffer
			if n < len(h.outputBuffer) {
				break
			}
		}
	}
	
	if event.Events&EventHup != 0 {
		// PTY closed
		debugLog("[DEBUG] PTY closed (HUP event)")
		h.eventLoop.Stop()
	}
}

// AddStdinPipe adds stdin pipe monitoring to the event loop
func (h *PTYEventHandler) AddStdinPipe(stdinPipe *os.File) error {
	stdinFD := int(stdinPipe.Fd())
	
	// Set non-blocking mode
	if err := syscall.SetNonblock(stdinFD, true); err != nil {
		return fmt.Errorf("failed to set stdin non-blocking: %w", err)
	}
	
	// Add to event loop
	if err := h.eventLoop.Add(stdinFD, EventRead, "stdin"); err != nil {
		return fmt.Errorf("failed to add stdin to event loop: %w", err)
	}
	
	// Set up handler
	h.handlers[stdinFD] = h.handleStdinEvent
	
	return nil
}

// handleStdinEvent processes stdin input events
func (h *PTYEventHandler) handleStdinEvent(event Event) {
	if event.Events&EventRead != 0 {
		buf := make([]byte, 1024)
		n, err := syscall.Read(event.FD, buf)
		if n > 0 {
			// Write to PTY
			if _, err := h.pty.pty.Write(buf[:n]); err != nil {
				debugLog("[ERROR] Failed to write to PTY: %v", err)
			}
			
			// Also write to asciinema stream
			if err := h.pty.streamWriter.WriteInput(buf[:n]); err != nil {
				debugLog("[ERROR] Failed to write input to stream: %v", err)
			}
		}
		
		if err != nil && err != syscall.EAGAIN && err != syscall.EWOULDBLOCK {
			debugLog("[ERROR] Stdin read error: %v", err)
			h.eventLoop.Remove(event.FD)
		}
	}
}

// Stop stops the event loop
func (h *PTYEventHandler) Stop() error {
	return h.eventLoop.Stop()
}

// Close cleans up resources
func (h *PTYEventHandler) Close() error {
	return h.eventLoop.Close()
}