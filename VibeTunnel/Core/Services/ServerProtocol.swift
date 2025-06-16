import Combine
import Foundation

/// Common interface for server implementations
@MainActor
protocol ServerProtocol: AnyObject {
    /// Current running state of the server
    var isRunning: Bool { get }

    /// Port the server is configured to use
    var port: String { get set }

    /// Server type identifier
    var serverType: ServerMode { get }

    /// Start the server
    func start() async throws

    /// Stop the server
    func stop() async

    /// Restart the server
    func restart() async throws

    /// Publisher for streaming log messages
    var logPublisher: AnyPublisher<ServerLogEntry, Never> { get }
}

/// Server mode options
enum ServerMode: String, CaseIterable {
    case hummingbird
    case rust

    var displayName: String {
        switch self {
        case .hummingbird:
            "Hummingbird"
        case .rust:
            "Rust"
        }
    }

    var description: String {
        switch self {
        case .hummingbird:
            "Built-in Swift server"
        case .rust:
            "External tty-fwd binary"
        }
    }
}

/// Log entry from server
struct ServerLogEntry {
    enum Level {
        case debug
        case info
        case warning
        case error
    }

    let timestamp: Date
    let level: Level
    let message: String
    let source: ServerMode

    init(level: Level = .info, message: String, source: ServerMode) {
        self.timestamp = Date()
        self.level = level
        self.message = message
        self.source = source
    }
}
