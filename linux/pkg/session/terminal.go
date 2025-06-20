package session

import (
	"fmt"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// TerminalMode represents terminal mode settings
type TerminalMode struct {
	Raw         bool
	Echo        bool
	LineMode    bool
	FlowControl bool
}

// configurePTYTerminal configures the PTY terminal attributes to match node-pty behavior
// This ensures proper terminal behavior with flow control, signal handling, and line editing
func configurePTYTerminal(ptyFile *os.File) error {
	fd := int(ptyFile.Fd())

	// Get current terminal attributes
	termios, err := unix.IoctlGetTermios(fd, ioctlGetTermios)
	if err != nil {
		// Non-fatal: some systems may not support this
		debugLog("[DEBUG] Could not get terminal attributes, using defaults: %v", err)
		return nil
	}

	// Match node-pty's default behavior: keep most settings from the parent terminal
	// but ensure proper signal handling and character processing

	// Ensure proper input processing
	// ICRNL: Map CR to NL on input (important for Enter key)
	termios.Iflag |= unix.ICRNL
	// Clear software flow control by default to match node-pty
	termios.Iflag &^= (unix.IXON | unix.IXOFF | unix.IXANY)

	// Configure output flags
	// OPOST: Enable output processing
	// ONLCR: Map NL to CR-NL on output (important for proper line endings)
	termios.Oflag |= unix.OPOST | unix.ONLCR

	// Configure control flags
	// CS8: 8-bit characters
	// CREAD: Enable receiver
	termios.Cflag |= unix.CS8 | unix.CREAD
	termios.Cflag &^= unix.PARENB // Disable parity

	// Configure local flags
	// ISIG: Enable signal generation (SIGINT on Ctrl+C, etc)
	// ICANON: Enable canonical mode (line editing)
	// IEXTEN: Enable extended functions
	termios.Lflag |= unix.ISIG | unix.ICANON | unix.IEXTEN
	
	// IMPORTANT: Don't enable ECHO for PTY master
	// The terminal emulator (slave) handles echo, not the master
	// Enabling echo on the master causes duplicate output
	termios.Lflag &^= (unix.ECHO | unix.ECHOE | unix.ECHOK | unix.ECHONL)

	// Set control characters to sensible defaults
	termios.Cc[unix.VEOF] = 4     // Ctrl+D
	termios.Cc[unix.VERASE] = 127 // DEL
	termios.Cc[unix.VINTR] = 3    // Ctrl+C
	termios.Cc[unix.VKILL] = 21   // Ctrl+U
	termios.Cc[unix.VMIN] = 1     // Minimum characters for read
	termios.Cc[unix.VQUIT] = 28   // Ctrl+\
	termios.Cc[unix.VSUSP] = 26   // Ctrl+Z
	termios.Cc[unix.VTIME] = 0    // Timeout for read

	// Apply the terminal attributes
	if err := unix.IoctlSetTermios(fd, ioctlSetTermios, termios); err != nil {
		// Non-fatal: log but continue
		debugLog("[DEBUG] Could not set terminal attributes: %v", err)
		return nil
	}

	debugLog("[DEBUG] PTY terminal configured to match node-pty defaults")
	return nil
}

// setPTYSize sets the window size of the PTY
func setPTYSize(ptyFile *os.File, cols, rows uint16) error {
	fd := int(ptyFile.Fd())

	ws := &unix.Winsize{
		Row:    rows,
		Col:    cols,
		Xpixel: 0,
		Ypixel: 0,
	}

	if err := unix.IoctlSetWinsize(fd, unix.TIOCSWINSZ, ws); err != nil {
		return fmt.Errorf("failed to set PTY size: %w", err)
	}

	return nil
}

// getPTYSize gets the current window size of the PTY
func getPTYSize(ptyFile *os.File) (cols, rows uint16, err error) {
	fd := int(ptyFile.Fd())

	ws, err := unix.IoctlGetWinsize(fd, unix.TIOCGWINSZ)
	if err != nil {
		return 0, 0, fmt.Errorf("failed to get PTY size: %w", err)
	}

	return ws.Col, ws.Row, nil
}

// sendSignalToPTY sends a signal to the PTY process group
func sendSignalToPTY(ptyFile *os.File, signal syscall.Signal) error {
	fd := int(ptyFile.Fd())

	// Get the process group ID of the PTY
	pgid, err := unix.IoctlGetInt(fd, unix.TIOCGPGRP)
	if err != nil {
		return fmt.Errorf("failed to get PTY process group: %w", err)
	}

	// Send signal to the process group
	if err := syscall.Kill(-pgid, signal); err != nil {
		return fmt.Errorf("failed to send signal to PTY process group: %w", err)
	}

	return nil
}

// isTerminal checks if a file descriptor is a terminal
func isTerminal(fd int) bool {
	_, err := unix.IoctlGetTermios(fd, ioctlGetTermios)
	return err == nil
}
