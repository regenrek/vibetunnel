# tty-fwd

`tty-fwd` is a utility to capture TTY sessions and forward them. It spawns processes in a pseudo-TTY and records their output in asciinema format while providing remote control capabilities.

## Features

- **Session Management**: Create, list, and manage TTY sessions
- **Remote Control**: Send text and key inputs to running sessions
- **Output Recording**: Records sessions in asciinema format for playback
- **Session Persistence**: Sessions persist in control directories with metadata
- **Process Monitoring**: Tracks process status and exit codes

## Usage

### Basic Usage

Spawn a command in a TTY session:
```bash
tty-fwd -- bash
```

### Session Management

List all sessions:
```bash
tty-fwd --list-sessions
```

Create a named session:
```bash
tty-fwd --session-name "my-session" -- vim
```

### Remote Control

Send text to a session:
```bash
tty-fwd --session <session-id> --send-text "hello world"
```

Send special keys:
```bash
tty-fwd --session <session-id> --send-key enter
tty-fwd --session <session-id> --send-key arrow_up
```

Supported keys: `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`, `escape`, `enter`, `ctrl_enter`, `shift_enter`

### Process Control

Stop a session gracefully:
```bash
tty-fwd --session <session-id> --stop
```

Kill a session forcefully:
```bash
tty-fwd --session <session-id> --kill
```

Send custom signal to session:
```bash
tty-fwd --session <session-id> --signal <number>
```

### HTTP API Server

Start HTTP server for remote session management:
```bash
tty-fwd --serve 8080
```

Start server with static file serving:
```bash
tty-fwd --serve 127.0.0.1:8080 --static-path ./web
```

### Cleanup

Remove stopped sessions:
```bash
tty-fwd --cleanup
```

Remove a specific session:
```bash
tty-fwd --session <session-id> --cleanup
```

## HTTP API

When running with `--serve`, the following REST API endpoints are available:

### Session Management

- **GET /api/sessions** - List all sessions with metadata
- **POST /api/sessions** - Create new session (body: `{"command": ["cmd", "args"], "workingDir": "/path"}`)
- **DELETE /api/sessions/{session-id}** - Kill session
- **DELETE /api/sessions/{session-id}/cleanup** - Clean up specific session
- **POST /api/cleanup-exited** - Clean up all exited sessions

### Session Interaction

- **GET /api/sessions/{session-id}/stream** - Real-time session output (Server-Sent Events)
- **GET /api/sessions/{session-id}/snapshot** - Current session output snapshot
- **POST /api/sessions/{session-id}/input** - Send input to session (body: `{"text": "input"}`)

### File System Operations

- **POST /api/mkdir** - Create directory (body: `{"path": "/path/to/directory"}`)

### Static Files

- **GET /** - Serves static files from `--static-path` directory

## Options

- `--control-path`: Specify control directory location (default: `~/.vibetunnel/control`)
- `--session-name`: Name the session when creating
- `--session`: Target specific session by ID
- `--list-sessions`: List all sessions with metadata
- `--send-text`: Send text input to session
- `--send-key`: Send special key input to session
- `--signal`: Send custom signal to session process
- `--stop`: Send SIGTERM to session (graceful stop)
- `--kill`: Send SIGKILL to session (force kill)
- `--serve`: Start HTTP API server on specified address/port
- `--static-path`: Directory to serve static files from (requires --serve)
- `--cleanup`: Remove exited sessions
- `--password`: Enables an HTTP basic auth password (username is ignored)

## License

Licensed under the Apache License, Version 2.0.