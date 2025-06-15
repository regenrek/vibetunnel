//
//  TunnelServer.swift
//  VibeTunnel
//
//  Created by VibeTunnel on 15.06.25.
//

import Foundation
import Hummingbird
import AppKit

@MainActor
final class TunnelServer: ObservableObject {
    private var app: HBApplication?
    private let port: Int
    
    @Published var isRunning = false
    @Published var lastError: Error?
    
    init(port: Int = 8080) {
        self.port = port
    }
    
    func start() async throws {
        let router = HBRouter()
        
        // Health check endpoint
        router.get("/health") { request, context in
            return ["status": "ok", "timestamp": Date().timeIntervalSince1970]
        }
        
        // Tunnel endpoint for Claude Code control
        router.post("/tunnel/command") { request, context in
            struct CommandRequest: Decodable {
                let command: String
                let args: [String]?
            }
            
            struct CommandResponse: Encodable {
                let success: Bool
                let output: String?
                let error: String?
            }
            
            do {
                let commandRequest = try await request.decode(as: CommandRequest.self, context: context)
                
                // Handle the command (placeholder for actual implementation)
                // This is where you'd interface with Claude Code or terminal apps
                print("Received command: \(commandRequest.command)")
                
                return CommandResponse(
                    success: true,
                    output: "Command executed: \(commandRequest.command)",
                    error: nil
                )
            } catch {
                return CommandResponse(
                    success: false,
                    output: nil,
                    error: error.localizedDescription
                )
            }
        }
        
        // WebSocket endpoint for real-time communication
        router.ws("/tunnel/stream") { request, ws, context in
            ws.onText { ws, text in
                // Echo back for now - implement actual command handling
                try await ws.send(text: "Received: \(text)")
            }
        }
        
        // Info endpoint
        router.get("/info") { request, context in
            return [
                "name": "VibeTunnel",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "1.0",
                "port": self.port
            ]
        }
        
        var configuration = HBApplication.Configuration()
        configuration.address = .hostname("127.0.0.1", port: self.port)
        
        let app = HBApplication(
            configuration: configuration,
            router: router
        )
        
        self.app = app
        self.isRunning = true
        
        // Run the server
        try await app.run()
    }
    
    func stop() async {
        await app?.stop()
        app = nil
        isRunning = false
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