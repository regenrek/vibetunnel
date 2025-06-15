//
//  TunnelSession.swift
//  VibeTunnel
//
//  Created by VibeTunnel on 15.06.25.
//

import Foundation

/// Represents a terminal session that can be controlled remotely
struct TunnelSession: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var lastActivity: Date
    let processID: Int32?
    var isActive: Bool
    
    init(id: UUID = UUID(), processID: Int32? = nil) {
        self.id = id
        self.createdAt = Date()
        self.lastActivity = Date()
        self.processID = processID
        self.isActive = true
    }
    
    mutating func updateActivity() {
        self.lastActivity = Date()
    }
}

/// Request to create a new terminal session
struct CreateSessionRequest: Codable {
    let workingDirectory: String?
    let environment: [String: String]?
    let shell: String?
}

/// Response after creating a session
struct CreateSessionResponse: Codable {
    let sessionId: String
    let createdAt: Date
}

/// Command execution request
struct CommandRequest: Codable {
    let sessionId: String
    let command: String
    let args: [String]?
    let environment: [String: String]?
}

/// Command execution response
struct CommandResponse: Codable {
    let sessionId: String
    let output: String?
    let error: String?
    let exitCode: Int32?
    let timestamp: Date
}

/// Session information
struct SessionInfo: Codable {
    let id: String
    let createdAt: Date
    let lastActivity: Date
    let isActive: Bool
}

/// List sessions response
struct ListSessionsResponse: Codable {
    let sessions: [SessionInfo]
}