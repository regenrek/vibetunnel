package ngrok

import (
	"context"
	"sync"
	"time"

	"golang.ngrok.com/ngrok"
)

// Status represents the current state of ngrok tunnel
type Status string

const (
	StatusDisconnected Status = "disconnected"
	StatusConnecting   Status = "connecting"
	StatusConnected    Status = "connected"
	StatusError        Status = "error"
)

// TunnelInfo contains information about the active tunnel
type TunnelInfo struct {
	URL           string    `json:"url"`
	Status        Status    `json:"status"`
	ConnectedAt   time.Time `json:"connected_at,omitempty"`
	Error         string    `json:"error,omitempty"`
	LocalURL      string    `json:"local_url"`
	TunnelVersion string    `json:"tunnel_version,omitempty"`
}

// Config holds ngrok configuration
type Config struct {
	AuthToken string `json:"auth_token"`
	Enabled   bool   `json:"enabled"`
}

// Service manages ngrok tunnel lifecycle
type Service struct {
	mu        sync.RWMutex
	forwarder ngrok.Forwarder
	info      TunnelInfo
	config    Config
	ctx       context.Context
	cancel    context.CancelFunc
}

// StartRequest represents the request to start ngrok tunnel
type StartRequest struct {
	AuthToken string `json:"auth_token,omitempty"`
}

// StatusResponse represents the response for tunnel status
type StatusResponse struct {
	TunnelInfo
	IsRunning bool `json:"is_running"`
}

// NgrokError represents ngrok-specific errors
type NgrokError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details string `json:"details,omitempty"`
}

func (e NgrokError) Error() string {
	if e.Details != "" {
		return e.Message + ": " + e.Details
	}
	return e.Message
}

// Common ngrok errors
var (
	ErrNotConnected     = NgrokError{Code: "not_connected", Message: "Ngrok tunnel is not connected"}
	ErrAlreadyRunning   = NgrokError{Code: "already_running", Message: "Ngrok tunnel is already running"}
	ErrInvalidAuthToken = NgrokError{Code: "invalid_auth_token", Message: "Invalid ngrok auth token"}
	ErrTunnelFailed     = NgrokError{Code: "tunnel_failed", Message: "Failed to establish tunnel"}
)
