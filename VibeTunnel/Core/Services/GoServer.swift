import Foundation
import OSLog

/// Go vibetunnel server implementation.
///
/// Manages the external vibetunnel Go binary as a subprocess. This implementation
/// provides high-performance terminal multiplexing by leveraging the Go-based
/// vibetunnel server. It handles process lifecycle, log streaming, and error recovery
/// while maintaining compatibility with the ServerProtocol interface.
@MainActor
final class GoServer: ServerProtocol {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "sh.vibetunnel.vibetunnel", category: "GoServer")
    private var logContinuation: AsyncStream<ServerLogEntry>.Continuation?
    private let processQueue = DispatchQueue(label: "sh.vibetunnel.vibetunnel.GoServer", qos: .userInitiated)

    /// Actor to handle process operations on background thread.
    ///
    /// Isolates process management operations to prevent blocking the main thread
    /// while maintaining Swift concurrency safety.
    private actor ProcessHandler {
        private let queue = DispatchQueue(
            label: "sh.vibetunnel.vibetunnel.GoServer.ProcessHandler",
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

    var serverType: ServerMode { .go }

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
            logger.warning("Go server already running")
            return
        }

        guard !port.isEmpty else {
            let error = GoServerError.invalidPort
            logger.error("Port not configured")
            logContinuation?.yield(ServerLogEntry(level: .error, message: error.localizedDescription, source: .go))
            throw error
        }

        logger.info("Starting Go vibetunnel server on port \(self.port)")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Initializing Go vibetunnel server...",
            source: .go
        ))

        // Get the vibetunnel binary path
        let binaryPath = Bundle.main.path(forResource: "vibetunnel", ofType: nil)

        // Check if Go was not available during build (indicated by .disabled file)
        let disabledPath = Bundle.main.path(forResource: "vibetunnel", ofType: "disabled")
        if disabledPath != nil {
            let error = GoServerError.goNotInstalled
            logger.error("Go was not available during build")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Go server is not available. Please install Go and rebuild the app to enable Go server support.",
                source: .go
            ))
            throw error
        }

        guard let binaryPath else {
            let error = GoServerError.binaryNotFound
            logger.error("vibetunnel binary not found in bundle")
            logContinuation?.yield(ServerLogEntry(level: .error, message: error.localizedDescription, source: .go))
            throw error
        }

        // Ensure binary is executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)

        // Verify binary exists and is executable
        var isDirectory: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: binaryPath, isDirectory: &isDirectory)
        logger.info("vibetunnel binary exists: \(fileExists), is directory: \(isDirectory.boolValue)")

        if fileExists && !isDirectory.boolValue {
            let attributes = try FileManager.default.attributesOfItem(atPath: binaryPath)
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                logger.info("vibetunnel binary permissions: \(String(permissions.intValue, radix: 8))")
            }
            if let fileSize = attributes[.size] as? NSNumber {
                logger.info("vibetunnel binary size: \(fileSize.intValue) bytes")
            }

            // Log binary architecture info
            logContinuation?.yield(ServerLogEntry(
                level: .debug,
                message: "Binary path: \(binaryPath)",
                source: .go
            ))
        } else if !fileExists {
            logger.error("vibetunnel binary NOT FOUND at: \(binaryPath)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Binary not found at: \(binaryPath)",
                source: .go
            ))
        }

        // Create the process using login shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        // Get the Resources directory path
        let resourcesPath = Bundle.main.resourcePath ?? Bundle.main.bundlePath

        // Set working directory to Resources directory
        process.currentDirectoryURL = URL(fileURLWithPath: resourcesPath)
        logger.info("Working directory: \(resourcesPath)")

        // Static files are always at Resources/web/public
        let staticPath = URL(fileURLWithPath: resourcesPath).appendingPathComponent("web/public").path
        
        // Verify the web directory exists
        if !FileManager.default.fileExists(atPath: staticPath) {
            logger.error("Web directory not found at expected location: \(staticPath)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Web directory not found at: \(staticPath)",
                source: .go
            ))
        }

        // Build command to run vibetunnel through login shell
        // Use bind address from ServerManager to control server accessibility
        let bindAddress = ServerManager.shared.bindAddress

        var vibetunnelCommand =
            "\"\(binaryPath)\" --static-path \"\(staticPath)\" --serve --bind \(bindAddress) --port \(port)"

        // Add password flag if password protection is enabled
        // Only check if password exists, don't retrieve it yet
        if UserDefaults.standard.bool(forKey: "dashboardPasswordEnabled") && DashboardKeychain.shared.hasPassword() {
            logger.info("Password protection enabled, retrieving from keychain")
            if let password = DashboardKeychain.shared.getPassword() {
                // Escape the password for shell
                let escapedPassword = password.replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "$", with: "\\$")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "\\", with: "\\\\")
                vibetunnelCommand += " --password \"\(escapedPassword)\" --password-enabled"
            }
        }

        // Add cleanup on startup flag if enabled
        if UserDefaults.standard.bool(forKey: "cleanupOnStartup") {
            vibetunnelCommand += " --cleanup-startup"
        }

        process.arguments = ["-l", "-c", vibetunnelCommand]

        logger.info("Executing command: /bin/zsh -l -c \"\(vibetunnelCommand)\"")
        logger.info("Working directory: \(resourcesPath)")

        // Set up environment - login shell will load the rest
        var environment = ProcessInfo.processInfo.environment
        environment["RUST_LOG"] = "info" // Go server also respects RUST_LOG for compatibility
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

        do {
            // Start the process (this just launches it and returns immediately)
            try await processHandler.runProcess(process)

            // Mark server as running
            isRunning = true

            logger.info("Go server process started")

            // Give the process a moment to start before checking for early failures
            try await Task.sleep(for: .milliseconds(100))

            // Check if process exited immediately (indicating failure)
            if !process.isRunning {
                isRunning = false
                let exitCode = process.terminationStatus
                logger.error("Process exited immediately with code: \(exitCode)")

                // Try to read any error output
                var errorDetails = "Exit code: \(exitCode)"
                if let stderrPipe = self.stderrPipe {
                    let errorData = stderrPipe.fileHandleForReading.availableData
                    if !errorData.isEmpty, let errorOutput = String(data: errorData, encoding: .utf8) {
                        errorDetails += "\nError: \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }

                logContinuation?.yield(ServerLogEntry(
                    level: .error,
                    message: "Server failed to start: \(errorDetails)",
                    source: .go
                ))

                throw GoServerError.processFailedToStart
            }

            logger.info("Go server process started, performing health check...")
            logContinuation?.yield(ServerLogEntry(level: .info, message: "Performing health check...", source: .go))

            // Perform health check to ensure server is actually responding
            let isHealthy = await performHealthCheck(maxAttempts: 10, delaySeconds: 0.5)

            if isHealthy {
                logger.info("Go server started successfully and is responding")
                logContinuation?.yield(ServerLogEntry(level: .info, message: "Health check passed ✓", source: .go))
                logContinuation?.yield(ServerLogEntry(
                    level: .info,
                    message: "Go vibetunnel server is ready",
                    source: .go
                ))

                // Monitor process termination with task context
                Task {
                    await ServerTaskContext.$taskName.withValue("GoServer-monitor-\(port)") {
                        await ServerTaskContext.$serverType.withValue(.go) {
                            await monitorProcessTermination()
                        }
                    }
                }
            } else {
                // Server process is running but not responding
                logger.error("Go server process started but is not responding to health checks")
                logContinuation?.yield(ServerLogEntry(
                    level: .error,
                    message: "Health check failed - server not responding",
                    source: .go
                ))

                // Clean up the non-responsive process
                process.terminate()
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                isRunning = false

                throw GoServerError.serverNotResponding
            }
        } catch {
            isRunning = false

            // Log more detailed error information
            let errorMessage: String
            if let goError = error as? GoServerError {
                errorMessage = goError.localizedDescription
            } else if let nsError = error as NSError? {
                errorMessage = "\(nsError.localizedDescription) (Code: \(nsError.code), Domain: \(nsError.domain))"
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] {
                    logger.error("Underlying error: \(String(describing: underlyingError))")
                }
            } else {
                errorMessage = String(describing: error)
            }

            logger.error("Failed to start Go server: \(errorMessage)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Failed to start Go server: \(errorMessage)",
                source: .go
            ))
            throw error
        }
    }

    func stop() async {
        guard let process, isRunning else {
            logger.warning("Go server not running")
            return
        }

        logger.info("Stopping Go server")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Shutting down Go vibetunnel server...",
            source: .go
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
            logger.warning("Force killed Go server after timeout")
            logContinuation?.yield(ServerLogEntry(
                level: .warning,
                message: "Force killed server after timeout",
                source: .go
            ))
        }

        // Clean up
        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.outputTask = nil
        self.errorTask = nil
        isRunning = false

        logger.info("Go server stopped")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Go vibetunnel server shutdown complete",
            source: .go
        ))
    }

    func restart() async throws {
        logger.info("Restarting Go server")
        logContinuation?.yield(ServerLogEntry(level: .info, message: "Restarting server", source: .go))

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
                    source: .go
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
                        source: .go
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
            ServerTaskContext.$taskName.withValue("GoServer-stdout-\(currentPort)") {
                ServerTaskContext.$serverType.withValue(.go) {
                    guard let self, let pipe = stdoutPipe else { return }

                    let handle = pipe.fileHandleForReading
                    self.logger.debug("Starting stdout monitoring for Go server on port \(currentPort)")

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
                                            source: .go
                                        ))
                                    }
                                }
                            }
                        }
                    }

                    self.logger.debug("Stopped stdout monitoring for Go server")
                }
            }
        }

        // Monitor stderr on background thread
        errorTask = Task.detached { [weak self] in
            ServerTaskContext.$taskName.withValue("GoServer-stderr-\(currentPort)") {
                ServerTaskContext.$serverType.withValue(.go) {
                    guard let self, let pipe = stderrPipe else { return }

                    let handle = pipe.fileHandleForReading
                    self.logger.debug("Starting stderr monitoring for Go server on port \(currentPort)")

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
                                            source: .go
                                        ))
                                    }
                                }
                            }
                        }
                    }

                    self.logger.debug("Stopped stderr monitoring for Go server")
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
            self.logger.error("Go server terminated unexpectedly with exit code: \(exitCode)")
            self.logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Server terminated unexpectedly with exit code: \(exitCode)",
                source: .go
            ))

            self.isRunning = false

            // Auto-restart on unexpected termination
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.process == nil { // Only restart if not manually stopped
                    self.logger.info("Auto-restarting Go server after crash")
                    self.logContinuation?.yield(ServerLogEntry(
                        level: .info,
                        message: "Auto-restarting server after crash",
                        source: .go
                    ))
                    try? await self.start()
                }
            }
        }
    }

    private func detectLogLevel(from line: String) -> ServerLogEntry.Level {
        let lowercased = line.lowercased()
        if lowercased.contains("[error]") || lowercased.contains("fatal") || lowercased.contains("error:") {
            return .error
        } else if lowercased.contains("[warn]") || lowercased.contains("warning") || lowercased.contains("warn:") {
            return .warning
        } else if lowercased.contains("[debug]") || lowercased.contains("trace") || lowercased.contains("debug:") {
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

enum GoServerError: LocalizedError {
    case binaryNotFound
    case processFailedToStart
    case serverNotResponding
    case invalidPort
    case goNotInstalled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "The vibetunnel binary was not found in the app bundle"
        case .processFailedToStart:
            "The server process failed to start"
        case .serverNotResponding:
            "The server process started but is not responding to health checks"
        case .invalidPort:
            "Server port is not configured"
        case .goNotInstalled:
            "Go is not installed. Please install Go and rebuild the app to enable Go server support"
        }
    }
}
