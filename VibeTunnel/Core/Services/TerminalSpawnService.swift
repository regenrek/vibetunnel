import Foundation
import os.log

/// Service that listens for terminal spawn requests via Unix domain socket using POSIX APIs
final class TerminalSpawnService: @unchecked Sendable {
    static let shared = TerminalSpawnService()

    private let logger = Logger(subsystem: "sh.vibetunnel.VibeTunnel", category: "TerminalSpawnService")
    private let socketPath = "/tmp/vibetunnel-terminal.sock"
    private let lock = NSLock()
    private var serverSocket: Int32 = -1
    private var listenQueue: DispatchQueue?
    private var shouldStop = false

    private init() {}

    /// Start listening for terminal spawn requests
    func start() {
        lock.lock()
        defer { lock.unlock() }
        // Clean up any existing socket
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path to sun_path
        socketPath.withCString { pathCString in
            withUnsafeMutableBytes(of: &addr.sun_path) { sunPathPtr in
                guard let baseAddress = sunPathPtr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                strncpy(baseAddress, pathCString, sunPathPtr.count - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        // Listen for connections
        guard listen(serverSocket, 5) == 0 else {
            logger.error("Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Terminal spawn service listening on \(self.socketPath)")

        // Start accepting connections on background queue
        shouldStop = false
        listenQueue = DispatchQueue(label: "sh.vibetunnel.terminal-spawn", qos: .userInitiated)
        listenQueue?.async { [weak self] in
            self?.acceptConnectionsAsync()
        }
    }

    /// Stop the service
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        logger.info("Stopping terminal spawn service")
        shouldStop = true

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        unlink(socketPath)
        listenQueue = nil
    }

    private func acceptConnectionsAsync() {
        while true {
            lock.lock()
            let shouldContinue = !shouldStop && serverSocket >= 0
            let socket = serverSocket
            lock.unlock()

            if !shouldContinue {
                break
            }
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(socket, sockaddrPtr, &clientAddrLen)
                }
            }

            if clientSocket < 0 {
                if errno != EINTR {
                    lock.lock()
                    let stopped = shouldStop
                    lock.unlock()
                    if !stopped {
                        logger.error("Failed to accept connection: \(String(cString: strerror(errno)))")
                    }
                }
                continue
            }

            // Handle connection on separate queue
            handleConnectionAsync(clientSocket)
        }
    }

    private func handleConnectionAsync(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read request data
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)

        guard bytesRead > 0 else {
            logger.error("Failed to read from client socket")
            return
        }

        let requestData = Data(bytes: buffer, count: bytesRead)

        // Parse and handle the request
        let responseData = handleRequestSync(requestData)
        sendResponse(responseData, to: clientSocket)
    }

    private func handleRequestSync(_ data: Data) -> Data {
        struct SpawnRequest: Codable {
            let ttyFwdPath: String? // Optional: if provided, use this path instead of bundled one
            let workingDir: String
            let sessionId: String
            let command: String // Already properly formatted command (not array)
            let terminal: String? // Optional: preferred terminal (e.g. "ghostty", "terminal")
        }

        struct SpawnResponse: Codable {
            let success: Bool
            let error: String?
            let sessionId: String?
        }

        do {
            let request = try JSONDecoder().decode(SpawnRequest.self, from: data)
            logger.info("Received spawn request for session \(request.sessionId)")

            // Use DispatchQueue.main.sync to call TerminalLauncher on main thread
            var launchError: Error?
            DispatchQueue.main.sync {
                do {
                    // If a specific terminal is requested, temporarily set it
                    var originalTerminal: String?
                    if let requestedTerminal = request.terminal {
                        originalTerminal = UserDefaults.standard.string(forKey: "preferredTerminal")
                        UserDefaults.standard.set(requestedTerminal, forKey: "preferredTerminal")
                    }

                    defer {
                        // Restore original terminal preference if we changed it
                        if let original = originalTerminal {
                            UserDefaults.standard.set(original, forKey: "preferredTerminal")
                        }
                    }

                    try TerminalLauncher.shared.launchOptimizedTerminalSession(
                        workingDirectory: request.workingDir,
                        command: request.command,
                        sessionId: request.sessionId,
                        ttyFwdPath: request.ttyFwdPath
                    )
                } catch {
                    launchError = error
                }
            }

            if let error = launchError {
                throw error
            }

            let response = SpawnResponse(success: true, error: nil, sessionId: request.sessionId)
            return try JSONEncoder().encode(response)

        } catch {
            logger.error("Failed to handle spawn request: \(error)")
            let response = SpawnResponse(success: false, error: error.localizedDescription, sessionId: nil)
            return (try? JSONEncoder().encode(response)) ?? Data()
        }
    }

    private func sendResponse(_ data: Data, to clientSocket: Int32) {
        data.withUnsafeBytes { bytes in
            _ = send(clientSocket, bytes.baseAddress, data.count, 0)
        }
    }
}
