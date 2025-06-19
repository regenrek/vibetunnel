package session

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
)

// GenerateID generates a new unique session ID
func GenerateID() string {
	return uuid.New().String()
}

type Status string

const (
	StatusStarting Status = "starting"
	StatusRunning  Status = "running"
	StatusExited   Status = "exited"
)

type Config struct {
	Name    string
	Cmdline []string
	Cwd     string
	Env     []string
	Width   int
	Height  int
}

type Info struct {
	ID        string            `json:"id"`
	Name      string            `json:"name"`
	Cmdline   string            `json:"cmdline"`
	Cwd       string            `json:"cwd"`
	Pid       int               `json:"pid,omitempty"`
	Status    string            `json:"status"`
	ExitCode  *int              `json:"exit_code,omitempty"`
	StartedAt time.Time         `json:"started_at"`
	Term      string            `json:"term"`
	Width     int               `json:"width"`
	Height    int               `json:"height"`
	Env       map[string]string `json:"env,omitempty"`
	Args      []string          `json:"-"` // Internal use only
}

type Session struct {
	ID          string
	controlPath string
	info        *Info
	pty         *PTY
	stdinPipe   *os.File
	stdinMutex  sync.Mutex
	mu          sync.RWMutex
}

func newSession(controlPath string, config Config) (*Session, error) {
	id := uuid.New().String()
	sessionPath := filepath.Join(controlPath, id)

	log.Printf("[DEBUG] Creating new session %s with config: Name=%s, Cmdline=%v, Cwd=%s",
		id[:8], config.Name, config.Cmdline, config.Cwd)

	if err := os.MkdirAll(sessionPath, 0755); err != nil {
		return nil, fmt.Errorf("failed to create session directory: %w", err)
	}

	if config.Name == "" {
		config.Name = id[:8]
	}

	// Set default command if empty
	if len(config.Cmdline) == 0 {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/bash"
		}
		config.Cmdline = []string{shell}
		log.Printf("[DEBUG] Session %s: Set default command to %v", id[:8], config.Cmdline)
	}

	// Set default working directory if empty
	if config.Cwd == "" {
		cwd, err := os.Getwd()
		if err != nil {
			config.Cwd = os.Getenv("HOME")
			if config.Cwd == "" {
				config.Cwd = "/"
			}
		} else {
			config.Cwd = cwd
		}
		log.Printf("[DEBUG] Session %s: Set default working directory to %s", id[:8], config.Cwd)
	}

	term := os.Getenv("TERM")
	if term == "" {
		term = "xterm-256color"
	}

	// Set default terminal dimensions if not provided
	width := config.Width
	if width <= 0 {
		width = 120 // Better default for modern terminals
	}
	height := config.Height
	if height <= 0 {
		height = 30 // Better default for modern terminals
	}

	info := &Info{
		ID:        id,
		Name:      config.Name,
		Cmdline:   strings.Join(config.Cmdline, " "),
		Cwd:       config.Cwd,
		Status:    string(StatusStarting),
		StartedAt: time.Now(),
		Term:      term,
		Width:     width,
		Height:    height,
		Args:      config.Cmdline,
	}

	if err := info.Save(sessionPath); err != nil {
		os.RemoveAll(sessionPath)
		return nil, fmt.Errorf("failed to save session info: %w", err)
	}

	return &Session{
		ID:          id,
		controlPath: controlPath,
		info:        info,
	}, nil
}

func loadSession(controlPath, id string) (*Session, error) {
	sessionPath := filepath.Join(controlPath, id)
	info, err := LoadInfo(sessionPath)
	if err != nil {
		return nil, err
	}

	session := &Session{
		ID:          id,
		controlPath: controlPath,
		info:        info,
	}

	// If session is running, we need to reconnect to the PTY for operations like resize
	// For now, we'll handle this by checking if we need PTY access in individual methods

	return session, nil
}

func (s *Session) Path() string {
	return filepath.Join(s.controlPath, s.ID)
}

func (s *Session) StreamOutPath() string {
	return filepath.Join(s.Path(), "stream-out")
}

func (s *Session) StdinPath() string {
	return filepath.Join(s.Path(), "stdin")
}

func (s *Session) NotificationPath() string {
	return filepath.Join(s.Path(), "notification-stream")
}

func (s *Session) Start() error {
	pty, err := NewPTY(s)
	if err != nil {
		return fmt.Errorf("failed to create PTY: %w", err)
	}

	s.pty = pty
	s.info.Status = string(StatusRunning)
	s.info.Pid = pty.Pid()

	if err := s.info.Save(s.Path()); err != nil {
		pty.Close()
		return fmt.Errorf("failed to update session info: %w", err)
	}

	go func() {
		if err := s.pty.Run(); err != nil {
			log.Printf("[DEBUG] Session %s: PTY.Run() exited with error: %v", s.ID[:8], err)
		} else {
			log.Printf("[DEBUG] Session %s: PTY.Run() exited normally", s.ID[:8])
		}
	}()

	// Start control listener
	s.startControlListener()

	// Process status will be checked on first access - no artificial delay needed
	log.Printf("[DEBUG] Session %s: Started successfully", s.ID[:8])

	return nil
}

func (s *Session) Attach() error {
	if s.pty == nil {
		return fmt.Errorf("session not started")
	}
	return s.pty.Attach()
}

func (s *Session) SendKey(key string) error {
	return s.sendInput([]byte(key))
}

func (s *Session) SendText(text string) error {
	return s.sendInput([]byte(text))
}

func (s *Session) sendInput(data []byte) error {
	s.stdinMutex.Lock()
	defer s.stdinMutex.Unlock()

	// Open pipe if not already open
	if s.stdinPipe == nil {
		stdinPath := s.StdinPath()
		pipe, err := os.OpenFile(stdinPath, os.O_WRONLY, 0)
		if err != nil {
			return fmt.Errorf("failed to open stdin pipe: %w", err)
		}
		s.stdinPipe = pipe
	}

	_, err := s.stdinPipe.Write(data)
	if err != nil {
		// If write fails, close and reset the pipe for next attempt
		s.stdinPipe.Close()
		s.stdinPipe = nil
		return fmt.Errorf("failed to write to stdin pipe: %w", err)
	}
	return nil
}

func (s *Session) Signal(sig string) error {
	if s.info.Pid == 0 {
		return fmt.Errorf("no process to signal")
	}

	proc, err := os.FindProcess(s.info.Pid)
	if err != nil {
		return err
	}

	switch sig {
	case "SIGTERM":
		return proc.Signal(os.Interrupt)
	case "SIGKILL":
		return proc.Kill()
	default:
		return fmt.Errorf("unsupported signal: %s", sig)
	}
}

func (s *Session) Stop() error {
	return s.Signal("SIGTERM")
}

func (s *Session) Kill() error {
	err := s.Signal("SIGKILL")
	s.cleanup()
	return err
}

func (s *Session) cleanup() {
	s.stdinMutex.Lock()
	defer s.stdinMutex.Unlock()

	if s.stdinPipe != nil {
		s.stdinPipe.Close()
		s.stdinPipe = nil
	}
}

func (s *Session) Resize(width, height int) error {
	if s.pty == nil {
		return fmt.Errorf("session not started")
	}

	// Check if session is still alive
	if s.info.Status == string(StatusExited) {
		return fmt.Errorf("cannot resize exited session")
	}

	// Validate dimensions
	if width <= 0 || height <= 0 {
		return fmt.Errorf("invalid dimensions: width=%d, height=%d", width, height)
	}

	// Update session info
	s.info.Width = width
	s.info.Height = height

	// Save updated session info
	if err := s.info.Save(s.Path()); err != nil {
		log.Printf("[ERROR] Failed to save session info after resize: %v", err)
	}

	// Resize the PTY
	return s.pty.Resize(width, height)
}

func (s *Session) IsAlive() bool {
	if s.info.Pid == 0 {
		return false
	}

	proc, err := os.FindProcess(s.info.Pid)
	if err != nil {
		return false
	}

	err = proc.Signal(syscall.Signal(0))
	return err == nil
}

func (s *Session) UpdateStatus() error {
	if s.info.Status == string(StatusExited) {
		return nil
	}

	if !s.IsAlive() {
		s.info.Status = string(StatusExited)
		exitCode := 0
		s.info.ExitCode = &exitCode
		return s.info.Save(s.Path())
	}

	return nil
}

func (i *Info) Save(sessionPath string) error {
	data, err := json.MarshalIndent(i, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(filepath.Join(sessionPath, "session.json"), data, 0644)
}

func LoadInfo(sessionPath string) (*Info, error) {
	data, err := os.ReadFile(filepath.Join(sessionPath, "session.json"))
	if err != nil {
		return nil, err
	}

	var info Info
	if err := json.Unmarshal(data, &info); err != nil {
		return nil, err
	}

	return &info, nil
}
