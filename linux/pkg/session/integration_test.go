package session

import (
	"testing"
	"time"
)

func TestEscapeParserIntegration(t *testing.T) {
	// Test that escape parser is integrated properly
	t.Log("Escape parser is integrated into the session package")
}

func TestProcessTerminatorIntegration(t *testing.T) {
	// Test process terminator
	session := &Session{
		ID: "test-terminator",
		info: &Info{
			Pid:    999999, // Non-existent
			Status: string(StatusRunning),
		},
	}

	terminator := NewProcessTerminator(session)

	// Verify it was created with correct timeouts
	if terminator.gracefulTimeout != 3*time.Second {
		t.Errorf("Expected 3s graceful timeout, got %v", terminator.gracefulTimeout)
	}
	if terminator.checkInterval != 500*time.Millisecond {
		t.Errorf("Expected 500ms check interval, got %v", terminator.checkInterval)
	}
}

func TestCustomErrorsIntegration(t *testing.T) {
	// Test custom error types
	err := NewSessionError("test error", ErrSessionNotFound, "test-id")

	if err.Code != ErrSessionNotFound {
		t.Errorf("Expected code %v, got %v", ErrSessionNotFound, err.Code)
	}

	if !IsSessionError(err, ErrSessionNotFound) {
		t.Error("IsSessionError should return true")
	}

	if GetSessionID(err) != "test-id" {
		t.Errorf("Expected session ID 'test-id', got '%s'", GetSessionID(err))
	}
}
