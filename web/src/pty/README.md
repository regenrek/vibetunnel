# PTY Module

A Node.js/TypeScript implementation for managing PTY (pseudo-terminal) sessions with automatic fallback to tty-fwd.

## Features

- **Native Node.js Implementation**: Uses `node-pty` for high-performance terminal management
- **Automatic Fallback**: Falls back to `tty-fwd` binary if node-pty is unavailable
- **Asciinema Recording**: Records terminal sessions in standard asciinema format
- **Session Persistence**: Sessions persist across restarts with metadata
- **Full Compatibility**: Drop-in replacement for existing tty-fwd integration
- **TypeScript Support**: Fully typed interfaces and error handling

## Quick Start

```typescript
import { PtyService } from './pty/index.js';

// Create service with auto-detection
const ptyService = new PtyService({
  implementation: 'auto',
  fallbackToTtyFwd: true,
});

// Create a session
const result = await ptyService.createSession(['bash'], {
  sessionName: 'my-session',
  workingDir: '/home/user',
  cols: 80,
  rows: 24,
});

console.log(`Created session: ${result.sessionId}`);

// Send input to session
ptyService.sendInput(result.sessionId, { text: 'echo hello\n' });

// List all sessions
const sessions = ptyService.listSessions();

// Cleanup session
ptyService.cleanupSession(result.sessionId);
```

## Configuration

Configure the service via constructor options or environment variables:

```typescript
const ptyService = new PtyService({
  implementation: 'node-pty', // 'node-pty' | 'tty-fwd' | 'auto'
  controlPath: '/custom/path', // Session storage directory
  fallbackToTtyFwd: true, // Enable fallback to tty-fwd
  ttyFwdPath: '/path/to/tty-fwd', // Custom tty-fwd binary path
});
```

### Environment Variables

- `PTY_IMPLEMENTATION`: Implementation to use ('node-pty', 'tty-fwd', 'auto')
- `TTY_FWD_CONTROL_DIR`: Control directory path (default: ~/.vibetunnel/control)
- `PTY_FALLBACK_TTY_FWD`: Enable fallback ('true' or 'false')
- `TTY_FWD_PATH`: Path to tty-fwd binary

## API Reference

### PtyService

Main service class providing unified PTY management.

#### Methods

##### `createSession(command: string[], options?: SessionOptions): Promise<SessionCreationResult>`

Creates a new PTY session.

**Parameters:**

- `command`: Array of command and arguments to execute
- `options`: Optional session configuration

**Returns:** Promise resolving to session ID and info

**Example:**

```typescript
const result = await ptyService.createSession(['vim', 'file.txt'], {
  sessionName: 'vim-session',
  workingDir: '/home/user/projects',
  term: 'xterm-256color',
  cols: 120,
  rows: 30,
});
```

##### `sendInput(sessionId: string, input: SessionInput): void`

Sends input to a session.

**Parameters:**

- `sessionId`: Target session ID
- `input`: Text or special key input

**Example:**

```typescript
// Send text
ptyService.sendInput(sessionId, { text: 'hello world\n' });

// Send special key
ptyService.sendInput(sessionId, { key: 'arrow_up' });
```

**Supported special keys:**

- `arrow_up`, `arrow_down`, `arrow_left`, `arrow_right`
- `escape`, `enter`, `ctrl_enter`, `shift_enter`

##### `listSessions(): SessionEntryWithId[]`

Lists all sessions with metadata.

##### `getSession(sessionId: string): SessionEntryWithId | null`

Gets specific session by ID.

##### `killSession(sessionId: string, signal?: string | number): Promise<void>`

Terminates a session and waits for the process to actually be killed.

**Parameters:**

- `sessionId`: Session to terminate
- `signal`: Signal to send (default: 'SIGTERM')

**Returns:** Promise that resolves when the process is actually terminated

**Process:**

1. Sends SIGTERM initially
2. Waits up to 3 seconds (checking every 500ms)
3. Sends SIGKILL if process doesn't terminate gracefully
4. Resolves when process is confirmed dead

##### `cleanupSession(sessionId: string): void`

Removes session and cleans up files.

##### `cleanupExitedSessions(): string[]`

Removes all exited sessions and returns cleaned session IDs.

##### `resizeSession(sessionId: string, cols: number, rows: number): void`

Resizes session terminal (node-pty only).

#### Status Methods

##### `getCurrentImplementation(): string`

Returns current implementation ('node-pty' or 'tty-fwd').

##### `isUsingNodePty(): boolean`

Returns true if using node-pty implementation.

##### `isUsingTtyFwd(): boolean`

Returns true if using tty-fwd implementation.

##### `getActiveSessionCount(): number`

Returns number of active sessions.

##### `getControlPath(): string`

Returns session storage directory path.

##### `getConfig(): PtyConfig`

Returns current configuration.

## Session File Structure

Sessions are stored in a directory structure compatible with tty-fwd:

```
~/.vibetunnel/control/
├── session-uuid-1/
│   ├── session.json          # Session metadata
│   ├── stream-out           # Asciinema recording
│   ├── stdin                # Input pipe/file
│   └── notification-stream  # Event notifications
└── session-uuid-2/
    └── ...
```

### session.json Format

```json
{
  "cmdline": ["bash", "-l"],
  "name": "my-session",
  "cwd": "/home/user",
  "pid": 1234,
  "status": "running",
  "exit_code": null,
  "started_at": "2023-12-01T10:00:00.000Z",
  "term": "xterm-256color",
  "spawn_type": "pty"
}
```

### Asciinema Format

The `stream-out` file follows the [asciinema file format](https://github.com/asciinema/asciinema/blob/develop/doc/asciicast-v2.md):

```
{"version": 2, "width": 80, "height": 24, "timestamp": 1609459200, "env": {"SHELL": "/bin/bash", "TERM": "xterm-256color"}}
[0.248848, "o", "\u001b]0;user@host: ~\u0007\u001b[01;32muser@host\u001b[00m:\u001b[01;34m~\u001b[00m$ "]
[1.001376, "o", "h"]
[1.064593, "o", "e"]
```

## Integration with Existing Server

### Drop-in Replacement

Replace existing tty-fwd calls with the PTY service:

```typescript
// Before (tty-fwd)
const proc = spawn(ttyFwdPath, ['--control-path', controlPath, '--', ...command]);

// After (PTY service)
const result = await ptyService.createSession(command, options);
```

### Express.js Route Integration

```typescript
import { PtyService } from './pty/index.js';

const ptyService = new PtyService();

// POST /api/sessions
app.post('/api/sessions', async (req, res) => {
  try {
    const { command, workingDir } = req.body;
    const result = await ptyService.createSession(command, { workingDir });
    res.json({ sessionId: result.sessionId });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// GET /api/sessions
app.get('/api/sessions', (req, res) => {
  const sessions = ptyService.listSessions();
  res.json(sessions);
});

// POST /api/sessions/:id/input
app.post('/api/sessions/:id/input', (req, res) => {
  const { text, key } = req.body;
  ptyService.sendInput(req.params.id, { text, key });
  res.json({ success: true });
});
```

## Error Handling

All methods throw `PtyError` instances with structured error information:

```typescript
try {
  await ptyService.createSession(['invalid-command']);
} catch (error) {
  if (error instanceof PtyError) {
    console.error(`PTY Error [${error.code}]: ${error.message}`);
    if (error.sessionId) {
      console.error(`Session ID: ${error.sessionId}`);
    }
  }
}
```

## Testing

Run the test suite:

```bash
npm test src/pty/__tests__/
```

The tests automatically detect the available implementation and test accordingly.

## Performance Considerations

### Node.js Implementation

- **Memory Usage**: ~10-20MB per active session
- **CPU Overhead**: Minimal, event-driven
- **Latency**: < 5ms for input/output operations
- **Concurrency**: Supports 50+ concurrent sessions

### tty-fwd Fallback

- **Subprocess Overhead**: ~2-5ms per operation
- **Memory Usage**: Minimal for service, ~5-10MB per session
- **Compatibility**: Works on all platforms where tty-fwd runs

## Migration Guide

### From Direct tty-fwd Usage

1. **Replace Binary Calls**:

   ```typescript
   // Old
   spawn('tty-fwd', ['--control-path', path, '--list-sessions']);

   // New
   ptyService.listSessions();
   ```

2. **Update Session Creation**:

   ```typescript
   // Old
   spawn('tty-fwd', ['--control-path', path, '--', ...command]);

   // New
   await ptyService.createSession(command);
   ```

3. **Modernize Input Handling**:

   ```typescript
   // Old
   spawn('tty-fwd', ['--session', id, '--send-text', text]);

   // New
   ptyService.sendInput(id, { text });
   ```

### Environment Variables

Set environment variables to control behavior:

```bash
# Force node-pty usage
export PTY_IMPLEMENTATION=node-pty

# Force tty-fwd usage
export PTY_IMPLEMENTATION=tty-fwd

# Auto-detect (default)
export PTY_IMPLEMENTATION=auto

# Disable fallback
export PTY_FALLBACK_TTY_FWD=false
```

## Troubleshooting

### Common Issues

**"node-pty not available"**

- Install dependencies: `npm install node-pty`
- Check platform compatibility
- Enable fallback: `PTY_FALLBACK_TTY_FWD=true`

**"tty-fwd binary not found"**

- Set path: `TTY_FWD_PATH=/path/to/tty-fwd`
- Ensure binary is in PATH
- Check file permissions

**Permission errors**

- Verify control directory permissions
- Check PTY device access
- Run with appropriate user privileges

**Session not found**

- Check session ID validity
- Verify control directory path
- Ensure session hasn't been cleaned up

### Debug Logging

Enable debug logging to troubleshoot issues:

```typescript
// Log current implementation
console.log('Using:', ptyService.getCurrentImplementation());

// Log configuration
console.log('Config:', ptyService.getConfig());

// Log active sessions
console.log('Active sessions:', ptyService.getActiveSessionCount());
```

## Contributing

When adding features or fixing bugs:

1. **Add Tests**: Ensure new functionality is tested
2. **Update Types**: Keep TypeScript interfaces current
3. **Maintain Compatibility**: Preserve tty-fwd compatibility
4. **Document Changes**: Update this README and code comments

## License

Licensed under the same license as the parent project.
