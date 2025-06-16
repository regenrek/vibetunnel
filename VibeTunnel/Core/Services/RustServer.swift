//
//  RustServer.swift
//  VibeTunnel
//
//  Rust tty-fwd binary server implementation
//

import Foundation
import Combine
import OSLog

/// Task tracking for better debugging
enum ServerTaskContext {
    @TaskLocal
    static var taskName: String?
    
    @TaskLocal
    static var serverType: ServerMode?
}

/// Rust tty-fwd server implementation
@MainActor
final class RustServer: ServerProtocol {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    
    private let logger = Logger(subsystem: "com.steipete.VibeTunnel", category: "RustServer")
    private let logSubject = PassthroughSubject<ServerLogEntry, Never>()
    private let processQueue = DispatchQueue(label: "com.steipete.VibeTunnel.RustServer", qos: .userInitiated)
    
    // Actor to handle process operations on background thread
    private actor ProcessHandler {
        private let queue = DispatchQueue(label: "com.steipete.VibeTunnel.RustServer.ProcessHandler", qos: .userInitiated)
        
        func runProcess(_ process: Process) async throws {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try process.run()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        func waitForExit(_ process: Process) async {
            await withCheckedContinuation { continuation in
                queue.async {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        }
        
        func terminateProcess(_ process: Process) async {
            await withCheckedContinuation { continuation in
                queue.async {
                    process.terminate()
                    continuation.resume()
                }
            }
        }
    }
    
    private let processHandler = ProcessHandler()
    
    var serverType: ServerMode { .rust }
    
    private(set) var isRunning = false
    
    var port: String = "4020" {
        didSet {
            // If server is running and port changed, we need to restart
            if isRunning && oldValue != port {
                Task {
                    try? await restart()
                }
            }
        }
    }
    
    var logPublisher: AnyPublisher<ServerLogEntry, Never> {
        logSubject.eraseToAnyPublisher()
    }
    
    func start() async throws {
        guard !isRunning else {
            logger.warning("Rust server already running")
            return
        }
        
        logger.info("Starting Rust tty-fwd server on port \(self.port)")
        logSubject.send(ServerLogEntry(level: .info, message: "Initializing Rust tty-fwd server...", source: .rust))
        
        // Get the tty-fwd binary path
        let binaryPath = Bundle.main.path(forResource: "tty-fwd", ofType: nil)
        guard let binaryPath = binaryPath else {
            let error = RustServerError.binaryNotFound
            logger.error("tty-fwd binary not found in bundle")
            logSubject.send(ServerLogEntry(level: .error, message: error.localizedDescription, source: .rust))
            throw error
        }
        
        // Ensure binary is executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)
        
        // Verify binary exists and is executable
        var isDirectory: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: binaryPath, isDirectory: &isDirectory)
        logger.info("tty-fwd binary exists: \(fileExists), is directory: \(isDirectory.boolValue)")
        
        if fileExists && !isDirectory.boolValue {
            let attributes = try FileManager.default.attributesOfItem(atPath: binaryPath)
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                logger.info("tty-fwd binary permissions: \(String(permissions.intValue, radix: 8))")
            }
        }
        
        // Create the process using login shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        
        // Get the Resources directory path
        let bundlePath = Bundle.main.bundlePath
        let resourcesPath = Bundle.main.resourcePath ?? bundlePath
        
        // Set working directory to Resources directory where both tty-fwd and web folder exist
        process.currentDirectoryURL = URL(fileURLWithPath: resourcesPath)
        logger.info("Setting working directory to: \(resourcesPath)")
        
        // The web/public directory should be at web/public relative to Resources
        let webPublicPath = URL(fileURLWithPath: resourcesPath).appendingPathComponent("web/public")
        let webPublicExists = FileManager.default.fileExists(atPath: webPublicPath.path)
        logger.info("Web public directory at \(webPublicPath.path) exists: \(webPublicExists)")
        
        let staticPath = "web/public"
        
        // Build command to run tty-fwd through login shell
        let ttyFwdCommand = "\"\(binaryPath)\" --static-path \(staticPath) --serve \(port)"
        process.arguments = ["-l", "-c", ttyFwdCommand]
        
        logger.info("Executing command: /bin/zsh -l -c \"\(ttyFwdCommand)\"")
        logger.info("Working directory: \(resourcesPath)")
        
        // Set up environment - login shell will load the rest
        var environment = ProcessInfo.processInfo.environment
        environment["RUST_LOG"] = "info"
        process.environment = environment
        
        // Set up pipes for stdout and stderr
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        
        // Start monitoring output
        startOutputMonitoring()
        
        // Start the process on background thread
        do {
            try await processHandler.runProcess(process)
            
            isRunning = true
            
            // Give the server a moment to start
            try await Task.sleep(for: .seconds(1))
            
            // Check if process is still running
            if !process.isRunning {
                logger.error("Process terminated with exit code: \(process.terminationStatus)")
                
                // Try to read any error output
                if let stderrPipe = self.stderrPipe {
                    let errorData = stderrPipe.fileHandleForReading.availableData
                    if !errorData.isEmpty, let errorOutput = String(data: errorData, encoding: .utf8) {
                        logger.error("Process stderr: \(errorOutput)")
                        logSubject.send(ServerLogEntry(level: .error, message: "Process error: \(errorOutput)", source: .rust))
                    }
                }
                
                throw RustServerError.processFailedToStart
            }
            
            logger.info("Rust server process started, performing health check...")
            logSubject.send(ServerLogEntry(level: .info, message: "Performing health check...", source: .rust))
            
            // Perform health check to ensure server is actually responding
            let isHealthy = await performHealthCheck(maxAttempts: 10, delaySeconds: 0.5)
            
            if isHealthy {
                logger.info("Rust server started successfully and is responding")
                logSubject.send(ServerLogEntry(level: .info, message: "Health check passed ✓", source: .rust))
                logSubject.send(ServerLogEntry(level: .info, message: "Rust tty-fwd server is ready", source: .rust))
                
                // Monitor process termination with task context
                Task {
                    await ServerTaskContext.$taskName.withValue("RustServer-monitor-\(port)") {
                        await ServerTaskContext.$serverType.withValue(.rust) {
                            await monitorProcessTermination()
                        }
                    }
                }
            } else {
                // Server process is running but not responding
                logger.error("Rust server process started but is not responding to health checks")
                logSubject.send(ServerLogEntry(level: .error, message: "Health check failed - server not responding", source: .rust))
                
                // Clean up the non-responsive process
                process.terminate()
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                isRunning = false
                
                throw RustServerError.serverNotResponding
            }
            
        } catch {
            isRunning = false
            logger.error("Failed to start Rust server: \(error.localizedDescription)")
            logSubject.send(ServerLogEntry(level: .error, message: "Failed to start: \(error.localizedDescription)", source: .rust))
            throw error
        }
    }
    
    func stop() async {
        guard let process = process, isRunning else {
            logger.warning("Rust server not running")
            return
        }
        
        logger.info("Stopping Rust server")
        logSubject.send(ServerLogEntry(level: .info, message: "Shutting down Rust tty-fwd server...", source: .rust))
        
        // Cancel output monitoring tasks
        outputTask?.cancel()
        errorTask?.cancel()
        
        // Terminate the process on background thread
        await processHandler.terminateProcess(process)
        
        // Wait for process to terminate (with timeout)
        let terminated: Void? = await withTimeoutOrNil(seconds: 5) { [self] in
            await self.processHandler.waitForExit(process)
        }
        
        if terminated == nil {
            // Force kill if termination timeout
            process.interrupt()
            logger.warning("Force killed Rust server after timeout")
            logSubject.send(ServerLogEntry(level: .warning, message: "Force killed server after timeout", source: .rust))
        }
        
        // Clean up
        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.outputTask = nil
        self.errorTask = nil
        isRunning = false
        
        logger.info("Rust server stopped")
        logSubject.send(ServerLogEntry(level: .info, message: "Rust tty-fwd server shutdown complete", source: .rust))
    }
    
    func restart() async throws {
        logger.info("Restarting Rust server")
        logSubject.send(ServerLogEntry(level: .info, message: "Restarting server", source: .rust))
        
        await stop()
        try await start()
    }
    
    // MARK: - Private Methods
    
    private func performHealthCheck(maxAttempts: Int, delaySeconds: Double) async -> Bool {
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        
        for attempt in 1...maxAttempts {
            do {
                // Create request with short timeout
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = 2.0
                
                logSubject.send(ServerLogEntry(
                    level: .debug,
                    message: "Health check attempt \(attempt)/\(maxAttempts)...",
                    source: .rust
                ))
                
                let (_, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    logger.debug("Health check succeeded on attempt \(attempt)")
                    return true
                }
            } catch {
                logger.debug("Health check attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt == maxAttempts {
                    logSubject.send(ServerLogEntry(
                        level: .warning,
                        message: "Health check failed after \(maxAttempts) attempts",
                        source: .rust
                    ))
                }
            }
            
            // Wait before next attempt (except on last attempt)
            if attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
        }
        
        return false
    }
    
    private func startOutputMonitoring() {
        // Capture pipes and port before starting detached tasks
        let stdoutPipe = self.stdoutPipe
        let stderrPipe = self.stderrPipe
        let currentPort = self.port
        
        // Monitor stdout on background thread
        outputTask = Task.detached { [weak self] in
            ServerTaskContext.$taskName.withValue("RustServer-stdout-\(currentPort)") {
                ServerTaskContext.$serverType.withValue(.rust) {
                    guard let self = self, let pipe = stdoutPipe else { return }
                    
                    let handle = pipe.fileHandleForReading
                    self.logger.debug("Starting stdout monitoring for Rust server on port \(currentPort)")
                    
                    while !Task.isCancelled {
                        autoreleasepool {
                            let data = handle.availableData
                            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                                let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
                                for line in lines where !line.isEmpty {
                                    // Skip shell initialization messages
                                    if line.contains("zsh:") || line.hasPrefix("Last login:") {
                                        continue
                                    }
                                    Task { @MainActor [weak self] in
                                        guard let self = self else { return }
                                        let level = self.detectLogLevel(from: line)
                                        self.logSubject.send(ServerLogEntry(level: level, message: line, source: .rust))
                                    }
                                }
                            }
                        }
                    }
                    
                    self.logger.debug("Stopped stdout monitoring for Rust server")
                }
            }
        }
        
        // Monitor stderr on background thread
        errorTask = Task.detached { [weak self] in
            ServerTaskContext.$taskName.withValue("RustServer-stderr-\(currentPort)") {
                ServerTaskContext.$serverType.withValue(.rust) {
                    guard let self = self, let pipe = stderrPipe else { return }
                    
                    let handle = pipe.fileHandleForReading
                    self.logger.debug("Starting stderr monitoring for Rust server on port \(currentPort)")
                    
                    while !Task.isCancelled {
                        autoreleasepool {
                            let data = handle.availableData
                            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                                let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
                                for line in lines where !line.isEmpty {
                                    // Skip shell initialization messages
                                    if line.contains("zsh:") || line.hasPrefix("Last login:") {
                                        continue
                                    }
                                    Task { @MainActor [weak self] in
                                        guard let self = self else { return }
                                        self.logSubject.send(ServerLogEntry(level: .error, message: line, source: .rust))
                                    }
                                }
                            }
                        }
                    }
                    
                    self.logger.debug("Stopped stderr monitoring for Rust server")
                }
            }
        }
    }
    
    private func monitorProcessTermination() async {
        guard let process = process else { return }
        
        // Wait for process exit on background thread
        await processHandler.waitForExit(process)
        
        if self.isRunning {
            // Unexpected termination
            let exitCode = process.terminationStatus
            self.logger.error("Rust server terminated unexpectedly with exit code: \(exitCode)")
            self.logSubject.send(ServerLogEntry(
                level: .error,
                message: "Server terminated unexpectedly with exit code: \(exitCode)",
                source: .rust
            ))
            
            self.isRunning = false
            
            // Auto-restart on unexpected termination
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.process == nil { // Only restart if not manually stopped
                    self.logger.info("Auto-restarting Rust server after crash")
                    self.logSubject.send(ServerLogEntry(
                        level: .info,
                        message: "Auto-restarting server after crash",
                        source: .rust
                    ))
                    try? await self.start()
                }
            }
        }
    }
    
    private func detectLogLevel(from line: String) -> ServerLogEntry.Level {
        let lowercased = line.lowercased()
        if lowercased.contains("error") || lowercased.contains("fatal") {
            return .error
        } else if lowercased.contains("warn") || lowercased.contains("warning") {
            return .warning
        } else if lowercased.contains("debug") || lowercased.contains("trace") {
            return .debug
        } else {
            return .info
        }
    }
    
    private func withTimeoutOrNil<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }
}

// MARK: - Errors

enum RustServerError: LocalizedError {
    case binaryNotFound
    case processFailedToStart
    case serverNotResponding
    
    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "The tty-fwd binary was not found in the app bundle"
        case .processFailedToStart:
            return "The server process failed to start"
        case .serverNotResponding:
            return "The server process started but is not responding to health checks"
        }
    }
}