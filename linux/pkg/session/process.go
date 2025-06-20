package session

import (
	"log"
	"os"
	"time"
)

// ProcessTerminator provides graceful process termination with timeout
// Matches the Node.js implementation behavior
type ProcessTerminator struct {
	session         *Session
	gracefulTimeout time.Duration
	checkInterval   time.Duration
}

// NewProcessTerminator creates a new process terminator
func NewProcessTerminator(session *Session) *ProcessTerminator {
	return &ProcessTerminator{
		session:         session,
		gracefulTimeout: 3 * time.Second,  // Match Node.js 3 second timeout
		checkInterval:   500 * time.Millisecond, // Match Node.js 500ms check interval
	}
}

// TerminateGracefully attempts graceful termination with escalation to SIGKILL
// This matches the Node.js implementation behavior:
// 1. Send SIGTERM
// 2. Wait up to 3 seconds for graceful termination
// 3. Send SIGKILL if process is still alive
func (pt *ProcessTerminator) TerminateGracefully() error {
	sessionID := pt.session.ID[:8]
	pid := pt.session.info.Pid

	// Check if already exited
	if pt.session.info.Status == string(StatusExited) {
		debugLog("[DEBUG] ProcessTerminator: Session %s already exited", sessionID)
		pt.session.cleanup()
		return nil
	}

	if pid == 0 {
		return NewSessionError("no process to terminate", ErrProcessNotFound, pt.session.ID)
	}

	log.Printf("[INFO] Terminating session %s (PID: %d) with SIGTERM...", sessionID, pid)

	// Send SIGTERM first
	if err := pt.session.Signal("SIGTERM"); err != nil {
		// If process doesn't exist, that's fine
		if !pt.session.IsAlive() {
			log.Printf("[INFO] Session %s already terminated", sessionID)
			pt.session.cleanup()
			return nil
		}
		// If it's already a SessionError, return as-is
		if se, ok := err.(*SessionError); ok {
			return se
		}
		return NewSessionErrorWithCause("failed to send SIGTERM", ErrProcessTerminateFailed, pt.session.ID, err)
	}

	// Wait for graceful termination
	startTime := time.Now()
	checkCount := 0
	maxChecks := int(pt.gracefulTimeout / pt.checkInterval)

	for checkCount < maxChecks {
		// Wait for check interval
		time.Sleep(pt.checkInterval)
		checkCount++

		// Check if process is still alive
		if !pt.session.IsAlive() {
			elapsed := time.Since(startTime)
			log.Printf("[INFO] Session %s terminated gracefully after %dms", sessionID, elapsed.Milliseconds())
			pt.session.cleanup()
			return nil
		}

		// Log progress
		elapsed := time.Since(startTime)
		log.Printf("[INFO] Session %s still alive after %dms...", sessionID, elapsed.Milliseconds())
	}

	// Process didn't terminate gracefully, force kill
	log.Printf("[INFO] Session %s didn't terminate gracefully, sending SIGKILL...", sessionID)
	
	if err := pt.session.Signal("SIGKILL"); err != nil {
		// If process doesn't exist anymore, that's fine
		if !pt.session.IsAlive() {
			log.Printf("[INFO] Session %s terminated before SIGKILL", sessionID)
			pt.session.cleanup()
			return nil
		}
		// If it's already a SessionError, return as-is
		if se, ok := err.(*SessionError); ok {
			return se
		}
		return NewSessionErrorWithCause("failed to send SIGKILL", ErrProcessTerminateFailed, pt.session.ID, err)
	}

	// Wait a bit for SIGKILL to take effect
	time.Sleep(100 * time.Millisecond)
	
	if pt.session.IsAlive() {
		log.Printf("[WARN] Session %s may still be alive after SIGKILL", sessionID)
	} else {
		log.Printf("[INFO] Session %s forcefully terminated with SIGKILL", sessionID)
	}

	pt.session.cleanup()
	return nil
}

// waitForProcessExit waits for a process to exit with timeout
// Returns true if process exited within timeout, false otherwise
func waitForProcessExit(pid int, timeout time.Duration) bool {
	startTime := time.Now()
	checkInterval := 100 * time.Millisecond

	for time.Since(startTime) < timeout {
		// Try to find the process
		proc, err := os.FindProcess(pid)
		if err != nil {
			// Process doesn't exist
			return true
		}

		// Check if process is alive using signal 0
		if err := proc.Signal(os.Signal(nil)); err != nil {
			// Process doesn't exist or we don't have permission
			return true
		}

		time.Sleep(checkInterval)
	}

	return false
}

// isProcessRunning checks if a process is running by PID
// Uses platform-appropriate methods
func isProcessRunning(pid int) bool {
	if pid <= 0 {
		return false
	}

	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}

	// On Unix, signal 0 checks if process exists
	err = proc.Signal(os.Signal(nil))
	return err == nil
}