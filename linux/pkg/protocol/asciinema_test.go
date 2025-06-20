package protocol

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestAsciinemaHeader(t *testing.T) {
	header := AsciinemaHeader{
		Version:   2,
		Width:     80,
		Height:    24,
		Timestamp: 1234567890,
		Command:   "/bin/bash",
		Title:     "Test Recording",
		Env: map[string]string{
			"TERM": "xterm-256color",
		},
	}

	// Test JSON marshaling
	data, err := json.Marshal(header)
	if err != nil {
		t.Fatalf("Failed to marshal header: %v", err)
	}

	// Verify it contains expected fields
	jsonStr := string(data)
	if !strings.Contains(jsonStr, `"version":2`) {
		t.Error("JSON should contain version")
	}
	if !strings.Contains(jsonStr, `"width":80`) {
		t.Error("JSON should contain width")
	}
	if !strings.Contains(jsonStr, `"height":24`) {
		t.Error("JSON should contain height")
	}

	// Test unmarshaling
	var decoded AsciinemaHeader
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("Failed to unmarshal header: %v", err)
	}

	if decoded.Version != header.Version {
		t.Errorf("Version = %d, want %d", decoded.Version, header.Version)
	}
	if decoded.Width != header.Width {
		t.Errorf("Width = %d, want %d", decoded.Width, header.Width)
	}
}

func TestStreamWriter_WriteHeader(t *testing.T) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{
		Version: 2,
		Width:   80,
		Height:  24,
	}

	writer := NewStreamWriter(&buf, header)

	// Write header
	if err := writer.WriteHeader(); err != nil {
		t.Fatalf("WriteHeader() error = %v", err)
	}

	// Check output
	output := buf.String()
	if !strings.HasSuffix(output, "\n") {
		t.Error("Header should end with newline")
	}

	// Parse the header
	var decoded AsciinemaHeader
	headerLine := strings.TrimSpace(output)
	if err := json.Unmarshal([]byte(headerLine), &decoded); err != nil {
		t.Fatalf("Failed to decode header: %v", err)
	}

	if decoded.Version != 2 {
		t.Errorf("Version = %d, want 2", decoded.Version)
	}
	if decoded.Timestamp == 0 {
		t.Error("Timestamp should be set automatically")
	}
}

func TestStreamWriter_WriteOutput(t *testing.T) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{
		Version: 2,
		Width:   80,
		Height:  24,
	}

	writer := NewStreamWriter(&buf, header)

	// Write some output
	testData := []byte("Hello, World!")
	if err := writer.WriteOutput(testData); err != nil {
		t.Fatalf("WriteOutput() error = %v", err)
	}

	// Check output format
	output := buf.String()
	if !strings.HasSuffix(output, "\n") {
		t.Error("Event should end with newline")
	}

	// Parse the event
	var event []interface{}
	eventLine := strings.TrimSpace(output)
	if err := json.Unmarshal([]byte(eventLine), &event); err != nil {
		t.Fatalf("Failed to decode event: %v", err)
	}

	if len(event) != 3 {
		t.Fatalf("Event should have 3 elements, got %d", len(event))
	}

	// Check timestamp (should be close to 0 for first event)
	timestamp, ok := event[0].(float64)
	if !ok {
		t.Fatalf("First element should be float64 timestamp")
	}
	if timestamp < 0 || timestamp > 1 {
		t.Errorf("Timestamp = %f, want close to 0", timestamp)
	}

	// Check event type
	eventType, ok := event[1].(string)
	if !ok || eventType != "o" {
		t.Errorf("Event type = %v, want 'o'", event[1])
	}

	// Check data
	data, ok := event[2].(string)
	if !ok || data != string(testData) {
		t.Errorf("Event data = %v, want %q", event[2], testData)
	}
}

func TestStreamWriter_WriteInput(t *testing.T) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{Version: 2}
	writer := NewStreamWriter(&buf, header)

	testInput := []byte("ls -la")
	if err := writer.WriteInput(testInput); err != nil {
		t.Fatalf("WriteInput() error = %v", err)
	}

	// Parse the event
	var event []interface{}
	if err := json.Unmarshal([]byte(strings.TrimSpace(buf.String())), &event); err != nil {
		t.Fatal(err)
	}

	if event[1] != "i" {
		t.Errorf("Event type = %v, want 'i'", event[1])
	}
	if event[2] != string(testInput) {
		t.Errorf("Event data = %v, want %q", event[2], testInput)
	}
}

func TestStreamWriter_WriteResize(t *testing.T) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{Version: 2}
	writer := NewStreamWriter(&buf, header)

	if err := writer.WriteResize(120, 40); err != nil {
		t.Fatalf("WriteResize() error = %v", err)
	}

	// Parse the event
	var event []interface{}
	if err := json.Unmarshal([]byte(strings.TrimSpace(buf.String())), &event); err != nil {
		t.Fatal(err)
	}

	if event[1] != "r" {
		t.Errorf("Event type = %v, want 'r'", event[1])
	}
	if event[2] != "120x40" {
		t.Errorf("Event data = %v, want '120x40'", event[2])
	}
}

func TestStreamWriter_EscapeSequenceHandling(t *testing.T) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{Version: 2}
	writer := NewStreamWriter(&buf, header)

	// Write data with incomplete escape sequence
	part1 := []byte("Hello \x1b[31")
	part2 := []byte("mRed Text\x1b[0m")

	// First write - incomplete sequence should be buffered
	if err := writer.WriteOutput(part1); err != nil {
		t.Fatal(err)
	}

	// Should only write "Hello "
	var event1 []interface{}
	if buf.Len() > 0 {
		line := strings.TrimSpace(buf.String())
		if err := json.Unmarshal([]byte(line), &event1); err != nil {
			t.Fatal(err)
		}
		if event1[2] != "Hello " {
			t.Errorf("First write data = %q, want %q", event1[2], "Hello ")
		}
	}

	buf.Reset()

	// Second write - should complete the sequence
	if err := writer.WriteOutput(part2); err != nil {
		t.Fatal(err)
	}

	// Should write the complete escape sequence
	var event2 []interface{}
	line := strings.TrimSpace(buf.String())
	if err := json.Unmarshal([]byte(line), &event2); err != nil {
		t.Fatal(err)
	}

	expected := "\x1b[31mRed Text\x1b[0m"
	if event2[2] != expected {
		t.Errorf("Second write data = %q, want %q", event2[2], expected)
	}
}

func TestStreamWriter_Close(t *testing.T) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{Version: 2}
	writer := NewStreamWriter(&buf, header)

	// Write some data with incomplete sequence
	if err := writer.WriteOutput([]byte("test\x1b[")); err != nil {
		t.Fatal(err)
	}

	initialLen := buf.Len()

	// Close should flush remaining data
	if err := writer.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	// Should have written more data (the flushed incomplete sequence)
	if buf.Len() <= initialLen {
		t.Error("Close() should flush remaining data")
	}

	// Try to write after close
	if err := writer.WriteOutput([]byte("more")); err == nil {
		t.Error("Writing after close should return error")
	}
}

func TestStreamWriter_Timing(t *testing.T) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{Version: 2}
	writer := NewStreamWriter(&buf, header)

	// Write first event
	if err := writer.WriteOutput([]byte("first")); err != nil {
		t.Fatal(err)
	}

	// Wait a bit
	time.Sleep(100 * time.Millisecond)

	// Write second event
	buf.Reset() // Clear first event
	if err := writer.WriteOutput([]byte("second")); err != nil {
		t.Fatal(err)
	}

	// Parse second event
	var event []interface{}
	if err := json.Unmarshal([]byte(strings.TrimSpace(buf.String())), &event); err != nil {
		t.Fatal(err)
	}

	// Timestamp should be > 0.1 seconds
	timestamp := event[0].(float64)
	if timestamp < 0.09 || timestamp > 0.2 {
		t.Errorf("Timestamp = %f, want ~0.1", timestamp)
	}
}

func TestStreamReader_ReadHeader(t *testing.T) {
	// Create test data
	header := AsciinemaHeader{
		Version: 2,
		Width:   80,
		Height:  24,
		Command: "/bin/bash",
	}
	headerData, _ := json.Marshal(header)

	input := string(headerData) + "\n"
	reader := NewStreamReader(strings.NewReader(input))

	// Read header
	event, err := reader.Next()
	if err != nil {
		t.Fatalf("Next() error = %v", err)
	}

	if event.Type != "header" {
		t.Errorf("Event type = %s, want 'header'", event.Type)
	}
	if event.Header == nil {
		t.Fatal("Header should not be nil")
	}
	if event.Header.Version != 2 {
		t.Errorf("Version = %d, want 2", event.Header.Version)
	}
}

func TestStreamReader_ReadEvents(t *testing.T) {
	// Create test data with header and events
	header := AsciinemaHeader{Version: 2}
	headerData, _ := json.Marshal(header)

	event1 := []interface{}{0.5, "o", "Hello"}
	event1Data, _ := json.Marshal(event1)

	event2 := []interface{}{1.0, "i", "input"}
	event2Data, _ := json.Marshal(event2)

	input := string(headerData) + "\n" + string(event1Data) + "\n" + string(event2Data) + "\n"
	reader := NewStreamReader(strings.NewReader(input))

	// Read header
	headerEvent, err := reader.Next()
	if err != nil || headerEvent.Type != "header" {
		t.Fatal("Failed to read header")
	}

	// Read first event
	ev1, err := reader.Next()
	if err != nil {
		t.Fatal(err)
	}
	if ev1.Type != "event" || ev1.Event == nil {
		t.Fatal("Expected event type")
	}
	if ev1.Event.Type != "o" || ev1.Event.Data != "Hello" {
		t.Errorf("Event 1 mismatch: %+v", ev1.Event)
	}

	// Read second event
	ev2, err := reader.Next()
	if err != nil {
		t.Fatal(err)
	}
	if ev2.Event.Type != "i" || ev2.Event.Data != "input" {
		t.Errorf("Event 2 mismatch: %+v", ev2.Event)
	}

	// Read EOF
	endEvent, err := reader.Next()
	if err != nil {
		t.Fatal(err)
	}
	if endEvent.Type != "end" {
		t.Errorf("Expected end event, got %s", endEvent.Type)
	}
}

func TestExtractCompleteUTF8(t *testing.T) {
	tests := []struct {
		name          string
		input         []byte
		wantComplete  []byte
		wantRemaining []byte
	}{
		{
			name:          "all ASCII",
			input:         []byte("Hello"),
			wantComplete:  []byte("Hello"),
			wantRemaining: []byte{},
		},
		{
			name:          "complete UTF-8",
			input:         []byte("Hello 世界"),
			wantComplete:  []byte("Hello 世界"),
			wantRemaining: []byte{},
		},
		{
			name:          "incomplete 2-byte",
			input:         []byte("Hello \xc3"),
			wantComplete:  []byte("Hello "),
			wantRemaining: []byte("\xc3"),
		},
		{
			name:          "incomplete 3-byte",
			input:         []byte("Hello \xe4\xb8"),
			wantComplete:  []byte("Hello "),
			wantRemaining: []byte("\xe4\xb8"),
		},
		{
			name:          "incomplete 4-byte",
			input:         []byte("Hello \xf0\x9f\x98"),
			wantComplete:  []byte("Hello "),
			wantRemaining: []byte("\xf0\x9f\x98"),
		},
		{
			name:          "empty",
			input:         []byte{},
			wantComplete:  nil,
			wantRemaining: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			complete, remaining := extractCompleteUTF8(tt.input)
			if !bytes.Equal(complete, tt.wantComplete) {
				t.Errorf("complete = %q, want %q", complete, tt.wantComplete)
			}
			if !bytes.Equal(remaining, tt.wantRemaining) {
				t.Errorf("remaining = %q, want %q", remaining, tt.wantRemaining)
			}
		})
	}
}

func BenchmarkStreamWriter_WriteOutput(b *testing.B) {
	var buf bytes.Buffer
	header := &AsciinemaHeader{Version: 2}
	writer := NewStreamWriter(&buf, header)

	data := []byte("This is a line of terminal output with some \x1b[31mcolor\x1b[0m\n")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writer.WriteOutput(data)
		buf.Reset()
	}
}

func BenchmarkStreamReader_Next(b *testing.B) {
	// Create test data
	header := AsciinemaHeader{Version: 2}
	headerData, _ := json.Marshal(header)

	var events []string
	events = append(events, string(headerData))
	for i := 0; i < 100; i++ {
		event := []interface{}{float64(i) * 0.1, "o", "Line of output\n"}
		eventData, _ := json.Marshal(event)
		events = append(events, string(eventData))
	}

	input := strings.Join(events, "\n")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		reader := NewStreamReader(strings.NewReader(input))
		for {
			event, err := reader.Next()
			if err != nil || event.Type == "end" {
				break
			}
		}
	}
}
