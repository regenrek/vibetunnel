//go:build !darwin && !linux

package session

import "golang.org/x/sys/unix"

const (
	// Default to Linux constants for other Unix systems
	ioctlGetTermios = unix.TCGETS
	ioctlSetTermios = unix.TCSETS
)
