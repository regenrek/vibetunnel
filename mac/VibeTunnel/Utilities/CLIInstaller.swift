import AppKit
import Foundation
import Observation
import os.log
import SwiftUI

/// Service responsible for creating symlinks to command line tools with sudo authentication.
///
/// ## Overview
/// This service creates symlinks from the application bundle's resources to system locations like /usr/local/bin
/// to enable command line access to bundled tools. It handles sudo authentication through system dialogs.
///
/// ## Usage
/// ```swift
/// let installer = CLIInstaller()
/// installer.installCLITool()
/// ```
///
/// ## Safety Considerations
/// - Always prompts user before performing operations requiring sudo
/// - Provides clear error messages and graceful failure handling
/// - Checks for existing symlinks and handles conflicts appropriately
/// - Logs all operations for debugging purposes
@MainActor
@Observable
final class CLIInstaller {
    // MARK: - Properties

    private let logger = Logger(subsystem: "sh.vibetunnel.vibetunnel", category: "CLIInstaller")

    var isInstalled = false
    var isInstalling = false
    var lastError: String?
    var installedVersion: String?
    var bundledVersion: String?
    var needsUpdate = false

    // MARK: - Public Interface

    /// Checks if the CLI tool is installed
    func checkInstallationStatus() {
        Task { @MainActor in
            let vtPath = "/usr/local/bin/vt"
            let vibetunnelPath = "/usr/local/bin/vibetunnel"
            
            // Both tools must be installed
            let vtInstalled = FileManager.default.fileExists(atPath: vtPath)
            let vibetunnelInstalled = FileManager.default.fileExists(atPath: vibetunnelPath)
            let installed = vtInstalled && vibetunnelInstalled

            // Update state without animation
            isInstalled = installed

            // Move version checks to background
            Task.detached(priority: .userInitiated) {
                var installedVer: String?
                var bundledVer: String?

                if installed {
                    // Check version of installed tools
                    installedVer = await self.getInstalledVersionAsync()
                }

                // Get bundled version
                bundledVer = await self.getBundledVersionAsync()

                // Update UI on main thread
                await MainActor.run {
                    self.installedVersion = installedVer
                    self.bundledVersion = bundledVer

                    // Check if update is needed
                    self.needsUpdate = installed && self.installedVersion != self.bundledVersion

                    self.logger
                        .info(
                            "CLIInstaller: CLI tools installed: \(self.isInstalled) (vt: \(vtInstalled), vibetunnel: \(vibetunnelInstalled)), installed version: \(self.installedVersion ?? "unknown"), bundled version: \(self.bundledVersion ?? "unknown"), needs update: \(self.needsUpdate)"
                        )
                }
            }
        }
    }

    /// Gets the version of the installed vt tool
    private func getInstalledVersion() -> String? {
        // Get vt version
        var vtVersion: String?
        let vtTask = Process()
        vtTask.launchPath = "/usr/local/bin/vt"
        vtTask.arguments = ["--version"]

        let vtPipe = Pipe()
        vtTask.standardOutput = vtPipe
        vtTask.standardError = vtPipe

        do {
            try vtTask.run()
            vtTask.waitUntilExit()

            let data = vtPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse version from output like "vt version 2.0.0"
            if let output, output.contains("version") {
                let components = output.components(separatedBy: " ")
                if let versionIndex = components.firstIndex(of: "version"), versionIndex + 1 < components.count {
                    vtVersion = components[versionIndex + 1]
                }
            }
        } catch {
            logger.error("Failed to get installed vt version: \(error)")
            vtVersion = nil
        }
        
        // Get vibetunnel version
        var vibetunnelVersion: String?
        let vibetunnelTask = Process()
        vibetunnelTask.launchPath = "/usr/local/bin/vibetunnel"
        vibetunnelTask.arguments = ["version"]

        let vibetunnelPipe = Pipe()
        vibetunnelTask.standardOutput = vibetunnelPipe
        vibetunnelTask.standardError = vibetunnelPipe

        do {
            try vibetunnelTask.run()
            vibetunnelTask.waitUntilExit()

            let data = vibetunnelPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse version from output like "VibeTunnel Linux v1.0.3"
            if let output, output.contains("v") {
                if let range = output.range(of: #"v(\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    vibetunnelVersion = String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            logger.error("Failed to get installed vibetunnel version: \(error)")
            vibetunnelVersion = nil
        }
        
        // Return the lowest version or "unknown" if either is missing
        if let vtVer = vtVersion, let vibetunnelVer = vibetunnelVersion {
            // Compare versions and return the lower one
            if vtVer.compare(vibetunnelVer, options: .numeric) == .orderedAscending {
                return vtVer
            } else {
                return vibetunnelVer
            }
        }
        
        // If either version is missing, return "unknown"
        return vtVersion ?? vibetunnelVersion ?? "unknown"
    }

    /// Gets the version of the bundled vt tool
    private func getBundledVersion() -> String? {
        // Get vt version
        var vtVersion: String?
        if let vtPath = Bundle.main.path(forResource: "vt", ofType: nil) {
            let vtTask = Process()
            vtTask.launchPath = vtPath
            vtTask.arguments = ["--version"]

            let vtPipe = Pipe()
            vtTask.standardOutput = vtPipe
            vtTask.standardError = vtPipe

            do {
                try vtTask.run()
                vtTask.waitUntilExit()

                let data = vtPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse version from output like "vt version 2.0.0"
                if let output, output.contains("version") {
                    let components = output.components(separatedBy: " ")
                    if let versionIndex = components.firstIndex(of: "version"), versionIndex + 1 < components.count {
                        vtVersion = components[versionIndex + 1]
                    }
                }
            } catch {
                logger.error("Failed to get bundled vt version: \(error)")
                vtVersion = nil
            }
        }
        
        // Get vibetunnel version
        var vibetunnelVersion: String?
        if let vibetunnelPath = Bundle.main.path(forResource: "vibetunnel", ofType: nil) {
            let vibetunnelTask = Process()
            vibetunnelTask.launchPath = vibetunnelPath
            vibetunnelTask.arguments = ["version"]

            let vibetunnelPipe = Pipe()
            vibetunnelTask.standardOutput = vibetunnelPipe
            vibetunnelTask.standardError = vibetunnelPipe

            do {
                try vibetunnelTask.run()
                vibetunnelTask.waitUntilExit()

                let data = vibetunnelPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse version from output like "VibeTunnel Linux v1.0.3"
                if let output, output.contains("v") {
                    if let range = output.range(of: #"v(\d+\.\d+\.\d+)"#, options: .regularExpression) {
                        vibetunnelVersion = String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                logger.error("Failed to get bundled vibetunnel version: \(error)")
                vibetunnelVersion = nil
            }
        }
        
        // Return the lowest version or "unknown" if either is missing
        if let vtVer = vtVersion, let vibetunnelVer = vibetunnelVersion {
            // Compare versions and return the lower one
            if vtVer.compare(vibetunnelVer, options: .numeric) == .orderedAscending {
                return vtVer
            } else {
                return vibetunnelVer
            }
        }
        
        // If either version is missing, return "unknown"
        return vtVersion ?? vibetunnelVersion ?? "unknown"
    }

    /// Gets the version of the installed vt tool (async version for background execution)
    private nonisolated func getInstalledVersionAsync() async -> String? {
        // Get vt version
        var vtVersion: String?
        let vtTask = Process()
        vtTask.launchPath = "/usr/local/bin/vt"
        vtTask.arguments = ["--version"]

        let vtPipe = Pipe()
        vtTask.standardOutput = vtPipe
        vtTask.standardError = vtPipe

        do {
            try vtTask.run()
            vtTask.waitUntilExit()

            let data = vtPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse version from output like "vt version 2.0.0"
            if let output, output.contains("version") {
                let components = output.components(separatedBy: " ")
                if let versionIndex = components.firstIndex(of: "version"), versionIndex + 1 < components.count {
                    vtVersion = components[versionIndex + 1]
                }
            }
        } catch {
            vtVersion = nil
        }
        
        // Get vibetunnel version
        var vibetunnelVersion: String?
        let vibetunnelTask = Process()
        vibetunnelTask.launchPath = "/usr/local/bin/vibetunnel"
        vibetunnelTask.arguments = ["version"]

        let vibetunnelPipe = Pipe()
        vibetunnelTask.standardOutput = vibetunnelPipe
        vibetunnelTask.standardError = vibetunnelPipe

        do {
            try vibetunnelTask.run()
            vibetunnelTask.waitUntilExit()

            let data = vibetunnelPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse version from output like "VibeTunnel Linux v1.0.3"
            if let output, output.contains("v") {
                if let range = output.range(of: #"v(\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    vibetunnelVersion = String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            vibetunnelVersion = nil
        }
        
        // Return the lowest version or "unknown" if either is missing
        if let vtVer = vtVersion, let vibetunnelVer = vibetunnelVersion {
            // Compare versions and return the lower one
            if vtVer.compare(vibetunnelVer, options: .numeric) == .orderedAscending {
                return vtVer
            } else {
                return vibetunnelVer
            }
        }
        
        // If either version is missing, return "unknown"
        return vtVersion ?? vibetunnelVersion ?? "unknown"
    }

    /// Gets the version of the bundled vt tool (async version for background execution)
    private nonisolated func getBundledVersionAsync() async -> String? {
        // Get vt version
        var vtVersion: String?
        if let vtPath = Bundle.main.path(forResource: "vt", ofType: nil) {
            let vtTask = Process()
            vtTask.launchPath = vtPath
            vtTask.arguments = ["--version"]

            let vtPipe = Pipe()
            vtTask.standardOutput = vtPipe
            vtTask.standardError = vtPipe

            do {
                try vtTask.run()
                vtTask.waitUntilExit()

                let data = vtPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse version from output like "vt version 2.0.0"
                if let output, output.contains("version") {
                    let components = output.components(separatedBy: " ")
                    if let versionIndex = components.firstIndex(of: "version"), versionIndex + 1 < components.count {
                        vtVersion = components[versionIndex + 1]
                    }
                }
            } catch {
                vtVersion = nil
            }
        }
        
        // Get vibetunnel version
        var vibetunnelVersion: String?
        if let vibetunnelPath = Bundle.main.path(forResource: "vibetunnel", ofType: nil) {
            let vibetunnelTask = Process()
            vibetunnelTask.launchPath = vibetunnelPath
            vibetunnelTask.arguments = ["version"]

            let vibetunnelPipe = Pipe()
            vibetunnelTask.standardOutput = vibetunnelPipe
            vibetunnelTask.standardError = vibetunnelPipe

            do {
                try vibetunnelTask.run()
                vibetunnelTask.waitUntilExit()

                let data = vibetunnelPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse version from output like "VibeTunnel Linux v1.0.3"
                if let output, output.contains("v") {
                    if let range = output.range(of: #"v(\d+\.\d+\.\d+)"#, options: .regularExpression) {
                        vibetunnelVersion = String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                vibetunnelVersion = nil
            }
        }
        
        // Return the lowest version or "unknown" if either is missing
        if let vtVer = vtVersion, let vibetunnelVer = vibetunnelVersion {
            // Compare versions and return the lower one
            if vtVer.compare(vibetunnelVer, options: .numeric) == .orderedAscending {
                return vtVer
            } else {
                return vibetunnelVer
            }
        }
        
        // If either version is missing, return "unknown"
        return vtVersion ?? vibetunnelVersion ?? "unknown"
    }

    /// Installs the CLI tool (async version for WelcomeView)
    func install() async {
        await MainActor.run {
            installCLITool()
        }
    }

    /// Updates the CLI tool to the bundled version
    func updateCLITool() {
        logger.info("CLIInstaller: Starting CLI tool update...")

        // Show update confirmation dialog
        let alert = NSAlert()
        alert.messageText = "Update VT Command Line Tools"
        alert.informativeText = """
        A newer version of the VibeTunnel command line tools is available.

        Installed version: \(installedVersion ?? "unknown")
        Available version: \(bundledVersion ?? "unknown")

        Would you like to update now? Administrator privileges will be required.
        """
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage

        let response = alert.runModal()
        if response != .alertFirstButtonReturn {
            logger.info("CLIInstaller: User cancelled update")
            return
        }

        // Proceed with installation (which will replace the existing tool)
        installCLITool()
    }

    /// Installs the vt CLI tool to /usr/local/bin with proper symlink
    func installCLITool() {
        logger.info("CLIInstaller: Starting CLI tool installation...")
        isInstalling = true
        lastError = nil

        guard let vtResourcePath = Bundle.main.path(forResource: "vt", ofType: nil) else {
            logger.error("CLIInstaller: Could not find vt binary in app bundle")
            lastError = "The vt command line tool could not be found in the application bundle."
            showError("The vt command line tool could not be found in the application bundle.")
            isInstalling = false
            return
        }
        
        guard let vibetunnelResourcePath = Bundle.main.path(forResource: "vibetunnel", ofType: nil) else {
            logger.error("CLIInstaller: Could not find vibetunnel binary in app bundle")
            lastError = "The vibetunnel binary could not be found in the application bundle."
            showError("The vibetunnel binary could not be found in the application bundle.")
            isInstalling = false
            return
        }

        let vtTargetPath = "/usr/local/bin/vt"
        let vibetunnelTargetPath = "/usr/local/bin/vibetunnel"
        
        logger.info("CLIInstaller: vt resource path: \(vtResourcePath)")
        logger.info("CLIInstaller: vibetunnel resource path: \(vibetunnelResourcePath)")
        logger.info("CLIInstaller: vt target path: \(vtTargetPath)")
        logger.info("CLIInstaller: vibetunnel target path: \(vibetunnelTargetPath)")

        // Show confirmation dialog (removed duplicate replacement dialog)
        let confirmAlert = NSAlert()
        confirmAlert.messageText = "Install CLI Tools"
        confirmAlert
            .informativeText =
            "This will install the 'vt' command and 'vibetunnel' binary to /usr/local/bin, allowing you to use VibeTunnel from the terminal. Administrator privileges are required."
        confirmAlert.addButton(withTitle: "Install")
        confirmAlert.addButton(withTitle: "Cancel")
        confirmAlert.alertStyle = .informational
        confirmAlert.icon = NSApp.applicationIconImage

        let response = confirmAlert.runModal()
        if response != .alertFirstButtonReturn {
            logger.info("CLIInstaller: User cancelled installation")
            isInstalling = false
            return
        }

        // Perform the installation
        performInstallation(vtPath: vtResourcePath, vibetunnelPath: vibetunnelResourcePath)
    }

    // MARK: - Private Implementation

    /// Performs the actual symlink creation with sudo privileges
    private func performInstallation(vtPath: String, vibetunnelPath: String) {
        logger.info("CLIInstaller: Performing installation of vt and vibetunnel")

        let vtTargetPath = "/usr/local/bin/vt"
        let vibetunnelTargetPath = "/usr/local/bin/vibetunnel"
        
        // Create the /usr/local/bin directory if it doesn't exist
        let binDirectory = "/usr/local/bin"
        let script = """
        #!/bin/bash
        set -e

        # Create /usr/local/bin if it doesn't exist
        if [ ! -d "\(binDirectory)" ]; then
            mkdir -p "\(binDirectory)"
            echo "Created directory \(binDirectory)"
        fi

        # Remove existing vt symlink if it exists
        if [ -L "\(vtTargetPath)" ] || [ -f "\(vtTargetPath)" ]; then
            rm -f "\(vtTargetPath)"
            echo "Removed existing file at \(vtTargetPath)"
        fi

        # Create the vt symlink
        ln -s "\(vtPath)" "\(vtTargetPath)"
        echo "Created symlink from \(vtPath) to \(vtTargetPath)"

        # Make sure the vt symlink is executable
        chmod +x "\(vtTargetPath)"
        echo "Set executable permissions on \(vtTargetPath)"
        
        # Remove existing vibetunnel if it exists
        if [ -L "\(vibetunnelTargetPath)" ] || [ -f "\(vibetunnelTargetPath)" ]; then
            rm -f "\(vibetunnelTargetPath)"
            echo "Removed existing file at \(vibetunnelTargetPath)"
        fi

        # Copy vibetunnel binary (not symlink, actual copy)
        cp "\(vibetunnelPath)" "\(vibetunnelTargetPath)"
        echo "Copied \(vibetunnelPath) to \(vibetunnelTargetPath)"

        # Make sure vibetunnel is executable
        chmod +x "\(vibetunnelTargetPath)"
        echo "Set executable permissions on \(vibetunnelTargetPath)"
        """

        // Write the script to a temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent("install_vt_cli.sh")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            // Make the script executable
            let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
            try FileManager.default.setAttributes(attributes, ofItemAtPath: scriptURL.path)

            logger.info("CLIInstaller: Created installation script at \(scriptURL.path)")

            // Execute with osascript to get sudo dialog
            let appleScript = """
            do shell script "bash '\(scriptURL.path)'" with administrator privileges
            """

            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", appleScript]

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            try task.run()
            task.waitUntilExit()

            // Clean up the temporary script
            try? FileManager.default.removeItem(at: scriptURL)

            if task.terminationStatus == 0 {
                logger.info("CLIInstaller: Installation completed successfully")
                isInstalled = true
                isInstalling = false
                showSuccess()
                // Refresh installation status to update version info and clear needsUpdate flag
                checkInstallationStatus()
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                logger.error("CLIInstaller: Installation failed with status \(task.terminationStatus): \(errorString)")
                lastError = "Installation failed: \(errorString)"
                isInstalling = false
                showError("Installation failed: \(errorString)")
            }
        } catch {
            logger.error("CLIInstaller: Installation failed with error: \(error)")
            lastError = "Installation failed: \(error.localizedDescription)"
            isInstalling = false
            showError("Installation failed: \(error.localizedDescription)")
        }
    }

    /// Shows success message after installation
    private func showSuccess() {
        let alert = NSAlert()
        alert.messageText = "CLI Tools Installed Successfully"
        alert.informativeText = "The 'vt' command and 'vibetunnel' binary have been installed. You can now use 'vt' from the terminal."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.runModal()
    }

    /// Shows error message for installation failures
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "CLI Tool Installation Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .critical
        alert.runModal()
    }
}
