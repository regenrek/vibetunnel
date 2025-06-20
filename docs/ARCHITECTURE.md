# VibeTunnel Architecture

This document describes the technical architecture and implementation details of VibeTunnel.

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
│  │  Implementation:                                 │   │
│  │  1. Rust Server (tty-fwd binary)                │   │
│  │  2. Go Server (Alternative)                     │   │
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

### 1. Native macOS Application

The main application is built with Swift and SwiftUI, providing:

- **Menu Bar Integration**: Lives in the system menu bar with optional dock mode
- **Server Lifecycle Management**: Controls starting, stopping, and switching between server implementations
- **System Integration**: Launch at login, single instance enforcement, application mover
- **Auto-Updates**: Sparkle framework integration for seamless updates

Key files:
- `VibeTunnel/VibeTunnelApp.swift`: Main application entry point
- `VibeTunnel/Core/Services/ServerManager.swift`: Orchestrates server operations
- `VibeTunnel/Core/Models/TunnelSession.swift`: Core session model

### 2. HTTP Server Layer

VibeTunnel offers multiple server implementations that can be switched at runtime:

#### Rust Server (tty-fwd)
- External binary written in Rust for high-performance TTY forwarding
- Spawns and manages terminal processes
- Records sessions in asciinema format
- WebSocket streaming for real-time terminal I/O
- Source: `tty-fwd/` directory

Both servers expose similar APIs:
- `POST /sessions`: Create new terminal session
- `GET /sessions`: List active sessions
- `GET /sessions/:id`: Get session details
- `POST /sessions/:id/send`: Send input to terminal
- `GET /sessions/:id/output`: Stream terminal output
- `DELETE /sessions/:id`: Terminate session

### 3. Web Frontend

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

## Key Features Implementation

### Security & Tunneling
- **Ngrok Integration**: Optional secure tunnel exposure for remote access
- **Keychain Storage**: Secure storage of authentication tokens
- **Code Signing**: Full support for macOS code signing and notarization
- **Basic Auth**: Password protection for network access

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
- **Swift NIO**: Network framework

### Build Tools
- **Xcode**: Main IDE and build system
- **Swift Package Manager**: Dependency management
- **Cargo**: Rust toolchain for tty-fwd
- **npm**: Frontend build tooling

## Project Structure

```
vibetunnel/
├── VibeTunnel/              # macOS app source
│   ├── Core/                # Core business logic
│   │   ├── Services/        # Core services (servers, managers)
│   │   ├── Models/          # Data models
│   │   └── Utilities/       # Helper utilities
│   ├── Presentation/        # UI layer
│   │   ├── Views/          # SwiftUI views
│   │   └── Utilities/      # UI utilities
│   ├── Utilities/          # App-level utilities
│   └── Resources/          # Assets and bundled files
├── tty-fwd/                # Rust TTY forwarding server
├── web/                    # TypeScript/JavaScript frontend
├── scripts/                # Build and utility scripts
└── Tests/                  # Unit and integration tests
```

## Key Design Patterns

1. **Protocol-Oriented Design**: `ServerProtocol` allows swapping server implementations
2. **Actor Pattern**: Swift actors for thread-safe state management
3. **Dependency Injection**: Services are injected for testability
4. **MVVM Architecture**: Clear separation of views and business logic
5. **Singleton Pattern**: Used for global services like ServerManager

## Development Guidelines

### Code Organization
- Services are organized by functionality in the `Core/Services` directory
- Views follow SwiftUI best practices with separate view models when needed
- Utilities are split between Core (business logic) and Presentation (UI)

### Error Handling
- All network operations use Swift's async/await with proper error propagation
- User-facing errors are localized and actionable
- Detailed logging for debugging without exposing sensitive information

### Testing Strategy
- Unit tests for core business logic
- Integration tests for server implementations
- UI tests for critical user flows

### Performance Considerations
- Rust server for CPU-intensive terminal operations
- Efficient WebSocket streaming for real-time updates
- Lazy loading of terminal sessions in the UI

## Security Model

1. **Local-Only Mode**: Default configuration restricts access to localhost
2. **Password Protection**: Optional password for network access stored in Keychain
3. **Secure Tunneling**: Integration with Tailscale/ngrok for remote access
4. **Process Isolation**: Each terminal session runs in its own process
5. **No Persistent Storage**: Sessions are ephemeral, recordings are opt-in

## Future Architecture Considerations

- **Plugin System**: Allow third-party extensions
- **Multi-Platform Support**: Potential Linux/Windows ports
- **Cloud Sync**: Optional session history synchronization
- **Terminal Multiplexing**: tmux-like functionality
- **API Extensions**: Programmatic control of sessions

## Acknowledgments

VibeTunnel's architecture is influenced by:
- Modern macOS app design patterns
- Unix philosophy of composable tools
- Web-based terminal emulators like ttyd and gotty
- The asciinema ecosystem for terminal recording