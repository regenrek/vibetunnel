package protocol

import (
	"bytes"
	"testing"
)

func TestEscapeParser_ProcessData(t *testing.T) {
	tests := []struct {
		name           string
		input          []byte
		wantProcessed  []byte
		wantRemaining  []byte
	}{
		{
			name:          "simple text",
			input:         []byte("Hello, World!"),
			wantProcessed: []byte("Hello, World!"),
			wantRemaining: []byte{},
		},
		{
			name:          "complete CSI sequence",
			input:         []byte("text\x1b[31mred\x1b[0m"),
			wantProcessed: []byte("text\x1b[31mred\x1b[0m"),
			wantRemaining: []byte{},
		},
		{
			name:          "incomplete CSI sequence",
			input:         []byte("text\x1b[31"),
			wantProcessed: []byte("text"),
			wantRemaining: []byte("\x1b[31"),
		},
		{
			name:          "cursor movement",
			input:         []byte("\x1b[1A\x1b[2B\x1b[3C\x1b[4D"),
			wantProcessed: []byte("\x1b[1A\x1b[2B\x1b[3C\x1b[4D"),
			wantRemaining: []byte{},
		},
		{
			name:          "OSC sequence with BEL",
			input:         []byte("\x1b]0;Terminal Title\x07rest"),
			wantProcessed: []byte("\x1b]0;Terminal Title\x07rest"),
			wantRemaining: []byte{},
		},
		{
			name:          "OSC sequence with ST",
			input:         []byte("\x1b]0;Terminal Title\x1b\\rest"),
			wantProcessed: []byte("\x1b]0;Terminal Title\x1b\\rest"),
			wantRemaining: []byte{},
		},
		{
			name:          "incomplete OSC sequence",
			input:         []byte("\x1b]0;Terminal"),
			wantProcessed: []byte{},
			wantRemaining: []byte("\x1b]0;Terminal"),
		},
		{
			name:          "charset selection",
			input:         []byte("\x1b(B\x1b)0text"),
			wantProcessed: []byte("\x1b(B\x1b)0text"),
			wantRemaining: []byte{},
		},
		{
			name:          "incomplete charset",
			input:         []byte("text\x1b("),
			wantProcessed: []byte("text"),
			wantRemaining: []byte("\x1b("),
		},
		{
			name:          "DCS sequence",
			input:         []byte("\x1bPdata\x1b\\text"),
			wantProcessed: []byte("\x1bPdata\x1b\\text"),
			wantRemaining: []byte{},
		},
		{
			name:          "incomplete DCS",
			input:         []byte("\x1bPdata"),
			wantProcessed: []byte{},
			wantRemaining: []byte("\x1bPdata"),
		},
		{
			name:          "mixed content",
			input:         []byte("normal\x1b[1mbold\x1b[0m\x1b["),
			wantProcessed: []byte("normal\x1b[1mbold\x1b[0m"),
			wantRemaining: []byte("\x1b["),
		},
		{
			name:          "UTF-8 text",
			input:         []byte("Hello 世界"),
			wantProcessed: []byte("Hello 世界"),
			wantRemaining: []byte{},
		},
		{
			name:          "incomplete UTF-8 at end",
			input:         []byte("Hello \xe4\xb8"),  // Missing last byte of 世
			wantProcessed: []byte("Hello "),
			wantRemaining: []byte("\xe4\xb8"),
		},
		{
			name:          "invalid UTF-8 byte",
			input:         []byte("Hello\xff\xfeWorld"),
			wantProcessed: []byte("Hello\xff\xfeWorld"),
			wantRemaining: []byte{},
		},
		{
			name:          "escape at end",
			input:         []byte("text\x1b"),
			wantProcessed: []byte("text"),
			wantRemaining: []byte("\x1b"),
		},
		{
			name:          "CSI with invalid terminator",
			input:         []byte("\x1b[31\x00text"),
			wantProcessed: []byte("\x1b[31\x00text"),
			wantRemaining: []byte{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parser := NewEscapeParser()
			processed, remaining := parser.ProcessData(tt.input)
			
			if !bytes.Equal(processed, tt.wantProcessed) {
				t.Errorf("ProcessData() processed = %q, want %q", processed, tt.wantProcessed)
			}
			if !bytes.Equal(remaining, tt.wantRemaining) {
				t.Errorf("ProcessData() remaining = %q, want %q", remaining, tt.wantRemaining)
			}
		})
	}
}

func TestEscapeParser_MultipleChunks(t *testing.T) {
	parser := NewEscapeParser()
	
	// First chunk ends with incomplete escape sequence
	chunk1 := []byte("Hello\x1b[31")
	processed1, remaining1 := parser.ProcessData(chunk1)
	
	if !bytes.Equal(processed1, []byte("Hello")) {
		t.Errorf("Chunk1 processed = %q, want %q", processed1, "Hello")
	}
	if !bytes.Equal(remaining1, []byte("\x1b[31")) {
		t.Errorf("Chunk1 remaining = %q, want %q", remaining1, "\x1b[31")
	}
	
	// Second chunk completes the sequence
	chunk2 := []byte("mRed Text\x1b[0m")
	processed2, remaining2 := parser.ProcessData(chunk2)
	
	expected := []byte("\x1b[31mRed Text\x1b[0m")
	if !bytes.Equal(processed2, expected) {
		t.Errorf("Chunk2 processed = %q, want %q", processed2, expected)
	}
	if len(remaining2) > 0 {
		t.Errorf("Chunk2 remaining = %q, want empty", remaining2)
	}
}

func TestEscapeParser_Flush(t *testing.T) {
	parser := NewEscapeParser()
	
	// Process data with incomplete sequence
	input := []byte("text\x1b[incomplete")
	processed, _ := parser.ProcessData(input)
	
	if !bytes.Equal(processed, []byte("text")) {
		t.Errorf("Processed = %q, want %q", processed, "text")
	}
	
	// Flush should return the incomplete sequence
	flushed := parser.Flush()
	if !bytes.Equal(flushed, []byte("\x1b[incomplete")) {
		t.Errorf("Flush() = %q, want %q", flushed, "\x1b[incomplete")
	}
	
	// Buffer should be empty after flush
	if parser.BufferSize() != 0 {
		t.Errorf("BufferSize() after flush = %d, want 0", parser.BufferSize())
	}
	
	// Second flush should return nothing
	flushed2 := parser.Flush()
	if len(flushed2) > 0 {
		t.Errorf("Second Flush() = %q, want empty", flushed2)
	}
}

func TestEscapeParser_Reset(t *testing.T) {
	parser := NewEscapeParser()
	
	// Add some incomplete data
	parser.ProcessData([]byte("text\x1b[31"))
	
	if parser.BufferSize() == 0 {
		t.Error("Buffer should not be empty before reset")
	}
	
	// Reset
	parser.Reset()
	
	if parser.BufferSize() != 0 {
		t.Errorf("BufferSize() after reset = %d, want 0", parser.BufferSize())
	}
}

func TestEscapeParser_ComplexSequences(t *testing.T) {
	tests := []struct {
		name     string
		input    []byte
		expected []byte
	}{
		{
			name:     "SGR with multiple parameters",
			input:    []byte("\x1b[1;31;40mBold Red on Black\x1b[0m"),
			expected: []byte("\x1b[1;31;40mBold Red on Black\x1b[0m"),
		},
		{
			name:     "cursor position",
			input:    []byte("\x1b[10;20H"),
			expected: []byte("\x1b[10;20H"),
		},
		{
			name:     "clear screen",
			input:    []byte("\x1b[2J\x1b[H"),
			expected: []byte("\x1b[2J\x1b[H"),
		},
		{
			name:     "save and restore cursor",
			input:    []byte("\x1b7text\x1b8"),
			expected: []byte("\x1b7text\x1b8"),
		},
		{
			name:     "alternate screen buffer",
			input:    []byte("\x1b[?1049h\x1b[?1049l"),
			expected: []byte("\x1b[?1049h\x1b[?1049l"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parser := NewEscapeParser()
			processed, remaining := parser.ProcessData(tt.input)
			
			if !bytes.Equal(processed, tt.expected) {
				t.Errorf("ProcessData() = %q, want %q", processed, tt.expected)
			}
			if len(remaining) > 0 {
				t.Errorf("Unexpected remaining data: %q", remaining)
			}
		})
	}
}

func TestIsCompleteEscapeSequence(t *testing.T) {
	tests := []struct {
		name     string
		input    []byte
		expected bool
	}{
		{
			name:     "complete CSI",
			input:    []byte("\x1b[31m"),
			expected: true,
		},
		{
			name:     "incomplete CSI",
			input:    []byte("\x1b[31"),
			expected: false,
		},
		{
			name:     "not escape sequence",
			input:    []byte("hello"),
			expected: false,
		},
		{
			name:     "empty",
			input:    []byte{},
			expected: false,
		},
		{
			name:     "just escape",
			input:    []byte("\x1b"),
			expected: false,
		},
		{
			name:     "complete two-char",
			input:    []byte("\x1b7"),
			expected: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IsCompleteEscapeSequence(tt.input); got != tt.expected {
				t.Errorf("IsCompleteEscapeSequence() = %v, want %v", got, tt.expected)
			}
		})
	}
}

func TestStripEscapeSequences(t *testing.T) {
	tests := []struct {
		name     string
		input    []byte
		expected []byte
	}{
		{
			name:     "colored text",
			input:    []byte("\x1b[31mRed\x1b[0m Normal \x1b[1mBold\x1b[0m"),
			expected: []byte("Red Normal Bold"),
		},
		{
			name:     "cursor movements",
			input:    []byte("A\x1b[1AB\x1b[2CC"),
			expected: []byte("ABC"),
		},
		{
			name:     "OSC sequence",
			input:    []byte("Text\x1b]0;Title\x07More"),
			expected: []byte("TextMore"),
		},
		{
			name:     "no escape sequences",
			input:    []byte("Plain text"),
			expected: []byte("Plain text"),
		},
		{
			name:     "incomplete sequence at end",
			input:    []byte("Text\x1b["),
			expected: []byte("Text\x1b["),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := StripEscapeSequences(tt.input)
			if !bytes.Equal(result, tt.expected) {
				t.Errorf("StripEscapeSequences() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestSplitEscapeSequences(t *testing.T) {
	tests := []struct {
		name     string
		input    []byte
		expected [][]byte
	}{
		{
			name:     "mixed content",
			input:    []byte("text\x1b[31mred\x1b[0m"),
			expected: [][]byte{[]byte("text\x1b[31mred\x1b[0m")},
		},
		{
			name:     "incomplete at end",
			input:    []byte("complete\x1b["),
			expected: [][]byte{[]byte("complete"), []byte("\x1b[")},
		},
		{
			name:     "empty input",
			input:    []byte{},
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := SplitEscapeSequences(tt.input)
			if len(result) != len(tt.expected) {
				t.Fatalf("SplitEscapeSequences() returned %d chunks, want %d", len(result), len(tt.expected))
			}
			for i, chunk := range result {
				if !bytes.Equal(chunk, tt.expected[i]) {
					t.Errorf("Chunk %d = %q, want %q", i, chunk, tt.expected[i])
				}
			}
		})
	}
}

func TestEscapeParser_UTF8Handling(t *testing.T) {
	parser := NewEscapeParser()
	
	// Test multi-byte UTF-8 split across chunks
	chunk1 := []byte("Hello 世")[:8]  // Split in middle of 世
	chunk2 := []byte("Hello 世")[8:]
	
	processed1, _ := parser.ProcessData(chunk1)
	if !bytes.Equal(processed1, []byte("Hello ")) {
		t.Errorf("Chunk1 should process only complete UTF-8: %q", processed1)
	}
	
	processed2, remaining := parser.ProcessData(chunk2)
	expected := []byte("世")
	if !bytes.Equal(processed2, expected) {
		t.Errorf("Chunk2 processed = %q, want %q", processed2, expected)
	}
	if len(remaining) > 0 {
		t.Errorf("Should have no remaining data: %q", remaining)
	}
}

func BenchmarkEscapeParser_ProcessData(b *testing.B) {
	parser := NewEscapeParser()
	// Typical terminal output with colors and cursor movements
	data := []byte("Normal text \x1b[31mRed\x1b[0m \x1b[1mBold\x1b[0m \x1b[10;20HPosition\x1b[2J\x1b[H")
	
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		parser.ProcessData(data)
		parser.Reset()
	}
}

func BenchmarkEscapeParser_LargeData(b *testing.B) {
	parser := NewEscapeParser()
	// Create large data with mixed content
	var buf bytes.Buffer
	for i := 0; i < 100; i++ {
		buf.WriteString("Line ")
		buf.WriteString("\x1b[32m")
		buf.WriteString("colored")
		buf.WriteString("\x1b[0m")
		buf.WriteString(" text with UTF-8: 你好世界\n")
	}
	data := buf.Bytes()
	
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		parser.ProcessData(data)
		parser.Reset()
	}
}