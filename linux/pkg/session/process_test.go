package session

import (
	"os"
	"os/exec"
	"runtime"
	"testing"
	"time"
)

func TestProcessTerminator_TerminateGracefully(t *testing.T) {
	// Skip on Windows as signal handling is different
	if runtime.GOOS == "windows" {
		t.Skip("Skipping signal tests on Windows")
	}

	tests := []struct {
		name           string
		setupSession   func() *Session
		expectGraceful bool
		checkInterval  time.Duration
	}{
		{
			name: "already exited session",
			setupSession: func() *Session {
				s := &Session{
					ID: "test-session-1",
					info: &Info{
						Status: string(StatusExited),
					},
				}
				return s
			},
			expectGraceful: true,
		},
		{
			name: "no process to terminate",
			setupSession: func() *Session {
				s := &Session{
					ID: "test-session-2",
					info: &Info{
						Status: string(StatusRunning),
						Pid:    0,
					},
				}
				return s
			},
			expectGraceful: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			session := tt.setupSession()
			terminator := NewProcessTerminator(session)

			err := terminator.TerminateGracefully()

			if tt.expectGraceful && err != nil {
				t.Errorf("TerminateGracefully() error = %v, want nil", err)
			}
			if !tt.expectGraceful && err == nil {
				t.Error("TerminateGracefully() error = nil, want error")
			}
		})
	}
}

func TestProcessTerminator_RealProcess(t *testing.T) {
	// Skip in CI or on Windows
	if os.Getenv("CI") == "true" || runtime.GOOS == "windows" {
		t.Skip("Skipping real process test in CI/Windows")
	}

	// Start a sleep process that ignores SIGTERM
	cmd := exec.Command("sh", "-c", "trap '' TERM; sleep 10")
	if err := cmd.Start(); err != nil {
		t.Skipf("Cannot start test process: %v", err)
	}

	session := &Session{
		ID: "test-real-process",
		info: &Info{
			Status: string(StatusRunning),
			Pid:    cmd.Process.Pid,
		},
	}

	// Skip cleanup tracking as cleanup is a method not a field

	terminator := NewProcessTerminator(session)
	terminator.gracefulTimeout = 1 * time.Second // Shorter timeout for test
	terminator.checkInterval = 100 * time.Millisecond

	start := time.Now()
	err := terminator.TerminateGracefully()
	elapsed := time.Since(start)

	if err != nil {
		t.Errorf("TerminateGracefully() error = %v", err)
	}

	// Should have waited about 1 second before SIGKILL
	if elapsed < 900*time.Millisecond || elapsed > 1500*time.Millisecond {
		t.Errorf("Expected termination after ~1s, but took %v", elapsed)
	}

	// Process should be dead now
	if err := cmd.Process.Signal(os.Signal(nil)); err == nil {
		t.Error("Process should be terminated")
	}
}

func TestWaitForProcessExit(t *testing.T) {
	tests := []struct {
		name     string
		pid      int
		timeout  time.Duration
		expected bool
	}{
		{
			name:     "non-existent process",
			pid:      999999,
			timeout:  100 * time.Millisecond,
			expected: true,
		},
		{
			name:     "current process (should not exit)",
			pid:      os.Getpid(),
			timeout:  100 * time.Millisecond,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := waitForProcessExit(tt.pid, tt.timeout)
			if result != tt.expected {
				t.Errorf("waitForProcessExit() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestIsProcessRunning(t *testing.T) {
	tests := []struct {
		name     string
		pid      int
		expected bool
	}{
		{
			name:     "invalid pid",
			pid:      0,
			expected: false,
		},
		{
			name:     "negative pid",
			pid:      -1,
			expected: false,
		},
		{
			name:     "current process",
			pid:      os.Getpid(),
			expected: true,
		},
		{
			name:     "non-existent process",
			pid:      999999,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isProcessRunning(tt.pid)
			if result != tt.expected {
				t.Errorf("isProcessRunning(%d) = %v, want %v", tt.pid, result, tt.expected)
			}
		})
	}
}

func TestProcessTerminator_CheckInterval(t *testing.T) {
	session := &Session{
		ID: "test-session",
		info: &Info{
			Status: string(StatusRunning),
			Pid:    999999, // Non-existent
		},
	}

	terminator := NewProcessTerminator(session)

	// Verify default values match Node.js
	if terminator.gracefulTimeout != 3*time.Second {
		t.Errorf("gracefulTimeout = %v, want 3s", terminator.gracefulTimeout)
	}
	if terminator.checkInterval != 500*time.Millisecond {
		t.Errorf("checkInterval = %v, want 500ms", terminator.checkInterval)
	}
}

func BenchmarkIsProcessRunning(b *testing.B) {
	pid := os.Getpid()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		isProcessRunning(pid)
	}
}

func BenchmarkWaitForProcessExit(b *testing.B) {
	// Use non-existent PID for immediate return
	pid := 999999
	timeout := 1 * time.Millisecond

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		waitForProcessExit(pid, timeout)
	}
}
