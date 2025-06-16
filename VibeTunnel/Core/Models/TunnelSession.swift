import Foundation

/// Represents a terminal session that can be controlled remotely
public struct TunnelSession: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var lastActivity: Date
    public let processID: Int32?
    public var isActive: Bool

    public init(id: UUID = UUID(), processID: Int32? = nil) {
        self.id = id
        self.createdAt = Date()
        self.lastActivity = Date()
        self.processID = processID
        self.isActive = true
    }

    public mutating func updateActivity() {
        self.lastActivity = Date()
    }
}

/// Request to create a new terminal session
public struct CreateSessionRequest: Codable, Sendable {
    public let workingDirectory: String?
    public let environment: [String: String]?
    public let shell: String?

    public init(workingDirectory: String? = nil, environment: [String: String]? = nil, shell: String? = nil) {
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.shell = shell
    }
}

/// Response after creating a session
public struct CreateSessionResponse: Codable, Sendable {
    public let sessionId: String
    public let createdAt: Date

    public init(sessionId: String, createdAt: Date) {
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Command execution request
public struct CommandRequest: Codable, Sendable {
    public let sessionId: String
    public let command: String
    public let args: [String]?
    public let environment: [String: String]?

    public init(sessionId: String, command: String, args: [String]? = nil, environment: [String: String]? = nil) {
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.environment = environment
    }
}

/// Command execution response
public struct CommandResponse: Codable, Sendable {
    public let sessionId: String
    public let output: String?
    public let error: String?
    public let exitCode: Int32?
    public let timestamp: Date

    public init(
        sessionId: String,
        output: String? = nil,
        error: String? = nil,
        exitCode: Int32? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionId = sessionId
        self.output = output
        self.error = error
        self.exitCode = exitCode
        self.timestamp = timestamp
    }
}

/// Session information
public struct SessionInfo: Codable, Sendable {
    public let id: String
    public let createdAt: Date
    public let lastActivity: Date
    public let isActive: Bool

    public init(id: String, createdAt: Date, lastActivity: Date, isActive: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.isActive = isActive
    }
}

/// List sessions response
public struct ListSessionsResponse: Codable, Sendable {
    public let sessions: [SessionInfo]

    public init(sessions: [SessionInfo]) {
        self.sessions = sessions
    }
}

// MARK: - Extensions for TunnelClient

extension TunnelSession {
    /// Client information for session creation
    public struct ClientInfo: Codable, Sendable {
        public let hostname: String
        public let username: String
        public let homeDirectory: String
        public let operatingSystem: String
        public let architecture: String

        public init(
            hostname: String,
            username: String,
            homeDirectory: String,
            operatingSystem: String,
            architecture: String
        ) {
            self.hostname = hostname
            self.username = username
            self.homeDirectory = homeDirectory
            self.operatingSystem = operatingSystem
            self.architecture = architecture
        }
    }

    /// Request to create a new session
    public struct CreateRequest: Codable, Sendable {
        public let clientInfo: ClientInfo?

        public init(clientInfo: ClientInfo? = nil) {
            self.clientInfo = clientInfo
        }
    }

    /// Response after creating a session
    public struct CreateResponse: Codable, Sendable {
        public let id: String
        public let session: TunnelSession

        public init(id: String, session: TunnelSession) {
            self.id = id
            self.session = session
        }
    }

    /// Request to execute a command
    public struct ExecuteCommandRequest: Codable, Sendable {
        public let sessionId: String
        public let command: String
        public let environment: [String: String]?
        public let workingDirectory: String?

        public init(
            sessionId: String,
            command: String,
            environment: [String: String]? = nil,
            workingDirectory: String? = nil
        ) {
            self.sessionId = sessionId
            self.command = command
            self.environment = environment
            self.workingDirectory = workingDirectory
        }
    }

    /// Response from command execution
    public struct ExecuteCommandResponse: Codable, Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Health check response
    public struct HealthResponse: Codable, Sendable {
        public let status: String
        public let timestamp: Date
        public let sessions: Int
        public let version: String

        public init(status: String, timestamp: Date, sessions: Int, version: String) {
            self.status = status
            self.timestamp = timestamp
            self.sessions = sessions
            self.version = version
        }
    }

    /// List sessions response
    public struct ListResponse: Codable, Sendable {
        public let sessions: [TunnelSession]

        public init(sessions: [TunnelSession]) {
            self.sessions = sessions
        }
    }

    /// Error response from server
    public struct ErrorResponse: Codable, Sendable {
        public let error: String
        public let code: String?

        public init(error: String, code: String? = nil) {
            self.error = error
            self.code = code
        }
    }
}
