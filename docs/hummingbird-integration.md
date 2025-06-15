# Hummingbird Integration Guide for VibeTunnel

This guide explains how to integrate Hummingbird web framework into VibeTunnel for creating the tunnel server functionality.

## Current Status

The Hummingbird dependency has been added to the project, but the actual server implementation is pending. The `TunnelServer.swift` file contains a placeholder implementation that allows the app to build.

## Hummingbird 2.0 Example Implementation

Here's a working example of how to implement the tunnel server with Hummingbird 2.0:

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