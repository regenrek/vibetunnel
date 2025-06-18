# Swift-Rust Communication Architecture

This document describes the inter-process communication (IPC) architecture between the Swift VibeTunnel macOS application and the Rust tty-fwd terminal multiplexer.

## Overview

VibeTunnel uses a Unix domain socket for communication between the Swift app and Rust components. This approach avoids UI spawning issues and provides reliable, bidirectional communication.

## Architecture Components

### 1. Terminal Spawn Service (Swift)

**File**: `VibeTunnel/Core/Services/TerminalSpawnService.swift`

The `TerminalSpawnService` listens on a Unix domain socket at `/tmp/vibetunnel-terminal.sock` and handles requests to spawn terminal windows.

Key features:
- Uses POSIX socket APIs (socket, bind, listen, accept) for reliable Unix domain socket communication
- Runs on a dedicated queue with `.userInitiated` QoS
- Automatically cleans up the socket on startup and shutdown
- Handles JSON-encoded spawn requests and responses
- Non-blocking accept loop with proper error handling

**Lifecycle**:
- Started in `AppDelegate.applicationDidFinishLaunching`
- Stopped in `AppDelegate.applicationWillTerminate`

### 2. Socket Client (Rust)

**File**: `tty-fwd/src/term_socket.rs`

The Rust client connects to the Unix socket to request terminal spawning:

```rust
pub fn spawn_terminal_via_socket(
    command: &[String],
    working_dir: Option<&str>,
) -> Result<String>
```

**Communication Protocol**:

Request format (optimized):
```json
{
  "command": "tty-fwd --session-id=\"uuid\" -- zsh && exit",
  "workingDir": "/Users/example",
  "sessionId": "uuid-here",
  "ttyFwdPath": "/path/to/tty-fwd",
  "terminal": "ghostty"  // optional
}
```

Response format:
```json
{
  "success": true,
  "error": null,
  "sessionId": "uuid-here"
}
```

Key optimizations:
- Command is pre-formatted in Rust to avoid double-escaping issues
- ttyFwdPath is provided to avoid path discovery
- Terminal preference can be specified per-request
- Working directory handling is simplified

### 3. Integration Points

#### Swift Server (Hummingbird)

**File**: `VibeTunnel/Core/Services/TunnelServer.swift`

When `spawn_terminal: true` is received in a session creation request:
1. Connects to the Unix socket using low-level socket APIs
2. Sends the spawn request
3. Reads the response
4. Returns appropriate HTTP response to the web UI

#### Rust API Server

**File**: `tty-fwd/src/api_server.rs`

The API server handles HTTP requests and uses `spawn_terminal_command` when the `spawn_terminal` flag is set.

## Communication Flow

```
Web UI → HTTP POST /api/sessions (spawn_terminal: true)
       ↓
   API Server (Swift or Rust)
       ↓
   Unix Socket Client
       ↓
   /tmp/vibetunnel-terminal.sock
       ↓
   TerminalSpawnService (Swift)
       ↓
   TerminalLauncher
       ↓
   AppleScript execution
       ↓
   Terminal.app/iTerm2/etc opens with command
```

## Benefits of This Architecture

1. **No UI Spawning**: The main VibeTunnel app handles all terminal spawning, avoiding macOS restrictions on spawning UI apps from background processes.

2. **Process Isolation**: tty-fwd doesn't need to know about VibeTunnel's location or how to invoke it.

3. **Reliable Communication**: Unix domain sockets provide fast, reliable local IPC.

4. **Clean Separation**: Terminal spawning logic stays in the Swift app where it belongs.

5. **Fallback Support**: If the socket is unavailable, appropriate error messages guide the user.

## Error Handling

Common error scenarios:

1. **Socket Unavailable**: 
   - Error: "Terminal spawn service not available at /tmp/vibetunnel-terminal.sock"
   - Cause: VibeTunnel app not running or service not started
   - Solution: Ensure VibeTunnel is running

2. **Permission Denied**:
   - Error: "Failed to spawn terminal: Accessibility permission denied"
   - Cause: macOS security restrictions on AppleScript
   - Solution: Grant accessibility permissions to VibeTunnel

3. **Terminal Not Found**:
   - Error: "Selected terminal application not found"
   - Cause: Configured terminal app not installed
   - Solution: Install the terminal or change preferences

## Implementation Notes

### Socket Path

The socket path `/tmp/vibetunnel-terminal.sock` was chosen because:
- `/tmp` is accessible to all processes
- Automatically cleaned up on system restart
- No permission issues between different processes

### JSON Protocol

JSON was chosen for the protocol because:
- Easy to parse in both Swift and Rust
- Human-readable for debugging
- Extensible for future features

### Performance Optimizations

1. **Pre-formatted Commands**: Rust formats the complete command string, avoiding complex escaping logic in Swift
2. **Path Discovery**: tty-fwd path is passed in the request to avoid repeated file system lookups
3. **Direct Terminal Selection**: Terminal preference can be specified per-request without changing global settings
4. **Simplified Escaping**: Using shell-words crate in Rust for proper command escaping
5. **Reduced Payload Size**: Command is a single string instead of an array

### Security Considerations

- The socket is created with default permissions (user-only access)
- No authentication is required as it's local-only communication
- The socket is cleaned up on app termination
- Commands are properly escaped using shell-words to prevent injection

## Adding New IPC Features

To add new IPC commands:

1. Define the request/response structures in both Swift and Rust
2. Add a new handler in `TerminalSpawnService.handleRequest`
3. Create a corresponding client function in Rust
4. Update error handling for the new command

Example:
```swift
struct NewCommand: Codable {
    let action: String
    let parameters: [String: String]
}
```

```rust
#[derive(serde::Serialize)]
struct NewCommand {
    action: String,
    parameters: HashMap<String, String>,
}
```

## Debugging

To debug socket communication:

1. Check if the socket exists: `ls -la /tmp/vibetunnel-terminal.sock`
2. Monitor Swift logs: Look for `TerminalSpawnService` category
3. Check Rust debug output when running tty-fwd with verbose logging
4. Use `netstat -an | grep vibetunnel` to see socket connections

## Implementation Details

### POSIX Socket Implementation

The service uses low-level POSIX socket APIs for maximum compatibility:

```swift
// Socket creation
serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)

// Binding to path
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
bind(serverSocket, &addr, socklen_t(MemoryLayout<sockaddr_un>.size))

// Accept connections
let clientSocket = accept(serverSocket, &clientAddr, &clientAddrLen)
```

This approach avoids the Network framework's limitations with Unix domain sockets and provides reliable, cross-platform compatible IPC.

## Historical Context

Previously, tty-fwd would spawn VibeTunnel as a subprocess with CLI arguments. This approach had several issues:
- macOS security restrictions on spawning UI apps
- Duplicate instance detection conflicts
- Complex error handling
- Path discovery problems

The Unix socket approach would resolve these issues while providing a cleaner architecture, but needs to be implemented using lower-level APIs due to Network framework limitations.