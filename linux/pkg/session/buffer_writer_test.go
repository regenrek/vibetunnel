package session

import (
	"bytes"
	"testing"
	"time"

	"github.com/vibetunnel/linux/pkg/terminal"
)

func TestBufferWriterDirectIntegration(t *testing.T) {
	// Create a terminal buffer
	buffer := terminal.NewTerminalBuffer(80, 24)
	
	// Track notifications
	notificationCount := 0
	notifyCallback := func(sessionID string) error {
		notificationCount++
		if sessionID != "test-session" {
			t.Errorf("Expected session ID 'test-session', got '%s'", sessionID)
		}
		return nil
	}
	
	// Create buffer writer without stream writer (direct integration only)
	bw := NewBufferWriter(buffer, nil, "test-session", notifyCallback)
	
	// Test writing output
	testData := []byte("Hello, Terminal!\n")
	n, err := bw.Write(testData)
	if err != nil {
		t.Fatalf("Failed to write: %v", err)
	}
	if n != len(testData) {
		t.Errorf("Expected to write %d bytes, wrote %d", len(testData), n)
	}
	
	// Verify notification was called
	if notificationCount != 1 {
		t.Errorf("Expected 1 notification, got %d", notificationCount)
	}
	
	// Get buffer snapshot to verify content
	snapshot := buffer.GetSnapshot()
	if snapshot == nil {
		t.Fatal("Failed to get buffer snapshot")
	}
	
	// Extract text from first line
	var lineBuffer bytes.Buffer
	for _, cell := range snapshot.Cells[0] {
		if cell.Char != ' ' && cell.Char != 0 {
			lineBuffer.WriteRune(cell.Char)
		}
	}
	
	expectedText := "Hello, Terminal!"
	if lineBuffer.String() != expectedText {
		t.Errorf("Expected buffer to contain '%s', got '%s'", expectedText, lineBuffer.String())
	}
	
	// Test resize
	err = bw.WriteResize(100, 30)
	if err != nil {
		t.Fatalf("Failed to resize: %v", err)
	}
	
	// Verify notification was called for resize
	if notificationCount != 2 {
		t.Errorf("Expected 2 notifications after resize, got %d", notificationCount)
	}
	
	// Verify buffer was resized
	snapshot = buffer.GetSnapshot()
	if snapshot.Cols != 100 || snapshot.Rows != 30 {
		t.Errorf("Expected buffer size 100x30, got %dx%d", snapshot.Cols, snapshot.Rows)
	}
}

func TestBufferWriterWithStreamWriter(t *testing.T) {
	// This test would verify that buffer writer works with both
	// direct buffer integration AND asciinema file recording
	// For now, we'll just verify the buffer writer can be created
	// with a nil stream writer
	
	buffer := terminal.NewTerminalBuffer(80, 24)
	bw := NewBufferWriter(buffer, nil, "test-session", nil)
	
	if bw == nil {
		t.Fatal("Failed to create buffer writer")
	}
	
	// Verify last write time is set
	lastWrite := bw.GetLastWriteTime()
	if lastWrite.IsZero() {
		t.Error("Last write time should not be zero")
	}
	
	// Write some data
	time.Sleep(10 * time.Millisecond) // Ensure time difference
	_, err := bw.Write([]byte("test"))
	if err != nil {
		t.Fatalf("Failed to write: %v", err)
	}
	
	newLastWrite := bw.GetLastWriteTime()
	if !newLastWrite.After(lastWrite) {
		t.Error("Last write time should be updated after write")
	}
}

func TestBufferWriterSubscribers(t *testing.T) {
	buffer := terminal.NewTerminalBuffer(80, 24)
	bw := NewBufferWriter(buffer, nil, "test-session", nil)
	
	// Subscribe to raw output
	ch := bw.Subscribe()
	
	// Write data
	testData := []byte("subscriber test")
	go func() {
		_, err := bw.Write(testData)
		if err != nil {
			t.Errorf("Failed to write: %v", err)
		}
	}()
	
	// Read from subscriber channel
	select {
	case data := <-ch:
		if !bytes.Equal(data, testData) {
			t.Errorf("Expected to receive '%s', got '%s'", testData, data)
		}
	case <-time.After(100 * time.Millisecond):
		t.Error("Timeout waiting for subscriber notification")
	}
	
	// Unsubscribe
	bw.Unsubscribe(ch)
	
	// Verify channel is closed
	select {
	case _, ok := <-ch:
		if ok {
			t.Error("Expected channel to be closed after unsubscribe")
		}
	case <-time.After(100 * time.Millisecond):
		t.Error("Channel should be closed immediately")
	}
}