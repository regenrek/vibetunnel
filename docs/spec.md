# VibeTunnel Technical Specification

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [System Architecture](#system-architecture)
3. [Core Components](#core-components)
4. [Server Implementations](#server-implementations)
5. [Web Frontend](#web-frontend)
6. [Security Model](#security-model)
7. [Session Management](#session-management)
8. [CLI Integration](#cli-integration)
9. [API Specifications](#api-specifications)
10. [User Interface](#user-interface)
11. [Configuration System](#configuration-system)
12. [Build and Release](#build-and-release)
13. [Testing Strategy](#testing-strategy)
14. [Performance Requirements](#performance-requirements)
15. [Error Handling](#error-handling)
16. [Update System](#update-system)
17. [Platform Integration](#platform-integration)
18. [Data Formats](#data-formats)
19. [Networking](#networking)
20. [Future Roadmap](#future-roadmap)

## Executive Summary

### Project Overview

VibeTunnel is a macOS application that provides browser-based access to Mac terminals, designed to make terminal access as simple as opening a web page. The project specifically targets developers and engineers who need to monitor AI agents (like Claude Code) remotely.

### Key Features

- **Zero-Configuration Terminal Access**: Launch terminals with a simple `vt` command
- **Browser-Based Interface**: Access terminals from any modern web browser
- **Real-Time Streaming**: Live terminal updates via WebSocket
- **Session Recording**: Full asciinema format recording support
- **Security Options**: Password protection, localhost-only mode, Tailscale/ngrok integration
- **Multiple Server Backends**: Choice between Swift (Hummingbird) and Rust (tty-fwd) implementations
- **Auto-Updates**: Sparkle framework integration for seamless updates
- **AI Agent Integration**: Special support for Claude Code with shortcuts

### Technical Stack

- **Native App**: Swift 6.0, SwiftUI, macOS 14.0+
- **HTTP Servers**: Hummingbird (Swift), tty-fwd (Rust)
- **Web Frontend**: TypeScript, JavaScript, Tailwind CSS
- **Build System**: Xcode, Swift Package Manager, Cargo
- **Distribution**: Signed/notarized DMG with Sparkle updates

## System Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      macOS Application                       │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Menu Bar UI │  │ Server       │  │ Session          │  │
│  │ (SwiftUI)   │──│ Manager      │──│ Monitor          │  │
│  └─────────────┘  └──────────────┘  └──────────────────┘  │
│                           │                                  │
│  ┌─────────────────────────────────────────────────────┐  │
│  │                  Server Abstraction                   │  │
│  │  ┌──────────────────┐  ┌──────────────────────┐     │  │
│  │  │ Hummingbird      │  │ Rust Server          │     │  │
│  │  │ Server           │  │ (tty-fwd)            │     │  │
│  │  └──────────────────┘  └──────────────────────┘     │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                               │
                               ├── HTTP API
                               ├── WebSocket
                               │
┌─────────────────────────────────────────────────────────────┐
│                      Web Browser                             │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐   │
│  │ Dashboard    │  │ Terminal     │  │ Asciinema      │   │
│  │ View         │  │ Interface    │  │ Player         │   │
│  └──────────────┘  └──────────────┘  └────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Component Interaction Flow

1. **Terminal Launch**: User executes `vt` command
2. **Session Creation**: ServerManager creates new terminal session
3. **PTY Allocation**: Server allocates pseudo-terminal
4. **WebSocket Connection**: Browser establishes real-time connection
5. **Data Streaming**: Terminal I/O streams to/from browser
6. **Recording**: Session data recorded in asciinema format
7. **Session Cleanup**: Resources freed on terminal exit

### Design Principles

- **Modularity**: Clean separation between UI, business logic, and server implementations
- **Protocol-Oriented**: Interfaces define contracts between components
- **Thread Safety**: Swift actors ensure concurrent access safety
- **Minimal Dependencies**: Only essential third-party libraries
- **User Privacy**: No telemetry or user tracking

## Core Components

### ServerManager

**Location**: `VibeTunnel/Core/Services/ServerManager.swift`

**Responsibilities**:
- Orchestrates server lifecycle (start/stop/restart)
- Manages server selection (Hummingbird vs Rust)
- Coordinates with other services (Ngrok, SessionMonitor)
- Provides unified API for UI layer

**Key Methods**:
```swift
func startServer(serverType: ServerType) async throws
func stopServer() async
func restartServer() async throws
func getServerURL() -> URL?
func isServerRunning() -> Bool
```

**State Management**:
- Uses Swift actors for thread-safe state updates
- Publishes state changes via Combine
- Maintains server configuration

### SessionMonitor

**Location**: `VibeTunnel/Core/Services/SessionMonitor.swift`

**Responsibilities**:
- Tracks active terminal sessions
- Monitors session lifecycle
- Collects session metrics
- Provides session listing API

**Key Features**:
- Real-time session tracking
- Session metadata management
- Automatic cleanup of terminated sessions
- Performance monitoring

### TerminalManager

**Location**: `VibeTunnel/Core/Services/TerminalManager.swift`

**Responsibilities**:
- Creates new terminal processes
- Manages PTY (pseudo-terminal) allocation
- Handles terminal I/O redirection
- Implements terminal control operations

**Terminal Operations**:
- Shell selection (bash, zsh, fish)
- Environment variable management
- Working directory configuration
- Terminal size handling

### NgrokService

**Location**: `VibeTunnel/Core/Services/NgrokService.swift`

**Responsibilities**:
- Manages ngrok tunnel lifecycle
- Provides secure public URLs
- Handles authentication
- Monitors tunnel status

**Configuration**:
- API key management via Keychain
- Custom domain support
- Region selection
- Protocol configuration

## Server Implementations

### Hummingbird Server (Swift)

**Location**: `VibeTunnel/Core/Services/HummingbirdServer.swift`

**Architecture**:
```swift
protocol ServerProtocol {
    func start(port: Int) async throws
    func stop() async
    var isRunning: Bool { get }
    var port: Int? { get }
}
```

**Features**:
- Native Swift implementation
- Async/await concurrency
- Built on SwiftNIO
- Direct macOS integration

**Endpoints**:
- `GET /` - Dashboard HTML
- `GET /api/sessions` - List active sessions
- `POST /api/sessions` - Create new session
- `GET /api/sessions/:id` - Session details
- `DELETE /api/sessions/:id` - Terminate session
- `WS /api/sessions/:id/stream` - Terminal WebSocket

**Middleware Stack**:
1. CORS handling
2. Basic authentication (optional)
3. Request logging
4. Error handling
5. Static file serving

### Rust Server (tty-fwd)

**Location**: Binary embedded in app bundle

**Features**:
- High-performance Rust implementation
- Native PTY handling
- Asciinema recording built-in
- Minimal memory footprint

**Command-Line Interface**:
```bash
tty-fwd --port 9700 \
        --auth-mode basic \
        --username user \
        --password pass \
        --allowed-origins "*"
```

**Advantages**:
- Better terminal compatibility
- Lower latency
- Efficient resource usage
- Battle-tested PTY handling

## Web Frontend

### Technology Stack

**Location**: `web/` directory

**Core Technologies**:
- TypeScript for type safety
- Vanilla JavaScript for performance
- Tailwind CSS for styling
- Asciinema player for terminal rendering
- WebSocket API for real-time updates

### Component Architecture

```
web/
├── src/
│   ├── components/
│   │   ├── Dashboard.ts
│   │   ├── SessionList.ts
│   │   ├── TerminalView.ts
│   │   └── SettingsPanel.ts
│   ├── services/
│   │   ├── ApiClient.ts
│   │   ├── WebSocketClient.ts
│   │   └── SessionManager.ts
│   ├── utils/
│   │   ├── Terminal.ts
│   │   └── Authentication.ts
│   └── styles/
│       └── main.css
├── public/
│   ├── index.html
│   └── assets/
└── build/
```

### Key Features

**Dashboard**:
- Real-time session listing
- One-click terminal creation
- Session metadata display
- Server status indicators

**Terminal Interface**:
- Full ANSI color support
- Copy/paste functionality
- Responsive terminal sizing
- Keyboard shortcut support
- Mobile-friendly design

**Performance Optimizations**:
- Lazy loading of terminal sessions
- WebSocket connection pooling
- Efficient DOM updates
- Asset bundling and minification

## Security Model

### Authentication

**Basic Authentication**:
- Username/password protection
- Credentials stored in macOS Keychain
- Secure credential transmission
- Session-based authentication

**Implementation**:
```swift
class LazyBasicAuthMiddleware: HTTPMiddleware {
    func intercept(_ request: Request, next: Next) async throws -> Response {
        guard requiresAuth(request) else {
            return try await next(request)
        }
        
        guard let auth = request.headers["Authorization"].first,
              validateCredentials(auth) else {
            return Response(status: .unauthorized)
        }
        
        return try await next(request)
    }
}
```

### Network Security

**Access Control**:
- Localhost-only mode by default
- CORS configuration
- IP whitelisting support
- Request rate limiting

**Secure Tunneling**:
- Tailscale integration for VPN access
- Ngrok support for secure public URLs
- TLS encryption for remote connections
- Certificate validation

### System Security

**Privileges**:
- No app sandbox (required for terminal access)
- Hardened runtime enabled
- Code signing with Developer ID
- Notarization for Gatekeeper

**Data Protection**:
- No persistent storage of terminal content
- Session data cleared on termination
- Secure credential storage in Keychain
- No telemetry or analytics

## Session Management

### Session Lifecycle

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ Created │ --> │ Active  │ --> │ Closing │ --> │ Closed  │
└─────────┘     └─────────┘     └─────────┘     └─────────┘
     │                                                 │
     └─────────────── Errored ────────────────────────┘
```

### Session Model

```swift
struct TunnelSession: Identifiable, Codable {
    let id: String
    let name: String
    let command: String
    let createdAt: Date
    let pid: Int32?
    let recordingPath: String?
    var status: SessionStatus
    var lastActivity: Date
}
```

### Session Operations

**Creation**:
1. Generate unique session ID
2. Allocate PTY
3. Launch shell process
4. Initialize recording
5. Establish WebSocket

**Monitoring**:
- Process status checks
- I/O activity tracking
- Resource usage monitoring
- Automatic timeout handling

**Termination**:
- Graceful process shutdown
- PTY cleanup
- Recording finalization
- WebSocket closure
- Resource deallocation

## CLI Integration

### vt Command Wrapper

**Location**: `Resources/vt`

**Installation**:
```bash
# Automatic installation
/Applications/VibeTunnel.app/Contents/MacOS/VibeTunnel --install-cli

# Manual installation
ln -s /Applications/VibeTunnel.app/Contents/Resources/vt /usr/local/bin/vt
```

**Usage Patterns**:
```bash
# Basic usage
vt

# With custom command
vt -- npm run dev

# Claude integration
vt --claude
vt --claude-yolo

# Custom working directory
vt --cwd /path/to/project
```

### CLI Features

**Command Parsing**:
- Argument forwarding to shell
- Environment variable preservation
- Working directory handling
- Shell selection

**App Integration**:
- Launches VibeTunnel if not running
- Waits for server readiness
- Opens browser automatically
- Returns session URL

## API Specifications

### RESTful API

**Base URL**: `http://localhost:9700`

**Authentication**: Optional Basic Auth

#### Endpoints

**GET /api/sessions**
```json
{
  "sessions": [
    {
      "id": "abc123",
      "name": "Terminal 1",
      "command": "/bin/zsh",
      "createdAt": "2024-01-20T10:30:00Z",
      "status": "active"
    }
  ]
}
```

**POST /api/sessions**
```json
// Request
{
  "command": "/bin/bash",
  "args": ["-c", "echo hello"],
  "cwd": "/Users/username",
  "env": {
    "CUSTOM_VAR": "value"
  }
}

// Response
{
  "id": "xyz789",
  "url": "/sessions/xyz789",
  "websocket": "/api/sessions/xyz789/stream"
}
```

**DELETE /api/sessions/:id**
```json
{
  "status": "terminated"
}
```

### WebSocket Protocol

**Endpoint**: `/api/sessions/:id/stream`

**Message Format**:
```typescript
interface TerminalMessage {
  type: 'data' | 'resize' | 'close';
  data?: string;  // Base64 encoded for binary safety
  cols?: number;
  rows?: number;
}
```

**Connection Flow**:
1. Client connects to WebSocket
2. Server sends initial terminal size
3. Bidirectional data flow begins
4. Client sends resize events
5. Server sends close event on termination

## User Interface

### Menu Bar Application

**Components**:
- Status icon with server state
- Quick access menu
- Session listing
- Settings access
- About/Help options

**State Indicators**:
- Gray: Server stopped
- Blue: Server running
- Red: Error state
- Animated: Starting/stopping

### Settings Window

**General Tab**:
- Server selection (Hummingbird/Rust)
- Port configuration
- Auto-start preferences
- Update channel selection

**Security Tab**:
- Authentication toggle
- Username/password fields
- Localhost-only mode
- Allowed origins configuration

**Advanced Tab**:
- Shell selection
- Environment variables
- Terminal preferences
- Debug logging

**Integrations Tab**:
- Ngrok configuration
- Tailscale settings
- CLI installation
- Browser selection

### Design Guidelines

**Visual Design**:
- Native macOS appearance
- System color scheme support
- Consistent spacing (8pt grid)
- SF Symbols for icons

**Interaction Patterns**:
- Immediate feedback for actions
- Confirmation for destructive operations
- Keyboard shortcuts support
- Accessibility compliance

## Configuration System

### User Defaults

**Storage**: `UserDefaults.standard`

**Key Structure**:
```swift
enum UserDefaultsKeys {
    static let serverType = "serverType"
    static let serverPort = "serverPort"
    static let authEnabled = "authEnabled"
    static let localhostOnly = "localhostOnly"
    static let autoStart = "autoStart"
    static let updateChannel = "updateChannel"
}
```

### Keychain Integration

**Secure Storage**:
- Authentication credentials
- Ngrok API tokens
- Session tokens
- Encryption keys

**Implementation**:
```swift
class KeychainService {
    func store(_ data: Data, for key: String) throws
    func retrieve(for key: String) throws -> Data?
    func delete(for key: String) throws
}
```

### Configuration Migration

**Version Handling**:
- Configuration version tracking
- Automatic migration on upgrade
- Backup before migration
- Rollback capability

## Build and Release

### Build System

**Requirements**:
- Xcode 16.0+
- Swift 6.0+
- Rust 1.83.0+
- macOS 14.0+ SDK

**Build Script**: `scripts/build.sh`
```bash
./scripts/build.sh [debug|release] [sign] [notarize]
```

**Build Phases**:
1. Clean previous builds
2. Build Rust components
3. Build Swift application
4. Copy resources
5. Code signing
6. Notarization
7. DMG creation

### Code Signing

**Requirements**:
- Apple Developer ID certificate
- Hardened runtime enabled
- Entitlements configuration
- Notarization credentials

**Entitlements**:
```xml
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

### Distribution

**Channels**:
- Direct download from website
- GitHub releases
- Homebrew cask (planned)
- Mac App Store (future)

**Package Format**:
- Signed and notarized DMG
- Universal binary (Intel + Apple Silicon)
- Embedded update framework
- Version metadata

## Testing Strategy

### Unit Tests

**Coverage Areas**:
- Session management logic
- API endpoint handlers
- Configuration handling
- Utility functions

**Test Structure**:
```swift
class SessionManagerTests: XCTestCase {
    func testSessionCreation() async throws
    func testSessionTermination() async throws
    func testConcurrentSessions() async throws
}
```

### Integration Tests

**Server Tests**:
- HTTP endpoint testing
- WebSocket communication
- Authentication flows
- Error scenarios

**Mock Infrastructure**:
```swift
class MockHTTPClient: HTTPClient {
    var responses: [URL: Response] = [:]
    func send(_ request: Request) async throws -> Response
}
```

### UI Tests

**Scenarios**:
- Menu bar interactions
- Settings window navigation
- Session creation flow
- Error state handling

### Performance Tests

**Metrics**:
- Server startup time < 1s
- Session creation < 100ms
- WebSocket latency < 10ms
- Memory usage < 50MB idle

## Performance Requirements

### Latency Targets

**Terminal I/O**:
- Keystroke to display: < 50ms
- Command execution: < 100ms
- Screen refresh: 60 FPS

**API Response Times**:
- Session list: < 50ms
- Session creation: < 200ms
- Static assets: < 100ms

### Resource Usage

**Memory**:
- Base application: < 50MB
- Per session: < 10MB
- WebSocket buffer: 64KB

**CPU**:
- Idle: < 1%
- Active session: < 5%
- Multiple sessions: Linear scaling

### Scalability

**Concurrent Sessions**:
- Target: 50 simultaneous sessions
- Graceful degradation beyond limit
- Resource pooling for efficiency

## Error Handling

### Error Categories

**User Errors**:
- Invalid configuration
- Authentication failures
- Network issues
- Permission denied

**System Errors**:
- Server startup failures
- PTY allocation errors
- Process spawn failures
- Resource exhaustion

**Recovery Strategies**:
- Automatic retry with backoff
- Graceful degradation
- User notification
- Error logging

### Error Reporting

**User Feedback**:
```swift
enum UserError: LocalizedError {
    case serverStartFailed(String)
    case authenticationFailed
    case sessionCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .serverStartFailed(let reason):
            return "Failed to start server: \(reason)"
        // ...
        }
    }
}
```

**Logging**:
- Structured logging with SwiftLog
- Log levels (debug, info, warning, error)
- Rotating log files
- Privacy-preserving logging

## Update System

### Sparkle Integration

**Configuration**:
```xml
<key>SUFeedURL</key>
<string>https://vibetunnel.sh/appcast.xml</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

**Update Channels**:
- Stable: Production releases
- Beta: Pre-release testing
- Edge: Nightly builds

### Update Process

**Flow**:
1. Check for updates (daily)
2. Download update in background
3. Verify signature
4. Prompt user for installation
5. Install and restart

**Rollback Support**:
- Previous version backup
- Automatic rollback on crash
- Manual downgrade option

## Platform Integration

### macOS Integration

**System Features**:
- Launch at login
- Dock/menu bar modes
- Notification Center
- Keyboard shortcuts
- Services menu

**Accessibility**:
- VoiceOver support
- Keyboard navigation
- High contrast mode
- Reduced motion

### Shell Integration

**Supported Shells**:
- bash
- zsh (default)
- fish
- sh
- Custom shells

**Environment Setup**:
- Path preservation
- Environment variable forwarding
- Shell configuration sourcing
- Terminal type setting

## Data Formats

### Asciinema Format

**Recording Structure**:
```json
{
  "version": 2,
  "width": 80,
  "height": 24,
  "timestamp": 1642694400,
  "env": {
    "SHELL": "/bin/zsh",
    "TERM": "xterm-256color"
  }
}
```

**Event Format**:
```json
[timestamp, "o", "output data"]
[timestamp, "i", "input data"]
```

### Session Metadata

**Storage Format**:
```json
{
  "id": "session-uuid",
  "created": "2024-01-20T10:30:00Z",
  "command": "/bin/zsh",
  "duration": 3600,
  "size": {
    "cols": 80,
    "rows": 24
  }
}
```

## Networking

### Protocol Support

**HTTP/HTTPS**:
- HTTP/1.1 for compatibility
- HTTP/2 support planned
- TLS 1.3 for secure connections
- Certificate pinning option

**WebSocket**:
- RFC 6455 compliant
- Binary frame support
- Ping/pong keepalive
- Automatic reconnection

### Network Configuration

**Firewall Rules**:
- Incoming connections prompt
- Automatic rule creation
- Port range restrictions
- Interface binding options

**Proxy Support**:
- System proxy settings
- Custom proxy configuration
- SOCKS5 support
- Authentication handling

## Future Roadmap

### Version 1.0 Goals

**Core Features**:
- ✅ Basic terminal forwarding
- ✅ Browser interface
- ✅ Session management
- ✅ Security options
- ⏳ Session persistence
- ⏳ Multi-user support

### Version 2.0 Plans

**Advanced Features**:
- Terminal multiplexing
- Session recording playback
- Collaborative sessions
- Terminal sharing
- Cloud synchronization
- Mobile app companion

### Long-term Vision

**Enterprise Features**:
- LDAP/AD integration
- Audit logging
- Compliance reporting
- Role-based access
- Session policies
- Integration APIs

**Platform Expansion**:
- Linux support
- Windows support (WSL)
- iOS/iPadOS app
- Web-based management
- Container deployment

### Technical Debt

**Planned Refactoring**:
- Modularize server implementations
- Extract shared protocol library
- Improve test coverage
- Performance optimizations
- Documentation improvements

## Conclusion

VibeTunnel represents a modern approach to terminal access, combining native macOS development with web technologies to create a seamless user experience. The architecture prioritizes security, performance, and ease of use while maintaining flexibility for future enhancements.

The dual-server implementation strategy provides both performance (Rust) and integration (Swift) options, while the clean architectural boundaries enable independent evolution of components. With careful attention to macOS platform conventions and user expectations, VibeTunnel delivers a professional-grade solution for terminal access needs.

This specification serves as the authoritative reference for understanding, maintaining, and extending the VibeTunnel project. As the project evolves, this document should be updated to reflect architectural decisions, implementation details, and future directions.