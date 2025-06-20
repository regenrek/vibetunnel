package session

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Manager struct {
	controlPath     string
	runningSessions map[string]*Session
	mutex           sync.RWMutex
	stopChan        chan struct{}
	cleanupInterval time.Duration
}

func NewManager(controlPath string) *Manager {
	m := &Manager{
		controlPath:     controlPath,
		runningSessions: make(map[string]*Session),
		stopChan:        make(chan struct{}),
		cleanupInterval: 30 * time.Second, // Clean up every 30 seconds
	}
	
	// Start background cleanup goroutine
	// Disabled automatic cleanup to match Rust behavior
	// go m.backgroundCleanup()
	
	return m
}

func (m *Manager) CreateSession(config Config) (*Session, error) {
	if err := os.MkdirAll(m.controlPath, 0755); err != nil {
		return nil, fmt.Errorf("failed to create control directory: %w", err)
	}

	session, err := newSession(m.controlPath, config)
	if err != nil {
		return nil, err
	}

	if err := session.Start(); err != nil {
		os.RemoveAll(session.Path())
		return nil, err
	}

	// Add to running sessions registry
	m.mutex.Lock()
	m.runningSessions[session.ID] = session
	m.mutex.Unlock()

	return session, nil
}

func (m *Manager) CreateSessionWithID(id string, config Config) (*Session, error) {
	if err := os.MkdirAll(m.controlPath, 0755); err != nil {
		return nil, fmt.Errorf("failed to create control directory: %w", err)
	}

	session, err := newSessionWithID(m.controlPath, id, config)
	if err != nil {
		return nil, err
	}

	if err := session.Start(); err != nil {
		os.RemoveAll(session.Path())
		return nil, err
	}

	// Add to running sessions registry
	m.mutex.Lock()
	m.runningSessions[session.ID] = session
	m.mutex.Unlock()

	return session, nil
}

func (m *Manager) GetSession(id string) (*Session, error) {
	// First check if we have this session in our running sessions registry
	m.mutex.RLock()
	if session, exists := m.runningSessions[id]; exists {
		m.mutex.RUnlock()
		return session, nil
	}
	m.mutex.RUnlock()

	// Fall back to loading from disk (for sessions that might have been started before this manager instance)
	return loadSession(m.controlPath, id)
}

func (m *Manager) FindSession(nameOrID string) (*Session, error) {
	sessions, err := m.ListSessions()
	if err != nil {
		return nil, err
	}

	for _, s := range sessions {
		if s.ID == nameOrID || s.Name == nameOrID || strings.HasPrefix(s.ID, nameOrID) {
			return m.GetSession(s.ID)
		}
	}

	return nil, fmt.Errorf("session not found: %s", nameOrID)
}

func (m *Manager) ListSessions() ([]*Info, error) {
	entries, err := os.ReadDir(m.controlPath)
	if err != nil {
		if os.IsNotExist(err) {
			return []*Info{}, nil
		}
		return nil, err
	}

	sessions := make([]*Info, 0)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		session, err := loadSession(m.controlPath, entry.Name())
		if err != nil {
			// Log the error when we can't load a session
			if os.Getenv("VIBETUNNEL_DEBUG") != "" {
				log.Printf("[DEBUG] Failed to load session %s: %v", entry.Name(), err)
			}
			continue
		}

		// Update status on-demand like Rust implementation
		session.UpdateStatus()
		
		sessions = append(sessions, session.info)
	}

	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].StartedAt.After(sessions[j].StartedAt)
	})

	return sessions, nil
}

// CleanupExitedSessions now only updates session status to match Rust behavior
// Use RemoveExitedSessions for actual cleanup
func (m *Manager) CleanupExitedSessions() error {
	// This method now just updates statuses to match Rust implementation
	return m.UpdateAllSessionStatuses()
}

// RemoveExitedSessions actually removes dead sessions from disk (manual cleanup)
func (m *Manager) RemoveExitedSessions() error {
	sessions, err := m.ListSessions()
	if err != nil {
		return err
	}

	var errs []error
	for _, info := range sessions {
		// Check if the process is actually alive, not just the stored status
		shouldRemove := false
		
		if info.Pid == 0 {
			// No PID recorded, consider it exited
			shouldRemove = true
		} else {
			// First check if it's a zombie process
			statPath := fmt.Sprintf("/proc/%d/stat", info.Pid)
			if data, err := os.ReadFile(statPath); err == nil {
				statStr := string(data)
				if lastParen := strings.LastIndex(statStr, ")"); lastParen != -1 {
					fields := strings.Fields(statStr[lastParen+1:])
					if len(fields) > 0 && fields[0] == "Z" {
						// It's a zombie, should remove
						shouldRemove = true
						
						// Try to reap the zombie
						var status syscall.WaitStatus
						syscall.Wait4(info.Pid, &status, syscall.WNOHANG, nil)
					}
				}
			} else {
				// Can't read stat, process doesn't exist
				shouldRemove = true
			}
			
			// If not already marked for removal, check if process is alive
			if !shouldRemove {
				proc, err := os.FindProcess(info.Pid)
				if err != nil {
					shouldRemove = true
				} else {
					// Signal 0 just checks if process exists without actually sending a signal
					err = proc.Signal(syscall.Signal(0))
					if err != nil {
						// Process doesn't exist
						shouldRemove = true
					}
				}
			}
		}
		
		if shouldRemove {
			sessionPath := filepath.Join(m.controlPath, info.ID)
			if err := os.RemoveAll(sessionPath); err != nil {
				errs = append(errs, fmt.Errorf("failed to remove %s: %w", info.ID, err))
			} else {
				fmt.Printf("Cleaned up session: %s\n", info.ID)
			}
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("cleanup errors: %v", errs)
	}

	return nil
}

// backgroundCleanup runs periodic cleanup of dead sessions
func (m *Manager) backgroundCleanup() {
	ticker := time.NewTicker(m.cleanupInterval)
	defer ticker.Stop()
	
	for {
		select {
		case <-ticker.C:
			// Update session statuses and clean up dead ones
			if err := m.UpdateAllSessionStatuses(); err != nil {
				fmt.Printf("Background cleanup error: %v\n", err)
			}
			if err := m.CleanupExitedSessions(); err != nil {
				fmt.Printf("Background cleanup error: %v\n", err)
			}
		case <-m.stopChan:
			return
		}
	}
}

// UpdateAllSessionStatuses updates the status of all sessions
func (m *Manager) UpdateAllSessionStatuses() error {
	sessions, err := m.ListSessions()
	if err != nil {
		return err
	}
	
	for _, info := range sessions {
		if sess, err := m.GetSession(info.ID); err == nil {
			sess.UpdateStatus()
		}
	}
	
	return nil
}

// Stop stops the background cleanup goroutine
func (m *Manager) Stop() {
	close(m.stopChan)
}

func (m *Manager) RemoveSession(id string) error {
	// Remove from running sessions registry
	m.mutex.Lock()
	delete(m.runningSessions, id)
	m.mutex.Unlock()

	sessionPath := filepath.Join(m.controlPath, id)
	return os.RemoveAll(sessionPath)
}
