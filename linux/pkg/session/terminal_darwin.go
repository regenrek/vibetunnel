//go:build darwin

package session

import "golang.org/x/sys/unix"

const (
	ioctlGetTermios = unix.TIOCGETA
	ioctlSetTermios = unix.TIOCSETA
)

// getControlCharConstant returns the platform-specific control character constant if it exists
func getControlCharConstant(name string) (uint8, bool) {
	// Platform-specific constants for Darwin
	switch name {
	case "VDSUSP":
		// VDSUSP is index 11 on Darwin
		return 11, true
	case "VSTATUS":
		// VSTATUS is index 18 on Darwin  
		return 18, true
	default:
		return 0, false
	}
}
