# VibeTunnel

VibeTunnel is a macOS application that bridges terminal applications to the web, enabling remote control of terminal tools from anywhere. It creates secure tunnels between local terminal sessions and web browsers, making it possible to access and control command-line applications like Claude Code remotely.

## Architecture Overview

VibeTunnel employs a multi-layered architecture designed for flexibility, security, and ease of use:

```
┌─────────────────────────────────────────────────────────┐
│                   Web Browser (Client)                   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  TypeScript/JavaScript Frontend                  │   │
│  │  - Asciinema Player for Terminal Rendering      │   │
│  │  - WebSocket for Real-time Updates              │   │
│  │  - Tailwind CSS for UI                          │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                            ↕ HTTPS/WebSocket
┌─────────────────────────────────────────────────────────┐
│                    HTTP Server Layer                     │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Dual Implementation:                            │   │
│  │  1. Hummingbird Server (Swift)                  │   │
│  │  2. Rust Server (tty-fwd binary)                │   │
│  │  - REST APIs for session management              │   │
│  │  - WebSocket streaming for terminal I/O         │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                            ↕
┌─────────────────────────────────────────────────────────┐
│                 macOS Application (Swift)                │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Core Components:                                │   │
│  │  - ServerManager: Orchestrates server lifecycle  │   │
│  │  - SessionMonitor: Tracks active sessions       │   │
│  │  - TTYForwardManager: Handles TTY forwarding    │   │
│  │  - TerminalManager: Terminal operations         │   │
│  │  - NgrokService: Optional tunnel exposure       │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  UI Layer (SwiftUI):                            │   │
│  │  - MenuBarView: System menu bar integration     │   │
│  │  - SettingsView: Configuration interface        │   │
│  │  - ServerConsoleView: Diagnostics & logs        │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Core Components

### 1. **Native macOS Application**

The main application is built with Swift and SwiftUI, providing:

- **Menu Bar Integration**: Lives in the system menu bar with optional dock mode
- **Server Lifecycle Management**: Controls starting, stopping, and switching between server implementations
- **System Integration**: Launch at login, single instance enforcement, application mover
- **Auto-Updates**: Sparkle framework integration for seamless updates

Key files:
- `VibeTunnel/VibeTunnelApp.swift`: Main application entry point
- `VibeTunnel/Services/ServerManager.swift`: Orchestrates server operations
- `VibeTunnel/Models/TunnelSession.swift`: Core session model

### 2. **HTTP Server Layer**

VibeTunnel offers two server implementations that can be switched at runtime:

#### **Hummingbird Server (Swift)**
- Built-in Swift implementation using the Hummingbird framework
- Native integration with the macOS app
- RESTful APIs for session management
- File: `VibeTunnel/Services/HummingbirdServer.swift`

#### **Rust Server (tty-fwd)**
- External binary written in Rust for high-performance TTY forwarding
- Spawns and manages terminal processes
- Records sessions in asciinema format
- WebSocket streaming for real-time terminal I/O
- Source: `rust/tty-fwd/` directory

Both servers expose similar APIs:
- `POST /sessions`: Create new terminal session
- `GET /sessions`: List active sessions
- `GET /sessions/:id`: Get session details
- `POST /sessions/:id/send`: Send input to terminal
- `GET /sessions/:id/output`: Stream terminal output
- `DELETE /sessions/:id`: Terminate session

### 3. **Web Frontend**

A modern web interface for terminal interaction:

- **Terminal Rendering**: Uses asciinema player for accurate terminal display
- **Real-time Updates**: WebSocket connections for live terminal output
- **Responsive Design**: Tailwind CSS for mobile-friendly interface
- **Session Management**: Create, list, and control multiple terminal sessions

Key files:
- `web/`: Frontend source code
- `VibeTunnel/Resources/WebRoot/`: Bundled static assets

## Session Management Flow

1. **Session Creation**:
   ```
   Client → POST /sessions → Server spawns terminal process → Returns session ID
   ```

2. **Command Execution**:
   ```
   Client → POST /sessions/:id/send → Server writes to PTY → Process executes
   ```

3. **Output Streaming**:
   ```
   Process → PTY output → Server captures → WebSocket/HTTP stream → Client renders
   ```

4. **Session Termination**:
   ```
   Client → DELETE /sessions/:id → Server kills process → Cleanup resources
   ```

## Key Features

### Security & Tunneling
- **Ngrok Integration**: Optional secure tunnel exposure for remote access
- **Keychain Storage**: Secure storage of authentication tokens
- **Code Signing**: Full support for macOS code signing and notarization

### Terminal Capabilities
- **Full TTY Support**: Proper handling of terminal control sequences
- **Process Management**: Spawn, monitor, and control terminal processes
- **Session Recording**: Asciinema format recording for playback
- **Multiple Sessions**: Concurrent terminal session support

### Developer Experience
- **Hot Reload**: Development server with live updates
- **Comprehensive Logging**: Detailed logs for debugging
- **Error Handling**: Robust error handling throughout the stack
- **Swift 6 Concurrency**: Modern async/await patterns

## Technology Stack

### macOS Application
- **Language**: Swift 6.0
- **UI Framework**: SwiftUI
- **Minimum OS**: macOS 14.0 (Sonoma)
- **Architecture**: Universal Binary (Intel + Apple Silicon)

### Dependencies
- **Hummingbird**: HTTP server framework
- **Sparkle**: Auto-update framework
- **Swift Log**: Structured logging
- **Swift HTTP Types**: Type-safe HTTP handling

### Build Tools
- **Xcode**: Main IDE and build system
- **Swift Package Manager**: Dependency management
- **Cargo**: Rust toolchain for tty-fwd
- **npm**: Frontend build tooling

## Installation

### Prerequisites
- macOS 14.0 or later
- Xcode 15.0 or later (for development)
- Rust toolchain (for building tty-fwd)
- Node.js and npm (for frontend development)

### Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/amantus-ai/vibetunnel.git
   cd vibetunnel
   ```

2. Build the Rust server:
   ```bash
   cd rust/tty-fwd
   cargo build --release
   cd ../..
   ```

3. Build the web frontend:
   ```bash
   cd web
   npm install
   npm run build
   cd ..
   ```

4. Open in Xcode and build:
   ```bash
   open VibeTunnel.xcodeproj
   ```

## Usage

1. **Launch VibeTunnel**: The app appears in your menu bar
2. **Start Server**: Click the menu bar icon and select "Start Server"
3. **Access Web UI**: Navigate to `http://localhost:4020` (default port)
4. **Create Session**: Use the web interface to create new terminal sessions
5. **Remote Access**: Enable ngrok integration for secure remote access

## Development

### Project Structure
```
vibetunnel/
├── VibeTunnel/              # macOS app source
│   ├── Services/            # Core services (servers, managers)
│   ├── Models/              # Data models
│   ├── Views/               # SwiftUI views
│   └── Resources/           # Assets and bundled files
├── rust/tty-fwd/           # Rust TTY forwarding server
├── web/                    # TypeScript/JavaScript frontend
├── scripts/                # Build and utility scripts
└── Tests/                  # Unit and integration tests
```

### Key Design Patterns

1. **Protocol-Oriented Design**: `ServerProtocol` allows swapping server implementations
2. **Actor Pattern**: Swift actors for thread-safe state management
3. **Dependency Injection**: Services are injected for testability
4. **MVVM Architecture**: Clear separation of views and business logic

### Testing
```bash
# Run Swift tests
swift test

# Run Rust tests
cd rust/tty-fwd && cargo test

# Run frontend tests
cd web && npm test
```

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

VibeTunnel is open source software licensed under the MIT License. See the LICENSE file for details.

## Acknowledgments

- Built with [Hummingbird](https://github.com/hummingbird-project/hummingbird) HTTP server framework
- Terminal rendering powered by [asciinema player](https://github.com/asciinema/asciinema-player)
- Auto-updates via [Sparkle](https://sparkle-project.org/)

---

*VibeTunnel - Bridging terminals to the web, one session at a time.*