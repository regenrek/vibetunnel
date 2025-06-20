package terminal

import (
	"testing"
)

func TestTerminalBuffer(t *testing.T) {
	// Create a 80x24 terminal buffer
	buffer := NewTerminalBuffer(80, 24)

	// Test writing simple text
	text := "Hello, World!"
	n, err := buffer.Write([]byte(text))
	if err != nil {
		t.Fatalf("Failed to write to buffer: %v", err)
	}
	if n != len(text) {
		t.Errorf("Expected to write %d bytes, wrote %d", len(text), n)
	}

	// Get snapshot
	snapshot := buffer.GetSnapshot()
	if snapshot.Cols != 80 || snapshot.Rows != 24 {
		t.Errorf("Unexpected dimensions: %dx%d", snapshot.Cols, snapshot.Rows)
	}

	// Check that text was written
	firstLine := snapshot.Cells[0]
	for i, ch := range text {
		if i >= len(firstLine) {
			break
		}
		if firstLine[i].Char != ch {
			t.Errorf("Expected char %c at position %d, got %c", ch, i, firstLine[i].Char)
		}
	}

	// Test cursor movement
	buffer.Write([]byte("\r\n"))
	snapshot = buffer.GetSnapshot()
	if snapshot.CursorY != 1 || snapshot.CursorX != 0 {
		t.Errorf("Expected cursor at (0,1), got (%d,%d)", snapshot.CursorX, snapshot.CursorY)
	}

	// Test ANSI escape sequences
	buffer.Write([]byte("\x1b[2J")) // Clear screen
	snapshot = buffer.GetSnapshot()

	// All cells should be spaces
	for y := 0; y < snapshot.Rows; y++ {
		for x := 0; x < snapshot.Cols; x++ {
			if snapshot.Cells[y][x].Char != ' ' {
				t.Errorf("Expected space at (%d,%d), got %c", x, y, snapshot.Cells[y][x].Char)
			}
		}
	}

	// Test resize
	buffer.Resize(120, 30)
	snapshot = buffer.GetSnapshot()
	if snapshot.Cols != 120 || snapshot.Rows != 30 {
		t.Errorf("Resize failed: expected 120x30, got %dx%d", snapshot.Cols, snapshot.Rows)
	}
}

func TestAnsiParser(t *testing.T) {
	parser := NewAnsiParser()

	var printedChars []rune
	var executedBytes []byte
	var csiCalls []string

	parser.OnPrint = func(r rune) {
		printedChars = append(printedChars, r)
	}

	parser.OnExecute = func(b byte) {
		executedBytes = append(executedBytes, b)
	}

	parser.OnCsi = func(params []int, intermediate []byte, final byte) {
		csiCalls = append(csiCalls, string(final))
	}

	// Test simple text
	parser.Parse([]byte("Hello"))
	if string(printedChars) != "Hello" {
		t.Errorf("Expected 'Hello', got '%s'", string(printedChars))
	}

	// Test control characters
	printedChars = nil
	parser.Parse([]byte("\r\n"))
	if len(executedBytes) != 2 || executedBytes[0] != '\r' || executedBytes[1] != '\n' {
		t.Errorf("Control characters not properly executed")
	}

	// Test CSI sequence
	parser.Parse([]byte("\x1b[2J"))
	if len(csiCalls) != 1 || csiCalls[0] != "J" {
		t.Errorf("CSI sequence not properly parsed")
	}
}

func TestBufferSerialization(t *testing.T) {
	buffer := NewTerminalBuffer(2, 2)
	buffer.Write([]byte("AB\r\nCD"))

	snapshot := buffer.GetSnapshot()
	data := snapshot.SerializeToBinary()

	// Binary format should contain:
	// - 5 uint32s for dimensions (20 bytes)
	// - 4 cells with char data and attributes
	if len(data) < 20 {
		t.Errorf("Serialized data too short: %d bytes", len(data))
	}
}
