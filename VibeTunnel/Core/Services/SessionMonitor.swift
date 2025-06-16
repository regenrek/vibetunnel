//
//  SessionMonitor.swift
//  VibeTunnel
//
//  Created by Assistant on 6/16/25.
//

import Foundation
import Observation

/// Monitors tty-fwd sessions and provides real-time session count
@MainActor
@Observable
class SessionMonitor {
    static let shared = SessionMonitor()
    
    var sessionCount: Int = 0
    var sessions: [String: SessionInfo] = [:]
    var lastError: String?
    
    private var monitoringTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 5.0 // Check every 5 seconds
    private var serverPort: Int
    
    struct SessionInfo: Codable {
        let cmdline: [String]
        let cwd: String
        let exit_code: Int?
        let name: String
        let pid: Int
        let started_at: String
        let status: String
        let stdin: String
        let `stream-out`: String
        
        var isRunning: Bool {
            status == "running"
        }
    }
    
    private init() {
        let port = UserDefaults.standard.integer(forKey: "serverPort")
        self.serverPort = port > 0 ? port : 4020
    }
    
    func startMonitoring() {
        stopMonitoring()
        
        // Update port from UserDefaults in case it changed
        let port = UserDefaults.standard.integer(forKey: "serverPort")
        self.serverPort = port > 0 ? port : 4020
        
        // Start monitoring task
        monitoringTask = Task {
            // Initial fetch
            await fetchSessions()
            
            // Set up periodic fetching
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                if !Task.isCancelled {
                    await fetchSessions()
                }
            }
        }
    }
    
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    @MainActor
    private func fetchSessions() async {
        do {
            // First check if server is running
            let healthURL = URL(string: "http://127.0.0.1:\(serverPort)/health")!
            let healthRequest = URLRequest(url: healthURL, timeoutInterval: 2.0)
            
            do {
                let (_, healthResponse) = try await URLSession.shared.data(for: healthRequest)
                guard let httpResponse = healthResponse as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    // Server not running
                    self.sessions = [:]
                    self.sessionCount = 0
                    self.lastError = nil
                    return
                }
            } catch {
                // Server not reachable
                self.sessions = [:]
                self.sessionCount = 0
                self.lastError = nil
                return
            }
            
            // Server is running, fetch sessions
            let url = URL(string: "http://127.0.0.1:\(serverPort)/sessions")!
            let request = URLRequest(url: url, timeoutInterval: 5.0)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                self.lastError = "Failed to fetch sessions"
                return
            }
            
            // Parse JSON response
            let sessionsData = try JSONDecoder().decode([String: SessionInfo].self, from: data)
            self.sessions = sessionsData
            
            // Count only running sessions
            self.sessionCount = sessionsData.values.filter { $0.isRunning }.count
            self.lastError = nil
            
        } catch {
            // Don't set error for connection issues when server is likely not running
            if !(error is URLError) {
                self.lastError = "Error fetching sessions: \(error.localizedDescription)"
            }
            // Clear sessions on error
            self.sessions = [:]
            self.sessionCount = 0
        }
    }
    
    func refreshNow() async {
        await fetchSessions()
    }
}