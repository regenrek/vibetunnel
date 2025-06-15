# Hummingbird Integration Guide for VibeTunnel

This guide explains the Hummingbird web framework integration in VibeTunnel for creating the tunnel server functionality.

## Current Status

✅ **IMPLEMENTED** - The VibeTunnel server is now fully implemented with:
- HTTP REST API endpoints for terminal session management
- WebSocket support for real-time terminal communication
- Authentication via API keys
- Session management with automatic cleanup
- Client SDK for easy integration
- Comprehensive error handling

## Architecture Overview

The VibeTunnel server is built with the following components:

### Core Components

1. **TunnelServer** (`/VibeTunnel/Core/Services/TunnelServer.swift`)
   - Main server implementation using Hummingbird
   - Manages HTTP endpoints and WebSocket connections
   - Handles server lifecycle and configuration

2. **TerminalManager** (`/VibeTunnel/Core/Services/TerminalManager.swift`)
   - Actor-based terminal session management
   - Handles process creation and command execution
   - Manages pipes for stdin/stdout/stderr communication
   - Automatic cleanup of inactive sessions

3. **WebSocketHandler** (`/VibeTunnel/Core/Services/WebSocketHandler.swift`)
   - Real-time bidirectional communication
   - JSON-based message protocol
   - Session-based terminal streaming

4. **AuthenticationMiddleware** (`/VibeTunnel/Core/Services/AuthenticationMiddleware.swift`)
   - API key-based authentication
   - Secure key generation and storage
   - Protects all endpoints except health check

5. **TunnelClient** (`/VibeTunnel/Core/Services/TunnelClient.swift`)
   - Swift SDK for server interaction
   - Async/await based API
   - WebSocket client for real-time communication

### Data Models

- **TunnelSession** - Represents a terminal session
- **CreateSessionRequest/Response** - Session creation
- **CommandRequest/Response** - Command execution
- **WSMessage** - WebSocket message format

## API Endpoints

### REST API

- `GET /health` - Health check (no auth required)
- `GET /info` - Server information
- `GET /sessions` - List all active sessions
- `POST /sessions` - Create new terminal session
- `GET /sessions/:id` - Get session details
- `DELETE /sessions/:id` - Close a session
- `POST /execute` - Execute command in session

### WebSocket

- `WS /ws/terminal` - Real-time terminal communication

## Example Implementation

```swift
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore

// Basic server implementation
struct TunnelServerApp {
    let logger = Logger(label: "VibeTunnel.Server")
    
    func buildApplication() -> some ApplicationProtocol {
        let router = Router()
        
        // Health check endpoint
        router.get("/health") { request, context -> [String: Any] in
            return [
                "status": "ok",
                "timestamp": Date().timeIntervalSince1970
            ]
        }
        
        // Command endpoint
        router.post("/tunnel/command") { request, context -> Response in
            struct CommandRequest: Decodable {
                let command: String
                let args: [String]?
            }
            
            let commandRequest = try await request.decode(
                as: CommandRequest.self,
                context: context
            )
            
            // Process command here
            logger.info("Received command: \(commandRequest.command)")
            
            return Response(
                status: .ok,
                headers: HTTPFields([
                    .contentType: "application/json"
                ]),
                body: .data(Data("{\"success\":true}".utf8))
            )
        }
        
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: 8080)
            )
        )
        
        return app
    }
}
```

## WebSocket Support

For real-time communication with Claude Code, you'll want to add WebSocket support:

```swift
// Add HummingbirdWebSocket dependency first
import HummingbirdWebSocket

// Then add WebSocket routes
router.ws("/tunnel/stream") { request, ws, context in
    ws.onText { ws, text in
        // Handle incoming text messages
        logger.info("Received: \(text)")
        
        // Echo back or process command
        try await ws.send(text: "Acknowledged: \(text)")
    }
    
    ws.onBinary { ws, buffer in
        // Handle binary data if needed
    }
    
    ws.onClose { closeCode in
        logger.info("WebSocket closed: \(closeCode)")
    }
}
```

## Integration Steps

1. **Update the Package Dependencies**: Make sure to include any additional Hummingbird modules you need (like HummingbirdWebSocket).

2. **Replace the Placeholder**: Update `TunnelServer.swift` with the actual Hummingbird implementation.

3. **Handle Concurrency**: Since the server runs asynchronously, ensure proper handling of the server lifecycle with the SwiftUI app lifecycle.

4. **Add Security**: Implement authentication and secure communication for production use.

## Testing the Server

Once implemented, you can test the server with curl:

```bash
# Health check
curl http://localhost:8080/health

# Send a command
curl -X POST http://localhost:8080/tunnel/command \
  -H "Content-Type: application/json" \
  -d '{"command":"ls","args":["-la"]}'
```

## Next Steps

1. Implement actual command execution logic
2. Add authentication/authorization
3. Implement WebSocket support for real-time communication
4. Add SSL/TLS support for secure connections
5. Create client SDK for easy integration