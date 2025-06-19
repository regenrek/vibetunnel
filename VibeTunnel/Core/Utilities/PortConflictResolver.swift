import Foundation
import OSLog

/// Information about a process that's using a port
struct ProcessDetails {
    let pid: Int
    let name: String
    let path: String?
    let parentPid: Int?
    let bundleIdentifier: String?
    
    /// Check if this is a VibeTunnel process
    var isVibeTunnel: Bool {
        if let bundleId = bundleIdentifier {
            return bundleId.contains("vibetunnel") || bundleId.contains("VibeTunnel")
        }
        if let path = path {
            return path.contains("VibeTunnel")
        }
        return name.contains("VibeTunnel")
    }
    
    /// Check if this is one of our managed servers
    var isManagedServer: Bool {
        name == "tty-fwd" || name.contains("node") && (path?.contains("VibeTunnel") ?? false)
    }
}

/// Information about a port conflict
struct PortConflict {
    let port: Int
    let process: ProcessDetails
    let rootProcess: ProcessDetails?
    let suggestedAction: ConflictAction
    let alternativePorts: [Int]
}

/// Suggested action for resolving a port conflict
enum ConflictAction {
    case killOurInstance(pid: Int, processName: String)
    case suggestAlternativePort
    case reportExternalApp(name: String)
}

/// Resolves port conflicts and suggests remediation
@MainActor
final class PortConflictResolver {
    private let logger = Logger(subsystem: "com.steipete.VibeTunnel", category: "PortConflictResolver")
    
    static let shared = PortConflictResolver()
    
    private init() {}
    
    /// Check if a port is available
    func isPortAvailable(_ port: Int) async -> Bool {
        let result = await detectConflict(on: port)
        return result == nil
    }
    
    /// Detect what process is using a port
    func detectConflict(on port: Int) async -> PortConflict? {
        do {
            // Use lsof to find process using the port
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-i", ":\(port)", "-n", "-P", "-F"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                // Port is free
                return nil
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                return nil
            }
            
            // Parse lsof output
            if let processInfo = parseLsofOutput(output) {
                // Get root process
                let rootProcess = await findRootProcess(for: processInfo)
                
                // Find alternative ports
                let alternatives = await findAvailablePorts(near: port, count: 3)
                
                // Determine action
                let action = determineAction(for: processInfo, rootProcess: rootProcess)
                
                return PortConflict(
                    port: port,
                    process: processInfo,
                    rootProcess: rootProcess,
                    suggestedAction: action,
                    alternativePorts: alternatives
                )
            }
        } catch {
            logger.error("Failed to check port conflict: \(error)")
        }
        
        return nil
    }
    
    /// Kill a process and optionally its parent VibeTunnel instance
    func resolveConflict(_ conflict: PortConflict) async throws {
        switch conflict.suggestedAction {
        case .killOurInstance(let pid, let processName):
            logger.info("Killing conflicting process: \(processName) (PID: \(pid))")
            
            // Kill the process
            let killProcess = Process()
            killProcess.executableURL = URL(fileURLWithPath: "/bin/kill")
            killProcess.arguments = ["-9", "\(pid)"]
            
            try killProcess.run()
            killProcess.waitUntilExit()
            
            if killProcess.terminationStatus != 0 {
                throw PortConflictError.failedToKillProcess(pid: pid)
            }
            
            // Wait a moment for port to be released
            try await Task.sleep(for: .milliseconds(500))
            
        case .suggestAlternativePort, .reportExternalApp:
            // These require user action
            throw PortConflictError.requiresUserAction
        }
    }
    
    /// Find available ports near a given port
    func findAvailablePorts(near port: Int, count: Int) async -> [Int] {
        var availablePorts: [Int] = []
        let range = max(1024, port - 10)...(port + 100)
        
        for candidatePort in range where candidatePort != port {
            if await isPortAvailable(candidatePort) {
                availablePorts.append(candidatePort)
                if availablePorts.count >= count {
                    break
                }
            }
        }
        
        return availablePorts
    }
    
    // MARK: - Private Methods
    
    private func parseLsofOutput(_ output: String) -> ProcessDetails? {
        var pid: Int?
        var name: String?
        var ppid: Int?
        
        // Parse lsof field output format
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("p") {
                pid = Int(line.dropFirst())
            } else if line.hasPrefix("c") {
                name = String(line.dropFirst())
            } else if line.hasPrefix("R") {
                ppid = Int(line.dropFirst())
            }
        }
        
        guard let pid = pid, let name = name else {
            return nil
        }
        
        // Get additional process info
        let path = getProcessPath(pid: pid)
        let bundleId = getProcessBundleIdentifier(pid: pid)
        
        return ProcessDetails(
            pid: pid,
            name: name,
            path: path,
            parentPid: ppid,
            bundleIdentifier: bundleId
        )
    }
    
    private func getProcessPath(pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "comm="]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.debug("Failed to get process path: \(error)")
        }
        
        return nil
    }
    
    private func getProcessBundleIdentifier(pid: Int) -> String? {
        // Try to get bundle identifier using lsappinfo
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = ["info", "-only", "bundleid", "\(pid)"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse bundleid from output
                if let range = output.range(of: "\"", options: .backwards) {
                    let beforeQuote = output[..<range.lowerBound]
                    if let startRange = beforeQuote.range(of: "\"", options: .backwards) {
                        let bundleId = output[startRange.upperBound..<range.lowerBound]
                        return String(bundleId)
                    }
                }
            }
        } catch {
            logger.debug("Failed to get bundle identifier: \(error)")
        }
        
        return nil
    }
    
    private func findRootProcess(for process: ProcessDetails) async -> ProcessDetails? {
        var current = process
        var visited = Set<Int>()
        
        while let parentPid = current.parentPid, parentPid > 1, !visited.contains(parentPid) {
            visited.insert(current.pid)
            
            // Get parent process info
            if let parentInfo = await getProcessInfo(pid: parentPid) {
                // If parent is VibeTunnel, it's our root
                if parentInfo.isVibeTunnel {
                    return parentInfo
                }
                current = parentInfo
            } else {
                break
            }
        }
        
        return nil
    }
    
    private func getProcessInfo(pid: Int) async -> ProcessDetails? {
        // Get process info using ps
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "pid=,ppid=,comm="]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                
                if components.count >= 3 {
                    let pid = Int(components[0]) ?? 0
                    let ppid = Int(components[1]) ?? 0
                    let name = components[2...].joined(separator: " ")
                    let path = getProcessPath(pid: pid)
                    let bundleId = getProcessBundleIdentifier(pid: pid)
                    
                    return ProcessDetails(
                        pid: pid,
                        name: name,
                        path: path,
                        parentPid: ppid > 0 ? ppid : nil,
                        bundleIdentifier: bundleId
                    )
                }
            }
        } catch {
            logger.debug("Failed to get process info: \(error)")
        }
        
        return nil
    }
    
    private func determineAction(for process: ProcessDetails, rootProcess: ProcessDetails?) -> ConflictAction {
        // If it's our managed server, kill it
        if process.isManagedServer {
            return .killOurInstance(pid: process.pid, processName: process.name)
        }
        
        // If root process is VibeTunnel, kill the whole app
        if let root = rootProcess, root.isVibeTunnel {
            return .killOurInstance(pid: root.pid, processName: root.name)
        }
        
        // If the process itself is VibeTunnel
        if process.isVibeTunnel {
            return .killOurInstance(pid: process.pid, processName: process.name)
        }
        
        // Otherwise, it's an external app
        return .reportExternalApp(name: process.name)
    }
}

// MARK: - Errors

enum PortConflictError: LocalizedError {
    case failedToKillProcess(pid: Int)
    case requiresUserAction
    
    var errorDescription: String? {
        switch self {
        case .failedToKillProcess(let pid):
            return "Failed to terminate process with PID \(pid)"
        case .requiresUserAction:
            return "This conflict requires user action to resolve"
        }
    }
}
