package protocol

import (
	"unicode/utf8"
)

// EscapeParser handles parsing of terminal escape sequences and UTF-8 data
// This ensures escape sequences are not split across chunks
type EscapeParser struct {
	buffer []byte
}

// NewEscapeParser creates a new escape sequence parser
func NewEscapeParser() *EscapeParser {
	return &EscapeParser{
		buffer: make([]byte, 0, 4096),
	}
}

// ProcessData processes terminal data ensuring escape sequences and UTF-8 are not split
// Returns processed data and any remaining incomplete sequences
func (p *EscapeParser) ProcessData(data []byte) (processed []byte, remaining []byte) {
	// Combine buffered data with new data
	combined := append(p.buffer, data...)
	p.buffer = p.buffer[:0] // Clear buffer without reallocating

	result := make([]byte, 0, len(combined))
	pos := 0

	for pos < len(combined) {
		// Check for escape sequence
		if combined[pos] == 0x1b { // ESC character
			seqEnd := p.findEscapeSequenceEnd(combined[pos:])
			if seqEnd == -1 {
				// Incomplete escape sequence, save for next time
				p.buffer = append(p.buffer, combined[pos:]...)
				break
			}
			// Include complete escape sequence
			result = append(result, combined[pos:pos+seqEnd]...)
			pos += seqEnd
			continue
		}

		// Process UTF-8 character
		r, size := utf8.DecodeRune(combined[pos:])
		if r == utf8.RuneError {
			if size == 0 {
				// No more data
				break
			}
			if size == 1 && pos+4 > len(combined) {
				// Might be incomplete UTF-8 at end of buffer
				if p.mightBeIncompleteUTF8(combined[pos:]) {
					p.buffer = append(p.buffer, combined[pos:]...)
					break
				}
			}
			// Invalid UTF-8, skip byte
			result = append(result, combined[pos])
			pos++
			continue
		}

		// Valid UTF-8 character
		result = append(result, combined[pos:pos+size]...)
		pos += size
	}

	return result, p.buffer
}

// findEscapeSequenceEnd finds the end of an ANSI escape sequence
// Returns -1 if sequence is incomplete
func (p *EscapeParser) findEscapeSequenceEnd(data []byte) int {
	if len(data) == 0 || data[0] != 0x1b {
		return -1
	}

	if len(data) < 2 {
		return -1 // Need more data
	}

	switch data[1] {
	case '[': // CSI sequence: ESC [ ... final_char
		pos := 2
		for pos < len(data) {
			b := data[pos]
			if b >= 0x20 && b <= 0x3f {
				// Parameter and intermediate characters
				pos++
			} else if b >= 0x40 && b <= 0x7e {
				// Final character found
				return pos + 1
			} else {
				// Invalid sequence
				return pos
			}
		}
		return -1 // Incomplete

	case ']': // OSC sequence: ESC ] ... (ST or BEL)
		pos := 2
		for pos < len(data) {
			if data[pos] == 0x07 { // BEL terminator
				return pos + 1
			}
			if data[pos] == 0x1b && pos+1 < len(data) && data[pos+1] == '\\' {
				// ESC \ (ST) terminator
				return pos + 2
			}
			pos++
		}
		return -1 // Incomplete

	case '(', ')', '*', '+': // Charset selection
		if len(data) < 3 {
			return -1
		}
		return 3

	case 'P', 'X', '^', '_': // DCS, SOS, PM, APC sequences
		// These need special termination sequences
		pos := 2
		for pos < len(data) {
			if data[pos] == 0x1b && pos+1 < len(data) && data[pos+1] == '\\' {
				// ESC \ (ST) terminator
				return pos + 2
			}
			pos++
		}
		return -1 // Incomplete

	default:
		// Simple two-character sequences
		return 2
	}
}

// mightBeIncompleteUTF8 checks if data might be an incomplete UTF-8 sequence
func (p *EscapeParser) mightBeIncompleteUTF8(data []byte) bool {
	if len(data) == 0 {
		return false
	}

	b := data[0]

	// Single byte (ASCII)
	if b < 0x80 {
		return false
	}

	// Multi-byte sequence starters
	if b >= 0xc0 {
		if b < 0xe0 {
			// 2-byte sequence
			return len(data) < 2
		}
		if b < 0xf0 {
			// 3-byte sequence
			return len(data) < 3
		}
		if b < 0xf8 {
			// 4-byte sequence
			return len(data) < 4
		}
	}

	return false
}

// Flush returns any buffered data (for use when closing)
func (p *EscapeParser) Flush() []byte {
	if len(p.buffer) == 0 {
		return nil
	}
	// Return buffered data as-is when flushing
	result := make([]byte, len(p.buffer))
	copy(result, p.buffer)
	p.buffer = p.buffer[:0]
	return result
}

// Reset clears the parser state
func (p *EscapeParser) Reset() {
	p.buffer = p.buffer[:0]
}

// BufferSize returns the current buffer size
func (p *EscapeParser) BufferSize() int {
	return len(p.buffer)
}

// SplitEscapeSequences splits data at escape sequence boundaries
// This is useful for processing data in chunks without splitting sequences
func SplitEscapeSequences(data []byte) [][]byte {
	if len(data) == 0 {
		return nil
	}

	var chunks [][]byte
	parser := NewEscapeParser()

	processed, remaining := parser.ProcessData(data)
	if len(processed) > 0 {
		chunks = append(chunks, processed)
	}
	if len(remaining) > 0 {
		chunks = append(chunks, remaining)
	}

	return chunks
}

// IsCompleteEscapeSequence checks if data contains a complete escape sequence
func IsCompleteEscapeSequence(data []byte) bool {
	if len(data) == 0 || data[0] != 0x1b {
		return false
	}
	parser := NewEscapeParser()
	end := parser.findEscapeSequenceEnd(data)
	return end > 0 && end == len(data)
}

// StripEscapeSequences removes all ANSI escape sequences from data
func StripEscapeSequences(data []byte) []byte {
	result := make([]byte, 0, len(data))
	pos := 0

	parser := NewEscapeParser()
	for pos < len(data) {
		if data[pos] == 0x1b {
			seqEnd := parser.findEscapeSequenceEnd(data[pos:])
			if seqEnd > 0 {
				pos += seqEnd
				continue
			}
		}
		result = append(result, data[pos])
		pos++
	}

	return result
}
