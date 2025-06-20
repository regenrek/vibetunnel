//go:build linux

package session

import "golang.org/x/sys/unix"

const (
	ioctlGetTermios = unix.TCGETS
	ioctlSetTermios = unix.TCSETS
)

// getControlCharConstant returns the platform-specific control character constant if it exists
func getControlCharConstant(name string) (uint8, bool) {
	// No platform-specific constants for Linux
	return 0, false
}
