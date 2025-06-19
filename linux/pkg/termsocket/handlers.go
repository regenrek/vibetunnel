package termsocket

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
)

// TerminalSpawner handles spawning terminals for different terminal applications
type TerminalSpawner struct {
	handlers map[string]func(*SpawnRequest) error
}

// NewTerminalSpawner creates a new terminal spawner with default handlers
func NewTerminalSpawner() *TerminalSpawner {
	ts := &TerminalSpawner{
		handlers: make(map[string]func(*SpawnRequest) error),
	}

	// Register default handlers
	ts.RegisterHandler("Terminal.app", ts.spawnTerminalApp)
	ts.RegisterHandler("terminal", ts.spawnTerminalApp)
	ts.RegisterHandler("iTerm.app", ts.spawnITerm)
	ts.RegisterHandler("iterm", ts.spawnITerm)
	ts.RegisterHandler("iTerm2.app", ts.spawnITerm)
	ts.RegisterHandler("iterm2", ts.spawnITerm)
	ts.RegisterHandler("ghostty", ts.spawnGhostty)
	ts.RegisterHandler("", ts.spawnDefault) // Default handler

	return ts
}

// RegisterHandler registers a custom terminal handler
func (ts *TerminalSpawner) RegisterHandler(terminal string, handler func(*SpawnRequest) error) {
	ts.handlers[terminal] = handler
}

// Spawn spawns a terminal based on the request
func (ts *TerminalSpawner) Spawn(req *SpawnRequest) error {
	handler, ok := ts.handlers[req.Terminal]
	if !ok {
		handler = ts.handlers[""] // Use default
	}

	if handler == nil {
		return fmt.Errorf("no handler for terminal type: %s", req.Terminal)
	}

	return handler(req)
}

// spawnTerminalApp spawns a session in macOS Terminal.app
func (ts *TerminalSpawner) spawnTerminalApp(req *SpawnRequest) error {
	script := fmt.Sprintf(`
tell application "Terminal"
	activate
	do script "cd %s && %s && exit"
end tell
`, escapeAppleScript(req.WorkingDir), escapeAppleScript(req.Command))

	cmd := exec.Command("osascript", "-e", script)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to spawn Terminal.app: %w", err)
	}

	log.Printf("[INFO] Spawned session in Terminal.app: %s", req.SessionID)
	return nil
}

// spawnITerm spawns a session in iTerm2
func (ts *TerminalSpawner) spawnITerm(req *SpawnRequest) error {
	script := fmt.Sprintf(`
tell application "iTerm"
	activate
	create window with default profile
	tell current session of current window
		write text "cd %s && %s && exit"
	end tell
end tell
`, escapeAppleScript(req.WorkingDir), escapeAppleScript(req.Command))

	cmd := exec.Command("osascript", "-e", script)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to spawn iTerm: %w", err)
	}

	log.Printf("[INFO] Spawned session in iTerm: %s", req.SessionID)
	return nil
}

// spawnGhostty spawns a session in Ghostty
func (ts *TerminalSpawner) spawnGhostty(req *SpawnRequest) error {
	// Check if ghostty is available
	ghosttyPath, err := exec.LookPath("ghostty")
	if err != nil {
		return fmt.Errorf("ghostty not found in PATH: %w", err)
	}

	// Build command arguments
	// Add && exit to ensure window closes when shell exits
	commandWithExit := req.Command + " && exit"
	args := []string{
		"--working-directory", req.WorkingDir,
		"-e", "sh", "-c", commandWithExit,
	}

	cmd := exec.Command(ghosttyPath, args...)
	cmd.Dir = req.WorkingDir
	cmd.Env = os.Environ()

	// Start detached
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to spawn ghostty: %w", err)
	}

	// Don't wait for it
	go cmd.Wait()

	log.Printf("[INFO] Spawned session in ghostty: %s", req.SessionID)
	return nil
}

// spawnDefault tries to spawn in the default terminal
func (ts *TerminalSpawner) spawnDefault(req *SpawnRequest) error {
	// Try Terminal.app first on macOS
	if err := ts.spawnTerminalApp(req); err == nil {
		return nil
	}

	// Try ghostty if available
	if _, err := exec.LookPath("ghostty"); err == nil {
		return ts.spawnGhostty(req)
	}

	// Try iTerm
	if err := ts.spawnITerm(req); err == nil {
		return nil
	}

	return fmt.Errorf("no suitable terminal found")
}

// escapeAppleScript escapes a string for use in AppleScript
func escapeAppleScript(s string) string {
	// Escape backslashes first
	s = strings.ReplaceAll(s, "\\", "\\\\")
	// Then escape quotes
	s = strings.ReplaceAll(s, "\"", "\\\"")
	return s
}
