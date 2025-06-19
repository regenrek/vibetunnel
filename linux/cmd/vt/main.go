package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

const Version = "1.0.0"

type Config struct {
	Server string `json:"server,omitempty"`
}

func main() {
	// Debug incoming args
	if os.Getenv("VT_DEBUG") != "" {
		fmt.Fprintf(os.Stderr, "VT Debug: args = %v\n", os.Args)
	}

	// Handle version flag only if it's the only argument
	if len(os.Args) == 2 && (os.Args[1] == "--version" || os.Args[1] == "-v") {
		fmt.Printf("vt version %s\n", Version)
		os.Exit(0)
	}

	// Get preferred server
	server := getPreferredServer()

	// Forward to appropriate server
	var err error
	switch server {
	case "rust":
		err = forwardToRustServer(os.Args[1:])
	case "go":
		err = forwardToGoServer(os.Args[1:])
	default:
		err = forwardToGoServer(os.Args[1:])
	}

	if err != nil {
		// If the command exited with a specific code, preserve it
		if exitErr, ok := err.(*exec.ExitError); ok {
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				os.Exit(status.ExitStatus())
			}
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "vt: %v\n", err)
		os.Exit(1)
	}
}

func getPreferredServer() string {
	// Check environment variable first
	if server := os.Getenv("VT_SERVER"); server != "" {
		if server == "rust" || server == "go" {
			return server
		}
	}

	// Read from config file
	configPath := filepath.Join(os.Getenv("HOME"), ".vibetunnel", "config.json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return "go" // default
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return "go" // default on parse error
	}

	if config.Server == "rust" || config.Server == "go" {
		return config.Server
	}
	return "go" // default for invalid values
}

func forwardToGoServer(args []string) error {
	// Find vibetunnel binary
	vibetunnelPath := findVibetunnelBinary()
	if vibetunnelPath == "" {
		return fmt.Errorf("vibetunnel binary not found")
	}

	// Check if this is a special VT command
	var finalArgs []string
	if len(args) > 0 && isVTSpecialCommand(args[0]) {
		// Translate special VT commands
		finalArgs = translateVTToGoArgs(args)
	} else {
		// For regular commands, just prepend -- to tell vibetunnel to stop parsing
		finalArgs = append([]string{"--"}, args...)
	}

	// Debug: print what we're executing
	if os.Getenv("VT_DEBUG") != "" {
		fmt.Fprintf(os.Stderr, "VT Debug: executing %s with args: %v\n", vibetunnelPath, finalArgs)
	}

	// Create command
	cmd := exec.Command(vibetunnelPath, finalArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// Run and return
	return cmd.Run()
}

func isVTSpecialCommand(arg string) bool {
	switch arg {
	case "--claude", "--claude-yolo", "--shell", "-i",
		"--no-shell-wrap", "-S", "--show-session-info", "--show-session-id":
		return true
	}
	return false
}

func forwardToRustServer(args []string) error {
	// Find tty-fwd binary
	ttyFwdPath := findTtyFwdBinary()
	if ttyFwdPath == "" {
		return fmt.Errorf("tty-fwd binary not found")
	}

	// Create command with original args (tty-fwd already understands vt args)
	cmd := exec.Command(ttyFwdPath, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// Run and return
	return cmd.Run()
}

func translateVTToGoArgs(args []string) []string {
	if len(args) == 0 {
		return args
	}

	// Check for special vt-only flags
	switch args[0] {
	case "--claude":
		// Find Claude and run it with any additional arguments
		claudePath := findClaude()
		if claudePath != "" {
			// Pass all remaining args to claude
			result := []string{"--", claudePath}
			if len(args) > 1 {
				result = append(result, args[1:]...)
			}
			return result
		}
		// Fallback
		result := []string{"--", "claude"}
		if len(args) > 1 {
			result = append(result, args[1:]...)
		}
		return result

	case "--claude-yolo":
		// Find Claude and run with permissions skip
		claudePath := findClaude()
		if claudePath != "" {
			return []string{"--", claudePath, "--dangerously-skip-permissions"}
		}
		return []string{"--", "claude", "--dangerously-skip-permissions"}

	case "--shell", "-i":
		// Launch interactive shell
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/bash"
		}
		return []string{"--", shell, "-i"}

	case "--no-shell-wrap", "-S":
		// Direct execution without shell - skip the flag and pass rest
		if len(args) > 1 {
			return append([]string{"--"}, args[1:]...)
		}
		return []string{}

	case "--show-session-info":
		return []string{"--list-sessions"}

	case "--show-session-id":
		// This needs special handling - just pass through for now
		return args

	default:
		// This shouldn't happen since we check isVTSpecialCommand first
		return args
	}
}

func findVibetunnelBinary() string {
	// Check common locations
	paths := []string{
		// App bundle location
		"/Applications/VibeTunnel.app/Contents/Resources/vibetunnel",
		// Development locations
		"./vibetunnel",
		"../vibetunnel",
		"../../linux/vibetunnel",
		// Installed location
		"/usr/local/bin/vibetunnel",
	}

	for _, path := range paths {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}

	// Try to find in PATH
	if path, err := exec.LookPath("vibetunnel"); err == nil {
		return path
	}

	return ""
}

func findTtyFwdBinary() string {
	// Check common locations
	paths := []string{
		// App bundle location
		"/Applications/VibeTunnel.app/Contents/Resources/tty-fwd",
		// Development locations
		"./tty-fwd",
		"../tty-fwd",
		"../../tty-fwd/target/release/tty-fwd",
		// Installed location
		"/usr/local/bin/tty-fwd",
	}

	for _, path := range paths {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}

	// Try to find in PATH
	if path, err := exec.LookPath("tty-fwd"); err == nil {
		return path
	}

	return ""
}

func findClaude() string {
	// Check common Claude installation paths
	claudePaths := []string{
		filepath.Join(os.Getenv("HOME"), ".claude", "local", "claude"),
		"/opt/homebrew/bin/claude",
		"/usr/local/bin/claude",
		"/usr/bin/claude",
	}

	for _, path := range claudePaths {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}

	// Try PATH
	if path, err := exec.LookPath("claude"); err == nil {
		return path
	}

	return ""
}
