import Foundation
import OSLog

/// Task tracking for better debugging.
///
/// Provides task-local storage for debugging context during
/// asynchronous server operations.
enum ServerTaskContext {
    @TaskLocal static var taskName: String?

    @TaskLocal static var serverType: ServerMode?
}

/// Rust tty-fwd server implementation.
///
/// Manages the external tty-fwd Rust binary as a subprocess. This implementation
/// provides high-performance terminal multiplexing by leveraging the battle-tested
/// tty-fwd server. It handles process lifecycle, log streaming, and error recovery
/// while maintaining compatibility with the ServerProtocol interface.
@MainActor
final class RustServer: ServerProtocol {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.steipete.VibeTunnel", category: "RustServer")
    private var logContinuation: AsyncStream<ServerLogEntry>.Continuation?
    private let processQueue = DispatchQueue(label: "com.steipete.VibeTunnel.RustServer", qos: .userInitiated)

    /// Actor to handle process operations on background thread.
    ///
    /// Isolates process management operations to prevent blocking the main thread
    /// while maintaining Swift concurrency safety.
    private actor ProcessHandler {
        private let queue = DispatchQueue(
            label: "com.steipete.VibeTunnel.RustServer.ProcessHandler",
            qos: .userInitiated
        )

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

    var port: String = "" {
        didSet {
            // If server is running and port changed, we need to restart
            if isRunning && oldValue != port {
                Task {
                    try? await restart()
                }
            }
        }
    }

    let logStream: AsyncStream<ServerLogEntry>

    init() {
        var localContinuation: AsyncStream<ServerLogEntry>.Continuation?
        self.logStream = AsyncStream { continuation in
            localContinuation = continuation
        }
        self.logContinuation = localContinuation
    }

    func start() async throws {
        guard !isRunning else {
            logger.warning("Rust server already running")
            return
        }

        guard !port.isEmpty else {
            let error = RustServerError.invalidPort
            logger.error("Port not configured")
            logContinuation?.yield(ServerLogEntry(level: .error, message: error.localizedDescription, source: .rust))
            throw error
        }

        logger.info("Starting Rust tty-fwd server on port \(self.port)")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Initializing Rust tty-fwd server...",
            source: .rust
        ))

        // Get the tty-fwd binary path
        let binaryPath = Bundle.main.path(forResource: "tty-fwd", ofType: nil)
        guard let binaryPath else {
            let error = RustServerError.binaryNotFound
            logger.error("tty-fwd binary not found in bundle")
            logContinuation?.yield(ServerLogEntry(level: .error, message: error.localizedDescription, source: .rust))
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
            if let fileSize = attributes[.size] as? NSNumber {
                logger.info("tty-fwd binary size: \(fileSize.intValue) bytes")
            }
            
            // Log binary architecture info
            logContinuation?.yield(ServerLogEntry(
                level: .debug,
                message: "Binary path: \(binaryPath)",
                source: .rust
            ))
        } else if !fileExists {
            logger.error("tty-fwd binary NOT FOUND at: \(binaryPath)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Binary not found at: \(binaryPath)",
                source: .rust
            ))
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
        
        if !webPublicExists {
            logger.error("Web public directory NOT FOUND at: \(webPublicPath.path)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Web public directory not found at: \(webPublicPath.path)",
                source: .rust
            ))
            // List contents of Resources directory for debugging
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: resourcesPath) {
                logger.debug("Resources directory contents: \(contents.joined(separator: ", "))")
            }
        }

        // Use absolute path for static directory
        let staticPath = webPublicPath.path

        // Build command to run tty-fwd through login shell
        // Use bind address from ServerManager to control server accessibility
        let bindAddress = ServerManager.shared.bindAddress

        var ttyFwdCommand = "\"\(binaryPath)\" --static-path \"\(staticPath)\" --serve \(bindAddress):\(port)"

        // Add password flag if password protection is enabled
        // Only check if password exists, don't retrieve it yet
        if UserDefaults.standard.bool(forKey: "dashboardPasswordEnabled") && DashboardKeychain.shared.hasPassword() {
            // Defer actual password retrieval until first authenticated request
            // For now, we'll use a placeholder that the Rust server will replace
            // when it needs to authenticate
            logger.info("Password protection enabled, deferring keychain access")
            // Note: The Rust server needs to be updated to support lazy password loading
            // For now, we still need to access the keychain here
            if let password = DashboardKeychain.shared.getPassword() {
                // Escape the password for shell
                let escapedPassword = password.replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "$", with: "\\$")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "\\", with: "\\\\")
                ttyFwdCommand += " --password \"\(escapedPassword)\""
            }
        }
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

            await MainActor.run {
                self.isRunning = true
            }

            // Check for early exit on background thread
            try await Task.detached(priority: .userInitiated) {
                try await Task.sleep(for: .milliseconds(100))
            }.value
            // Try to read any immediate error output
            if let stderrPipe = self.stderrPipe {
                let errorHandle = stderrPipe.fileHandleForReading
                if let immediateError = try? errorHandle.read(upToCount: 1024),
                   !immediateError.isEmpty,
                   let errorString = String(data: immediateError, encoding: .utf8) {
                    logger.error("Immediate stderr output: \(errorString)")
                    
                    // Check for specific errors
                    if errorString.contains("Address already in use") {
                        // Extract port number if possible
                        let portPattern = #"Address already in use.*?(\d+)"#
                        if let regex = try? NSRegularExpression(pattern: portPattern),
                           regex.firstMatch(in: errorString, range: NSRange(errorString.startIndex..., in: errorString)) != nil {
                            // Port conflict detected
                            logContinuation?.yield(ServerLogEntry(
                                level: .error,
                                message: "Port \(port) is already in use. Another process is using this port.",
                                source: .rust
                            ))
                        }
                        
                        // Check what's using the port
                        if let conflict = await PortConflictResolver.shared.detectConflict(on: Int(port) ?? 4020) {
                            let errorMessage = "Port \(port) is used by \(conflict.process.name)"
                            logContinuation?.yield(ServerLogEntry(
                                level: .error,
                                message: errorMessage,
                                source: .rust
                            ))
                        }
                    }
                }
            }
            
            // Give the server more time to fully start on background thread
            try await Task.detached(priority: .userInitiated) {
                try await Task.sleep(for: .milliseconds(900))
            }.value

            // Check if process is still running
            if !process.isRunning {
                let exitCode = process.terminationStatus
                logger.error("Process terminated with exit code: \(exitCode)")
                
                var errorDetails = "Exit code: \(exitCode)"
                
                // Try to read any error output
                if let stderrPipe = self.stderrPipe {
                    let errorData = stderrPipe.fileHandleForReading.availableData
                    if !errorData.isEmpty, let errorOutput = String(data: errorData, encoding: .utf8) {
                        logger.error("Process stderr: \(errorOutput)")
                        errorDetails += "\nError output: \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
                        logContinuation?.yield(ServerLogEntry(
                            level: .error,
                            message: "Process error: \(errorOutput)",
                            source: .rust
                        ))
                    }
                }
                
                // Also check stdout for any diagnostic info
                if let stdoutPipe = self.stdoutPipe {
                    let outputData = stdoutPipe.fileHandleForReading.availableData
                    if !outputData.isEmpty, let output = String(data: outputData, encoding: .utf8) {
                        logger.error("Process stdout before termination: \(output)")
                        errorDetails += "\nLast output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }
                
                logContinuation?.yield(ServerLogEntry(
                    level: .error,
                    message: "Server process failed to start - \(errorDetails)",
                    source: .rust
                ))

                throw RustServerError.processFailedToStart
            }

            logger.info("Rust server process started, performing health check...")
            logContinuation?.yield(ServerLogEntry(level: .info, message: "Performing health check...", source: .rust))

            // Perform health check to ensure server is actually responding
            let isHealthy = await performHealthCheck(maxAttempts: 10, delaySeconds: 0.5)

            if isHealthy {
                logger.info("Rust server started successfully and is responding")
                logContinuation?.yield(ServerLogEntry(level: .info, message: "Health check passed ✓", source: .rust))
                logContinuation?.yield(ServerLogEntry(
                    level: .info,
                    message: "Rust tty-fwd server is ready",
                    source: .rust
                ))

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
                logContinuation?.yield(ServerLogEntry(
                    level: .error,
                    message: "Health check failed - server not responding",
                    source: .rust
                ))

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
            
            // Log more detailed error information
            let errorMessage: String
            if let rustError = error as? RustServerError {
                errorMessage = rustError.localizedDescription
            } else if let nsError = error as NSError? {
                errorMessage = "\(nsError.localizedDescription) (Code: \(nsError.code), Domain: \(nsError.domain))"
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] {
                    logger.error("Underlying error: \(String(describing: underlyingError))")
                }
            } else {
                errorMessage = String(describing: error)
            }
            
            logger.error("Failed to start Rust server: \(errorMessage)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Failed to start Rust server: \(errorMessage)",
                source: .rust
            ))
            throw error
        }
    }

    func stop() async {
        guard let process, isRunning else {
            logger.warning("Rust server not running")
            return
        }

        logger.info("Stopping Rust server")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Shutting down Rust tty-fwd server...",
            source: .rust
        ))

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
            logContinuation?.yield(ServerLogEntry(
                level: .warning,
                message: "Force killed server after timeout",
                source: .rust
            ))
        }

        // Clean up
        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.outputTask = nil
        self.errorTask = nil
        isRunning = false

        logger.info("Rust server stopped")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Rust tty-fwd server shutdown complete",
            source: .rust
        ))
    }

    func restart() async throws {
        logger.info("Restarting Rust server")
        logContinuation?.yield(ServerLogEntry(level: .info, message: "Restarting server", source: .rust))

        await stop()
        try await start()
    }

    // MARK: - Private Methods

    private func performHealthCheck(maxAttempts: Int, delaySeconds: Double) async -> Bool {
        guard let healthURL = URL(string: "http://127.0.0.1:\(port)/api/health") else {
            return false
        }

        for attempt in 1...maxAttempts {
            do {
                // Create request with short timeout
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = 2.0

                logContinuation?.yield(ServerLogEntry(
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
                    logContinuation?.yield(ServerLogEntry(
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
                    guard let self, let pipe = stdoutPipe else { return }

                    let handle = pipe.fileHandleForReading
                    self.logger.debug("Starting stdout monitoring for Rust server on port \(currentPort)")

                    while !Task.isCancelled {
                        autoreleasepool {
                            let data = handle.availableData
                            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                                let lines = output.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .components(separatedBy: .newlines)
                                for line in lines where !line.isEmpty {
                                    // Skip shell initialization messages
                                    if line.contains("zsh:") || line.hasPrefix("Last login:") {
                                        continue
                                    }
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        let level = self.detectLogLevel(from: line)
                                        self.logContinuation?.yield(ServerLogEntry(
                                            level: level,
                                            message: line,
                                            source: .rust
                                        ))
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
                    guard let self, let pipe = stderrPipe else { return }

                    let handle = pipe.fileHandleForReading
                    self.logger.debug("Starting stderr monitoring for Rust server on port \(currentPort)")

                    while !Task.isCancelled {
                        autoreleasepool {
                            let data = handle.availableData
                            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                                let lines = output.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .components(separatedBy: .newlines)
                                for line in lines where !line.isEmpty {
                                    // Skip shell initialization messages
                                    if line.contains("zsh:") || line.hasPrefix("Last login:") {
                                        continue
                                    }
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        self.logContinuation?.yield(ServerLogEntry(
                                            level: .error,
                                            message: line,
                                            source: .rust
                                        ))
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
        guard let process else { return }

        // Wait for process exit on background thread
        await processHandler.waitForExit(process)

        if self.isRunning {
            // Unexpected termination
            let exitCode = process.terminationStatus
            self.logger.error("Rust server terminated unexpectedly with exit code: \(exitCode)")
            self.logContinuation?.yield(ServerLogEntry(
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
                    self.logContinuation?.yield(ServerLogEntry(
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

    private func withTimeoutOrNil<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    )
        async -> T?
    {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }

            if let result = await group.next() {
                group.cancelAll()
                return result
            }
            group.cancelAll()
            return nil
        }
    }
}

// MARK: - Errors

enum RustServerError: LocalizedError {
    case binaryNotFound
    case processFailedToStart
    case serverNotResponding
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "The tty-fwd binary was not found in the app bundle"
        case .processFailedToStart:
            "The server process failed to start"
        case .serverNotResponding:
            "The server process started but is not responding to health checks"
        case .invalidPort:
            "Server port is not configured"
        }
    }
}
