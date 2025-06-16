//
//  ServerManager.swift
//  VibeTunnel
//
//  Manages server lifecycle and switching between server modes
//

import Foundation
import SwiftUI
import Combine
import OSLog
import Observation

/// Manages the active server and handles switching between modes
@MainActor
@Observable
class ServerManager {
    static let shared = ServerManager()
    
    private var serverModeString: String {
        get { UserDefaults.standard.string(forKey: "serverMode") ?? ServerMode.rust.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "serverMode") }
    }
    
    var port: String {
        get { UserDefaults.standard.string(forKey: "serverPort") ?? "4020" }
        set { UserDefaults.standard.set(newValue, forKey: "serverPort") }
    }
    
    private var cleanupOnStartup: Bool {
        get { UserDefaults.standard.bool(forKey: "cleanupOnStartup") }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupOnStartup") }
    }
    
    private(set) var currentServer: ServerProtocol?
    private(set) var isRunning = false
    private(set) var isSwitching = false
    private(set) var lastError: Error?
    
    private let logger = Logger(subsystem: "com.steipete.VibeTunnel", category: "ServerManager")
    private var cancellables = Set<AnyCancellable>()
    private let logSubject = PassthroughSubject<ServerLogEntry, Never>()
    
    var serverMode: ServerMode {
        get { ServerMode(rawValue: serverModeString) ?? .rust }
        set { serverModeString = newValue.rawValue }
    }
    
    var logPublisher: AnyPublisher<ServerLogEntry, Never> {
        logSubject.eraseToAnyPublisher()
    }
    
    // Modern async stream for logs
    var logStream: AsyncStream<ServerLogEntry> {
        AsyncStream { continuation in
            // Use logPublisher directly without storing the cancellable
            Task { @MainActor in
                for await entry in logPublisher.values {
                    continuation.yield(entry)
                }
                continuation.finish()
            }
        }
    }
    
    private init() {
        setupObservers()
    }
    
    private func setupObservers() {
        // Watch for server mode changes when the value actually changes
        // Since we're using @AppStorage, we need to observe changes differently
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleServerModeChange()
                }
            }
            .store(in: &cancellables)
    }
    
    /// Start the server with current configuration
    func start() async {
        // Check if we already have a running server
        if let existingServer = currentServer {
            logger.info("Server already running on port \(existingServer.port)")
            
            // Ensure our state is synced
            isRunning = true
            lastError = nil
            ServerMonitor.shared.isServerRunning = true
            
            // Log for clarity
            logSubject.send(ServerLogEntry(
                level: .info,
                message: "\(serverMode.displayName) server already running on port \(port)",
                source: serverMode
            ))
            return
        }
        
        // Log that we're starting a server
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "Starting \(serverMode.displayName) server on port \(port)...",
            source: serverMode
        ))
        
        do {
            let server = createServer(for: serverMode)
            server.port = port
            
            // Subscribe to server logs
            server.logPublisher
                .sink { [weak self] entry in
                    self?.logSubject.send(entry)
                }
                .store(in: &cancellables)
            
            try await server.start()
            
            currentServer = server
            isRunning = true
            lastError = nil
            
            logger.info("Started \(self.serverMode.displayName) server on port \(self.port)")
            
            // Update ServerMonitor for compatibility
            ServerMonitor.shared.isServerRunning = true
            
            // Trigger cleanup of old sessions after server starts
            await triggerInitialCleanup()
            
        } catch {
            logger.error("Failed to start server: \(error.localizedDescription)")
            logSubject.send(ServerLogEntry(
                level: .error,
                message: "Failed to start \(serverMode.displayName) server: \(error.localizedDescription)",
                source: serverMode
            ))
            lastError = error
            
            // Check if server is actually running despite the error
            if let server = currentServer, server.isRunning {
                logger.warning("Server reported as running despite startup error, syncing state")
                isRunning = true
                ServerMonitor.shared.isServerRunning = true
            } else {
                isRunning = false
                ServerMonitor.shared.isServerRunning = false
            }
        }
    }
    
    /// Stop the current server
    func stop() async {
        guard let server = currentServer else {
            logger.warning("No server running")
            return
        }
        
        let serverType = server.serverType
        logger.info("Stopping \(serverType.displayName) server")
        
        // Log that we're stopping the server
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "Stopping \(serverType.displayName) server...",
            source: serverType
        ))
        
        await server.stop()
        currentServer = nil
        isRunning = false
        
        // Log that the server has stopped
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "\(serverType.displayName) server stopped",
            source: serverType
        ))
        
        // Update ServerMonitor for compatibility
        ServerMonitor.shared.isServerRunning = false
    }
    
    /// Restart the current server
    func restart() async {
        await stop()
        await start()
    }
    
    /// Switch to a different server mode
    func switchMode(to mode: ServerMode) async {
        guard mode != serverMode else { return }
        
        isSwitching = true
        defer { isSwitching = false }
        
        let oldMode = serverMode
        logger.info("Switching from \(oldMode.displayName) to \(mode.displayName)")
        
        // Log the mode switch with a clear separator
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "════════════════════════════════════════════════════════",
            source: oldMode
        ))
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "Switching server mode: \(oldMode.displayName) → \(mode.displayName)",
            source: oldMode
        ))
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "════════════════════════════════════════════════════════",
            source: oldMode
        ))
        
        // Stop current server if running
        if currentServer != nil {
            await stop()
        }
        
        // Add a small delay for visual clarity in logs
        try? await Task.sleep(for: .milliseconds(500))
        
        // Update mode
        serverMode = mode
        
        // Start new server
        await start()
        
        // Log completion
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "════════════════════════════════════════════════════════",
            source: mode
        ))
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "Server mode switch completed successfully",
            source: mode
        ))
        logSubject.send(ServerLogEntry(
            level: .info,
            message: "════════════════════════════════════════════════════════",
            source: mode
        ))
    }
    
    private func handleServerModeChange() async {
        // This is called when serverMode changes via AppStorage
        // If we have a running server, switch to the new mode
        if currentServer != nil {
            await switchMode(to: serverMode)
        }
    }
    
    private func createServer(for mode: ServerMode) -> ServerProtocol {
        switch mode {
        case .hummingbird:
            return HummingbirdServer()
        case .rust:
            return RustServer()
        }
    }
    
    /// Trigger cleanup of exited sessions after server startup
    private func triggerInitialCleanup() async {
        // Check if cleanup on startup is enabled
        guard cleanupOnStartup else {
            logger.info("Cleanup on startup is disabled in settings")
            return
        }
        
        logger.info("Triggering initial cleanup of exited sessions")
        
        // Small delay to ensure server is fully ready
        try? await Task.sleep(for: .milliseconds(500))
        
        do {
            // Create URL for cleanup endpoint
            let url = URL(string: "http://localhost:\(port)/api/cleanup-exited")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            
            // Make the cleanup request
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    // Try to parse the response
                    if let jsonData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let cleanedCount = jsonData["cleaned_count"] as? Int {
                        logger.info("Initial cleanup completed: cleaned \(cleanedCount) exited sessions")
                        logSubject.send(ServerLogEntry(
                            level: .info,
                            message: "Cleaned up \(cleanedCount) exited sessions on startup",
                            source: serverMode
                        ))
                    } else {
                        logger.info("Initial cleanup completed successfully")
                        logSubject.send(ServerLogEntry(
                            level: .info,
                            message: "Cleaned up exited sessions on startup",
                            source: serverMode
                        ))
                    }
                } else {
                    logger.warning("Initial cleanup returned status code: \(httpResponse.statusCode)")
                }
            }
        } catch {
            // Log the error but don't fail startup
            logger.warning("Failed to trigger initial cleanup: \(error.localizedDescription)")
            logSubject.send(ServerLogEntry(
                level: .warning,
                message: "Could not clean up old sessions: \(error.localizedDescription)",
                source: serverMode
            ))
        }
    }
}