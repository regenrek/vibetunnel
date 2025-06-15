//
//  WebSocketHandler.swift
//  VibeTunnel
//
//  Created by VibeTunnel on 15.06.25.
//

import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore
import NIOWebSocket
import Logging

/// WebSocket message types for terminal communication
enum WSMessageType: String, Codable {
    case connect = "connect"
    case command = "command"
    case output = "output"
    case error = "error"
    case ping = "ping"
    case pong = "pong"
    case close = "close"
}

/// WebSocket message structure
struct WSMessage: Codable {
    let type: WSMessageType
    let sessionId: String?
    let data: String?
    let timestamp: Date
    
    init(type: WSMessageType, sessionId: String? = nil, data: String? = nil) {
        self.type = type
        self.sessionId = sessionId
        self.data = data
        self.timestamp = Date()
    }
}

/// Handles WebSocket connections for real-time terminal communication
final class WebSocketHandler {
    private let terminalManager: TerminalManager
    private let logger = Logger(label: "VibeTunnel.WebSocketHandler")
    private var activeConnections: [UUID: WebSocketHandler.Connection] = [:]
    
    init(terminalManager: TerminalManager) {
        self.terminalManager = terminalManager
    }
    
    /// Handle incoming WebSocket connection
    func handle(ws: HBWebSocket, context: some RequestContext) async {
        let connectionId = UUID()
        let connection = Connection(id: connectionId, websocket: ws)
        
        await MainActor.run {
            activeConnections[connectionId] = connection
        }
        
        logger.info("WebSocket connection established: \(connectionId)")
        
        // Set up message handlers
        ws.onText { [weak self] ws, text in
            await self?.handleTextMessage(text, connection: connection)
        }
        
        ws.onBinary { [weak self] ws, buffer in
            // Handle binary data if needed
            self?.logger.debug("Received binary data: \(buffer.readableBytes) bytes")
        }
        
        ws.onClose { [weak self] closeCode in
            await self?.handleClose(connection: connection)
        }
        
        // Send initial connection acknowledgment
        await sendMessage(WSMessage(type: .connect, data: "Connected to VibeTunnel"), to: connection)
        
        // Keep connection alive with periodic pings
        Task {
            while !Task.isCancelled && !connection.isClosed {
                await sendMessage(WSMessage(type: .ping), to: connection)
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30 seconds
            }
        }
    }
    
    private func handleTextMessage(_ text: String, connection: Connection) async {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(WSMessage.self, from: data) else {
            logger.error("Failed to decode WebSocket message: \(text)")
            await sendError("Invalid message format", to: connection)
            return
        }
        
        switch message.type {
        case .connect:
            // Handle session connection
            if let sessionId = message.sessionId,
               let uuid = UUID(uuidString: sessionId) {
                connection.sessionId = uuid
                await sendMessage(WSMessage(type: .output, sessionId: sessionId, data: "Session connected"), to: connection)
            }
            
        case .command:
            // Execute command in terminal session
            guard let sessionId = connection.sessionId,
                  let command = message.data else {
                await sendError("Session ID and command required", to: connection)
                return
            }
            
            do {
                let (output, error) = try await terminalManager.executeCommand(sessionId: sessionId, command: command)
                
                if !output.isEmpty {
                    await sendMessage(WSMessage(type: .output, sessionId: sessionId.uuidString, data: output), to: connection)
                }
                
                if !error.isEmpty {
                    await sendMessage(WSMessage(type: .error, sessionId: sessionId.uuidString, data: error), to: connection)
                }
            } catch {
                await sendError(error.localizedDescription, to: connection)
            }
            
        case .ping:
            // Respond to ping with pong
            await sendMessage(WSMessage(type: .pong), to: connection)
            
        case .close:
            // Close the session
            if let sessionId = connection.sessionId {
                await terminalManager.closeSession(id: sessionId)
            }
            try? await connection.websocket.close()
            
        default:
            logger.warning("Unhandled message type: \(message.type)")
        }
    }
    
    private func handleClose(connection: Connection) async {
        logger.info("WebSocket connection closed: \(connection.id)")
        
        await MainActor.run {
            activeConnections.removeValue(forKey: connection.id)
        }
        
        // Clean up associated session if any
        if let sessionId = connection.sessionId {
            await terminalManager.closeSession(id: sessionId)
        }
        
        connection.isClosed = true
    }
    
    private func sendMessage(_ message: WSMessage, to connection: Connection) async {
        do {
            let data = try JSONEncoder().encode(message)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            try await connection.websocket.send(text: text)
        } catch {
            logger.error("Failed to send WebSocket message: \(error)")
        }
    }
    
    private func sendError(_ error: String, to connection: Connection) async {
        await sendMessage(WSMessage(type: .error, data: error), to: connection)
    }
    
    /// WebSocket connection wrapper
    class Connection {
        let id: UUID
        let websocket: HBWebSocket
        var sessionId: UUID?
        var isClosed = false
        
        init(id: UUID, websocket: HBWebSocket) {
            self.id = id
            self.websocket = websocket
        }
    }
}

/// Extension to add WebSocket routes to the router
extension Router {
    func addWebSocketRoutes(terminalManager: TerminalManager) {
        let wsHandler = WebSocketHandler(terminalManager: terminalManager)
        
        // WebSocket endpoint for terminal streaming
        ws("/ws/terminal") { request, ws, context in
            await wsHandler.handle(ws: ws, context: context)
        }
    }
}