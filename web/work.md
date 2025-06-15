# VibeTunnel Web Frontend - Project Documentation

## Project Overview
A web-based terminal multiplexer frontend that interfaces with `tty-fwd` binary to create, manage, and interact with terminal sessions through a browser interface.

## Current Status: ✅ FULLY FUNCTIONAL

### ✅ Completed Features
1. **Session Creation** - Create new terminal sessions with custom commands and working directories
2. **Session Listing** - View all active sessions with metadata (command, status, directory, etc.)
3. **Real-time Terminal Streaming** - Live terminal output via Server-Sent Events (SSE)
4. **Input Handling** - Send commands to sessions via HTTP POST using `tty-fwd --send-text`
5. **Session Termination** - Kill sessions with process cleanup and file removal
6. **Directory Browser** - Browse and select working directories for new sessions
7. **Hot Reload** - Development-time auto-refresh on code changes
8. **Asciinema Integration** - Terminal output displayed using asciinema player

## Architecture

### Backend (`src/server.ts`)
- **Express.js** server with TypeScript
- **node-pty** for spawning tty-fwd in pseudo-terminal environment
- **chokidar** for file watching and hot reload
- **Control Directory**: `~/.vibetunnel` (where tty-fwd stores session data)

#### API Endpoints:
- `GET /api/sessions` - List all sessions with metadata and last output
- `POST /api/sessions` - Create new session
- `DELETE /api/sessions/:id` - Kill session and cleanup files
- `GET /api/stream/:id` - SSE endpoint for real-time terminal output streaming
- `POST /api/input/:id` - Send text input to session
- `GET /api/ls?dir=path` - Directory browsing for file picker

#### tty-fwd Integration:
- **Session Creation**: `tty-fwd --control-path ~/.vibetunnel --session-name <name> -- <command>`
- **Input Sending**: `tty-fwd --control-path ~/.vibetunnel --session <id> --send-text "<text>"`
- **Session Listing**: `tty-fwd --control-path ~/.vibetunnel --list-sessions`
- **Cleanup**: `tty-fwd --control-path ~/.vibetunnel --session <id> --cleanup`

### Frontend (`src/client/app.ts`)
- **TypeScript** compiled to vanilla JavaScript
- **Single-page application** with hash-based routing (`#` vs `#terminal/sessionId`)
- **Asciinema Player** for terminal rendering
- **EventSource** for SSE real-time streaming
- **Fetch API** for REST operations

#### Key Classes:
- `VibeTunnelApp` - Main application controller
- `ProcessMetadata` - Interface for session data
- `CastEvent` - Interface for asciinema events

#### UI Components:
- **Process List Page** - Shows all sessions with create form and kill buttons
- **Terminal Page** - Individual session view with asciinema player and input field
- **Directory Browser Modal** - File system navigation for working directory selection

### Styling (`public/output.css`)
- **Tailwind CSS** with terminal color scheme
- **Terminal colors**: green, cyan, yellow, red, blue for status indicators
- **Responsive design** with mobile-friendly modals

## Development Setup

### Dependencies
```json
{
  "express": "^4.18.2",
  "ws": "^8.14.2", 
  "chokidar": "^3.5.3",
  "node-pty": "^1.0.0",
  "typescript": "^5.2.2",
  "tsx": "^4.6.2",
  "tailwindcss": "^3.3.6",
  "concurrently": "^8.2.2"
}
```

### Build Scripts
- `npm run dev` - Start all development processes (server, client, CSS)
- `npm run dev:server` - Start server with hot reload (`tsx watch src/server.ts`)
- `npm run dev:client` - TypeScript compilation watch mode
- `npm run dev:css` - Tailwind CSS watch mode
- `npm run build` - Production build

### File Structure
```
/web/
├── src/
│   ├── server.ts          # Express server with tty-fwd integration
│   ├── client/
│   │   └── app.ts         # Frontend TypeScript application
│   └── input.css          # Tailwind CSS source
├── public/
│   ├── index.html         # Main HTML with terminal UI structure
│   ├── app.js             # Compiled TypeScript output
│   ├── output.css         # Compiled Tailwind CSS
│   └── app.js.map         # Source maps
├── package.json           # Dependencies and scripts
├── tsconfig.json          # Server TypeScript config
├── tsconfig.client.json   # Client TypeScript config
└── tailwind.config.js     # Tailwind configuration
```

## Key Implementation Details

### Session Creation Flow
1. Frontend sends `POST /api/sessions` with `{command: ["bash"], workingDir: "~/"}`
2. Server generates unique session name: `session_${timestamp}_${random}`
3. Server spawns: `pty.spawn('bash', ['-c', 'tty-fwd --control-path ~/.vibetunnel --session-name <name> -- <command>'])`
4. Session persists in `~/.vibetunnel/<uuid>/` with `session.json`, `stream-out`, `stdin` files

### Real-time Streaming
1. Frontend opens `EventSource('/api/stream/sessionId')`
2. Server reads existing `stream-out` file and sends all lines as SSE
3. Server watches file with `chokidar` and streams new content as it's written
4. Frontend parses each line as asciinema cast event and updates player

### Input Handling
1. Frontend sends `POST /api/input/sessionId` with `{text: "command"}`
2. Server executes: `tty-fwd --control-path ~/.vibetunnel --session <id> --send-text "<command>"`
3. Input appears in terminal and output streams back via SSE

### Session Termination
1. Frontend sends `DELETE /api/sessions/sessionId`
2. Server lists sessions to get PID, kills process with SIGTERM then SIGKILL
3. Server runs cleanup: `tty-fwd --control-path ~/.vibetunnel --session <id> --cleanup`
4. Frontend refreshes session list and navigates away if needed

## Current Issues/Limitations
- **None currently** - System is fully functional for basic terminal multiplexing

## Future Enhancements (Not Implemented)
- Session persistence across server restarts
- User authentication and session isolation
- Terminal resizing support
- File upload/download from sessions
- Session sharing/collaboration
- Terminal themes and customization
- Session search and filtering
- Keyboard shortcuts and hotkeys
- Session groups/workspaces

## External Dependencies
- **tty-fwd binary** at `../tty-fwd/target/release/tty-fwd` (relative to web directory)
- **Asciinema Player** loaded from CDN for terminal rendering
- **Tailwind CSS** classes for styling

## Testing
The system has been manually tested and confirmed working for:
- ✅ Creating sessions with various commands (`bash`, `echo "test"`, complex commands)
- ✅ Real-time terminal output streaming
- ✅ Sending input to sessions
- ✅ Killing sessions and cleanup
- ✅ Directory browsing and working directory selection
- ✅ Hot reload during development

## Notes for Continuation
- Server runs on `http://localhost:3000`
- All session data stored in `~/.vibetunnel/`
- Frontend uses hash routing for SPA navigation
- TypeScript auto-compiles on save during development
- System ready for production deployment with `npm run build`