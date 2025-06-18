package client

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// VibeTunnelClient implements the VibeTunnel HTTP API protocol
type VibeTunnelClient struct {
	baseURL    string
	httpClient *http.Client
	authToken  string
}

// SessionConfig represents session creation parameters
type SessionConfig struct {
	Name       string            `json:"name"`
	Command    []string          `json:"command"`
	WorkingDir string            `json:"workingDir"`
	Width      int               `json:"width"`
	Height     int               `json:"height"`
	Term       string            `json:"term"`
	Env        map[string]string `json:"env"`
}

// SessionInfo represents session metadata
type SessionInfo struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	Status   string    `json:"status"`
	Created  time.Time `json:"created"`
	ExitCode *int      `json:"exit_code"`
	Cmdline  string    `json:"cmdline"`
	Width    int       `json:"width"`
	Height   int       `json:"height"`
	Cwd      string    `json:"cwd"`
	Term     string    `json:"term"`
}

// AsciinemaEvent represents terminal output events
type AsciinemaEvent struct {
	Time float64 `json:"time"`
	Type string  `json:"type"`
	Data string  `json:"data"`
}

// StreamEvent represents SSE stream events
type StreamEvent struct {
	Type    string          `json:"type"`
	Event   *AsciinemaEvent `json:"event,omitempty"`
	Message string          `json:"message,omitempty"`
}

// NewClient creates a new VibeTunnel API client
func NewClient(hostname string, port int) *VibeTunnelClient {
	return &VibeTunnelClient{
		baseURL: fmt.Sprintf("http://%s:%d", hostname, port),
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// SetAuth sets authentication token for requests
func (c *VibeTunnelClient) SetAuth(token string) {
	c.authToken = token
}

// CreateSession creates a new terminal session
func (c *VibeTunnelClient) CreateSession(config SessionConfig) (*SessionInfo, error) {
	data, err := json.Marshal(config)
	if err != nil {
		return nil, fmt.Errorf("marshal config: %w", err)
	}

	req, err := http.NewRequest("POST", c.baseURL+"/api/sessions", bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	var session SessionInfo
	if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	return &session, nil
}

// GetSession retrieves session information by ID
func (c *VibeTunnelClient) GetSession(sessionID string) (*SessionInfo, error) {
	req, err := http.NewRequest("GET", c.baseURL+"/api/sessions/"+sessionID, nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	var session SessionInfo
	if err := json.NewDecoder(resp.Body).Decode(&session); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	return &session, nil
}

// ListSessions retrieves all sessions
func (c *VibeTunnelClient) ListSessions() ([]SessionInfo, error) {
	req, err := http.NewRequest("GET", c.baseURL+"/api/sessions", nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	var sessions []SessionInfo
	if err := json.NewDecoder(resp.Body).Decode(&sessions); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	return sessions, nil
}

// SendInput sends input to a session
func (c *VibeTunnelClient) SendInput(sessionID, input string) error {
	data := map[string]string{"input": input}
	jsonData, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("marshal input: %w", err)
	}

	req, err := http.NewRequest("POST", c.baseURL+"/api/sessions/"+sessionID+"/input", bytes.NewReader(jsonData))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	return nil
}

// SSEStream represents an SSE connection for streaming events
type SSEStream struct {
	resp   *http.Response
	Events chan StreamEvent
	Errors chan error
	done   chan struct{}
}

// StreamSession opens an SSE connection to stream session events
func (c *VibeTunnelClient) StreamSession(sessionID string) (*SSEStream, error) {
	req, err := http.NewRequest("GET", c.baseURL+"/api/sessions/"+sessionID+"/stream", nil)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Cache-Control", "no-cache")
	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("do request: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	stream := &SSEStream{
		resp:   resp,
		Events: make(chan StreamEvent, 100),
		Errors: make(chan error, 10),
		done:   make(chan struct{}),
	}

	go stream.readLoop()

	return stream, nil
}

// Close closes the SSE stream
func (s *SSEStream) Close() error {
	close(s.done)
	return s.resp.Body.Close()
}

// readLoop processes SSE events from the stream
func (s *SSEStream) readLoop() {
	defer close(s.Events)
	defer close(s.Errors)

	buf := make([]byte, 4096)
	var buffer strings.Builder

	for {
		select {
		case <-s.done:
			return
		default:
		}

		n, err := s.resp.Body.Read(buf)
		if err != nil {
			if err != io.EOF {
				s.Errors <- fmt.Errorf("read stream: %w", err)
			}
			return
		}

		buffer.Write(buf[:n])
		content := buffer.String()

		// Process complete SSE events
		for {
			eventEnd := strings.Index(content, "\n\n")
			if eventEnd == -1 {
				break
			}

			eventData := content[:eventEnd]
			content = content[eventEnd+2:]

			if strings.HasPrefix(eventData, "data: ") {
				jsonData := strings.TrimPrefix(eventData, "data: ")
				
				var event StreamEvent
				if err := json.Unmarshal([]byte(jsonData), &event); err != nil {
					s.Errors <- fmt.Errorf("unmarshal event: %w", err)
					continue
				}

				select {
				case s.Events <- event:
				case <-s.done:
					return
				}
			}
		}

		buffer.Reset()
		buffer.WriteString(content)
	}
}

// DeleteSession deletes a session
func (c *VibeTunnelClient) DeleteSession(sessionID string) error {
	req, err := http.NewRequest("DELETE", c.baseURL+"/api/sessions/"+sessionID, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	return nil
}

// Ping tests server connectivity
func (c *VibeTunnelClient) Ping() error {
	req, err := http.NewRequest("GET", c.baseURL+"/api/sessions", nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	if c.authToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.authToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("do request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	return nil
}