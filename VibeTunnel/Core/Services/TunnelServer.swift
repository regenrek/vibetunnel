import Foundation
import Observation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import NIOPosix
import os

enum ServerError: LocalizedError {
    case failedToStart(String)
    
    var errorDescription: String? {
        switch self {
        case .failedToStart(let message):
            return message
        }
    }
}

/// HTTP server implementation for the macOS app
@MainActor
@Observable
public final class TunnelServer {
    public private(set) var isRunning = false
    public private(set) var port: Int
    public var lastError: Error?
    
    private var app: Application<Router<BasicRequestContext>.Responder>?
    private let logger = Logger(label: "VibeTunnel.TunnelServer")
    private let terminalManager = TerminalManager()
    private var serverTask: Task<Void, Error>?
    
    public init(port: Int = 4020) {
        self.port = port
    }
    
    public func start() async throws {
        guard !isRunning else { return }
        
        logger.info("Starting TunnelServer on port \(port)")
        
        do {
            let router = Router(context: BasicRequestContext.self)
            
            // Add middleware
            router.add(middleware: LogRequestsMiddleware(.info))
            
            // Health check endpoint
            router.get("/health") { _, _ -> HTTPResponse.Status in
                .ok
            }
            
            // Info endpoint
            router.get("/info") { _, _ -> Response in
                let info = [
                    "name": "VibeTunnel",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                    "uptime": ProcessInfo.processInfo.systemUptime
                ]
                
                let jsonData = try! JSONSerialization.data(withJSONObject: info)
                var buffer = ByteBuffer()
                buffer.writeBytes(jsonData)
                
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: buffer)
                )
            }
            
            // Simple test endpoint
            let portNumber = self.port  // Capture port value before closure
            router.get("/") { _, _ -> Response in
                let html = """
                <!DOCTYPE html>
                <html>
                <head>
                    <title>VibeTunnel Server</title>
                    <style>
                        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; }
                        h1 { color: #333; }
                        .status { color: green; font-weight: bold; }
                    </style>
                </head>
                <body>
                    <h1>VibeTunnel Server</h1>
                    <p class="status">Server is running on port \(portNumber)</p>
                    <p>Available endpoints:</p>
                    <ul>
                        <li><a href="/health">/health</a> - Health check</li>
                        <li><a href="/info">/info</a> - Server information</li>
                        <li><a href="/sessions">/sessions</a> - List tty-fwd sessions</li>
                    </ul>
                </body>
                </html>
                """
                
                var buffer = ByteBuffer()
                buffer.writeString(html)
                
                return Response(
                    status: .ok,
                    headers: [.contentType: "text/html"],
                    body: ResponseBody(byteBuffer: buffer)
                )
            }
            
            // Sessions endpoint - calls tty-fwd --list-sessions
            router.get("/sessions") { _, _ -> Response in
                let ttyManager = TTYForwardManager.shared
                guard let process = ttyManager.createTTYForwardProcess(with: ["--list-sessions"]) else {
                    self.logger.error("Failed to create tty-fwd process")
                    let errorJson = "{\"error\": \"tty-fwd binary not found\"}"
                    var buffer = ByteBuffer()
                    buffer.writeString(errorJson)
                    return Response(
                        status: .internalServerError,
                        headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: buffer)
                    )
                }
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        // Read the JSON output
                        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        var buffer = ByteBuffer()
                        buffer.writeBytes(outputData)
                        
                        return Response(
                            status: .ok,
                            headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: buffer)
                        )
                    } else {
                        // Read error output
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        self.logger.error("tty-fwd failed with status \(process.terminationStatus): \(errorString)")
                        
                        let errorJson = "{\"error\": \"Failed to list sessions: \(errorString.replacingOccurrences(of: "\"", with: "\\\""))\"}"
                        var buffer = ByteBuffer()
                        buffer.writeString(errorJson)
                        return Response(
                            status: .internalServerError,
                            headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: buffer)
                        )
                    }
                } catch {
                    self.logger.error("Failed to run tty-fwd: \(error)")
                    let errorJson = "{\"error\": \"Failed to execute tty-fwd: \(error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\""))\"}"
                    var buffer = ByteBuffer()
                    buffer.writeString(errorJson)
                    return Response(
                        status: .internalServerError,
                        headers: [.contentType: "application/json"],
                        body: ResponseBody(byteBuffer: buffer)
                    )
                }
            }
            
            // Create application configuration
            let configuration = ApplicationConfiguration(
                address: .hostname("127.0.0.1", port: port),
                serverName: "VibeTunnel"
            )
            
            // Create the application
            let app = Application(
                responder: router.buildResponder(),
                configuration: configuration,
                logger: logger
            )
            
            // Store the app reference first
            self.app = app
            
            // Run the server in a detached task to ensure it keeps running
            serverTask = Task.detached(priority: .background) { [weak self, logger] in
                do {
                    logger.info("Starting Hummingbird application...")
                    try await app.run()
                    logger.info("Hummingbird application stopped")
                } catch {
                    logger.error("Hummingbird error: \(error)")
                    await MainActor.run { [weak self] in
                        self?.lastError = error
                        self?.isRunning = false
                    }
                    throw error
                }
            }
            
            // Wait for the server to actually start listening
            var serverStarted = false
            for _ in 0..<10 { // Try for up to 1 second
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                
                // Check if the server is actually listening
                if await isServerListening(on: port) {
                    serverStarted = true
                    break
                }
            }
            
            if serverStarted {
                isRunning = true
                logger.info("Server started and listening on port \(port)")
            } else {
                throw ServerError.failedToStart("Server did not start listening on port \(port)")
            }
            
        } catch {
            lastError = error
            isRunning = false
            throw error
        }
    }
    
    public func stop() async throws {
        guard isRunning else { return }
        
        logger.info("Stopping server...")
        
        // Cancel the server task - this will stop the application
        serverTask?.cancel()
        serverTask = nil
        
        // Clear the application reference
        self.app = nil
        
        isRunning = false
    }
    
    /// Check if the server is actually listening on the specified port
    private func isServerListening(on port: Int) async -> Bool {
        do {
            let url = URL(string: "http://127.0.0.1:\(port)/health")!
            let request = URLRequest(url: url, timeoutInterval: 1.0)
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Server not yet ready
        }
        return false
    }
}