package session

import (
	"errors"
	"testing"
)

func TestSessionError(t *testing.T) {
	tests := []struct {
		name     string
		err      *SessionError
		wantMsg  string
		wantCode ErrorCode
		wantID   string
	}{
		{
			name: "basic error with session ID",
			err: &SessionError{
				Message:   "test error",
				Code:      ErrSessionNotFound,
				SessionID: "12345678-1234-1234-1234-123456789012",
			},
			wantMsg:  "test error (session: 12345678, code: SESSION_NOT_FOUND)",
			wantCode: ErrSessionNotFound,
			wantID:   "12345678-1234-1234-1234-123456789012",
		},
		{
			name: "error without session ID",
			err: &SessionError{
				Message: "test error",
				Code:    ErrInvalidArgument,
			},
			wantMsg:  "test error (code: INVALID_ARGUMENT)",
			wantCode: ErrInvalidArgument,
			wantID:   "",
		},
		{
			name: "error with cause",
			err: &SessionError{
				Message:   "wrapped error",
				Code:      ErrPTYCreationFailed,
				SessionID: "abcdef12-1234-1234-1234-123456789012",
				Cause:     errors.New("underlying error"),
			},
			wantMsg:  "wrapped error (session: abcdef12, code: PTY_CREATION_FAILED)",
			wantCode: ErrPTYCreationFailed,
			wantID:   "abcdef12-1234-1234-1234-123456789012",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.err.Error(); got != tt.wantMsg {
				t.Errorf("Error() = %v, want %v", got, tt.wantMsg)
			}
			if tt.err.Code != tt.wantCode {
				t.Errorf("Code = %v, want %v", tt.err.Code, tt.wantCode)
			}
			if tt.err.SessionID != tt.wantID {
				t.Errorf("SessionID = %v, want %v", tt.err.SessionID, tt.wantID)
			}
			if tt.err.Cause != nil {
				if unwrapped := tt.err.Unwrap(); unwrapped != tt.err.Cause {
					t.Errorf("Unwrap() = %v, want %v", unwrapped, tt.err.Cause)
				}
			}
		})
	}
}

func TestNewSessionError(t *testing.T) {
	sessionID := "test-session-id"
	message := "test message"
	code := ErrSessionNotFound

	err := NewSessionError(message, code, sessionID)

	if err.Message != message {
		t.Errorf("Message = %v, want %v", err.Message, message)
	}
	if err.Code != code {
		t.Errorf("Code = %v, want %v", err.Code, code)
	}
	if err.SessionID != sessionID {
		t.Errorf("SessionID = %v, want %v", err.SessionID, sessionID)
	}
	if err.Cause != nil {
		t.Errorf("Cause = %v, want nil", err.Cause)
	}
}

func TestNewSessionErrorWithCause(t *testing.T) {
	sessionID := "test-session-id"
	message := "test message"
	code := ErrPTYCreationFailed
	cause := errors.New("root cause")

	err := NewSessionErrorWithCause(message, code, sessionID, cause)

	if err.Message != message {
		t.Errorf("Message = %v, want %v", err.Message, message)
	}
	if err.Code != code {
		t.Errorf("Code = %v, want %v", err.Code, code)
	}
	if err.SessionID != sessionID {
		t.Errorf("SessionID = %v, want %v", err.SessionID, sessionID)
	}
	if err.Cause != cause {
		t.Errorf("Cause = %v, want %v", err.Cause, cause)
	}
}

func TestWrapError(t *testing.T) {
	tests := []struct {
		name      string
		err       error
		code      ErrorCode
		sessionID string
		wantNil   bool
		wantType  string
	}{
		{
			name:      "wrap nil error",
			err:       nil,
			code:      ErrInternal,
			sessionID: "test",
			wantNil:   true,
		},
		{
			name:      "wrap regular error",
			err:       errors.New("regular error"),
			code:      ErrStdinWriteFailed,
			sessionID: "12345678",
			wantType:  "regular",
		},
		{
			name: "wrap session error",
			err: &SessionError{
				Message:   "original",
				Code:      ErrSessionNotFound,
				SessionID: "original-id",
			},
			code:      ErrInternal,
			sessionID: "new-id",
			wantType:  "session",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			wrapped := WrapError(tt.err, tt.code, tt.sessionID)

			if tt.wantNil {
				if wrapped != nil {
					t.Errorf("WrapError() = %v, want nil", wrapped)
				}
				return
			}

			if wrapped == nil {
				t.Fatal("WrapError() = nil, want non-nil")
			}

			if wrapped.Code != tt.code {
				t.Errorf("Code = %v, want %v", wrapped.Code, tt.code)
			}
			if wrapped.SessionID != tt.sessionID {
				t.Errorf("SessionID = %v, want %v", wrapped.SessionID, tt.sessionID)
			}

			if tt.wantType == "session" {
				// When wrapping a SessionError, the cause should be the original
				if _, ok := wrapped.Cause.(*SessionError); !ok {
					t.Errorf("Cause type = %T, want *SessionError", wrapped.Cause)
				}
			}
		})
	}
}

func TestIsSessionError(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		code     ErrorCode
		expected bool
	}{
		{
			name: "matching session error",
			err: &SessionError{
				Code: ErrSessionNotFound,
			},
			code:     ErrSessionNotFound,
			expected: true,
		},
		{
			name: "non-matching session error",
			err: &SessionError{
				Code: ErrSessionNotFound,
			},
			code:     ErrPTYCreationFailed,
			expected: false,
		},
		{
			name:     "regular error",
			err:      errors.New("regular"),
			code:     ErrSessionNotFound,
			expected: false,
		},
		{
			name:     "nil error",
			err:      nil,
			code:     ErrSessionNotFound,
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsSessionError(tt.err, tt.code); got != tt.expected {
				t.Errorf("IsSessionError() = %v, want %v", got, tt.expected)
			}
		})
	}
}

func TestGetSessionID(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		expected string
	}{
		{
			name: "session error with ID",
			err: &SessionError{
				SessionID: "test-id-123",
			},
			expected: "test-id-123",
		},
		{
			name: "session error without ID",
			err: &SessionError{
				SessionID: "",
			},
			expected: "",
		},
		{
			name:     "regular error",
			err:      errors.New("regular"),
			expected: "",
		},
		{
			name:     "nil error",
			err:      nil,
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := GetSessionID(tt.err); got != tt.expected {
				t.Errorf("GetSessionID() = %v, want %v", got, tt.expected)
			}
		})
	}
}

func TestErrorConstructors(t *testing.T) {
	sessionID := "12345678-1234-1234-1234-123456789012"

	t.Run("ErrSessionNotFoundError", func(t *testing.T) {
		err := ErrSessionNotFoundError(sessionID)
		if err.Code != ErrSessionNotFound {
			t.Errorf("Code = %v, want %v", err.Code, ErrSessionNotFound)
		}
		if err.SessionID != sessionID {
			t.Errorf("SessionID = %v, want %v", err.SessionID, sessionID)
		}
		expectedMsg := "Session 12345678 not found"
		if err.Message != expectedMsg {
			t.Errorf("Message = %v, want %v", err.Message, expectedMsg)
		}
	})

	t.Run("ErrProcessSignalError", func(t *testing.T) {
		cause := errors.New("signal failed")
		err := ErrProcessSignalError(sessionID, "SIGTERM", cause)
		if err.Code != ErrProcessSignalFailed {
			t.Errorf("Code = %v, want %v", err.Code, ErrProcessSignalFailed)
		}
		if err.Cause != cause {
			t.Errorf("Cause = %v, want %v", err.Cause, cause)
		}
	})

	t.Run("ErrPTYCreationError", func(t *testing.T) {
		cause := errors.New("pty failed")
		err := ErrPTYCreationError(sessionID, cause)
		if err.Code != ErrPTYCreationFailed {
			t.Errorf("Code = %v, want %v", err.Code, ErrPTYCreationFailed)
		}
		if err.Cause != cause {
			t.Errorf("Cause = %v, want %v", err.Cause, cause)
		}
	})

	t.Run("ErrStdinWriteError", func(t *testing.T) {
		cause := errors.New("write failed")
		err := ErrStdinWriteError(sessionID, cause)
		if err.Code != ErrStdinWriteFailed {
			t.Errorf("Code = %v, want %v", err.Code, ErrStdinWriteFailed)
		}
		if err.Cause != cause {
			t.Errorf("Cause = %v, want %v", err.Cause, cause)
		}
	})
}
