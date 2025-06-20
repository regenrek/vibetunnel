# Direct PTY-to-Buffer Integration

This document describes the direct PTY-to-buffer integration feature that eliminates the asciinema file intermediary for improved performance.

## Overview

The original implementation used the following data flow:
1. PTY writes output to asciinema file
2. Buffer manager monitors the file for changes
3. Buffer manager reads new data and updates terminal buffer
4. WebSocket subscribers are notified of buffer changes

The new direct integration provides:
1. PTY writes directly to terminal buffer via BufferWriter
2. BufferWriter optionally records to asciinema file (for persistence)
3. BufferWriter notifies subscribers immediately
4. Eliminates file I/O latency for real-time updates

## Architecture

### Key Components

- **BufferWriter** (`pkg/session/buffer_writer.go`): Implements `io.Writer` to receive PTY output and write directly to a terminal buffer
- **PTY** (`pkg/session/pty.go`): Modified to support an optional BufferWriter for direct integration
- **Manager** (`pkg/termsocket/manager.go`): Extended with methods for direct integration support

### Data Flow

```
PTY Output → BufferWriter → Terminal Buffer → WebSocket Subscribers
                  ↓
            Asciinema File (optional)
```

## Usage

### Basic Setup

```go
// 1. Create a terminal buffer
buffer := terminal.NewTerminalBuffer(80, 24)

// 2. Create a BufferWriter with notification callback
bufferWriter := session.NewBufferWriter(
    buffer,
    streamWriter,  // Optional: for recording to file
    sessionID,
    notifyCallback, // Called when buffer updates
)

// 3. Set the BufferWriter on the PTY
pty.SetBufferWriter(bufferWriter)

// 4. Run the PTY
err := pty.Run()
```

### Integration with Terminal Socket Manager

```go
// Use the terminal socket manager's direct integration support
sb, err := termSocketManager.GetOrCreateBufferForDirectIntegration(sessionID)
if err != nil {
    return err
}

// Enable direct integration for a session
err = session.EnableDirectBufferIntegration(sess, termSocketManager)
```

## Benefits

1. **Lower Latency**: Eliminates file I/O operations in the critical path
2. **Reduced CPU Usage**: No file monitoring or polling required
3. **Simpler Architecture**: Direct data flow from PTY to buffer
4. **Backward Compatible**: Asciinema recording still works if needed
5. **Real-time Updates**: Immediate notification of buffer changes

## Configuration

The direct integration can be enabled on a per-session basis:

- **With Recording**: BufferWriter writes to both buffer and asciinema file
- **Without Recording**: BufferWriter only updates the terminal buffer
- **Fallback Mode**: If BufferWriter is not set, PTY uses the original file-based approach

## Performance Considerations

- Direct integration reduces latency from ~50ms (file polling) to <1ms
- Memory usage is slightly higher due to in-memory buffering
- CPU usage is lower due to elimination of file monitoring
- WebSocket updates are more responsive

## Migration

Existing code continues to work without modification. To enable direct integration:

1. Update the terminal socket manager to use `GetOrCreateBufferForDirectIntegration`
2. Call `EnableDirectBufferIntegration` after creating a session
3. Ensure WebSocket handlers are prepared for more frequent updates

## Testing

Run the buffer writer tests:
```bash
go test -v ./pkg/session -run TestBufferWriter
```

## Future Improvements

- Batch notifications for high-frequency output
- Configurable buffer sizes for different use cases
- Metrics for monitoring integration performance
- Automatic fallback to file-based approach on errors