import AppKit
import Foundation
import SwiftUI

/// Supported terminal applications.
///
/// Represents terminal emulators that VibeTunnel can launch
/// with commands, including detection of installed terminals.
enum Terminal: String, CaseIterable {
    case terminal = "Terminal"
    case iTerm2 = "iTerm2"
    case ghostty = "Ghostty"

    var bundleIdentifier: String {
        switch self {
        case .terminal:
            "com.apple.Terminal"
        case .iTerm2:
            "com.googlecode.iterm2"
        case .ghostty:
            "com.mitchellh.ghostty"
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

    @AppStorage("preferredTerminal")
    private var preferredTerminal = Terminal.terminal.rawValue

    private init() {}

    func launchCommand(_ command: String) throws {
        let terminal = Terminal(rawValue: preferredTerminal) ?? .terminal

        // Verify terminal is still installed, fallback to Terminal if not
        let actualTerminal = terminal.isInstalled ? terminal : .terminal

        if actualTerminal != terminal {
            // Update preference to fallback
            preferredTerminal = actualTerminal.rawValue
        }

        try launchCommand(command, in: actualTerminal)
    }

    private func launchCommand(_ command: String, in terminal: Terminal) throws {
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript: String
        switch terminal {
        case .terminal:
            appleScript = """
            tell application "Terminal"
                activate
                do script "\(escapedCommand)"
            end tell
            """

        case .iTerm2:
            appleScript = """
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "\(escapedCommand)"
                end tell
            end tell
            """

        case .ghostty:
            // Ghostty doesn't have AppleScript support, so we use open command
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-b", terminal.bundleIdentifier, "--args", "-e", command]

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    throw TerminalLauncherError.appleScriptExecutionFailed("Failed to launch Ghostty")
                }
                return
            } catch {
                throw TerminalLauncherError.appleScriptExecutionFailed(error.localizedDescription)
            }
        }

        // Execute AppleScript for Terminal and iTerm2
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            _ = scriptObject.executeAndReturnError(&error)

            if let error {
                let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? 0

                // Check for permission errors
                if errorNumber == -1_743 {
                    throw TerminalLauncherError.appleScriptPermissionDenied
                }

                throw TerminalLauncherError.appleScriptExecutionFailed(errorMessage)
            }
        }
    }

    func verifyPreferredTerminal() {
        let terminal = Terminal(rawValue: preferredTerminal) ?? .terminal
        if !terminal.isInstalled {
            preferredTerminal = Terminal.terminal.rawValue
        }
    }
}
