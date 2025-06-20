package session

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

type Manager struct {
	controlPath     string
	runningSessions map[string]*Session
	mutex           sync.RWMutex
}

func NewManager(controlPath string) *Manager {
	return &Manager{
		controlPath:     controlPath,
		runningSessions: make(map[string]*Session),
	}
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
			continue
		}

		// Return cached status for faster response - background updates will keep it current
		sessions = append(sessions, session.info)
	}

	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].StartedAt.After(sessions[j].StartedAt)
	})

	return sessions, nil
}

func (m *Manager) CleanupExitedSessions() error {
	sessions, err := m.ListSessions()
	if err != nil {
		return err
	}

	var errs []error
	for _, info := range sessions {
		if info.Status == string(StatusExited) {
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

func (m *Manager) RemoveSession(id string) error {
	// Remove from running sessions registry
	m.mutex.Lock()
	delete(m.runningSessions, id)
	m.mutex.Unlock()

	sessionPath := filepath.Join(m.controlPath, id)
	return os.RemoveAll(sessionPath)
}
