import Foundation

/// Terminal event types that match the server's output.
enum TerminalWebSocketEvent {
    case header(width: Int, height: Int)
    case output(timestamp: Double, data: String)
    case resize(timestamp: Double, dimensions: String)
    case exit(code: Int)
}

/// Errors that can occur during WebSocket operations.
enum WebSocketError: Error {
    case invalidURL
    case connectionFailed
    case invalidData
    case invalidMagicByte
}

/// WebSocket client for real-time terminal buffer streaming.
///
/// BufferWebSocketClient establishes a WebSocket connection to the server
/// to receive terminal output and events in real-time. It handles automatic
/// reconnection, binary message parsing, and event distribution to subscribers.
@MainActor
@Observable
class BufferWebSocketClient: NSObject {
    /// Magic byte for binary messages
    private static let bufferMagicByte: UInt8 = 0xBF

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var subscriptions = [String: (TerminalWebSocketEvent) -> Void]()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var isConnecting = false
    private var pingTask: Task<Void, Never>?

    // Observable properties
    private(set) var isConnected = false
    private(set) var connectionError: Error?

    private var baseURL: URL? {
        guard let config = UserDefaults.standard.data(forKey: "savedServerConfig"),
              let serverConfig = try? JSONDecoder().decode(ServerConfig.self, from: config)
        else {
            return nil
        }
        return serverConfig.baseURL
    }

    func connect() {
        guard !isConnecting else { return }
        guard let baseURL else {
            connectionError = WebSocketError.invalidURL
            return
        }

        isConnecting = true
        connectionError = nil

        // Convert HTTP URL to WebSocket URL
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/buffers"

        guard let wsURL = components?.url else {
            connectionError = WebSocketError.invalidURL
            isConnecting = false
            return
        }

        print("[BufferWebSocket] Connecting to \(wsURL)")

        // Cancel existing task if any
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        // Create request with authentication
        var request = URLRequest(url: wsURL)

        // Add authentication header if needed
        if let config = UserDefaults.standard.data(forKey: "savedServerConfig"),
           let serverConfig = try? JSONDecoder().decode(ServerConfig.self, from: config),
           let authHeader = serverConfig.authorizationHeader
        {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        // Create new WebSocket task
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start receiving messages
        receiveMessage()

        // Send initial ping to establish connection
        Task {
            do {
                try await sendPing()
                isConnected = true
                isConnecting = false
                reconnectAttempts = 0
                startPingTask()

                // Re-subscribe to all sessions
                for sessionId in subscriptions.keys {
                    try await subscribe(to: sessionId)
                }
            } catch {
                print("[BufferWebSocket] Connection failed: \(error)")
                connectionError = error
                isConnecting = false
                scheduleReconnect()
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                Task { @MainActor in
                    self.handleMessage(message)
                    self.receiveMessage() // Continue receiving
                }

            case .failure(let error):
                print("[BufferWebSocket] Receive error: \(error)")
                Task { @MainActor in
                    self.handleDisconnection()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleBinaryMessage(data)

        case .string(let text):
            handleTextMessage(text)

        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if let type = json["type"] as? String {
            switch type {
            case "ping":
                // Respond with pong
                Task {
                    try? await sendMessage(["type": "pong"])
                }

            case "error":
                if let message = json["message"] as? String {
                    print("[BufferWebSocket] Server error: \(message)")
                }

            default:
                print("[BufferWebSocket] Unknown message type: \(type)")
            }
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        print("[BufferWebSocket] Received binary message: \(data.count) bytes")
        
        guard data.count > 5 else { 
            print("[BufferWebSocket] Binary message too short")
            return 
        }

        var offset = 0

        // Check magic byte
        let magic = data[offset]
        offset += 1

        guard magic == Self.bufferMagicByte else {
            print("[BufferWebSocket] Invalid magic byte: \(String(format: "0x%02X", magic))")
            return
        }

        // Read session ID length (4 bytes, little endian)
        let sessionIdLength = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4

        // Read session ID
        guard data.count >= offset + Int(sessionIdLength) else { 
            print("[BufferWebSocket] Not enough data for session ID")
            return 
        }
        let sessionIdData = data.subdata(in: offset..<(offset + Int(sessionIdLength)))
        guard let sessionId = String(data: sessionIdData, encoding: .utf8) else { 
            print("[BufferWebSocket] Failed to decode session ID")
            return 
        }
        print("[BufferWebSocket] Session ID: \(sessionId)")
        offset += Int(sessionIdLength)

        // Remaining data is the message payload
        let messageData = data.subdata(in: offset..<data.count)
        print("[BufferWebSocket] Message payload: \(messageData.count) bytes")

        // Decode terminal event
        if let event = decodeTerminalEvent(from: messageData),
           let handler = subscriptions[sessionId]
        {
            print("[BufferWebSocket] Dispatching event to handler")
            handler(event)
        } else {
            print("[BufferWebSocket] No handler for session ID: \(sessionId)")
        }
    }

    private func decodeTerminalEvent(from data: Data) -> TerminalWebSocketEvent? {
        // Decode the JSON payload from the binary message
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String
            {
                print("[BufferWebSocket] Received event type: \(type)")
                
                switch type {
                case "header":
                    if let width = json["width"] as? Int,
                       let height = json["height"] as? Int
                    {
                        print("[BufferWebSocket] Terminal header: \(width)x\(height)")
                        return .header(width: width, height: height)
                    }

                case "output":
                    if let timestamp = json["timestamp"] as? Double,
                       let outputData = json["data"] as? String
                    {
                        print("[BufferWebSocket] Terminal output: \(outputData.count) bytes")
                        return .output(timestamp: timestamp, data: outputData)
                    }

                case "resize":
                    if let timestamp = json["timestamp"] as? Double,
                       let dimensions = json["dimensions"] as? String
                    {
                        return .resize(timestamp: timestamp, dimensions: dimensions)
                    }

                case "exit":
                    let code = json["code"] as? Int ?? 0
                    return .exit(code: code)

                default:
                    print("[BufferWebSocket] Unknown message type: \(type)")
                }
            }
        } catch {
            print("[BufferWebSocket] Failed to decode message: \(error)")
        }
        return nil
    }

    func subscribe(to sessionId: String, handler: @escaping (TerminalWebSocketEvent) -> Void) {
        subscriptions[sessionId] = handler

        Task {
            try? await subscribe(to: sessionId)
        }
    }

    private func subscribe(to sessionId: String) async throws {
        try await sendMessage(["type": "subscribe", "sessionId": sessionId])
    }

    func unsubscribe(from sessionId: String) {
        subscriptions.removeValue(forKey: sessionId)

        Task {
            try? await sendMessage(["type": "unsubscribe", "sessionId": sessionId])
        }
    }

    private func sendMessage(_ message: [String: Any]) async throws {
        guard let webSocketTask else {
            throw WebSocketError.connectionFailed
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WebSocketError.invalidData
        }

        try await webSocketTask.send(.string(string))
    }

    private func sendPing() async throws {
        try await sendMessage(["type": "ping"])
    }

    private func startPingTask() {
        stopPingTask()

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                if !Task.isCancelled {
                    try? await self?.sendPing()
                }
            }
        }
    }

    private func stopPingTask() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func handleDisconnection() {
        isConnected = false
        webSocketTask = nil
        stopPingTask()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        reconnectAttempts += 1

        print("[BufferWebSocket] Reconnecting in \(delay)s (attempt \(reconnectAttempts))")

        reconnectTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            if !Task.isCancelled {
                self?.reconnectTask = nil
                self?.connect()
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPingTask()

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        subscriptions.removeAll()
        isConnected = false
    }

    deinit {
        // Tasks will be cancelled automatically when the object is deallocated
        // WebSocket task cleanup happens in disconnect()
    }
}
