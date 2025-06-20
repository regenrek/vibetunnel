import Foundation

/// Common interface for server implementations.
///
/// Defines the contract that all VibeTunnel server implementations must follow.
/// This protocol ensures consistent behavior across different server backends
/// (Hummingbird, Rust) while allowing for implementation-specific details.
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

    /// Stream for receiving log messages
    var logStream: AsyncStream<ServerLogEntry> { get }
}

/// Server mode options.
///
/// Represents the available server implementations that VibeTunnel can use.
/// Each mode corresponds to a different backend technology with its own
/// performance characteristics and feature set.
enum ServerMode: String, CaseIterable {
    case rust
    case go

    var displayName: String {
        switch self {
        case .rust:
            "Rust"
        case .go:
            "Go"
        }
    }

    var description: String {
        switch self {
        case .rust:
            "External tty-fwd binary"
        case .go:
            "External Go binary"
        }
    }
}

/// Log entry from server.
///
/// Represents a single log message from a server implementation,
/// including severity level, timestamp, and source identification.
struct ServerLogEntry {
    /// Severity level of the log entry.
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
