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
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    var appleScriptEscapedCommand: String {
        fullCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
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
    case wezterm = "WezTerm"

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
        case .wezterm:
            "com.github.wez.wezterm"
        }
    }
    
    /// Priority for auto-detection (higher is better, based on popularity)
    var detectionPriority: Int {
        switch self {
        case .terminal: return 100   // Highest - macOS default, most popular
        case .iTerm2: return 95      // Very popular among developers
        case .warp: return 85        // Popular modern terminal
        case .ghostty: return 80     // New but gaining popularity
        case .alacritty: return 70   // Popular among power users
        case .wezterm: return 60     // Less common but powerful
        case .hyper: return 50       // Less popular Electron-based
        case .tabby: return 40       // Least popular
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
    
    /// Generate AppleScript for terminals that use keyboard input
    private func keystrokeAppleScript(for config: TerminalLaunchConfig) -> String {
        """
        tell application "\(processName)"
            activate
            tell application "System Events"
                keystroke "n" using {command down}
            end tell
            delay 0.2
            tell application "System Events"
                keystroke "\(config.appleScriptEscapedCommand)"
                key code 36
            end tell
        end tell
        """
    }
    
    /// Determine the launch method for this terminal
    func launchMethod(for config: TerminalLaunchConfig) -> TerminalLaunchMethod {
        switch self {
        case .terminal:
            // Terminal.app has very limited CLI support, must use AppleScript
            return .appleScript(script: """
                tell application "Terminal"
                    activate
                    tell application "System Events"
                        keystroke "n" using {command down}
                    end tell
                    delay 0.1
                    do script "\(config.command)" in front window
                end tell
                """)
            
        case .iTerm2:
            // iTerm2 supports URL schemes for command execution
            if let encoded = config.fullCommand.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                // Use iTerm2's URL scheme instead of AppleScript
                // Note: URL must be opened with 'open' command, not as an argument
                let urlString = "iterm2://profile=default?cmd=\(encoded)"
                return .processWithArgs(args: [urlString])
            } else {
                // Fallback to AppleScript if encoding fails
                return .appleScript(script: """
                    tell application "iTerm"
                        activate
                        create window with default profile
                        tell current session of current window
                            write text "\(config.command)"
                        end tell
                    end tell
                    """)
            }
            
        case .ghostty:
            // Ghostty requires AppleScript for command execution
            return .appleScript(script: keystrokeAppleScript(for: config))
            
        case .alacritty:
            var args = ["--args", "-e", config.command]
            if let workingDirectory = config.workingDirectory {
                args = ["--args", "--working-directory", workingDirectory, "-e", config.command]
            }
            return .processWithArgs(args: args)
            
        case .warp:
            // Warp requires AppleScript for command execution
            return .appleScript(script: keystrokeAppleScript(for: config))
            
        case .hyper:
            // Hyper requires AppleScript for command execution
            return .appleScript(script: keystrokeAppleScript(for: config))
            
        case .tabby:
            // Tabby has limited CLI support
            return .processWithTyping()
            
        case .wezterm:
            // WezTerm has excellent CLI support with the 'start' subcommand
            var args = ["--args", "start"]
            if let workingDirectory = config.workingDirectory {
                args += ["--cwd", workingDirectory]
            }
            args += ["--", "sh", "-c", config.command]
            return .processWithArgs(args: args)
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
        case .wezterm: return "WezTerm"
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

    @AppStorage("preferredTerminal")
    private var preferredTerminal = Terminal.terminal.rawValue

    private init() {
        logger.info("TerminalLauncher initializing...")
        performFirstRunAutoDetection()
        logger.info("TerminalLauncher initialized successfully")
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
                    logger.info("No running terminals found, set preferred terminal to most popular installed: \(bestTerminal.rawValue)")
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
            
            // Use the same keystroke pattern as other terminals
            try executeAppleScript(config.terminal.keystrokeAppleScript(for: config))
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
    
    
    // MARK: - Terminal Session Launching
    
    func launchTerminalSession(workingDirectory: String, command: String, sessionId: String) throws {
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