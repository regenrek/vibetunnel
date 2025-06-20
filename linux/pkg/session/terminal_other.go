//go:build !darwin && !linux

package session

import "golang.org/x/sys/unix"

const (
	// Default to Linux constants for other Unix systems
	ioctlGetTermios = unix.TCGETS
	ioctlSetTermios = unix.TCSETS
)

// getControlCharConstant returns the platform-specific control character constant if it exists
func getControlCharConstant(name string) (uint8, bool) {
	// No platform-specific constants for other systems
	return 0, false
}
