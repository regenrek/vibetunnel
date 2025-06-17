import AppKit
import Foundation
import SwiftUI
import os.log

/// Terminal launch configuration
struct TerminalLaunchConfig {
    let command: String
    let workingDirectory: String?
    let terminal: Terminal
    
    var fullCommand: String {
        guard let workingDirectory = workingDirectory else {
            return command
        }
        let escapedDir = workingDirectory.replacingOccurrences(of: "\"", with: "\\\"")
        return "cd \"\(escapedDir)\" && \(command)"
    }
    
    var escapedCommand: String {
        command.replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Terminal launch methods
enum TerminalLaunchMethod {
    case appleScript(script: String)
    case processWithArgs(args: [String])
    case processWithTyping(delaySeconds: Double = 0.5)
}

/// Supported terminal applications.
///
/// Represents terminal emulators that VibeTunnel can launch
/// with commands, including detection of installed terminals.
enum Terminal: String, CaseIterable {
    case terminal = "Terminal"
    case iTerm2 = "iTerm2"
    case ghostty = "Ghostty"
    case warp = "Warp"
    case tabby = "Tabby"
    case alacritty = "Alacritty"
    case hyper = "Hyper"
    case prompt = "Prompt"

    var bundleIdentifier: String {
        switch self {
        case .terminal:
            "com.apple.Terminal"
        case .iTerm2:
            "com.googlecode.iterm2"
        case .ghostty:
            "com.mitchellh.ghostty"
        case .warp:
            "dev.warp.Warp-Stable"
        case .tabby:
            "org.tabby"
        case .alacritty:
            "org.alacritty"
        case .hyper:
            "co.zeit.hyper"
        case .prompt:
            "com.panic.prompt.3"
        }
    }
    
    /// Priority for auto-detection (higher is better, Terminal has lowest priority)
    var detectionPriority: Int {
        switch self {
        case .terminal: return 0  // Lowest priority
        case .iTerm2: return 100
        case .ghostty: return 90
        case .alacritty: return 80
        case .warp: return 70
        case .hyper: return 60
        case .tabby: return 50
        case .prompt: return 85  // High priority SSH client
        }
    }

    var displayName: String {
        rawValue
    }

    var isInstalled: Bool {
        if self == .terminal {
            return true // Terminal is always installed
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    var appIcon: NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    static var installed: [Self] {
        allCases.filter(\.isInstalled)
    }
    
    /// Determine the launch method for this terminal
    func launchMethod(for config: TerminalLaunchConfig) -> TerminalLaunchMethod {
        switch self {
        case .terminal:
            return .appleScript(script: """
                tell application "Terminal"
                    activate
                    do script "\(config.fullCommand)"
                end tell
                """)
            
        case .iTerm2:
            return .appleScript(script: """
                tell application "iTerm"
                    activate
                    create window with default profile
                    tell current session of current window
                        write text "\(config.fullCommand)"
                    end tell
                end tell
                """)
            
        case .ghostty:
            var args = ["--args", "-e", config.command]
            if let workingDirectory = config.workingDirectory {
                args = ["--args", "--working-directory", workingDirectory, "-e", config.command]
            }
            return .processWithArgs(args: args)
            
        case .alacritty:
            var args = ["--args", "-e", config.command]
            if let workingDirectory = config.workingDirectory {
                args = ["--args", "--working-directory", workingDirectory, "-e", config.command]
            }
            return .processWithArgs(args: args)
            
        case .warp, .tabby, .hyper:
            // These terminals require launching first, then typing the command
            return .processWithTyping()
            
        case .prompt:
            // Prompt is an SSH client, use special handling
            return .processWithTyping(delaySeconds: 1.0)  // Longer delay for Prompt
        }
    }
    
    /// Process name for AppleScript typing
    var processName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm2: return "iTerm"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .tabby: return "Tabby"
        case .alacritty: return "Alacritty"
        case .hyper: return "Hyper"
        case .prompt: return "Prompt"
        }
    }
}

/// Errors that can occur when launching terminal commands.
///
/// Represents failures during terminal application launch,
/// including permission issues and missing applications.
enum TerminalLauncherError: LocalizedError {
    case terminalNotFound
    case appleScriptPermissionDenied
    case appleScriptExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .terminalNotFound:
            "Selected terminal application not found"
        case .appleScriptPermissionDenied:
            "AppleScript permission denied. Please grant permission in System Settings."
        case .appleScriptExecutionFailed(let message):
            "Failed to execute AppleScript: \(message)"
        }
    }
}

/// Manages launching terminal commands in the user's preferred terminal.
///
/// Handles terminal application detection, preference management,
/// and command execution through AppleScript or direct process launching.
/// Supports Terminal, iTerm2, and Ghostty with automatic fallback.
@MainActor
final class TerminalLauncher {
    static let shared = TerminalLauncher()
    
    private let logger = Logger(subsystem: "sh.vibetunnel.VibeTunnel", category: "TerminalLauncher")
    private nonisolated(unsafe) var notificationObserver: NSObjectProtocol?

    @AppStorage("preferredTerminal")
    private var preferredTerminal = Terminal.terminal.rawValue

    private init() {
        setupNotificationListener()
        performFirstRunAutoDetection()
    }
    
    deinit {
        // Clean up notification observer
        if let observer = notificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func launchCommand(_ command: String) throws {
        let terminal = getValidTerminal()
        let config = TerminalLaunchConfig(command: command, workingDirectory: nil, terminal: terminal)
        try launchWithConfig(config)
    }

    func verifyPreferredTerminal() {
        let terminal = Terminal(rawValue: preferredTerminal) ?? .terminal
        if !terminal.isInstalled {
            preferredTerminal = Terminal.terminal.rawValue
        }
    }
    
    // MARK: - Private Methods
    
    private func performFirstRunAutoDetection() {
        // Check if terminal preference has already been set
        let hasSetPreference = UserDefaults.standard.object(forKey: "preferredTerminal") != nil
        
        if !hasSetPreference {
            logger.info("First run detected, auto-detecting preferred terminal from running processes")
            
            if let detectedTerminal = detectRunningTerminals() {
                preferredTerminal = detectedTerminal.rawValue
                logger.info("Auto-detected and set preferred terminal to: \(detectedTerminal.rawValue)")
            } else {
                // No terminals detected in running processes, check installed terminals
                let installedTerminals = Terminal.installed.filter { $0 != .terminal }
                if let bestTerminal = installedTerminals.max(by: { $0.detectionPriority < $1.detectionPriority }) {
                    preferredTerminal = bestTerminal.rawValue
                    logger.info("No running terminals found, set preferred terminal to highest priority installed: \(bestTerminal.rawValue)")
                }
            }
        }
    }
    
    private func detectRunningTerminals() -> Terminal? {
        // Get all running applications
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Find all terminals that are currently running
        var runningTerminals: [Terminal] = []
        
        for terminal in Terminal.allCases {
            if runningApps.contains(where: { $0.bundleIdentifier == terminal.bundleIdentifier }) {
                runningTerminals.append(terminal)
                logger.debug("Detected running terminal: \(terminal.rawValue)")
            }
        }
        
        // Return the terminal with highest priority
        return runningTerminals.max(by: { $0.detectionPriority < $1.detectionPriority })
    }
    
    private func getValidTerminal() -> Terminal {
        let terminal = Terminal(rawValue: preferredTerminal) ?? .terminal
        let actualTerminal = terminal.isInstalled ? terminal : .terminal
        
        if actualTerminal != terminal {
            // Update preference to fallback
            preferredTerminal = actualTerminal.rawValue
            logger.warning("Preferred terminal \(terminal.rawValue) not installed, falling back to \(actualTerminal.rawValue)")
        }
        
        return actualTerminal
    }
    
    private func launchWithConfig(_ config: TerminalLaunchConfig) throws {
        let method = config.terminal.launchMethod(for: config)
        
        switch method {
        case .appleScript(let script):
            try executeAppleScript(script)
            
        case .processWithArgs(let args):
            try launchProcess(bundleIdentifier: config.terminal.bundleIdentifier, args: args)
            
        case .processWithTyping(let delay):
            try launchProcess(bundleIdentifier: config.terminal.bundleIdentifier, args: [])
            
            // Give the terminal time to start
            Thread.sleep(forTimeInterval: delay)
            
            // Type the command
            let typeScript = """
            tell application "System Events"
                tell process "\(config.terminal.processName)"
                    set frontmost to true
                    keystroke "\(config.fullCommand)"
                    key code 36
                end tell
            end tell
            """
            try executeAppleScript(typeScript)
        }
    }
    
    private func launchProcess(bundleIdentifier: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier] + args
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                throw TerminalLauncherError.appleScriptExecutionFailed("Process exited with status \(process.terminationStatus)")
            }
        } catch {
            logger.error("Failed to launch terminal: \(error.localizedDescription)")
            throw TerminalLauncherError.appleScriptExecutionFailed(error.localizedDescription)
        }
    }
    
    private func executeAppleScript(_ script: String) throws {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            _ = scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                
                // Check for permission errors
                if errorNumber == -1_743 {
                    throw TerminalLauncherError.appleScriptPermissionDenied
                }
                
                logger.error("AppleScript execution failed: \(errorMessage)")
                throw TerminalLauncherError.appleScriptExecutionFailed(errorMessage)
            }
        }
    }
    
    // MARK: - Distributed Notification Handling
    
    private func setupNotificationListener() {
        let notificationName = NSNotification.Name("sh.vibetunnel.vibetunnel.openSession")
        
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            // Extract values immediately to avoid sending notification across boundaries
            let userInfo = notification.userInfo
            let workingDirectory = userInfo?["workingDirectory"] as? String
            let command = userInfo?["command"] as? String
            let sessionId = userInfo?["sessionId"] as? String
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.processOpenSessionRequest(
                    workingDirectory: workingDirectory,
                    command: command,
                    sessionId: sessionId
                )
            }
        }
        
        logger.info("Registered for distributed notification: \(notificationName.rawValue)")
    }
    
    private func processOpenSessionRequest(workingDirectory: String?, command: String?, sessionId: String?) {
        guard let workingDirectory = workingDirectory,
              let command = command,
              let sessionId = sessionId else {
            logger.error("Invalid notification payload: missing required fields")
            return
        }
        
        logger.info("Received openSession notification - sessionId: \(sessionId), workingDirectory: \(workingDirectory)")
        
        Task {
            do {
                try await launchTerminalSession(
                    workingDirectory: workingDirectory,
                    command: command,
                    sessionId: sessionId
                )
            } catch {
                logger.error("Failed to launch terminal session: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Terminal Session Launching
    
    func launchTerminalSession(workingDirectory: String, command: String, sessionId: String) async throws {
        // Find tty-fwd binary path
        let ttyFwdPath = findTTYFwdBinary()
        
        // Escape the working directory for shell
        let escapedWorkingDir = workingDirectory.replacingOccurrences(of: "\"", with: "\\\"")
        
        // Construct the full command with cd && tty-fwd && exit pattern
        let fullCommand = "cd \"\(escapedWorkingDir)\" && \(ttyFwdPath) --session-id=\"\(sessionId)\" -- \(command) && exit"
        
        // Get the preferred terminal or fallback
        let terminal = getValidTerminal()
        
        // Launch with configuration - no working directory since we handle it in the command
        let config = TerminalLaunchConfig(
            command: fullCommand,
            workingDirectory: nil,
            terminal: terminal
        )
        try launchWithConfig(config)
    }
    
    private func findTTYFwdBinary() -> String {
        // First, check if tty-fwd is in PATH
        let checkTTYFwd = Process()
        checkTTYFwd.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        checkTTYFwd.arguments = ["tty-fwd"]
        
        let pipe = Pipe()
        checkTTYFwd.standardOutput = pipe
        checkTTYFwd.standardError = FileHandle.nullDevice
        
        do {
            try checkTTYFwd.run()
            checkTTYFwd.waitUntilExit()
            
            if checkTTYFwd.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    logger.info("Found tty-fwd in PATH at: \(path)")
                    return path
                }
            }
        } catch {
            logger.warning("Failed to check for tty-fwd in PATH: \(error.localizedDescription)")
        }
        
        // Look for bundled tty-fwd binary
        if let bundledTTYFwd = Bundle.main.path(forResource: "tty-fwd", ofType: nil) {
            logger.info("Using bundled tty-fwd at: \(bundledTTYFwd)")
            return bundledTTYFwd
        }
        
        // Try common locations
        let commonPaths = [
            "/usr/local/bin/tty-fwd",
            "/opt/homebrew/bin/tty-fwd",
            "/usr/bin/tty-fwd"
        ]
        
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                logger.info("Found tty-fwd at: \(path)")
                return path
            }
        }
        
        logger.error("No tty-fwd binary found, command will fail")
        return "echo 'VibeTunnel: tty-fwd binary not found'; false"
    }
}