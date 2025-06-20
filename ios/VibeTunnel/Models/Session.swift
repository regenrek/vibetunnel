import Foundation

/// Represents a terminal session on the server.
///
/// Session contains all information about a running or completed
/// terminal session, including its status, process information,
/// and terminal dimensions.
struct Session: Codable, Identifiable, Equatable {
    let id: String
    let command: String
    let workingDir: String
    let name: String?
    let status: SessionStatus
    let exitCode: Int?
    let startedAt: String
    let lastModified: String?
    let pid: Int?
    let waiting: Bool?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case workingDir
        case name
        case status
        case exitCode
        case startedAt
        case lastModified
        case pid
        case waiting
        case width
        case height
    }

    /// User-friendly display name for the session.
    ///
    /// Returns the custom name if set, otherwise the command.
    var displayName: String {
        name ?? command
    }

    /// Indicates whether the session is currently active.
    ///
    /// - Returns: true if the session status is `.running`.
    var isRunning: Bool {
        status == .running
    }

    /// Formats the session start time for display.
    ///
    /// - Returns: A localized time string or the raw timestamp if parsing fails.
    ///
    /// Attempts to parse various date formats including ISO8601
    /// and RFC3339 with or without fractional seconds.
    var formattedStartTime: String {
        // Parse and format the startedAt string
        // Try ISO8601 first
        let iso8601Formatter = ISO8601DateFormatter()
        if let date = iso8601Formatter.date(from: startedAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .none
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        // Try RFC3339 format (what Go uses)
        let rfc3339Formatter = DateFormatter()
        rfc3339Formatter.locale = Locale(identifier: "en_US_POSIX")
        rfc3339Formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        if let date = rfc3339Formatter.date(from: startedAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .none
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        // Try without fractional seconds
        rfc3339Formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        if let date = rfc3339Formatter.date(from: startedAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .none
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        return startedAt
    }
}

/// Represents the lifecycle state of a session.
enum SessionStatus: String, Codable {
    /// Session is being initialized.
    case starting

    /// Session is active and running.
    case running

    /// Session has terminated.
    case exited
}

/// Data required to create a new terminal session.
///
/// SessionCreateData encapsulates all parameters needed
/// to start a new terminal session on the server.
struct SessionCreateData: Codable {
    let command: [String]
    let workingDir: String
    let name: String?
    let spawnTerminal: Bool?
    let cols: Int?
    let rows: Int?

    enum CodingKeys: String, CodingKey {
        case command
        case workingDir
        case name
        case spawnTerminal = "spawn_terminal"
        case cols
        case rows
    }

    /// Creates session creation data with sensible defaults.
    ///
    /// - Parameters:
    ///   - command: Command to execute (default: "zsh").
    ///   - workingDir: Working directory for the session.
    ///   - name: Optional custom name.
    ///   - spawnTerminal: Whether to spawn a terminal (default: false).
    ///   - cols: Terminal width in columns (default: 120).
    ///   - rows: Terminal height in rows (default: 30).
    init(
        command: String = "zsh",
        workingDir: String,
        name: String? = nil,
        spawnTerminal: Bool = false,
        cols: Int = 120,
        rows: Int = 30
    ) {
        self.command = [command]
        self.workingDir = workingDir
        self.name = name
        self.spawnTerminal = spawnTerminal
        self.cols = cols
        self.rows = rows
    }
}
