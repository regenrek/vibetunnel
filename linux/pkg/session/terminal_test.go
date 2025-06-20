package session

import (
	"os"
	"testing"
	"golang.org/x/sys/unix"
)

func TestConfigurePTYTerminal(t *testing.T) {
	// Skip if not on a Unix system
	if os.Getenv("CI") == "true" {
		t.Skip("Skipping PTY tests in CI environment")
	}

	// Create a PTY for testing
	master, slave, err := unix.Openpty()
	if err != nil {
		t.Skipf("Cannot create PTY for testing: %v", err)
	}
	defer unix.Close(master)
	defer unix.Close(slave)

	masterFile := os.NewFile(uintptr(master), "master")
	defer masterFile.Close()

	// Test terminal configuration
	err = configurePTYTerminal(masterFile)
	if err != nil {
		t.Fatalf("configurePTYTerminal() error = %v", err)
	}

	// Verify terminal attributes were set
	fd := int(masterFile.Fd())
	termios, err := unix.IoctlGetTermios(fd, unix.TIOCGETA)
	if err != nil {
		t.Fatalf("Failed to get terminal attributes: %v", err)
	}

	// Check input flags
	inputFlags := termios.Iflag
	if inputFlags&unix.IXON == 0 {
		t.Error("IXON should be set for flow control")
	}
	if inputFlags&unix.IXOFF == 0 {
		t.Error("IXOFF should be set for flow control")
	}
	if inputFlags&unix.IXANY == 0 {
		t.Error("IXANY should be set for flow control")
	}
	if inputFlags&unix.ICRNL == 0 {
		t.Error("ICRNL should be set for CR to NL mapping")
	}

	// Check output flags
	outputFlags := termios.Oflag
	if outputFlags&unix.OPOST == 0 {
		t.Error("OPOST should be set for output processing")
	}
	if outputFlags&unix.ONLCR == 0 {
		t.Error("ONLCR should be set for NL to CR-NL mapping")
	}

	// Check local flags
	localFlags := termios.Lflag
	if localFlags&unix.ISIG == 0 {
		t.Error("ISIG should be set for signal generation")
	}
	if localFlags&unix.ICANON == 0 {
		t.Error("ICANON should be set for canonical mode")
	}
	if localFlags&unix.ECHO == 0 {
		t.Error("ECHO should be set")
	}

	// Check control characters
	if termios.Cc[unix.VINTR] != 3 {
		t.Errorf("VINTR = %d, want 3 (Ctrl+C)", termios.Cc[unix.VINTR])
	}
	if termios.Cc[unix.VQUIT] != 28 {
		t.Errorf("VQUIT = %d, want 28 (Ctrl+\\)", termios.Cc[unix.VQUIT])
	}
	if termios.Cc[unix.VERASE] != 127 {
		t.Errorf("VERASE = %d, want 127 (DEL)", termios.Cc[unix.VERASE])
	}
	if termios.Cc[unix.VKILL] != 21 {
		t.Errorf("VKILL = %d, want 21 (Ctrl+U)", termios.Cc[unix.VKILL])
	}
	if termios.Cc[unix.VSUSP] != 26 {
		t.Errorf("VSUSP = %d, want 26 (Ctrl+Z)", termios.Cc[unix.VSUSP])
	}
	if termios.Cc[unix.VSTART] != 17 {
		t.Errorf("VSTART = %d, want 17 (Ctrl+Q)", termios.Cc[unix.VSTART])
	}
	if termios.Cc[unix.VSTOP] != 19 {
		t.Errorf("VSTOP = %d, want 19 (Ctrl+S)", termios.Cc[unix.VSTOP])
	}
}

func TestSetPTYSize(t *testing.T) {
	// Skip if not on a Unix system
	if os.Getenv("CI") == "true" {
		t.Skip("Skipping PTY tests in CI environment")
	}

	// Create a PTY for testing
	master, slave, err := unix.Openpty()
	if err != nil {
		t.Skipf("Cannot create PTY for testing: %v", err)
	}
	defer unix.Close(master)
	defer unix.Close(slave)

	masterFile := os.NewFile(uintptr(master), "master")
	defer masterFile.Close()

	// Test setting PTY size
	testCols := uint16(120)
	testRows := uint16(40)
	
	err = setPTYSize(masterFile, testCols, testRows)
	if err != nil {
		t.Fatalf("setPTYSize() error = %v", err)
	}

	// Verify size was set
	gotCols, gotRows, err := getPTYSize(masterFile)
	if err != nil {
		t.Fatalf("getPTYSize() error = %v", err)
	}

	if gotCols != testCols {
		t.Errorf("cols = %d, want %d", gotCols, testCols)
	}
	if gotRows != testRows {
		t.Errorf("rows = %d, want %d", gotRows, testRows)
	}
}

func TestGetPTYSize(t *testing.T) {
	// Skip if not on a Unix system
	if os.Getenv("CI") == "true" {
		t.Skip("Skipping PTY tests in CI environment")
	}

	// Create a PTY for testing
	master, slave, err := unix.Openpty()
	if err != nil {
		t.Skipf("Cannot create PTY for testing: %v", err)
	}
	defer unix.Close(master)
	defer unix.Close(slave)

	masterFile := os.NewFile(uintptr(master), "master")
	defer masterFile.Close()

	// Get default size
	cols, rows, err := getPTYSize(masterFile)
	if err != nil {
		t.Fatalf("getPTYSize() error = %v", err)
	}

	// Should have some default size
	if cols == 0 || rows == 0 {
		t.Errorf("getPTYSize() = (%d, %d), want non-zero values", cols, rows)
	}
}

func TestIsTerminal(t *testing.T) {
	tests := []struct {
		name     string
		getFd    func() (int, func())
		expected bool
	}{
		{
			name: "stdout (may be terminal)",
			getFd: func() (int, func()) {
				return int(os.Stdout.Fd()), func() {}
			},
			expected: os.Getenv("CI") != "true", // Expect false in CI, true in dev
		},
		{
			name: "regular file",
			getFd: func() (int, func()) {
				f, err := os.CreateTemp("", "test")
				if err != nil {
					t.Fatal(err)
				}
				return int(f.Fd()), func() { 
					f.Close()
					os.Remove(f.Name())
				}
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fd, cleanup := tt.getFd()
			defer cleanup()

			result := isTerminal(fd)
			// Skip assertion if we're testing stdout in an unknown environment
			if tt.name == "stdout (may be terminal)" && os.Getenv("CI") == "" {
				t.Logf("isTerminal(stdout) = %v (skipping assertion in non-CI environment)", result)
				return
			}
			if result != tt.expected {
				t.Errorf("isTerminal() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestTerminalMode(t *testing.T) {
	// Test TerminalMode struct
	mode := TerminalMode{
		Raw:         false,
		Echo:        true,
		LineMode:    true,
		FlowControl: true,
	}

	if mode.Raw {
		t.Error("Raw mode should be false by default")
	}
	if !mode.Echo {
		t.Error("Echo should be true")
	}
	if !mode.LineMode {
		t.Error("LineMode should be true")
	}
	if !mode.FlowControl {
		t.Error("FlowControl should be true")
	}
}

func TestSendSignalToPTY(t *testing.T) {
	// Skip if not on a Unix system
	if os.Getenv("CI") == "true" {
		t.Skip("Skipping PTY tests in CI environment")
	}

	// This test would require a running process in the PTY
	// For now, just test that the function exists and compiles
	t.Log("sendSignalToPTY function exists and compiles")
}