package terminal

import (
	"bytes"
	"encoding/binary"
	"sync"
	"unicode/utf8"
)

// BufferCell represents a single cell in the terminal buffer
type BufferCell struct {
	Char  rune
	Fg    uint32 // Foreground color (RGB + flags)
	Bg    uint32 // Background color (RGB + flags)
	Flags uint8  // Bold, Italic, Underline, etc.
}

// BufferSnapshot represents the current state of the terminal buffer
type BufferSnapshot struct {
	Cols      int
	Rows      int
	ViewportY int
	CursorX   int
	CursorY   int
	Cells     [][]BufferCell
}

// TerminalBuffer manages a virtual terminal buffer similar to xterm.js
type TerminalBuffer struct {
	mu        sync.RWMutex
	cols      int
	rows      int
	buffer    [][]BufferCell
	cursorX   int
	cursorY   int
	viewportY int // For scrollback
	parser    *AnsiParser

	// Style state
	currentFg    uint32
	currentBg    uint32
	currentFlags uint8
}

// NewTerminalBuffer creates a new terminal buffer
func NewTerminalBuffer(cols, rows int) *TerminalBuffer {
	tb := &TerminalBuffer{
		cols:   cols,
		rows:   rows,
		buffer: make([][]BufferCell, rows),
		parser: NewAnsiParser(),
	}

	// Initialize buffer with empty cells
	for i := 0; i < rows; i++ {
		tb.buffer[i] = make([]BufferCell, cols)
		for j := 0; j < cols; j++ {
			tb.buffer[i][j] = BufferCell{Char: ' '}
		}
	}

	// Set up parser callbacks
	tb.parser.OnPrint = tb.handlePrint
	tb.parser.OnExecute = tb.handleExecute
	tb.parser.OnCsi = tb.handleCsi
	tb.parser.OnOsc = tb.handleOsc
	tb.parser.OnEscape = tb.handleEscape

	return tb
}

// Write processes terminal output and updates the buffer
func (tb *TerminalBuffer) Write(data []byte) (int, error) {
	tb.mu.Lock()
	defer tb.mu.Unlock()

	// Parse the data through ANSI parser
	tb.parser.Parse(data)

	return len(data), nil
}

// GetSnapshot returns the current buffer state
func (tb *TerminalBuffer) GetSnapshot() *BufferSnapshot {
	tb.mu.RLock()
	defer tb.mu.RUnlock()

	// Deep copy the buffer
	cells := make([][]BufferCell, tb.rows)
	for i := 0; i < tb.rows; i++ {
		cells[i] = make([]BufferCell, tb.cols)
		copy(cells[i], tb.buffer[i])
	}

	return &BufferSnapshot{
		Cols:      tb.cols,
		Rows:      tb.rows,
		ViewportY: tb.viewportY,
		CursorX:   tb.cursorX,
		CursorY:   tb.cursorY,
		Cells:     cells,
	}
}

// Resize adjusts the buffer size
func (tb *TerminalBuffer) Resize(cols, rows int) {
	tb.mu.Lock()
	defer tb.mu.Unlock()

	if cols == tb.cols && rows == tb.rows {
		return
	}

	// Create new buffer
	newBuffer := make([][]BufferCell, rows)
	for i := 0; i < rows; i++ {
		newBuffer[i] = make([]BufferCell, cols)
		for j := 0; j < cols; j++ {
			newBuffer[i][j] = BufferCell{Char: ' '}
		}
	}

	// Copy existing content
	minRows := rows
	if tb.rows < minRows {
		minRows = tb.rows
	}
	minCols := cols
	if tb.cols < minCols {
		minCols = tb.cols
	}

	for i := 0; i < minRows; i++ {
		for j := 0; j < minCols; j++ {
			newBuffer[i][j] = tb.buffer[i][j]
		}
	}

	tb.buffer = newBuffer
	tb.cols = cols
	tb.rows = rows

	// Adjust cursor position
	if tb.cursorX >= cols {
		tb.cursorX = cols - 1
	}
	if tb.cursorY >= rows {
		tb.cursorY = rows - 1
	}
}

// SerializeToBinary converts the buffer snapshot to the binary format expected by the web client
func (snapshot *BufferSnapshot) SerializeToBinary() []byte {
	var buf bytes.Buffer

	// Write dimensions (4 bytes each, little endian)
	binary.Write(&buf, binary.LittleEndian, uint32(snapshot.Cols))
	binary.Write(&buf, binary.LittleEndian, uint32(snapshot.Rows))
	binary.Write(&buf, binary.LittleEndian, uint32(snapshot.ViewportY))
	binary.Write(&buf, binary.LittleEndian, uint32(snapshot.CursorX))
	binary.Write(&buf, binary.LittleEndian, uint32(snapshot.CursorY))

	// Write cells
	for y := 0; y < snapshot.Rows; y++ {
		for x := 0; x < snapshot.Cols; x++ {
			cell := snapshot.Cells[y][x]

			// Encode character as UTF-8
			charBytes := make([]byte, 4)
			n := utf8.EncodeRune(charBytes, cell.Char)

			// Write char length (1 byte)
			buf.WriteByte(byte(n))
			// Write char bytes
			buf.Write(charBytes[:n])
			// Write foreground color (4 bytes)
			binary.Write(&buf, binary.LittleEndian, cell.Fg)
			// Write background color (4 bytes)
			binary.Write(&buf, binary.LittleEndian, cell.Bg)
			// Write flags (1 byte)
			buf.WriteByte(cell.Flags)
		}
	}

	return buf.Bytes()
}

// handlePrint handles printable characters
func (tb *TerminalBuffer) handlePrint(r rune) {
	// Place character at cursor position
	if tb.cursorY < tb.rows && tb.cursorX < tb.cols {
		tb.buffer[tb.cursorY][tb.cursorX] = BufferCell{
			Char:  r,
			Fg:    tb.currentFg,
			Bg:    tb.currentBg,
			Flags: tb.currentFlags,
		}
	}

	// Advance cursor
	tb.cursorX++
	if tb.cursorX >= tb.cols {
		tb.cursorX = 0
		tb.cursorY++
		if tb.cursorY >= tb.rows {
			// Scroll
			tb.scrollUp()
			tb.cursorY = tb.rows - 1
		}
	}
}

// handleExecute handles control characters
func (tb *TerminalBuffer) handleExecute(b byte) {
	switch b {
	case '\r': // Carriage return
		tb.cursorX = 0
	case '\n': // Line feed
		tb.cursorY++
		if tb.cursorY >= tb.rows {
			tb.scrollUp()
			tb.cursorY = tb.rows - 1
		}
	case '\b': // Backspace
		if tb.cursorX > 0 {
			tb.cursorX--
		}
	case '\t': // Tab
		// Move to next tab stop (every 8 columns)
		tb.cursorX = ((tb.cursorX / 8) + 1) * 8
		if tb.cursorX >= tb.cols {
			tb.cursorX = tb.cols - 1
		}
	}
}

// handleCsi handles CSI sequences
func (tb *TerminalBuffer) handleCsi(params []int, intermediate []byte, final byte) {
	switch final {
	case 'A': // Cursor up
		n := 1
		if len(params) > 0 && params[0] > 0 {
			n = params[0]
		}
		tb.cursorY -= n
		if tb.cursorY < 0 {
			tb.cursorY = 0
		}

	case 'B': // Cursor down
		n := 1
		if len(params) > 0 && params[0] > 0 {
			n = params[0]
		}
		tb.cursorY += n
		if tb.cursorY >= tb.rows {
			tb.cursorY = tb.rows - 1
		}

	case 'C': // Cursor forward
		n := 1
		if len(params) > 0 && params[0] > 0 {
			n = params[0]
		}
		tb.cursorX += n
		if tb.cursorX >= tb.cols {
			tb.cursorX = tb.cols - 1
		}

	case 'D': // Cursor back
		n := 1
		if len(params) > 0 && params[0] > 0 {
			n = params[0]
		}
		tb.cursorX -= n
		if tb.cursorX < 0 {
			tb.cursorX = 0
		}

	case 'H', 'f': // Cursor position
		row := 1
		col := 1
		if len(params) > 0 {
			row = params[0]
		}
		if len(params) > 1 {
			col = params[1]
		}
		// Convert from 1-based to 0-based
		tb.cursorY = row - 1
		tb.cursorX = col - 1
		// Clamp to bounds
		if tb.cursorY < 0 {
			tb.cursorY = 0
		}
		if tb.cursorY >= tb.rows {
			tb.cursorY = tb.rows - 1
		}
		if tb.cursorX < 0 {
			tb.cursorX = 0
		}
		if tb.cursorX >= tb.cols {
			tb.cursorX = tb.cols - 1
		}

	case 'J': // Erase display
		mode := 0
		if len(params) > 0 {
			mode = params[0]
		}
		switch mode {
		case 0: // Clear from cursor to end
			tb.clearFromCursor()
		case 1: // Clear from start to cursor
			tb.clearToCursor()
		case 2, 3: // Clear entire screen
			tb.clearScreen()
		}

	case 'K': // Erase line
		mode := 0
		if len(params) > 0 {
			mode = params[0]
		}
		switch mode {
		case 0: // Clear from cursor to end of line
			tb.clearLineFromCursor()
		case 1: // Clear from start of line to cursor
			tb.clearLineToCursor()
		case 2: // Clear entire line
			tb.clearLine()
		}

	case 'm': // SGR - Set Graphics Rendition
		tb.handleSGR(params)
	}
}

// handleSGR processes SGR (Select Graphic Rendition) parameters
func (tb *TerminalBuffer) handleSGR(params []int) {
	if len(params) == 0 {
		params = []int{0} // Default to reset
	}

	for i := 0; i < len(params); i++ {
		switch params[i] {
		case 0: // Reset
			tb.currentFg = 0
			tb.currentBg = 0
			tb.currentFlags = 0
		case 1: // Bold
			tb.currentFlags |= 0x01
		case 3: // Italic
			tb.currentFlags |= 0x02
		case 4: // Underline
			tb.currentFlags |= 0x04
		case 7: // Inverse
			tb.currentFlags |= 0x08
		case 30, 31, 32, 33, 34, 35, 36, 37: // Foreground colors
			tb.currentFg = uint32(params[i] - 30)
		case 40, 41, 42, 43, 44, 45, 46, 47: // Background colors
			tb.currentBg = uint32(params[i] - 40)
		case 38: // Extended foreground color
			if i+2 < len(params) && params[i+1] == 5 {
				// 256 color mode
				tb.currentFg = uint32(params[i+2])
				i += 2
			}
		case 48: // Extended background color
			if i+2 < len(params) && params[i+1] == 5 {
				// 256 color mode
				tb.currentBg = uint32(params[i+2])
				i += 2
			}
		}
	}
}

// handleOsc handles OSC sequences
func (tb *TerminalBuffer) handleOsc(params [][]byte) {
	// Handle window title changes, etc.
	// For now, we ignore these
}

// handleEscape handles ESC sequences
func (tb *TerminalBuffer) handleEscape(intermediate []byte, final byte) {
	// Handle various escape sequences
	// For now, we handle the basics
}

// Helper methods for clearing

func (tb *TerminalBuffer) clearScreen() {
	for y := 0; y < tb.rows; y++ {
		for x := 0; x < tb.cols; x++ {
			tb.buffer[y][x] = BufferCell{Char: ' '}
		}
	}
}

func (tb *TerminalBuffer) clearFromCursor() {
	// Clear from cursor to end of line
	for x := tb.cursorX; x < tb.cols; x++ {
		tb.buffer[tb.cursorY][x] = BufferCell{Char: ' '}
	}
	// Clear all lines below
	for y := tb.cursorY + 1; y < tb.rows; y++ {
		for x := 0; x < tb.cols; x++ {
			tb.buffer[y][x] = BufferCell{Char: ' '}
		}
	}
}

func (tb *TerminalBuffer) clearToCursor() {
	// Clear from start to cursor
	for x := 0; x <= tb.cursorX && x < tb.cols; x++ {
		tb.buffer[tb.cursorY][x] = BufferCell{Char: ' '}
	}
	// Clear all lines above
	for y := 0; y < tb.cursorY; y++ {
		for x := 0; x < tb.cols; x++ {
			tb.buffer[y][x] = BufferCell{Char: ' '}
		}
	}
}

func (tb *TerminalBuffer) clearLine() {
	for x := 0; x < tb.cols; x++ {
		tb.buffer[tb.cursorY][x] = BufferCell{Char: ' '}
	}
}

func (tb *TerminalBuffer) clearLineFromCursor() {
	for x := tb.cursorX; x < tb.cols; x++ {
		tb.buffer[tb.cursorY][x] = BufferCell{Char: ' '}
	}
}

func (tb *TerminalBuffer) clearLineToCursor() {
	for x := 0; x <= tb.cursorX && x < tb.cols; x++ {
		tb.buffer[tb.cursorY][x] = BufferCell{Char: ' '}
	}
}

func (tb *TerminalBuffer) scrollUp() {
	// Shift all lines up
	for y := 0; y < tb.rows-1; y++ {
		tb.buffer[y] = tb.buffer[y+1]
	}
	// Clear last line
	tb.buffer[tb.rows-1] = make([]BufferCell, tb.cols)
	for x := 0; x < tb.cols; x++ {
		tb.buffer[tb.rows-1][x] = BufferCell{Char: ' '}
	}
}
