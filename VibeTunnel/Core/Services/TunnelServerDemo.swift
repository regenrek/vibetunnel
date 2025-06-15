//
//  TunnelServerDemo.swift
//  VibeTunnel
//
//  Created by VibeTunnel on 15.06.25.
//

import Foundation
import Combine

/// Demo code showing how to use the VibeTunnel server
class TunnelServerDemo {
    
    static func runDemo() async {
        // Get the API key (in production, this should be managed securely)
        let apiKeys = APIKeyManager.loadStoredAPIKeys()
        guard let apiKey = apiKeys.first else {
            print("No API key found")
            return
        }
        
        print("Using API key: \(apiKey)")
        
        // Create client
        let client = TunnelClient(apiKey: apiKey)
        
        do {
            // Check server health
            let isHealthy = try await client.checkHealth()
            print("Server healthy: \(isHealthy)")
            
            // Create a new session
            let session = try await client.createSession(
                workingDirectory: "/tmp",
                shell: "/bin/zsh"
            )
            print("Created session: \(session.sessionId)")
            
            // Execute a command
            let response = try await client.executeCommand(
                sessionId: session.sessionId,
                command: "echo 'Hello from VibeTunnel!'"
            )
            print("Command output: \(response.output ?? "none")")
            
            // List all sessions
            let sessions = try await client.listSessions()
            print("Active sessions: \(sessions.count)")
            
            // Close the session
            try await client.closeSession(id: session.sessionId)
            print("Session closed")
            
        } catch {
            print("Demo error: \(error)")
        }
    }
    
    static func runWebSocketDemo() async {
        let apiKeys = APIKeyManager.loadStoredAPIKeys()
        guard let apiKey = apiKeys.first else {
            print("No API key found")
            return
        }
        
        let client = TunnelClient(apiKey: apiKey)
        
        do {
            // Create a session first
            let session = try await client.createSession()
            print("Created session for WebSocket: \(session.sessionId)")
            
            // Connect WebSocket
            let wsClient = client.connectWebSocket(sessionId: session.sessionId)
            wsClient.connect()
            
            // Subscribe to messages
            let cancellable = wsClient.messages.sink { message in
                switch message.type {
                case .output:
                    print("Output: \(message.data ?? "")")
                case .error:
                    print("Error: \(message.data ?? "")")
                default:
                    print("Message: \(message.type) - \(message.data ?? "")")
                }
            }
            
            // Send some commands
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            wsClient.sendCommand("pwd")
            
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            wsClient.sendCommand("ls -la")
            
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            
            // Disconnect
            wsClient.disconnect()
            cancellable.cancel()
            
        } catch {
            print("WebSocket demo error: \(error)")
        }
    }
}

// MARK: - cURL Examples

/*
 Here are some example cURL commands to test the server:
 
 # Set your API key
 export API_KEY="your-api-key-here"
 
 # Health check (no auth required)
 curl http://localhost:8080/health
 
 # Get server info
 curl -H "X-API-Key: $API_KEY" http://localhost:8080/info
 
 # Create a new session
 curl -X POST http://localhost:8080/sessions \
   -H "X-API-Key: $API_KEY" \
   -H "Content-Type: application/json" \
   -d '{
     "workingDirectory": "/tmp",
     "shell": "/bin/zsh"
   }'
 
 # List all sessions
 curl -H "X-API-Key: $API_KEY" http://localhost:8080/sessions
 
 # Execute a command
 curl -X POST http://localhost:8080/execute \
   -H "X-API-Key: $API_KEY" \
   -H "Content-Type: application/json" \
   -d '{
     "sessionId": "your-session-id",
     "command": "ls -la"
   }'
 
 # Get session info
 curl -H "X-API-Key: $API_KEY" http://localhost:8080/sessions/your-session-id
 
 # Close a session
 curl -X DELETE -H "X-API-Key: $API_KEY" http://localhost:8080/sessions/your-session-id
 
 # WebSocket connection (using websocat tool)
 websocat -H "X-API-Key: $API_KEY" ws://localhost:8080/ws/terminal
 */