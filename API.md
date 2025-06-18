# VibeTunnel API Analysis

## Summary

This document analyzes the API endpoints implemented across all VibeTunnel servers, what the web client expects, and identifies critical differences, implementation errors, and semantic inconsistencies. The analysis covers:

1. **Node.js/TypeScript Server** (`web/src/server.ts`) - ✅ Complete
2. **Rust API Server** (`tty-fwd/src/api_server.rs`) - ✅ Complete
3. **Go Server** (`linux/pkg/api/server.go`) - ✅ Complete
4. **Swift Server** (`VibeTunnel/Core/Services/TunnelServer.swift`) - ✅ Complete
5. **Web Client** (`web/src/client/`) - Expected API calls and formats

**Note**: Rust HTTP Server (`tty-fwd/src/http_server.rs`) is excluded as it's a utility component for static file serving, not a standalone API server.

## API Endpoint Comparison

| Endpoint | Client Expects | Node.js | Rust API | Go | Swift | Status |
|----------|----------------|---------|----------|----|---------| ------|
| `GET /api/health` | ✅ Used | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `GET /api/sessions` | ✅ **Critical** | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `POST /api/sessions` | ✅ **Critical** | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `DELETE /api/sessions/:id` | ✅ **Critical** | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `DELETE /api/sessions/:id/cleanup` | ❌ Not used | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `GET /api/sessions/:id/stream` | ✅ **Critical SSE** | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `GET /api/sessions/:id/snapshot` | ✅ **Critical** | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `POST /api/sessions/:id/input` | ✅ **Critical** | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `POST /api/sessions/:id/resize` | ✅ **Critical** | ✅ | ❌ | ✅ | ❌ | ⚠️ **Missing in Rust API & Swift** |
| `POST /api/cleanup-exited` | ✅ Used | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `GET /api/fs/browse` | ✅ **Critical** | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `POST /api/mkdir` | ✅ Used | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `GET /api/sessions/multistream` | ❌ Not used | ✅ | ✅ | ✅ | ✅ | ✅ **Complete** |
| `GET /api/pty/status` | ❌ Not used | ✅ | ❌ | ❌ | ❌ | ℹ️ **Node.js Only** |
| `GET /api/test-cast` | ❌ Not used | ✅ | ❌ | ❌ | ❌ | ℹ️ **Node.js Only** |
| `POST /api/ngrok/start` | ❌ Not used | ❌ | ❌ | ✅ | ✅ | ℹ️ **Go/Swift Only** |
| `POST /api/ngrok/stop` | ❌ Not used | ❌ | ❌ | ✅ | ✅ | ℹ️ **Go/Swift Only** |
| `GET /api/ngrok/status` | ❌ Not used | ❌ | ❌ | ✅ | ✅ | ℹ️ **Go/Swift Only** |

## Web Client API Requirements

Based on analysis of `web/src/client/`, the client **requires** these endpoints to function:

### Critical Endpoints (App breaks without these):
1. `GET /api/sessions` - Session list (polled every 3s)
2. `POST /api/sessions` - Session creation  
3. `DELETE /api/sessions/:id` - Session termination
4. `GET /api/sessions/:id/stream` - **SSE streaming** (real-time terminal output)
5. `GET /api/sessions/:id/snapshot` - Terminal snapshot for initial display
6. `POST /api/sessions/:id/input` - **Keyboard/mouse input** to terminal
7. `POST /api/sessions/:id/resize` - **Terminal resize** (debounced, 250ms)
8. `GET /api/fs/browse` - Directory browsing for session creation
9. `POST /api/cleanup-exited` - Cleanup exited sessions

### Expected Request/Response Formats by Client:

#### Session List Response (GET /api/sessions):
```typescript
Session[] = {
  id: string;
  command: string;
  workingDir: string;
  name?: string;
  status: 'running' | 'exited';
  exitCode?: number;
  startedAt: string;
  lastModified: string;
  pid?: number;
  waiting?: boolean;  // Node.js only
  width?: number;     // Go only  
  height?: number;    // Go only
}[]
```

#### Session Creation Request (POST /api/sessions):
```typescript
{
  command: string[];        // Required: parsed command array
  workingDir: string;       // Required: working directory path
  name?: string;           // Optional: session name
  spawn_terminal?: boolean; // Used by Rust API/Swift (always true)
  width?: number;          // Used by Go (default: 120)
  height?: number;         // Used by Go (default: 30)
}
```

#### Session Input Request (POST /api/sessions/:id/input):
```typescript
{
  text: string; // Input text or special keys: 'enter', 'escape', 'arrow_up', etc.
}
```

#### Terminal Resize Request (POST /api/sessions/:id/resize):
```typescript
{
  width: number;  // Terminal columns  
  height: number; // Terminal rows
}
```

## Major Implementation Differences

### 1. **Server Implementation Status**

All API servers are **fully functional and complete**:

**Rust API Server** (`tty-fwd/src/api_server.rs`):
- ✅ **Purpose**: Full terminal session management server  
- ✅ **APIs**: Complete implementation of all session endpoints
- ✅ **Features**: Authentication, SSE streaming, file system APIs
- ❌ **Missing**: Terminal resize endpoint only

**Architecture Note**: The Rust HTTP Server (`tty-fwd/src/http_server.rs`) is a utility component for static file serving and HTTP/SSE primitives, not a standalone API server. It's correctly excluded from this analysis.

### 2. **CRITICAL: Missing Terminal Resize API**

**Impact**: ⚠️ **Client expects this endpoint and calls it continuously**
**Affected**: Rust API Server, Swift Server
**Endpoints**: `POST /api/sessions/:id/resize`

**Client Behavior**: 
- Calls resize endpoint on window resize events (debounced 250ms)
- Tracks last sent dimensions to avoid redundant requests  
- Logs warnings on failure but continues operation
- **Will cause 404 errors** on Rust API and Swift servers

**Working Implementation Analysis**:

```javascript
// Node.js Implementation (✅ Complete)
app.post('/api/sessions/:sessionId/resize', async (req, res) => {
  const { width, height } = req.body;
  // Validation: 1-1000 range
  if (width < 1 || height < 1 || width > 1000 || height > 1000) {
    return res.status(400).json({ error: 'Width and height must be between 1 and 1000' });
  }
  ptyService.resizeSession(sessionId, width, height);
});
```

```go
// Go Implementation (✅ Complete)
func (s *Server) handleResizeSession(w http.ResponseWriter, r *http.Request) {
  // Includes validation for positive integers
  if req.Width <= 0 || req.Height <= 0 {
    http.Error(w, "Width and height must be positive integers", http.StatusBadRequest)
    return
  }
}
```

**Missing in**:
- Rust API Server: No resize endpoint
- Swift Server: No resize endpoint

### 3. **Session Creation Request Format Inconsistencies**

#### Node.js Format:
```json
{
  "command": ["bash", "-l"],
  "workingDir": "/path/to/dir",
  "name": "session_name"
}
```

#### Rust API Format:
```json
{
  "command": ["bash", "-l"],
  "workingDir": "/path/to/dir",
  "term": "xterm-256color",
  "spawn_terminal": true
}
```

#### Go Format:
```json
{
  "name": "session_name",
  "command": ["bash", "-l"],
  "workingDir": "/path/to/dir",
  "width": 120,
  "height": 30
}
```

#### Swift Format:
```json
{
  "command": ["bash", "-l"],
  "workingDir": "/path/to/dir",
  "term": "xterm-256color",
  "spawnTerminal": true
}
```

**Issues**:
1. Inconsistent field naming (`workingDir` vs `working_dir`)
2. Different optional fields across implementations
3. Terminal dimensions only in Go implementation

### 4. **Authentication Implementation Differences**

| Server | Auth Method | Details |
|--------|-------------|---------|
| Node.js | None | No authentication middleware |
| Rust API | Basic Auth | Configurable password, realm="tty-fwd" |
| Go | Basic Auth | Fixed username "admin", realm="VibeTunnel" |
| Swift | Basic Auth | Lazy keychain-based password loading |

**Problems**:
1. Different realm names (`"tty-fwd"` vs `"VibeTunnel"`)
2. Inconsistent username requirements
3. Node.js completely lacks authentication

### 5. **Session Input Handling Inconsistencies**

#### Special Key Mappings Differ:

**Node.js**:
```javascript
const specialKeys = [
  'arrow_up', 'arrow_down', 'arrow_left', 'arrow_right',
  'escape', 'enter', 'ctrl_enter', 'shift_enter'
];
```

**Go**:
```go
specialKeys := map[string]string{
  "arrow_up":    "\x1b[A",
  "arrow_down":  "\x1b[B", 
  "arrow_right": "\x1b[C",
  "arrow_left":  "\x1b[D",
  "escape":      "\x1b",
  "enter":       "\r",        // CR, not LF
  "ctrl_enter":  "\r",        // CR for ctrl+enter
  "shift_enter": "\x1b\x0d", // ESC + CR for shift+enter
}
```

**Swift**:
```swift
let specialKeys = [
  "arrow_up", "arrow_down", "arrow_left", "arrow_right",
  "escape", "enter", "ctrl_enter", "shift_enter"
]
```

**Issues**:
1. Go provides explicit escape sequence mappings
2. Node.js and Swift rely on PTY service for mapping
3. Different enter key handling (`\r` vs `\n`)

### 6. **Session Response Format Inconsistencies**

#### Node.js Session List Response:
```json
{
  "id": "session-123",
  "command": "bash -l",
  "workingDir": "/home/user",
  "name": "my-session",
  "status": "running",
  "exitCode": null,
  "startedAt": "2024-01-01T00:00:00Z",
  "lastModified": "2024-01-01T00:01:00Z",
  "pid": 1234,
  "waiting": false
}
```

#### Rust API Session List Response:
```json
{
  "id": "session-123",
  "command": "bash -l",
  "workingDir": "/home/user",
  "status": "running",
  "exitCode": null,
  "startedAt": "2024-01-01T00:00:00Z",
  "lastModified": "2024-01-01T00:01:00Z",
  "pid": 1234
}
```

**Differences**:
1. Node.js includes `name` and `waiting` fields
2. Rust API missing these fields
3. Field naming inconsistencies across servers

### 7. **File System API Response Format Differences**

#### Node.js FS Browse Response:
```json
{
  "absolutePath": "/home/user",
  "files": [{
    "name": "file.txt",
    "created": "2024-01-01T00:00:00Z",
    "lastModified": "2024-01-01T00:01:00Z",
    "size": 1024,
    "isDir": false
  }]
}
```

#### Go FS Browse Response:
```json
[{
  "name": "file.txt",
  "path": "/home/user/file.txt",
  "is_dir": false,
  "size": 1024,
  "mode": "-rw-r--r--",
  "mod_time": "2024-01-01T00:01:00Z"
}]
```

**Issues**:
1. Different response structures (object vs array)
2. Different field names (`isDir` vs `is_dir`)
3. Go includes additional fields (`path`, `mode`)
4. Missing `created` field in Go

### 8. **Error Response Format Inconsistencies**

#### Node.js Error Format:
```json
{
  "error": "Session not found"
}
```

#### Rust API Error Format:
```json
{
  "success": null,
  "message": null,
  "error": "Session not found",
  "sessionId": null
}
```

#### Go Simple Error:
```
"Session not found" (plain text)
```

**Problems**:
1. Inconsistent error response structures
2. Some servers use structured responses, others plain text
3. Different HTTP status codes for same error conditions

## Critical Security Issues

### 1. **Inconsistent Authentication**
- Node.js server has NO authentication
- Different authentication realms across servers
- No standardized credential management

### 2. **Path Traversal Vulnerabilities**
Different path sanitization across servers:

**Node.js** (Proper):
```javascript
function resolvePath(inputPath, fallback) {
  if (inputPath.startsWith('~')) {
    return path.join(os.homedir(), inputPath.slice(1));
  }
  return path.resolve(inputPath);
}
```

**Go** (Basic):
```go
// Expand ~ in working directory
if cwd != "" && cwd[0] == '~' {
  // Simple tilde expansion
}
```

## Missing Features by Server

### Node.js Missing:
- ngrok tunnel management
- Terminal dimensions in session creation

### Rust HTTP Server Missing:
- **ALL API endpoints** (only static file serving)

### Rust API Server Missing:
- Terminal resize functionality
- ngrok tunnel management

### Go Server Missing:
- None (most complete implementation)

### Swift Server Missing:
- Terminal resize functionality

## Recommendations

### 1. **Immediate Fixes Required**

1. **Standardize Request/Response Formats**:
   - Use consistent field naming (camelCase vs snake_case)
   - Standardize error response structure
   - Align session creation request formats

2. **Implement Missing Critical APIs**:
   - Add resize endpoint to Rust API and Swift servers
   - Add authentication to Node.js server
   - Deprecate or complete Rust HTTP server

3. **Fix Security Issues**:
   - Standardize authentication realms
   - Implement consistent path sanitization
   - Add proper input validation

### 2. **Semantic Alignment**

1. **Session Management**:
   - Standardize session ID generation
   - Align session status values
   - Consistent PID handling

2. **Special Key Handling**:
   - Standardize escape sequence mappings
   - Consistent enter key behavior
   - Align special key names

3. **File System Operations**:
   - Standardize directory listing format
   - Consistent path resolution
   - Align file metadata fields

### 3. **Architecture Improvements**

1. **API Versioning**:
   - Implement `/api/v1/` prefix
   - Version all endpoint contracts
   - Plan backward compatibility

2. **Error Handling**:
   - Standardize HTTP status codes
   - Consistent error response format
   - Proper error categorization

3. **Documentation**:
   - OpenAPI/Swagger specifications
   - API contract testing
   - Cross-server compatibility tests

## Rust Server Architecture Analysis 

After deeper analysis, the Rust servers have a clear separation of concerns:

### Rust Session Management (`tty-fwd/src/sessions.rs`)
**Complete session management implementation**:
- `list_sessions()` - ✅ Full session listing with status checking
- `send_key_to_session()` - ✅ Special key input (arrow keys, enter, escape, etc.)
- `send_text_to_session()` - ✅ Text input to sessions
- `send_signal_to_session()` - ✅ Signal sending (SIGTERM, SIGKILL, etc.)
- `cleanup_sessions()` - ✅ Session cleanup with PID validation
- `spawn_command()` - ✅ New session creation
- ✅ Process monitoring and zombie reaping
- ✅ Pipe-based I/O with timeout protection

### Rust Protocol Support (`tty-fwd/src/protocol.rs`)
**Complete streaming and protocol support**:
- ✅ Asciinema format reading/writing
- ✅ SSE streaming with `StreamingIterator` 
- ✅ Terminal escape sequence processing
- ✅ Real-time event streaming with file monitoring
- ✅ UTF-8 handling and buffering

### Main Binary (`tty-fwd/src/main.rs`)
**Complete CLI interface**:
- ✅ Session listing: `--list-sessions`
- ✅ Key input: `--send-key <key>` 
- ✅ Text input: `--send-text <text>`
- ✅ Process control: `--signal`, `--stop`, `--kill`
- ✅ Cleanup: `--cleanup`
- ✅ **HTTP Server**: `--serve <addr>` (launches API server)

**Key Finding**: `tty-fwd --serve` launches the **API server**, not the HTTP server.

## Corrected Assessment

### Rust Implementation Status: ✅ **COMPLETE AND CORRECT**

**All servers are properly implemented**:
1. **Node.js Server**: ✅ Complete - PTY service wrapper
2. **Rust HTTP Server**: ✅ Complete - Utility HTTP server (not meant for direct client use)  
3. **Rust API Server**: ✅ Complete - Full session management server
4. **Go Server**: ✅ Complete - Native session management
5. **Swift Server**: ✅ Complete - Wraps tty-fwd binary

### Remaining Issues (Reduced Severity):

1. **Terminal Resize Missing** (Rust API, Swift) - Client compatibility issue
2. **Request/Response Format Inconsistencies** - Client needs adaptation
3. **Authentication Differences** - Security/compatibility issue

## Updated Recommendations

### 1. **Immediate Priority: Terminal Resize**
Add resize endpoint to Rust API and Swift servers:
```rust
// Rust API Server needs:
POST /api/sessions/{sessionId}/resize
```

### 2. **Response Format Standardization**
Align session list responses across all servers for client compatibility.

### 3. **Authentication Standardization**  
Implement consistent Basic Auth across all servers.

## Conclusion

**Previous Assessment Correction**: The Rust servers are **fully functional and complete**. The HTTP server is correctly designed as a utility component, while the API server provides full session management.

**Current Status**: 4 out of 5 servers are **client-compatible**. Only missing terminal resize in Rust API and Swift servers.

**Impact**: Much lower than initially assessed. The main issues are:
1. **Terminal resize functionality** - causes 404s but client continues working
2. **Response format variations** - may cause field mapping issues
3. **Authentication inconsistencies** - different security models

The project has **solid API coverage** across all platforms with minor compatibility issues rather than fundamental implementation gaps.