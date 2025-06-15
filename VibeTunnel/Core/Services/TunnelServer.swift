//
//  TunnelServer.swift
//  VibeTunnel
//
//  Created by VibeTunnel on 15.06.25.
//

import Foundation
import Hummingbird
import AppKit
import Logging
import os

@MainActor
final class TunnelServer: ObservableObject {
    private var app: HBApplication?
    private let port: Int
    private let logger = Logger(label: "VibeTunnel.TunnelServer")
    
    @Published var isRunning = false
    @Published var lastError: Error?
    
    init(port: Int = 8080) {
        self.port = port
    }
    
    func start() async throws {
        logger.info("Starting tunnel server on port \(port)")
        
        let router = HBRouter()
        
        // Serve a simple HTML page at the root
        router.get("/") { request, context in
            let html = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>VibeTunnel</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                        max-width: 800px;
                        margin: 0 auto;
                        padding: 2rem;
                        background-color: #f5f5f7;
                        color: #1d1d1f;
                    }
                    .container {
                        background-color: white;
                        border-radius: 12px;
                        padding: 2rem;
                        box-shadow: 0 2px 8px rgba(0,0,0,0.1);
                    }
                    h1 {
                        color: #0071e3;
                        margin-bottom: 0.5rem;
                    }
                    .status {
                        display: inline-block;
                        padding: 0.25rem 0.75rem;
                        background-color: #30d158;
                        color: white;
                        border-radius: 100px;
                        font-size: 0.875rem;
                        font-weight: 500;
                    }
                    .info {
                        margin-top: 2rem;
                        padding: 1rem;
                        background-color: #f5f5f7;
                        border-radius: 8px;
                    }
                    .endpoint {
                        font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace;
                        background-color: #e8e8ed;
                        padding: 0.2rem 0.5rem;
                        border-radius: 4px;
                    }
                    a {
                        color: #0071e3;
                        text-decoration: none;
                    }
                    a:hover {
                        text-decoration: underline;
                    }
                </style>
            </head>
            <body>
                <div class="container">
                    <h1>VibeTunnel</h1>
                    <p class="status">Server Running</p>
                    <p>Connect to AI providers with a unified interface.</p>
                    
                    <div class="info">
                        <h2>API Endpoints</h2>
                        <ul>
                            <li><span class="endpoint">GET /</span> - This page</li>
                            <li><span class="endpoint">GET /health</span> - Health check</li>
                            <li><span class="endpoint">GET /info</span> - Server information</li>
                            <li><span class="endpoint">POST /tunnel/command</span> - Execute commands</li>
                            <li><span class="endpoint">WS /tunnel/stream</span> - WebSocket stream</li>
                        </ul>
                    </div>
                    
                    <div class="info">
                        <h2>Quick Start</h2>
                        <p>Test the health endpoint:</p>
                        <code class="endpoint">curl http://localhost:\(self.port)/health</code>
                    </div>
                    
                    <p style="margin-top: 2rem; font-size: 0.875rem; color: #86868b;">
                        Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.1") 
                        · <a href="https://github.com/amantus-ai/vibetunnel" target="_blank">GitHub</a>
                        · <a href="https://vibetunnel.sh" target="_blank">Documentation</a>
                    </p>
                </div>
            </body>
            </html>
            """
            
            return HBResponse(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: html))
            )
        }
        
        // Health check endpoint
        router.get("/health") { request, context in
            return [
                "status": "ok",
                "timestamp": Date().timeIntervalSince1970,
                "uptime": ProcessInfo.processInfo.systemUptime
            ]
        }
        
        // Server info endpoint
        router.get("/info") { request, context in
            return [
                "name": "VibeTunnel",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.1",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "100",
                "port": self.port,
                "platform": "macOS"
            ]
        }
        
        // Command endpoint
        router.post("/tunnel/command") { request, context in
            struct CommandRequest: Decodable {
                let command: String
                let args: [String]?
            }
            
            struct CommandResponse: Encodable {
                let success: Bool
                let message: String
                let timestamp: Date
            }
            
            do {
                let commandRequest = try await request.decode(as: CommandRequest.self, context: context)
                
                self.logger.info("Received command: \(commandRequest.command)")
                
                return CommandResponse(
                    success: true,
                    message: "Command '\(commandRequest.command)' received",
                    timestamp: Date()
                )
            } catch {
                return CommandResponse(
                    success: false,
                    message: "Invalid request: \(error.localizedDescription)",
                    timestamp: Date()
                )
            }
        }
        
        // WebSocket endpoint for real-time communication
        router.ws("/tunnel/stream") { request, ws, context in
            self.logger.info("WebSocket connection established")
            
            // Send welcome message
            try await ws.send(text: "Welcome to VibeTunnel WebSocket stream")
            
            ws.onText { ws, text in
                self.logger.info("WebSocket received: \(text)")
                // Echo back with timestamp
                let response = "[\(Date().ISO8601Format())] Echo: \(text)"
                try await ws.send(text: response)
            }
            
            ws.onClose { ws, closeCode in
                self.logger.info("WebSocket connection closed with code: \(closeCode)")
            }
        }
        
        // Configure and create the application
        var configuration = HBApplication.Configuration()
        configuration.address = .hostname("127.0.0.1", port: self.port)
        configuration.serverName = "VibeTunnel/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.1")"
        
        let app = HBApplication(
            configuration: configuration,
            router: router
        )
        
        self.app = app
        
        // Update state
        await MainActor.run {
            self.isRunning = true
        }
        
        logger.info("VibeTunnel server started on http://localhost:\(self.port)")
        
        // Run the server
        try await app.run()
    }
    
    func stop() async {
        logger.info("Stopping tunnel server")
        
        await app?.stop()
        app = nil
        
        await MainActor.run {
            isRunning = false
        }
    }
}

// MARK: - Integration with AppDelegate

extension AppDelegate {
    func startTunnelServer() {
        Task {
            do {
                let portString = UserDefaults.standard.string(forKey: "serverPort") ?? "8080"
                let port = Int(portString) ?? 8080
                let tunnelServer = TunnelServer(port: port)
                
                // Store reference if needed
                // self.tunnelServer = tunnelServer
                
                try await tunnelServer.start()
            } catch {
                os_log(.error, "Failed to start tunnel server: %{public}@", error.localizedDescription)
                
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