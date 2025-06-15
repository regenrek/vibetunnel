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

Supported keys: `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`, `escape`, `enter`

### Cleanup

Remove stopped sessions:
```bash
tty-fwd --cleanup
```

Remove a specific session:
```bash
tty-fwd --session <session-id> --cleanup
```

## Options

- `--control-path`: Specify control directory location (default: `~/.vibetunnel/control`)
- `--session-name`: Name the session when creating
- `--session`: Target specific session by ID
- `--list-sessions`: List all sessions with metadata
- `--send-text`: Send text input to session
- `--send-key`: Send special key input to session
- `--cleanup`: Remove exited sessions

## License

Licensed under the Apache License, Version 2.0.