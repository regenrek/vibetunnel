import Combine
import Foundation

/// Terminal event types that match the server's output
enum TerminalWebSocketEvent {
    case header(width: Int, height: Int)
    case output(timestamp: Double, data: String)
    case resize(timestamp: Double, dimensions: String)
    case exit(code: Int)
}

enum WebSocketError: Error {
    case invalidURL
    case connectionFailed
    case invalidData
    case invalidMagicByte
}

@MainActor
class BufferWebSocketClient: NSObject {
    /// Magic byte for binary messages
    private static let bufferMagicByte: UInt8 = 0xBF

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var subscriptions = [String: (TerminalWebSocketEvent) -> Void]()
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private var isConnecting = false
    private var pingTimer: Timer?

    // Published events
    @Published private(set) var isConnected = false
    @Published private(set) var connectionError: Error?

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
           let authHeader = serverConfig.authorizationHeader {
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
                startPingTimer()

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
        guard data.count > 5 else { return }

        var offset = 0

        // Check magic byte
        let magic = data[offset]
        offset += 1

        guard magic == Self.bufferMagicByte else {
            print("[BufferWebSocket] Invalid magic byte: \(magic)")
            return
        }

        // Read session ID length (4 bytes, little endian)
        let sessionIdLength = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4

        // Read session ID
        guard data.count >= offset + Int(sessionIdLength) else { return }
        let sessionIdData = data.subdata(in: offset..<(offset + Int(sessionIdLength)))
        guard let sessionId = String(data: sessionIdData, encoding: .utf8) else { return }
        offset += Int(sessionIdLength)

        // Remaining data is the message payload
        let messageData = data.subdata(in: offset..<data.count)

        // Decode terminal event
        if let event = decodeTerminalEvent(from: messageData),
           let handler = subscriptions[sessionId] {
            handler(event)
        }
    }

    private func decodeTerminalEvent(from data: Data) -> TerminalWebSocketEvent? {
        // Decode the JSON payload from the binary message
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {
                switch type {
                case "header":
                    if let width = json["width"] as? Int,
                       let height = json["height"] as? Int {
                        return .header(width: width, height: height)
                    }

                case "output":
                    if let timestamp = json["timestamp"] as? Double,
                       let outputData = json["data"] as? String {
                        return .output(timestamp: timestamp, data: outputData)
                    }

                case "resize":
                    if let timestamp = json["timestamp"] as? Double,
                       let dimensions = json["dimensions"] as? String {
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

    private func startPingTimer() {
        stopPingTimer()

        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { [weak self] in
                try? await self?.sendPing()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func handleDisconnection() {
        isConnected = false
        webSocketTask = nil
        stopPingTimer()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTimer == nil else { return }

        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        reconnectAttempts += 1

        print("[BufferWebSocket] Reconnecting in \(delay)s (attempt \(reconnectAttempts))")

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.reconnectTimer = nil
                self?.connect()
            }
        }
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        stopPingTimer()

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        subscriptions.removeAll()
        isConnected = false
    }

    deinit {
        // Cancel the WebSocket task
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        // Timers will be cleaned up automatically when the object is deallocated
    }
}
