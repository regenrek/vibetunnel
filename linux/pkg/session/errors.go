package session

import (
	"fmt"
)

// ErrorCode represents standardized error codes matching Node.js implementation
type ErrorCode string

const (
	// Session-related errors
	ErrSessionNotFound      ErrorCode = "SESSION_NOT_FOUND"
	ErrSessionAlreadyExists ErrorCode = "SESSION_ALREADY_EXISTS"
	ErrSessionStartFailed   ErrorCode = "SESSION_START_FAILED"
	ErrSessionNotRunning    ErrorCode = "SESSION_NOT_RUNNING"

	// Process-related errors
	ErrProcessNotFound        ErrorCode = "PROCESS_NOT_FOUND"
	ErrProcessSignalFailed    ErrorCode = "PROCESS_SIGNAL_FAILED"
	ErrProcessTerminateFailed ErrorCode = "PROCESS_TERMINATE_FAILED"

	// I/O related errors
	ErrStdinNotFound     ErrorCode = "STDIN_NOT_FOUND"
	ErrStdinWriteFailed  ErrorCode = "STDIN_WRITE_FAILED"
	ErrStreamReadFailed  ErrorCode = "STREAM_READ_FAILED"
	ErrStreamWriteFailed ErrorCode = "STREAM_WRITE_FAILED"

	// PTY-related errors
	ErrPTYCreationFailed ErrorCode = "PTY_CREATION_FAILED"
	ErrPTYConfigFailed   ErrorCode = "PTY_CONFIG_FAILED"
	ErrPTYResizeFailed   ErrorCode = "PTY_RESIZE_FAILED"

	// Control-related errors
	ErrControlPathNotFound  ErrorCode = "CONTROL_PATH_NOT_FOUND"
	ErrControlFileCorrupted ErrorCode = "CONTROL_FILE_CORRUPTED"

	// Input-related errors
	ErrUnknownKey   ErrorCode = "UNKNOWN_KEY"
	ErrInvalidInput ErrorCode = "INVALID_INPUT"

	// General errors
	ErrInvalidArgument  ErrorCode = "INVALID_ARGUMENT"
	ErrPermissionDenied ErrorCode = "PERMISSION_DENIED"
	ErrTimeout          ErrorCode = "TIMEOUT"
	ErrInternal         ErrorCode = "INTERNAL_ERROR"
)

// SessionError represents an error with context, matching Node.js PtyError
type SessionError struct {
	Message   string
	Code      ErrorCode
	SessionID string
	Cause     error
}

// Error implements the error interface
func (e *SessionError) Error() string {
	if e.SessionID != "" {
		return fmt.Sprintf("%s (session: %s, code: %s)", e.Message, e.SessionID[:8], e.Code)
	}
	return fmt.Sprintf("%s (code: %s)", e.Message, e.Code)
}

// Unwrap returns the underlying cause
func (e *SessionError) Unwrap() error {
	return e.Cause
}

// NewSessionError creates a new SessionError
func NewSessionError(message string, code ErrorCode, sessionID string) *SessionError {
	return &SessionError{
		Message:   message,
		Code:      code,
		SessionID: sessionID,
	}
}

// NewSessionErrorWithCause creates a new SessionError with an underlying cause
func NewSessionErrorWithCause(message string, code ErrorCode, sessionID string, cause error) *SessionError {
	return &SessionError{
		Message:   message,
		Code:      code,
		SessionID: sessionID,
		Cause:     cause,
	}
}

// WrapError wraps an existing error with session context
func WrapError(err error, code ErrorCode, sessionID string) *SessionError {
	if err == nil {
		return nil
	}

	// If it's already a SessionError, preserve the original but add context
	if se, ok := err.(*SessionError); ok {
		return &SessionError{
			Message:   se.Message,
			Code:      code,
			SessionID: sessionID,
			Cause:     se,
		}
	}

	return &SessionError{
		Message:   err.Error(),
		Code:      code,
		SessionID: sessionID,
		Cause:     err,
	}
}

// IsSessionError checks if an error is a SessionError with a specific code
func IsSessionError(err error, code ErrorCode) bool {
	se, ok := err.(*SessionError)
	return ok && se.Code == code
}

// GetSessionID extracts the session ID from an error if it's a SessionError
func GetSessionID(err error) string {
	if se, ok := err.(*SessionError); ok {
		return se.SessionID
	}
	return ""
}

// Common error constructors for convenience

// ErrSessionNotFoundError creates a session not found error
func ErrSessionNotFoundError(sessionID string) *SessionError {
	return NewSessionError(
		fmt.Sprintf("Session %s not found", sessionID[:8]),
		ErrSessionNotFound,
		sessionID,
	)
}

// ErrProcessSignalError creates a process signal error
func ErrProcessSignalError(sessionID string, signal string, cause error) *SessionError {
	return NewSessionErrorWithCause(
		fmt.Sprintf("Failed to send signal %s to session", signal),
		ErrProcessSignalFailed,
		sessionID,
		cause,
	)
}

// ErrPTYCreationError creates a PTY creation error
func ErrPTYCreationError(sessionID string, cause error) *SessionError {
	return NewSessionErrorWithCause(
		"Failed to create PTY",
		ErrPTYCreationFailed,
		sessionID,
		cause,
	)
}

// ErrStdinWriteError creates a stdin write error
func ErrStdinWriteError(sessionID string, cause error) *SessionError {
	return NewSessionErrorWithCause(
		"Failed to write to stdin",
		ErrStdinWriteFailed,
		sessionID,
		cause,
	)
}
