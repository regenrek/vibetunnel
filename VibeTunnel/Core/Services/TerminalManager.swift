//
//  TerminalManager.swift
//  VibeTunnel
//
//  Created by VibeTunnel on 15.06.25.
//

import Foundation
import Logging
import Combine

/// Manages terminal sessions and command execution
actor TerminalManager {
    private var sessions: [UUID: TunnelSession] = [:]
    private var processes: [UUID: Process] = [:]
    private var pipes: [UUID: (stdin: Pipe, stdout: Pipe, stderr: Pipe)] = [:]
    private let logger = Logger(label: "VibeTunnel.TerminalManager")
    
    /// Create a new terminal session
    func createSession(request: CreateSessionRequest) throws -> TunnelSession {
        let session = TunnelSession()
        sessions[session.id] = session
        
        // Set up process and pipes
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        // Configure the process
        process.executableURL = URL(fileURLWithPath: request.shell ?? "/bin/zsh")
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        
        if let environment = request.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        
        // Start the process
        do {
            try process.run()
            processes[session.id] = process
            pipes[session.id] = (stdinPipe, stdoutPipe, stderrPipe)
            
            logger.info("Created session \(session.id) with process \(process.processIdentifier)")
        } catch {
            sessions.removeValue(forKey: session.id)
            throw error
        }
        
        return session
    }
    
    /// Execute a command in a session
    func executeCommand(sessionId: UUID, command: String) async throws -> (output: String, error: String) {
        guard var session = sessions[sessionId],
              let process = processes[sessionId],
              let (stdin, stdout, stderr) = pipes[sessionId],
              process.isRunning else {
            throw TunnelError.sessionNotFound
        }
        
        // Update session activity
        session.updateActivity()
        sessions[sessionId] = session
        
        // Send command to stdin
        let commandData = (command + "\n").data(using: .utf8)!
        stdin.fileHandleForWriting.write(commandData)
        
        // Read output with timeout
        let outputData = try await withTimeout(seconds: 5) {
            stdout.fileHandleForReading.availableData
        }
        
        let errorData = try await withTimeout(seconds: 0.1) {
            stderr.fileHandleForReading.availableData
        }
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        
        return (output, error)
    }
    
    /// Get all active sessions
    func listSessions() -> [TunnelSession] {
        return Array(sessions.values)
    }
    
    /// Get a specific session
    func getSession(id: UUID) -> TunnelSession? {
        return sessions[id]
    }
    
    /// Close a session
    func closeSession(id: UUID) {
        if let process = processes[id] {
            process.terminate()
            processes.removeValue(forKey: id)
        }
        pipes.removeValue(forKey: id)
        sessions.removeValue(forKey: id)
        
        logger.info("Closed session \(id)")
    }
    
    /// Clean up inactive sessions
    func cleanupInactiveSessions(olderThan minutes: Int = 30) {
        let cutoffDate = Date().addingTimeInterval(-Double(minutes * 60))
        
        for (id, session) in sessions {
            if session.lastActivity < cutoffDate {
                closeSession(id: id)
                logger.info("Cleaned up inactive session \(id)")
            }
        }
    }
    
    // Helper function for timeout
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TunnelError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Errors that can occur in tunnel operations
enum TunnelError: LocalizedError {
    case sessionNotFound
    case commandExecutionFailed(String)
    case timeout
    case invalidRequest
    
    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        case .commandExecutionFailed(let message):
            return "Command execution failed: \(message)"
        case .timeout:
            return "Operation timed out"
        case .invalidRequest:
            return "Invalid request"
        }
    }
}