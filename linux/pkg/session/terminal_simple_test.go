package session

import (
	"os"
	"testing"
)

func TestTerminalMode(t *testing.T) {
	// Test TerminalMode struct
	mode := TerminalMode{
		Raw:         false,
		Echo:        true,
		LineMode:    true,
		FlowControl: true,
	}

	if mode.Raw {
		t.Error("Raw mode should be false by default")
	}
	if !mode.Echo {
		t.Error("Echo should be true")
	}
	if !mode.LineMode {
		t.Error("LineMode should be true")
	}
	if !mode.FlowControl {
		t.Error("FlowControl should be true")
	}
}

func TestIsTerminal(t *testing.T) {
	tests := []struct {
		name     string
		getFd    func() (int, func())
		expected bool
	}{
		{
			name: "stdout (may be terminal)",
			getFd: func() (int, func()) {
				return int(os.Stdout.Fd()), func() {}
			},
			expected: os.Getenv("CI") != "true", // Expect false in CI, true in dev
		},
		{
			name: "regular file",
			getFd: func() (int, func()) {
				f, err := os.CreateTemp("", "test")
				if err != nil {
					t.Fatal(err)
				}
				return int(f.Fd()), func() {
					f.Close()
					os.Remove(f.Name())
				}
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fd, cleanup := tt.getFd()
			defer cleanup()

			result := isTerminal(fd)
			// Skip assertion if we're testing stdout in an unknown environment
			if tt.name == "stdout (may be terminal)" && os.Getenv("CI") == "" {
				t.Logf("isTerminal(stdout) = %v (skipping assertion in non-CI environment)", result)
				return
			}
			if result != tt.expected {
				t.Errorf("isTerminal() = %v, want %v", result, tt.expected)
			}
		})
	}
}