import AppKit
import Combine
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import os

// MARK: - Response Models

/// Server info response
struct ServerInfoResponse: ResponseCodable {
    let name: String
    let version: String
    let uptime: TimeInterval
    let sessions: Int
}

/// Main tunnel server implementation using Hummingbird
@MainActor
final class TunnelServer: ObservableObject {
    private let port: Int
    private let logger = Logger(label: "VibeTunnel.TunnelServer")
    private var app: Application<Router<BasicRequestContext>.Responder>?
    private let terminalManager = TerminalManager()

    @Published var isRunning = false
    @Published var lastError: Error?
    @Published var connectedClients = 0

    init(port: Int = 8_080) {
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

        // In Hummingbird 2.x, the application lifecycle is managed differently
        // Setting app to nil will trigger cleanup when it's deallocated
        self.app = nil

        await MainActor.run {
            self.isRunning = false
        }
    }

    private func buildApplication() async throws -> Application<Router<BasicRequestContext>.Responder> {
        // Create router
        let router = Router<BasicRequestContext>()

        // Add middleware
        router.add(middleware: LogRequestsMiddleware(.info))
        router.add(middleware: CORSMiddleware(
            allowOrigin: .all,
            allowHeaders: [.contentType, .authorization],
            allowMethods: [.get, .post, .delete, .options]
        ))
        router.add(middleware: AuthenticationMiddleware(apiKeys: APIKeyManager.loadStoredAPIKeys()))

        // Configure routes
        configureRoutes(router)

        // Add WebSocket routes
        // TODO: Uncomment when HummingbirdWebSocket package is added
        // router.addWebSocketRoutes(terminalManager: terminalManager)

        // Create application configuration
        let configuration = ApplicationConfiguration(
            address: .hostname("127.0.0.1", port: port),
            serverName: "VibeTunnel"
        )

        // Create and configure the application
        let app = Application(
            responder: router.buildResponder(),
            configuration: configuration,
            logger: logger
        )

        // Add cleanup task
        // Start cleanup task
        Task {
            while !Task.isCancelled {
                await terminalManager.cleanupInactiveSessions(olderThan: 30)
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 minutes
            }
        }

        return app
    }

    private func configureRoutes(_ router: Router<BasicRequestContext>) {
        // Health check endpoint
        router.get("/health") { _, _ -> HTTPResponse.Status in
            .ok
        }

        // Server info endpoint
        router.get("/info") { _, _ async -> ServerInfoResponse in
            let sessionCount = await self.terminalManager.listSessions().count
            return ServerInfoResponse(
                name: "VibeTunnel",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                uptime: ProcessInfo.processInfo.systemUptime,
                sessions: sessionCount
            )
        }

        // Session management endpoints
        let sessions = router.group("sessions")

        // List all sessions
        sessions.get("/") { _, _ async -> ListSessionsResponse in
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
        sessions.post("/") { request, context async throws -> CreateSessionResponse in
            let createRequest = try await request.decode(as: CreateSessionRequest.self, context: context)
            let session = try await self.terminalManager.createSession(request: createRequest)

            return CreateSessionResponse(
                sessionId: session.id.uuidString,
                createdAt: session.createdAt
            )
        }

        // Get session info
        sessions.get(":sessionId") { _, context async throws -> SessionInfo in
            guard let sessionIdString = context.parameters.get("sessionId", as: String.self),
                  let sessionId = UUID(uuidString: sessionIdString),
                  let session = await self.terminalManager.getSession(id: sessionId)
            else {
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
        sessions.delete(":sessionId") { _, context async throws -> HTTPResponse.Status in
            guard let sessionIdString = context.parameters.get("sessionId", as: String.self),
                  let sessionId = UUID(uuidString: sessionIdString)
            else {
                throw HTTPError(.badRequest)
            }

            await self.terminalManager.closeSession(id: sessionId)
            return .noContent
        }

        // Command execution endpoint
        router.post("/execute") { request, context async throws -> CommandResponse in
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
}

// MARK: - Integration with AppDelegate

extension AppDelegate {
    func startTunnelServer() {
        Task {
            do {
                let port = UserDefaults.standard.integer(forKey: "serverPort")
                let tunnelServer = TunnelServer(port: port > 0 ? port : 8_080)

                // Store reference if needed
                // self.tunnelServer = tunnelServer

                try await tunnelServer.start()
            } catch {
                let logger = Logger(label: "VibeTunnel.AppDelegate")
                logger.error("Failed to start tunnel server: \(error)")

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
