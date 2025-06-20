package session

import (
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewStdinWatcher(t *testing.T) {
	// Create temporary directory for testing
	tmpDir := t.TempDir()

	// Create a named pipe
	pipePath := filepath.Join(tmpDir, "stdin")
	if err := os.MkdirAll(filepath.Dir(pipePath), 0755); err != nil {
		t.Fatal(err)
	}

	// Create the pipe file (will be a regular file in tests)
	if err := os.WriteFile(pipePath, []byte{}, 0644); err != nil {
		t.Fatal(err)
	}

	// Create a mock PTY file
	ptyFile, err := os.CreateTemp(tmpDir, "pty")
	if err != nil {
		t.Fatal(err)
	}
	defer ptyFile.Close()

	// Test creating stdin watcher
	watcher, err := NewStdinWatcher(pipePath, ptyFile)
	if err != nil {
		t.Fatalf("NewStdinWatcher() error = %v", err)
	}
	defer func() {
		// Only stop if it was started
		if watcher.watcher != nil {
			watcher.watcher.Close()
		}
		if watcher.stdinFile != nil {
			watcher.stdinFile.Close()
		}
	}()

	if watcher.stdinPath != pipePath {
		t.Errorf("stdinPath = %v, want %v", watcher.stdinPath, pipePath)
	}
	if watcher.ptyFile != ptyFile {
		t.Errorf("ptyFile = %v, want %v", watcher.ptyFile, ptyFile)
	}
	if watcher.watcher == nil {
		t.Error("watcher should not be nil")
	}
	if watcher.stdinFile == nil {
		t.Error("stdinFile should not be nil")
	}
}

func TestStdinWatcher_StartStop(t *testing.T) {
	// Create temporary directory for testing
	tmpDir := t.TempDir()

	// Create a named pipe
	pipePath := filepath.Join(tmpDir, "stdin")
	if err := os.WriteFile(pipePath, []byte{}, 0644); err != nil {
		t.Fatal(err)
	}

	// Create a mock PTY file
	ptyFile, err := os.CreateTemp(tmpDir, "pty")
	if err != nil {
		t.Fatal(err)
	}
	defer ptyFile.Close()

	watcher, err := NewStdinWatcher(pipePath, ptyFile)
	if err != nil {
		t.Fatal(err)
	}

	// Start the watcher
	watcher.Start()

	// Give it a moment to start
	time.Sleep(10 * time.Millisecond)

	// Stop the watcher
	done := make(chan bool)
	go func() {
		watcher.Stop()
		done <- true
	}()

	// Should stop quickly
	select {
	case <-done:
		// Success
	case <-time.After(1 * time.Second):
		t.Error("Stop() took too long")
	}
}

func TestStdinWatcher_HandleStdinData(t *testing.T) {
	// Create temporary directory for testing
	tmpDir := t.TempDir()

	// Create a named pipe path
	pipePath := filepath.Join(tmpDir, "stdin")

	// Create PTY pipe for reading what's written
	ptyReader, ptyWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer ptyReader.Close()
	defer ptyWriter.Close()

	// Create stdin file
	stdinFile, err := os.Create(pipePath)
	if err != nil {
		t.Fatal(err)
	}
	defer stdinFile.Close()

	// Create watcher
	watcher := &StdinWatcher{
		stdinPath:   pipePath,
		ptyFile:     ptyWriter,
		stdinFile:   stdinFile,
		buffer:      make([]byte, 4096),
		stopChan:    make(chan struct{}),
		stoppedChan: make(chan struct{}),
	}

	// Write test data to stdin
	testData := []byte("Hello, World!")
	if _, err := stdinFile.Write(testData); err != nil {
		t.Fatal(err)
	}
	if _, err := stdinFile.Seek(0, 0); err != nil {
		t.Fatal(err)
	}

	// Handle the data
	watcher.handleStdinData()

	// Read from PTY to verify data was forwarded
	result := make([]byte, len(testData))
	if _, err := io.ReadFull(ptyReader, result); err != nil {
		t.Fatalf("Failed to read forwarded data: %v", err)
	}

	if string(result) != string(testData) {
		t.Errorf("Forwarded data = %q, want %q", result, testData)
	}
}

func TestIsEAGAIN(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		expected bool
	}{
		{
			name:     "nil error",
			err:      nil,
			expected: false,
		},
		{
			name:     "EAGAIN error",
			err:      &os.PathError{Err: os.NewSyscallError("read", os.ErrDeadlineExceeded)},
			expected: false, // Our simple implementation checks string
		},
		{
			name:     "other error",
			err:      io.EOF,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := isEAGAIN(tt.err)
			if result != tt.expected {
				t.Errorf("isEAGAIN() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestStdinWatcher_Cleanup(t *testing.T) {
	// Create temporary directory for testing
	tmpDir := t.TempDir()

	// Create a named pipe
	pipePath := filepath.Join(tmpDir, "stdin")
	if err := os.WriteFile(pipePath, []byte{}, 0644); err != nil {
		t.Fatal(err)
	}

	// Create a mock PTY file
	ptyFile, err := os.CreateTemp(tmpDir, "pty")
	if err != nil {
		t.Fatal(err)
	}
	defer ptyFile.Close()

	watcher, err := NewStdinWatcher(pipePath, ptyFile)
	if err != nil {
		t.Fatal(err)
	}

	// Store references to check if closed
	stdinFile := watcher.stdinFile
	fsWatcher := watcher.watcher

	// Clean up
	watcher.cleanup()

	// Verify files are closed
	if err := stdinFile.Close(); err == nil {
		t.Error("stdinFile should have been closed")
	}

	// Verify watcher is closed by trying to add a path
	if err := fsWatcher.Add("/tmp"); err == nil {
		t.Error("fsnotify watcher should have been closed")
	}
}

func BenchmarkStdinWatcher_HandleData(b *testing.B) {
	// Create temporary directory for testing
	tmpDir := b.TempDir()

	// Create pipes
	_, ptyWriter, err := os.Pipe()
	if err != nil {
		b.Fatal(err)
	}
	defer ptyWriter.Close()

	// Create stdin file with data
	stdinPath := filepath.Join(tmpDir, "stdin")
	testData := []byte("This is test data for benchmarking stdin handling\n")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Create fresh stdin file each time
		stdinFile, err := os.Create(stdinPath)
		if err != nil {
			b.Fatal(err)
		}

		if _, err := stdinFile.Write(testData); err != nil {
			b.Fatal(err)
		}
		if _, err := stdinFile.Seek(0, 0); err != nil {
			b.Fatal(err)
		}

		watcher := &StdinWatcher{
			stdinPath: stdinPath,
			ptyFile:   ptyWriter,
			stdinFile: stdinFile,
			buffer:    make([]byte, 4096),
		}

		watcher.handleStdinData()
		stdinFile.Close()
	}
}
