package terminal

import (
	"unicode/utf8"
)

// AnsiParser implements a state machine for parsing ANSI escape sequences
type AnsiParser struct {
	state        parserState
	intermediate []byte
	params       []int
	currentParam int
	oscData      []byte

	// Callbacks
	OnPrint   func(rune)
	OnExecute func(byte)
	OnCsi     func(params []int, intermediate []byte, final byte)
	OnOsc     func(params [][]byte)
	OnEscape  func(intermediate []byte, final byte)
}

type parserState int

const (
	stateGround parserState = iota
	stateEscape
	stateEscapeIntermediate
	stateCsiEntry
	stateCsiParam
	stateCsiIntermediate
	stateCsiIgnore
	stateOscString
	stateDcsEntry
	stateDcsParam
	stateDcsIntermediate
	stateDcsPassthrough
	stateDcsIgnore
)

// NewAnsiParser creates a new ANSI escape sequence parser
func NewAnsiParser() *AnsiParser {
	return &AnsiParser{
		state:        stateGround,
		intermediate: make([]byte, 0, 2),
		params:       make([]int, 0, 16),
	}
}

// Parse processes input bytes through the ANSI state machine
func (p *AnsiParser) Parse(data []byte) {
	for i := 0; i < len(data); {
		b := data[i]

		switch p.state {
		case stateGround:
			if b == 0x1b { // ESC
				p.state = stateEscape
				i++
			} else if b < 0x20 { // C0 control codes
				if p.OnExecute != nil {
					p.OnExecute(b)
				}
				i++
			} else if b < 0x80 { // ASCII printable
				if p.OnPrint != nil {
					p.OnPrint(rune(b))
				}
				i++
			} else { // UTF-8 or extended ASCII
				r, size := utf8.DecodeRune(data[i:])
				if r != utf8.RuneError && p.OnPrint != nil {
					p.OnPrint(r)
				}
				i += size
			}

		case stateEscape:
			p.intermediate = p.intermediate[:0]
			if b >= 0x20 && b <= 0x2f { // Intermediate bytes
				p.intermediate = append(p.intermediate, b)
				p.state = stateEscapeIntermediate
			} else if b == '[' { // CSI
				p.params = p.params[:0]
				p.currentParam = 0
				p.state = stateCsiEntry
			} else if b == ']' { // OSC
				p.oscData = p.oscData[:0]
				p.state = stateOscString
			} else if b >= 0x30 && b <= 0x7e { // Final byte
				if p.OnEscape != nil {
					p.OnEscape(p.intermediate, b)
				}
				p.state = stateGround
			} else {
				p.state = stateGround
			}
			i++

		case stateEscapeIntermediate:
			if b >= 0x20 && b <= 0x2f { // More intermediate bytes
				p.intermediate = append(p.intermediate, b)
			} else if b >= 0x30 && b <= 0x7e { // Final byte
				if p.OnEscape != nil {
					p.OnEscape(p.intermediate, b)
				}
				p.state = stateGround
			} else {
				p.state = stateGround
			}
			i++

		case stateCsiEntry:
			if b >= '0' && b <= '9' { // Parameter digit
				p.currentParam = int(b - '0')
				p.state = stateCsiParam
			} else if b == ';' { // Parameter separator
				p.params = append(p.params, 0)
			} else if b >= 0x20 && b <= 0x2f { // Intermediate bytes
				p.intermediate = append(p.intermediate, b)
				p.state = stateCsiIntermediate
			} else if b >= 0x40 && b <= 0x7e { // Final byte
				if p.OnCsi != nil {
					p.OnCsi(p.params, p.intermediate, b)
				}
				p.state = stateGround
			} else {
				p.state = stateCsiIgnore
			}
			i++

		case stateCsiParam:
			if b >= '0' && b <= '9' { // More digits
				p.currentParam = p.currentParam*10 + int(b-'0')
			} else if b == ';' { // Parameter separator
				p.params = append(p.params, p.currentParam)
				p.currentParam = 0
			} else if b >= 0x20 && b <= 0x2f { // Intermediate bytes
				p.params = append(p.params, p.currentParam)
				p.intermediate = append(p.intermediate, b)
				p.state = stateCsiIntermediate
			} else if b >= 0x40 && b <= 0x7e { // Final byte
				p.params = append(p.params, p.currentParam)
				if p.OnCsi != nil {
					p.OnCsi(p.params, p.intermediate, b)
				}
				p.state = stateGround
			} else {
				p.state = stateCsiIgnore
			}
			i++

		case stateCsiIntermediate:
			if b >= 0x20 && b <= 0x2f { // More intermediate bytes
				p.intermediate = append(p.intermediate, b)
			} else if b >= 0x40 && b <= 0x7e { // Final byte
				if p.OnCsi != nil {
					p.OnCsi(p.params, p.intermediate, b)
				}
				p.state = stateGround
			} else {
				p.state = stateCsiIgnore
			}
			i++

		case stateCsiIgnore:
			if b >= 0x40 && b <= 0x7e { // Wait for final byte
				p.state = stateGround
			}
			i++

		case stateOscString:
			if b == 0x07 { // BEL terminates OSC
				if p.OnOsc != nil {
					// Parse OSC data
					p.parseOscData()
				}
				p.state = stateGround
			} else if b == 0x1b && i+1 < len(data) && data[i+1] == '\\' { // ESC \ also terminates
				if p.OnOsc != nil {
					p.parseOscData()
				}
				p.state = stateGround
				i++ // Skip the backslash
			} else {
				p.oscData = append(p.oscData, b)
			}
			i++

		default:
			p.state = stateGround
			i++
		}
	}
}

// parseOscData splits OSC data into parameters
func (p *AnsiParser) parseOscData() {
	params := make([][]byte, 0)
	start := 0

	for i, b := range p.oscData {
		if b == ';' {
			params = append(params, p.oscData[start:i])
			start = i + 1
		}
	}

	if start < len(p.oscData) {
		params = append(params, p.oscData[start:])
	}

	p.OnOsc(params)
}

// Reset resets the parser to ground state
func (p *AnsiParser) Reset() {
	p.state = stateGround
	p.intermediate = p.intermediate[:0]
	p.params = p.params[:0]
	p.currentParam = 0
	p.oscData = p.oscData[:0]
}
