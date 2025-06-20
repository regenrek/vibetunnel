# VibeTunnel Server Specification

This document provides a comprehensive specification of the VibeTunnel server architecture, including PTY management, terminal state management, distributed HQ mode, and all protocols. This specification is designed to enable implementation in any programming language.

## Table of Contents

1. [Overview](#overview)
2. [Server Modes](#server-modes)
3. [Authentication](#authentication)
4. [Session Management](#session-management)
5. [Terminal Management](#terminal-management)
6. [Binary Buffer Protocol](#binary-buffer-protocol)
7. [Stream Format](#stream-format)
8. [API Endpoints](#api-endpoints)
9. [WebSocket Protocols](#websocket-protocols)
10. [HQ Mode Architecture](#hq-mode-architecture)
11. [File System Structure](#file-system-structure)

## Overview

VibeTunnel is a terminal session management server that provides:
- Remote terminal session creation and management
- Real-time terminal output streaming
- Session persistence and replay
- Distributed architecture with HQ mode for managing multiple servers
- Binary-optimized terminal buffer synchronization

## Server Modes

The server can operate in three modes:

### 1. Normal Mode (Default)
- Standalone server managing local terminal sessions
- Optional Basic Authentication
- No connection to other servers

### 2. HQ Mode (`--hq` flag)
- Acts as a headquarters server managing multiple remote servers
- Aggregates sessions from all registered remotes
- Proxies API requests to appropriate remote servers
- Maintains health checks on all remotes

### 3. Remote Mode (`--hq-url` flag)
- Registers with an HQ server
- Accepts both Basic Auth and Bearer token authentication
- Operates independently if HQ is unavailable
- Provides all normal mode functionality

## Authentication

### Configuration

#### Environment Variables
- `VIBETUNNEL_USERNAME` - Username for Basic Authentication
- `VIBETUNNEL_PASSWORD` - Password for Basic Authentication
- Both must be provided together or neither

#### Command Line Arguments
- `--username` - Local server username (overrides env var)
- `--password` - Local server password (overrides env var)
- `--hq-url` - URL of HQ server to register with (enables remote mode)
- `--hq-username` - Username for authenticating with HQ
- `--hq-password` - Password for authenticating with HQ
- `--name` - Unique name for this remote server (required with --hq-url)

### Authentication Flow

#### Basic Authentication
- Standard HTTP Basic Auth: `Authorization: Basic base64(username:password)`
- Used by clients to authenticate with any server
- Used by remote servers to authenticate with HQ during registration

#### Bearer Token Authentication
- Format: `Authorization: Bearer <token>`
- Remote servers generate a unique token (UUID v4) during registration
- HQ uses this token for all API calls to the remote
- Remote servers accept both Basic Auth and Bearer token

### Authentication Middleware
1. Skip auth if not configured (no username/password and not in remote mode)
2. Skip auth for WebSocket upgrade requests (handled separately)
3. Check Bearer token first if server is in remote mode
4. Fall back to Basic Auth check
5. Return 401 Unauthorized with `WWW-Authenticate: Basic realm="VibeTunnel"` if failed

## Session Management

### Session States
- `starting` - Session is being created
- `running` - Session is active
- `exited` - Session has terminated

### Session Data Structure
```typescript
interface Session {
  id: string;              // UUID v4
  name: string;            // User-friendly name
  command: string;         // Command line as string
  workingDir: string;      // Working directory path
  status: string;          // Session state
  exitCode?: number;       // Exit code if exited
  startedAt: string;       // ISO 8601 timestamp
  lastModified: string;    // ISO 8601 timestamp
  pid?: number;            // Process ID
  waiting?: boolean;       // If waiting for input
  remoteName?: string;     // Name of remote server (HQ mode)
}
```

### PTY Service

The PTY service manages the actual terminal processes using `node-pty`:

```typescript
interface PtyConfig {
  implementation: 'node-pty';
  controlPath: string;     // Base directory for session data
}
```

Key responsibilities:
- Create PTY sessions with specified dimensions
- Manage session lifecycle (create, kill, cleanup)
- Handle input/output to/from PTY
- Resize terminal dimensions
- Track session metadata

## Terminal Management

The Terminal Manager maintains server-side terminal state for efficient buffer synchronization:

### Terminal State
```typescript
interface TerminalState {
  cols: number;           // Terminal width
  rows: number;           // Terminal height
  buffer: string[][];     // 2D array of [char, style] pairs
  cursor: {
    x: number;
    y: number;
    visible: boolean;
  };
  scrollback: string[][]; // Historical lines
  title: string;          // Terminal title
  applicationKeypad: boolean;
  applicationCursor: boolean;
  bracketedPasteMode: boolean;
  origin: boolean;
  reverseWraparound: boolean;
  wraparound: boolean;
  insertMode: boolean;
}
```

### Buffer Management
1. Parse ANSI escape sequences from PTY output
2. Update terminal state based on control sequences
3. Maintain accurate buffer representation
4. Support terminal operations:
   - Cursor movement
   - Text insertion/deletion
   - Screen clearing
   - Scrolling
   - Style changes

## Binary Buffer Protocol

The binary buffer protocol provides efficient terminal state synchronization:

### Snapshot Encoding
```
[4 bytes: magic "SNAP"]
[4 bytes: version (1)]
[4 bytes: cols]
[4 bytes: rows]
[4 bytes: cursor X]
[4 bytes: cursor Y]
[1 byte: cursor visible]
[4 bytes: scrollback length]
[scrollback data...]
[4 bytes: buffer length]
[buffer data...]
[4 bytes: title length]
[title UTF-8 bytes]
[1 byte: flags]
  - bit 0: applicationKeypad
  - bit 1: applicationCursor
  - bit 2: bracketedPasteMode
  - bit 3: origin
  - bit 4: reverseWraparound
  - bit 5: wraparound
  - bit 6: insertMode
```

### Line Encoding
Each line is encoded as:
```
[4 bytes: line length]
[4 bytes: number of cells]
[cell data...]
```

### Cell Encoding
Each cell is encoded as:
```
[4 bytes: character UTF-8 length]
[character UTF-8 bytes]
[4 bytes: style]
```

Style is a 32-bit integer:
- Bits 0-7: Foreground color (256 colors)
- Bits 8-15: Background color (256 colors)
- Bit 16: Bold
- Bit 17: Italic
- Bit 18: Underline
- Bit 19: Blink
- Bit 20: Inverse
- Bit 21: Hidden
- Bit 22: Strikethrough

## Stream Format

Session output is stored in asciicast v2 format:

### Header
```json
{
  "version": 2,
  "width": 80,
  "height": 24,
  "timestamp": 1234567890,
  "env": {"TERM": "xterm-256color"}
}
```

### Events
Each subsequent line is an event:
```json
[timestamp, type, data]
```

Types:
- `"o"` - Output data (UTF-8 string)
- `"i"` - Input data (UTF-8 string)
- `"r"` - Resize event (e.g., "80x24")

## API Endpoints

### Health Check
```
GET /api/health
Response: {"status": "ok", "timestamp": "2024-01-01T00:00:00.000Z"}
```

### Session Management

#### List Sessions
```
GET /api/sessions
Response: Session[]
```

In HQ mode, aggregates sessions from all registered remotes.

#### Create Session
```
POST /api/sessions
Body: {
  "command": ["bash", "-l"],
  "workingDir": "/home/user",
  "name": "My Session",
  "remoteId": "remote-uuid"  // Optional, HQ mode only
}
Response: {"sessionId": "uuid"}
```

#### Get Session Info
```
GET /api/sessions/:sessionId
Response: Session
```

#### Kill Session
```
DELETE /api/sessions/:sessionId
Response: {"success": true, "message": "Session killed"}
```

#### Cleanup Session
```
DELETE /api/sessions/:sessionId/cleanup
Response: {"success": true, "message": "Session cleaned up"}
```

#### Cleanup All Exited
```
POST /api/cleanup-exited
Response: {
  "success": true,
  "message": "N exited sessions cleaned up across all servers",
  "localCleaned": 5,
  "remoteResults": [
    {"remoteName": "server1", "cleaned": 3},
    {"remoteName": "server2", "cleaned": 2, "error": "timeout"}
  ]
}
```

### Terminal I/O

#### Stream Session Output (SSE)
```
GET /api/sessions/:sessionId/stream
Response: Server-Sent Events stream
```

Event format:
```
event: output
data: {"data": "terminal output...", "timestamp": 1234567890}

event: exit
data: {"exitCode": 0}
```

#### Get Session Snapshot
```
GET /api/sessions/:sessionId/snapshot
Response: Optimized asciicast v2 format (text/plain)
```

Returns events after the last clear screen command.

#### Get Buffer Stats
```
GET /api/sessions/:sessionId/buffer/stats
Response: {
  "lines": 100,
  "cells": 8000,
  "scrollbackLines": 500,
  "lastModified": "2024-01-01T00:00:00.000Z"
}
```

#### Get Buffer
```
GET /api/sessions/:sessionId/buffer?format=binary
Response: Binary encoded buffer (application/octet-stream)

GET /api/sessions/:sessionId/buffer?format=json
Response: JSON representation of terminal state
```

#### Send Input
```
POST /api/sessions/:sessionId/input
Body: {"text": "ls -la\n"}
Response: {"success": true}
```

Special keys:
- `"arrow_up"`, `"arrow_down"`, `"arrow_left"`, `"arrow_right"`
- `"escape"`, `"enter"`, `"ctrl_enter"`, `"shift_enter"`

#### Resize Terminal
```
POST /api/sessions/:sessionId/resize
Body: {"cols": 120, "rows": 40}
Response: {"success": true, "cols": 120, "rows": 40}
```

### File System

#### Browse Directory
```
GET /api/fs/browse?path=/home/user
Response: {
  "absolutePath": "/home/user",
  "files": [
    {
      "name": "document.txt",
      "created": "2024-01-01T00:00:00.000Z",
      "lastModified": "2024-01-01T00:00:00.000Z",
      "size": 1024,
      "isDir": false
    }
  ]
}
```

#### Create Directory
```
POST /api/mkdir
Body: {"path": "/home/user", "name": "newfolder"}
Response: {
  "success": true,
  "path": "/home/user/newfolder",
  "message": "Directory 'newfolder' created successfully"
}
```

### HQ Mode Endpoints

#### Register Remote
```
POST /api/remotes/register
Headers: Authorization: Basic <hq-credentials>
Body: {
  "id": "remote-uuid",
  "name": "unique-remote-name",
  "url": "http://remote-server:4020",
  "token": "bearer-token-uuid"
}
Response: {
  "success": true,
  "remote": {"id": "remote-uuid", "name": "unique-remote-name"}
}
```

#### Unregister Remote
```
DELETE /api/remotes/:remoteId
Headers: Authorization: Basic <hq-credentials>
Response: {"success": true}
```

#### List Remotes
```
GET /api/remotes
Response: [
  {
    "id": "remote-uuid",
    "name": "unique-remote-name",
    "url": "http://remote-server:4020",
    "sessionCount": 5,
    "lastHeartbeat": "2024-01-01T00:00:00.000Z"
  }
]
```

## WebSocket Protocols

### Buffer Synchronization WebSocket

Endpoint: `/buffers`

#### Client → Server Messages

Subscribe to session:
```json
{"type": "subscribe", "sessionId": "session-uuid"}
```

Unsubscribe from session:
```json
{"type": "unsubscribe", "sessionId": "session-uuid"}
```

Heartbeat response:
```json
{"type": "pong"}
```

#### Server → Client Messages

Heartbeat:
```json
{"type": "ping"}
```

Error:
```json
{"type": "error", "message": "Error description"}
```

Binary buffer update:
```
[1 byte: 0xBF magic byte]
[4 bytes: session ID length (little-endian)]
[N bytes: session ID UTF-8]
[M bytes: encoded buffer snapshot]
```

## HQ Mode Architecture

### Remote Registration
1. Remote server starts with `--hq-url`, `--hq-username`, `--hq-password`, `--name`
2. Remote generates unique ID (UUID v4) and token (UUID v4)
3. Remote sends POST to `/api/remotes/register` with Basic Auth
4. HQ validates unique name and stores remote info
5. Remote registration is complete

### Health Checking
1. HQ checks each remote every 15 seconds
2. First tries GET `/api/health` with Bearer token
3. Falls back to GET `/api/sessions` if health endpoint not found
4. Updates session tracking from sessions response
5. Removes remote if health check fails

### Request Proxying
1. Session proxy middleware intercepts requests with session IDs
2. Looks up which remote owns the session
3. Forwards request to remote with Bearer token auth
4. Returns remote's response to client

### Session Aggregation
1. GET `/api/sessions` in HQ mode fetches from all remotes
2. Adds `remoteName` field to each session
3. Tracks session ownership for future proxying
4. Returns combined list sorted by last modified

## File System Structure

```
~/.vibetunnel/control/
├── {session-id}/
│   ├── info.json       # Session metadata
│   ├── stream-out      # Asciicast v2 format output
│   └── stream-in       # Input log (optional)
```

### info.json Structure
```json
{
  "version": 1,
  "session_id": "uuid",
  "name": "Session Name",
  "cmdline": ["bash", "-l"],
  "cwd": "/home/user",
  "env": {},
  "term": "xterm-256color",
  "width": 80,
  "height": 24,
  "started_at": "2024-01-01T00:00:00.000Z",
  "pid": 12345,
  "status": "running",
  "exit_code": null
}
```

## Implementation Notes

### Error Handling
- All endpoints should return appropriate HTTP status codes
- Error responses should include `{"error": "Description"}`
- WebSocket errors should send error message before closing

### Security Considerations
- HTTPS required for HQ URL
- Tokens should be cryptographically random (UUID v4)
- File system access restricted to home directory and temp
- Input validation on all user-provided paths

### Performance Considerations
- Stream files are append-only for efficiency
- Binary buffer protocol minimizes data transfer
- Health checks have 5-second timeout
- Proxy requests have 30-second timeout
- Buffer updates are debounced to avoid flooding

### Compatibility
- UTF-8 encoding throughout
- Little-endian byte order for binary protocol
- ISO 8601 timestamps in UTC
- Line endings normalized to LF (\n)