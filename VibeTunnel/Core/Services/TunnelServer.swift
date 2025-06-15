//
//  TunnelServer.swift
//  VibeTunnel
//
//  Created by VibeTunnel on 15.06.25.
//

import Foundation
import AppKit
import Combine
import Logging
import os
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import NIOCore
import NIOHTTP1

/// Main tunnel server implementation using Hummingbird
@MainActor
final class TunnelServer: ObservableObject {
    private let port: Int
    private let logger = Logger(label: "VibeTunnel.TunnelServer")
    private var app: Application<some Router>?
    private let terminalManager = TerminalManager()
    
    @Published var isRunning = false
    @Published var lastError: Error?
    @Published var connectedClients = 0
    
    init(port: Int = 8080) {
        self.port = port
    }
    
    func start() async throws {
        logger.info("Starting tunnel server on port \(port)")
        
        do {
            // Build the Hummingbird application
            let app = try await buildApplication()
            self.app = app
            
            // Start the server
            try await app.run()
            
            await MainActor.run {
                self.isRunning = true
            }
        } catch {
            await MainActor.run {
                self.lastError = error
                self.isRunning = false
            }
            throw error
        }
    }
    
    func stop() async {
        logger.info("Stopping tunnel server")
        
        if let app = app {
            await app.stop()
            self.app = nil
        }
        
        await MainActor.run {
            self.isRunning = false
        }
    }
    
    private func buildApplication() async throws -> Application<some Router> {
        // Create router
        var router = RouterBuilder()
        
        // Add middleware
        router.middlewares.add(LogRequestsMiddleware(logLevel: .info))
        router.middlewares.add(CORSMiddleware())
        router.middlewares.add(AuthenticationMiddleware(apiKeys: AuthenticationMiddleware.loadStoredAPIKeys()))
        
        // Configure routes
        configureRoutes(&router)
        
        // Add WebSocket routes
        router.addWebSocketRoutes(terminalManager: terminalManager)
        
        // Create application configuration
        let configuration = ApplicationConfiguration(
            address: .hostname("127.0.0.1", port: port),
            serverName: "VibeTunnel"
        )
        
        // Create and configure the application
        let app = Application(
            router: router.buildRouter(),
            configuration: configuration,
            logger: logger
        )
        
        // Add cleanup task
        app.services.add(CleanupService(terminalManager: terminalManager))
        
        return app
    }
    
    private func configureRoutes(_ router: inout RouterBuilder) {
        // Health check endpoint
        router.get("/health") { request, context -> HTTPResponse.Status in
            return .ok
        }
        
        // Server info endpoint
        router.get("/info") { request, context -> [String: Any] in
            return [
                "name": "VibeTunnel",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                "uptime": ProcessInfo.processInfo.systemUptime,
                "sessions": await self.terminalManager.listSessions().count
            ]
        }
        
        // Session management endpoints
        router.group("sessions") { sessions in
            // List all sessions
            sessions.get("/") { request, context -> ListSessionsResponse in
                let sessions = await self.terminalManager.listSessions()
                let sessionInfos = sessions.map { session in
                    SessionInfo(
                        id: session.id.uuidString,
                        createdAt: session.createdAt,
                        lastActivity: session.lastActivity,
                        isActive: session.isActive
                    )
                }
                return ListSessionsResponse(sessions: sessionInfos)
            }
            
            // Create new session
            sessions.post("/") { request, context -> CreateSessionResponse in
                let createRequest = try await request.decode(as: CreateSessionRequest.self, context: context)
                let session = try await self.terminalManager.createSession(request: createRequest)
                
                return CreateSessionResponse(
                    sessionId: session.id.uuidString,
                    createdAt: session.createdAt
                )
            }
            
            // Get session info
            sessions.get(":sessionId") { request, context -> SessionInfo in
                guard let sessionIdString = request.parameters.get("sessionId"),
                      let sessionId = UUID(uuidString: sessionIdString),
                      let session = await self.terminalManager.getSession(id: sessionId) else {
                    throw HTTPError(.notFound)
                }
                
                return SessionInfo(
                    id: session.id.uuidString,
                    createdAt: session.createdAt,
                    lastActivity: session.lastActivity,
                    isActive: session.isActive
                )
            }
            
            // Close session
            sessions.delete(":sessionId") { request, context -> HTTPResponse.Status in
                guard let sessionIdString = request.parameters.get("sessionId"),
                      let sessionId = UUID(uuidString: sessionIdString) else {
                    throw HTTPError(.badRequest)
                }
                
                await self.terminalManager.closeSession(id: sessionId)
                return .noContent
            }
        }
        
        // Command execution endpoint
        router.post("/execute") { request, context -> CommandResponse in
            let commandRequest = try await request.decode(as: CommandRequest.self, context: context)
            
            guard let sessionId = UUID(uuidString: commandRequest.sessionId) else {
                throw HTTPError(.badRequest, message: "Invalid session ID")
            }
            
            do {
                let (output, error) = try await self.terminalManager.executeCommand(
                    sessionId: sessionId,
                    command: commandRequest.command
                )
                
                return CommandResponse(
                    sessionId: commandRequest.sessionId,
                    output: output.isEmpty ? nil : output,
                    error: error.isEmpty ? nil : error,
                    exitCode: nil,
                    timestamp: Date()
                )
            } catch {
                throw HTTPError(.internalServerError, message: error.localizedDescription)
            }
        }
    }
    
    // Service for periodic cleanup
    struct CleanupService: Service {
        let terminalManager: TerminalManager
        
        func run() async throws {
            // Run cleanup every 5 minutes
            while !Task.isCancelled {
                await terminalManager.cleanupInactiveSessions(olderThan: 30)
                try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 minutes
            }
        }
    }
}

// MARK: - Middleware

/// CORS middleware for browser-based clients
struct CORSMiddleware: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        
        response.headers[.accessControlAllowOrigin] = "*"
        response.headers[.accessControlAllowMethods] = "GET, POST, PUT, DELETE, OPTIONS"
        response.headers[.accessControlAllowHeaders] = "Content-Type, Authorization"
        
        return response
    }
}

// MARK: - Integration with AppDelegate

extension AppDelegate {
    func startTunnelServer() {
        Task {
            do {
                let port = UserDefaults.standard.integer(forKey: "serverPort")
                let tunnelServer = TunnelServer(port: port > 0 ? port : 8080)
                
                // Store reference if needed
                // self.tunnelServer = tunnelServer
                
                try await tunnelServer.start()
            } catch {
                print("Failed to start tunnel server: \(error)")
                
                // Show error alert
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Start Server"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }
}