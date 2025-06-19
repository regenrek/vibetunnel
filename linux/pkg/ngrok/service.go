package ngrok

import (
	"context"
	"fmt"
	"log"
	"net/url"
	"time"

	"golang.ngrok.com/ngrok"
	"golang.ngrok.com/ngrok/config"
)

// NewService creates a new ngrok service instance
func NewService() *Service {
	ctx, cancel := context.WithCancel(context.Background())
	return &Service{
		ctx:    ctx,
		cancel: cancel,
		info: TunnelInfo{
			Status: StatusDisconnected,
		},
	}
}

// Start initiates a new ngrok tunnel
func (s *Service) Start(authToken string, localPort int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.info.Status == StatusConnected || s.info.Status == StatusConnecting {
		return ErrAlreadyRunning
	}

	s.info.Status = StatusConnecting
	s.info.Error = ""
	s.info.LocalURL = fmt.Sprintf("http://127.0.0.1:%d", localPort)

	// Start tunnel in a goroutine
	go func() {
		if err := s.startTunnel(authToken, localPort); err != nil {
			s.mu.Lock()
			s.info.Status = StatusError
			s.info.Error = err.Error()
			s.mu.Unlock()
			log.Printf("[ERROR] Ngrok tunnel failed: %v", err)
		}
	}()

	return nil
}

// startTunnel creates and maintains the ngrok tunnel
func (s *Service) startTunnel(authToken string, localPort int) error {
	// Create local URL for forwarding
	localURL, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", localPort))
	if err != nil {
		return fmt.Errorf("invalid local port: %w", err)
	}

	// Create forwarder that automatically handles the tunnel and forwarding
	forwarder, err := ngrok.ListenAndForward(s.ctx, localURL, config.HTTPEndpoint(), ngrok.WithAuthtoken(authToken))
	if err != nil {
		return fmt.Errorf("failed to create ngrok tunnel: %w", err)
	}

	s.mu.Lock()
	s.forwarder = forwarder
	s.info.URL = forwarder.URL()
	s.info.Status = StatusConnected
	s.info.ConnectedAt = time.Now()
	s.mu.Unlock()

	log.Printf("[INFO] Ngrok tunnel established: %s -> http://127.0.0.1:%d", forwarder.URL(), localPort)

	// Wait for the forwarder to close
	return forwarder.Wait()
}

// Stop terminates the ngrok tunnel
func (s *Service) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.info.Status == StatusDisconnected {
		return ErrNotConnected
	}

	// Cancel context to stop all operations
	s.cancel()

	// Close forwarder if it exists
	if s.forwarder != nil {
		if err := s.forwarder.Close(); err != nil {
			log.Printf("[WARNING] Error closing ngrok forwarder: %v", err)
		}
		s.forwarder = nil
	}

	// Reset status
	s.info.Status = StatusDisconnected
	s.info.URL = ""
	s.info.Error = ""
	s.info.ConnectedAt = time.Time{}

	// Create new context for potential restart
	s.ctx, s.cancel = context.WithCancel(context.Background())

	log.Printf("[INFO] Ngrok tunnel stopped")
	return nil
}

// GetStatus returns the current tunnel status
func (s *Service) GetStatus() StatusResponse {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return StatusResponse{
		TunnelInfo: s.info,
		IsRunning:  s.info.Status == StatusConnected || s.info.Status == StatusConnecting,
	}
}

// IsRunning returns true if the tunnel is active
func (s *Service) IsRunning() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.info.Status == StatusConnected || s.info.Status == StatusConnecting
}

// GetURL returns the public tunnel URL
func (s *Service) GetURL() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.info.URL
}

// SetConfig updates the ngrok configuration
func (s *Service) SetConfig(config Config) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.config = config
}

// GetConfig returns the current configuration
func (s *Service) GetConfig() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.config
}

// Cleanup performs cleanup when the service is being destroyed
func (s *Service) Cleanup() {
	if err := s.Stop(); err != nil && err != ErrNotConnected {
		log.Printf("[WARNING] Error during ngrok cleanup: %v", err)
	}
}
