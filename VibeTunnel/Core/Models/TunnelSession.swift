import Foundation
import Hummingbird

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
public struct CreateSessionRequest: Codable {
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
public struct CreateSessionResponse: ResponseCodable {
    public let sessionId: String
    public let createdAt: Date

    public init(sessionId: String, createdAt: Date) {
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Command execution request
public struct CommandRequest: Codable {
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
public struct CommandResponse: ResponseCodable {
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
public struct SessionInfo: ResponseCodable {
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
public struct ListSessionsResponse: ResponseCodable {
    public let sessions: [SessionInfo]

    public init(sessions: [SessionInfo]) {
        self.sessions = sessions
    }
}