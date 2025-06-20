package terminal

import (
	"encoding/binary"
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

	// Check header
	if len(data) < 32 {
		t.Fatalf("Serialized data too short: %d bytes", len(data))
	}

	// Check magic bytes "VT" (0x5654)
	if data[0] != 0x54 || data[1] != 0x56 { // Little endian
		t.Errorf("Invalid magic bytes: %02x %02x", data[0], data[1])
	}

	// Check version
	if data[2] != 0x01 {
		t.Errorf("Invalid version: %02x", data[2])
	}

	// Check dimensions at correct offsets
	cols := binary.LittleEndian.Uint32(data[4:8])
	rows := binary.LittleEndian.Uint32(data[8:12])
	if cols != 2 || rows != 2 {
		t.Errorf("Invalid dimensions: %dx%d", cols, rows)
	}
}

func TestBinaryFormatOptimizations(t *testing.T) {
	// Test empty row optimization
	buffer := NewTerminalBuffer(10, 3)
	buffer.Write([]byte("Hello"))     // First row has content
	buffer.Write([]byte("\r\n"))      // Second row empty
	buffer.Write([]byte("\r\nWorld")) // Third row has content

	snapshot := buffer.GetSnapshot()
	data := snapshot.SerializeToBinary()

	// Skip header (28 bytes - the Node.js comment says 32 but it's actually 28)
	offset := 28

	// First row should have content marker (0xfd)
	if data[offset] != 0xfd {
		t.Errorf("Expected row marker 0xfd at offset %d, got %02x (decimal %d)", offset, data[offset], data[offset])
	}

	// Find empty row marker (0xfe) - it should be somewhere in the data
	foundEmptyRow := false
	for i := offset; i < len(data)-1; i++ {
		if data[i] == 0xfe {
			foundEmptyRow = true
			break
		}
	}
	if !foundEmptyRow {
		t.Error("Empty row marker not found in serialized data")
	}

	// Test ASCII character encoding with type byte
	buffer3 := NewTerminalBuffer(5, 1)
	buffer3.Write([]byte("A")) // Single ASCII character

	snapshot3 := buffer3.GetSnapshot()
	data3 := snapshot3.SerializeToBinary()

	// Look for ASCII type byte (0x01) followed by 'A' (0x41)
	foundAsciiEncoding := false
	for i := 28; i < len(data3)-1; i++ {
		if data3[i] == 0x01 && data3[i+1] == 0x41 {
			foundAsciiEncoding = true
			break
		}
	}
	if !foundAsciiEncoding {
		t.Error("ASCII encoding (type 0x01 + char) not found in serialized data")
	}

	// Test Unicode character encoding
	buffer4 := NewTerminalBuffer(5, 1)
	buffer4.Write([]byte("世")) // Unicode character

	snapshot4 := buffer4.GetSnapshot()
	data4 := snapshot4.SerializeToBinary()

	// Look for Unicode type byte (bit 6 set = 0x40+)
	foundUnicodeEncoding := false
	for i := 32; i < len(data4); i++ {
		if (data4[i] & 0x40) != 0 { // Unicode bit set
			foundUnicodeEncoding = true
			break
		}
	}
	if !foundUnicodeEncoding {
		t.Error("Unicode encoding (type with bit 6 set) not found in serialized data")
	}
}
