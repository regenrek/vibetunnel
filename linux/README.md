# VibeTunnel Linux

A Linux implementation of VibeTunnel that provides remote terminal access via web browser, fully compatible with the macOS VibeTunnel app.

## Features

- 🖥️ **Remote Terminal Access**: Access your Linux terminal from any web browser
- 🔒 **Secure**: Optional password protection and localhost-only mode
- 🌐 **Network Ready**: Support for both localhost and network access modes
- 🔌 **ngrok Integration**: Easy external access via ngrok tunnels
- 📱 **Mobile Friendly**: Responsive web interface works on phones and tablets
- 🎬 **Session Recording**: All sessions recorded in asciinema format
- ⚡ **Real-time**: Live terminal streaming with proper escape sequence handling
- 🛠️ **CLI Compatible**: Full command-line interface for session management

## Quick Start

### Build from Source

```bash
# Clone the repository (if not already done)
git clone <repository-url>
cd vibetunnel/linux

# Build web assets and binary
make web build

# Start the server
./build/vibetunnel --serve
```

### Using the Pre-built Binary

```bash
# Download latest release
wget <release-url>
chmod +x vibetunnel

# Start server on localhost:4020
./vibetunnel --serve

# Or with password protection
./vibetunnel --serve --password mypassword

# Or accessible from network
./vibetunnel --serve --network
```

## Installation

### System-wide Installation

```bash
make install
```

### User Installation

```bash
make install-user
```

### As a Service (systemd)

```bash
make service-install
make service-enable
make service-start
```

## Usage

### Server Mode

Start the web server to access terminals via browser:

```bash
# Basic server (localhost only)
vibetunnel --serve

# Server with password protection
vibetunnel --serve --password mypassword

# Server accessible from network
vibetunnel --serve --network

# Custom port
vibetunnel --serve --port 8080

# With ngrok tunnel
vibetunnel --serve --ngrok --ngrok-token YOUR_TOKEN

# Disable terminal spawning (detached sessions only)
vibetunnel --serve --no-spawn
```

Access the dashboard at `http://localhost:4020` (or your configured port).

### Session Management

Create and manage terminal sessions:

```bash
# List all sessions
vibetunnel --list-sessions

# Create a new session
vibetunnel bash
vibetunnel --session-name "dev" zsh

# Send input to a session
vibetunnel --session-name "dev" --send-text "ls -la\n"
vibetunnel --session-name "dev" --send-key "C-c"

# Kill a session
vibetunnel --session-name "dev" --kill

# Clean up exited sessions
vibetunnel --cleanup-exited
```

### Configuration

VibeTunnel supports configuration files for persistent settings:

```bash
# Show current configuration
vibetunnel config

# Use custom config file
vibetunnel --config ~/.config/vibetunnel.yaml --serve
```

Example configuration file (`~/.vibetunnel/config.yaml`):

```yaml
control_path: /home/user/.vibetunnel/control
server:
  port: "4020"
  access_mode: "localhost"  # or "network"
  static_path: ""
  mode: "native"
security:
  password_enabled: true
  password: "mypassword"
ngrok:
  enabled: false
  auth_token: ""
advanced:
  debug_mode: false
  cleanup_startup: true
  preferred_terminal: "auto"
update:
  channel: "stable"
  auto_check: true
```

## Command Line Options

### Server Options
- `--serve`: Start HTTP server mode
- `--port, -p`: Server port (default: 4020)
- `--localhost`: Bind to localhost only (127.0.0.1)
- `--network`: Bind to all interfaces (0.0.0.0)
- `--static-path`: Custom path for web UI files

### Security Options
- `--password`: Dashboard password for Basic Auth
- `--password-enabled`: Enable password protection

### ngrok Integration
- `--ngrok`: Enable ngrok tunnel
- `--ngrok-token`: ngrok authentication token

### Session Management
- `--list-sessions`: List all sessions
- `--session-name`: Specify session name
- `--send-key`: Send key sequence to session
- `--send-text`: Send text to session
- `--signal`: Send signal to session
- `--stop`: Stop session (SIGTERM)
- `--kill`: Kill session (SIGKILL)
- `--cleanup-exited`: Clean up exited sessions

### Advanced Options
- `--debug`: Enable debug mode
- `--cleanup-startup`: Clean up sessions on startup
- `--server-mode`: Server mode (native, rust)
- `--no-spawn`: Disable terminal spawning (creates detached sessions only)
- `--control-path`: Control directory path
- `--config, -c`: Configuration file path

## Web Interface

The web interface provides:

- **Dashboard**: Overview of all terminal sessions
- **Terminal View**: Real-time terminal interaction
- **Session Management**: Start, stop, and manage sessions
- **File Browser**: Browse filesystem (if enabled)
- **Session Recording**: Playback of recorded sessions

## Compatibility

VibeTunnel Linux is designed to be 100% compatible with the macOS VibeTunnel app:

- **Same API**: Identical REST API and WebSocket endpoints
- **Same Web UI**: Uses the exact same web interface
- **Same Session Format**: Compatible asciinema recording format
- **Same Configuration**: Similar configuration options and structure

## Development

### Prerequisites

- Go 1.21 or later
- Node.js and npm (for web UI)
- Make

### Building

```bash
# Install dependencies
make deps

# Build web assets
make web

# Build binary
make build

# Run in development mode
make dev

# Run tests
make test

# Format and lint code
make check
```

### Project Structure

```
linux/
├── cmd/vibetunnel/     # Main application
├── pkg/
│   ├── api/           # HTTP server and API endpoints
│   ├── config/        # Configuration management
│   ├── protocol/      # Asciinema protocol implementation
│   └── session/       # Terminal session management
├── scripts/           # Build and utility scripts
├── Makefile          # Build system
└── README.md         # This file
```

## License

This project is part of the VibeTunnel ecosystem. See the main repository for license information.

## Contributing

Contributions are welcome! Please see the main VibeTunnel repository for contribution guidelines.

## Support

For support and questions:
1. Check the [main VibeTunnel documentation](../README.md)
2. Open an issue in the main repository
3. Check existing issues for known problems