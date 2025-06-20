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
        // This is binary buffer data, not JSON
        // Decode the binary terminal buffer
        guard let bufferSnapshot = decodeBinaryBuffer(data) else {
            print("[BufferWebSocket] Failed to decode binary buffer")
            return nil
        }
        
        // Convert buffer snapshot to terminal output
        let outputData = convertBufferToANSI(bufferSnapshot)
        print("[BufferWebSocket] Decoded buffer: \(bufferSnapshot.cols)x\(bufferSnapshot.rows), \(outputData.count) bytes output")
        
        // Return as output event with current timestamp
        return .output(timestamp: Date().timeIntervalSince1970, data: outputData)
    }
    
    private struct BufferSnapshot {
        let cols: Int
        let rows: Int
        let viewportY: Int
        let cursorX: Int
        let cursorY: Int
        let cells: [[BufferCell]]
    }
    
    private struct BufferCell {
        let char: String
        let width: Int
        let fg: Int?
        let bg: Int?
        let attributes: Int?
    }
    
    private func decodeBinaryBuffer(_ data: Data) -> BufferSnapshot? {
        var offset = 0
        
        // Read header
        guard data.count >= 32 else {
            print("[BufferWebSocket] Buffer too small for header")
            return nil
        }
        
        // Magic bytes "VT" (0x5654 in little endian)
        let magic = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
        offset += 2
        
        guard magic == 0x5654 else {
            print("[BufferWebSocket] Invalid magic bytes: \(String(format: "0x%04X", magic))")
            return nil
        }
        
        // Version
        let version = data[offset]
        offset += 1
        
        guard version == 0x01 else {
            print("[BufferWebSocket] Unsupported version: \(version)")
            return nil
        }
        
        // Flags (unused)
        offset += 1
        
        // Dimensions and cursor
        let cols = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4
        
        let rows = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
        offset += 4
        
        let viewportY = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
        }
        offset += 4
        
        let cursorX = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
        }
        offset += 4
        
        let cursorY = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
        }
        offset += 4
        
        // Skip reserved
        offset += 4
        
        // Decode cells
        var cells: [[BufferCell]] = []
        
        while offset < data.count {
            let marker = data[offset]
            offset += 1
            
            if marker == 0xFE {
                // Empty row(s)
                let count = data[offset]
                offset += 1
                
                for _ in 0..<count {
                    cells.append([BufferCell(char: " ", width: 1, fg: nil, bg: nil, attributes: nil)])
                }
            } else if marker == 0xFD {
                // Row with content
                guard offset + 2 <= data.count else { break }
                
                let cellCount = data.withUnsafeBytes { bytes in
                    bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
                }
                offset += 2
                
                var rowCells: [BufferCell] = []
                for _ in 0..<cellCount {
                    if let (cell, newOffset) = decodeCell(data, offset: offset) {
                        rowCells.append(cell)
                        offset = newOffset
                    } else {
                        break
                    }
                }
                cells.append(rowCells)
            }
        }
        
        return BufferSnapshot(
            cols: Int(cols),
            rows: Int(rows),
            viewportY: Int(viewportY),
            cursorX: Int(cursorX),
            cursorY: Int(cursorY),
            cells: cells
        )
    }
    
    private func decodeCell(_ data: Data, offset: Int) -> (BufferCell, Int)? {
        guard offset < data.count else { return nil }
        
        var currentOffset = offset
        let typeByte = data[currentOffset]
        currentOffset += 1
        
        // Simple space optimization
        if typeByte == 0x00 {
            return (BufferCell(char: " ", width: 1, fg: nil, bg: nil, attributes: nil), currentOffset)
        }
        
        // Decode type byte
        let hasExtended = (typeByte & 0x80) != 0
        let isUnicode = (typeByte & 0x40) != 0
        let hasFg = (typeByte & 0x20) != 0
        let hasBg = (typeByte & 0x10) != 0
        let isRgbFg = (typeByte & 0x08) != 0
        let isRgbBg = (typeByte & 0x04) != 0
        
        // Read character
        var char: String
        var width: Int = 1
        
        if isUnicode {
            // UTF-8 encoded character
            guard currentOffset < data.count else { return nil }
            let firstByte = data[currentOffset]
            
            let utf8Length: Int
            if firstByte & 0x80 == 0 {
                utf8Length = 1
            } else if firstByte & 0xE0 == 0xC0 {
                utf8Length = 2
            } else if firstByte & 0xF0 == 0xE0 {
                utf8Length = 3
            } else if firstByte & 0xF8 == 0xF0 {
                utf8Length = 4
            } else {
                utf8Length = 1
            }
            
            guard currentOffset + utf8Length <= data.count else { return nil }
            
            let charData = data.subdata(in: currentOffset..<(currentOffset + utf8Length))
            char = String(data: charData, encoding: .utf8) ?? "?"
            currentOffset += utf8Length
            
            // Read width for Unicode chars
            guard currentOffset < data.count else { return nil }
            width = Int(data[currentOffset])
            currentOffset += 1
        } else {
            // ASCII character
            guard currentOffset < data.count else { return nil }
            char = String(Character(UnicodeScalar(data[currentOffset])))
            currentOffset += 1
        }
        
        // Read colors and attributes
        var fg: Int?
        var bg: Int?
        var attributes: Int?
        
        if hasFg {
            if isRgbFg {
                // RGB color (3 bytes)
                guard currentOffset + 3 <= data.count else { return nil }
                let r = Int(data[currentOffset])
                let g = Int(data[currentOffset + 1])
                let b = Int(data[currentOffset + 2])
                fg = (r << 16) | (g << 8) | b | 0xFF000000 // Add alpha for RGB
                currentOffset += 3
            } else {
                // Palette color (1 byte)
                guard currentOffset < data.count else { return nil }
                fg = Int(data[currentOffset])
                currentOffset += 1
            }
        }
        
        if hasBg {
            if isRgbBg {
                // RGB color (3 bytes)
                guard currentOffset + 3 <= data.count else { return nil }
                let r = Int(data[currentOffset])
                let g = Int(data[currentOffset + 1])
                let b = Int(data[currentOffset + 2])
                bg = (r << 16) | (g << 8) | b | 0xFF000000 // Add alpha for RGB
                currentOffset += 3
            } else {
                // Palette color (1 byte)
                guard currentOffset < data.count else { return nil }
                bg = Int(data[currentOffset])
                currentOffset += 1
            }
        }
        
        if hasExtended {
            // Read attributes byte
            guard currentOffset < data.count else { return nil }
            attributes = Int(data[currentOffset])
            currentOffset += 1
        }
        
        return (BufferCell(char: char, width: width, fg: fg, bg: bg, attributes: attributes), currentOffset)
    }
    
    private func convertBufferToANSI(_ snapshot: BufferSnapshot) -> String {
        var output = ""
        
        // Clear screen and move cursor to top
        output += "\u{001B}[2J\u{001B}[H"
        
        // Render each row
        for (rowIndex, row) in snapshot.cells.enumerated() {
            if rowIndex > 0 {
                output += "\n"
            }
            
            var currentFg: Int?
            var currentBg: Int?
            var currentAttrs: Int = 0
            
            for cell in row {
                // Handle attributes
                if let attrs = cell.attributes, attrs != currentAttrs {
                    // Reset all attributes
                    output += "\u{001B}[0m"
                    currentAttrs = attrs
                    currentFg = nil
                    currentBg = nil
                    
                    // Apply new attributes
                    if (attrs & 0x01) != 0 { output += "\u{001B}[1m" } // Bold
                    if (attrs & 0x02) != 0 { output += "\u{001B}[3m" } // Italic
                    if (attrs & 0x04) != 0 { output += "\u{001B}[4m" } // Underline
                    if (attrs & 0x08) != 0 { output += "\u{001B}[2m" } // Dim
                    if (attrs & 0x10) != 0 { output += "\u{001B}[7m" } // Inverse
                    if (attrs & 0x40) != 0 { output += "\u{001B}[9m" } // Strikethrough
                }
                
                // Handle foreground color
                if cell.fg != currentFg {
                    currentFg = cell.fg
                    if let fg = cell.fg {
                        if fg & 0xFF000000 != 0 {
                            // RGB color
                            let r = (fg >> 16) & 0xFF
                            let g = (fg >> 8) & 0xFF
                            let b = fg & 0xFF
                            output += "\u{001B}[38;2;\(r);\(g);\(b)m"
                        } else if fg <= 255 {
                            // Palette color
                            output += "\u{001B}[38;5;\(fg)m"
                        }
                    } else {
                        // Default foreground
                        output += "\u{001B}[39m"
                    }
                }
                
                // Handle background color
                if cell.bg != currentBg {
                    currentBg = cell.bg
                    if let bg = cell.bg {
                        if bg & 0xFF000000 != 0 {
                            // RGB color
                            let r = (bg >> 16) & 0xFF
                            let g = (bg >> 8) & 0xFF
                            let b = bg & 0xFF
                            output += "\u{001B}[48;2;\(r);\(g);\(b)m"
                        } else if bg <= 255 {
                            // Palette color
                            output += "\u{001B}[48;5;\(bg)m"
                        }
                    } else {
                        // Default background
                        output += "\u{001B}[49m"
                    }
                }
                
                // Add the character
                output += cell.char
            }
        }
        
        // Reset attributes at the end
        output += "\u{001B}[0m"
        
        // Position cursor
        output += "\u{001B}[\(snapshot.cursorY + 1);\(snapshot.cursorX + 1)H"
        
        return output
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
