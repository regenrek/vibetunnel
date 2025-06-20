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
            
            // Check if vt is a proper symlink pointing to vibetunnel
            var vtIsSymlink = false
            if vtInstalled {
                if let vtAttributes = try? FileManager.default.attributesOfItem(atPath: vtPath),
                   let fileType = vtAttributes[.type] as? FileAttributeType,
                   fileType == .typeSymbolicLink {
                    // Check if it points to vibetunnel
                    if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: vtPath) {
                        vtIsSymlink = destination.contains("vibetunnel") || destination == vibetunnelPath
                    }
                }
            }
            
            let installed = vtInstalled && vibetunnelInstalled
            let needsVtMigration = vtInstalled && !vtIsSymlink

            // Update state without animation
            isInstalled = installed

            // Capture values for use in detached task
            let capturedVtInstalled = vtInstalled
            let capturedVibetunnelInstalled = vibetunnelInstalled
            let capturedVtIsSymlink = vtIsSymlink
            let capturedNeedsVtMigration = needsVtMigration

            // Move version checks to background
            Task.detached(priority: .userInitiated) {
                var installedVer: String?
                var bundledVer: String?

                // Only check vibetunnel version if it's installed
                if capturedVibetunnelInstalled {
                    // Check version of installed tools
                    installedVer = await self.getInstalledVersionAsync()
                }

                // Get bundled version
                bundledVer = await self.getBundledVersionAsync()

                // Update UI on main thread
                await MainActor.run {
                    self.installedVersion = installedVer
                    self.bundledVersion = bundledVer

                    // Check if update is needed:
                    // 1. If vt needs migration (not a symlink)
                    // 2. If vibetunnel is not installed
                    // 3. If versions don't match
                    self.needsUpdate = capturedNeedsVtMigration || !capturedVibetunnelInstalled || 
                        (capturedVibetunnelInstalled && installedVer != nil && bundledVer != nil && installedVer != bundledVer)

                    self.logger
                        .info(
                            "CLIInstaller: CLI tools installed: \(self.isInstalled) (vt: \(capturedVtInstalled), vibetunnel: \(capturedVibetunnelInstalled)), vt is symlink: \(capturedVtIsSymlink), installed version: \(self.installedVersion ?? "unknown"), bundled version: \(self.bundledVersion ?? "unknown"), needs update: \(self.needsUpdate)"
                        )
                }
            }
        }
    }

    /// Gets the version of the installed vibetunnel binary
    private func getInstalledVersion() -> String? {
        let vibetunnelPath = "/usr/local/bin/vibetunnel"
        
        // First check if vibetunnel exists
        guard FileManager.default.fileExists(atPath: vibetunnelPath) else {
            logger.info("Vibetunnel binary not found at \(vibetunnelPath)")
            return nil
        }
        
        // Only check vibetunnel version since vt is now a symlink
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
                    return String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            logger.error("Failed to get installed vibetunnel version: \(error)")
        }
        
        return nil
    }

    /// Gets the version of the bundled vibetunnel binary
    private func getBundledVersion() -> String? {
        // Only check vibetunnel version since vt is now a symlink
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
                        return String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                logger.error("Failed to get bundled vibetunnel version: \(error)")
            }
        }
        
        return nil
    }

    /// Gets the version of the installed vibetunnel binary (async version for background execution)
    private nonisolated func getInstalledVersionAsync() async -> String? {
        let vibetunnelPath = "/usr/local/bin/vibetunnel"
        
        // First check if vibetunnel exists
        guard FileManager.default.fileExists(atPath: vibetunnelPath) else {
            return nil
        }
        
        // Only check vibetunnel version since vt is now a symlink
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
                    return String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            // Silently fail for async version
        }
        
        return nil
    }

    /// Gets the version of the bundled vibetunnel binary (async version for background execution)
    private nonisolated func getBundledVersionAsync() async -> String? {
        // Only check vibetunnel version since vt is now a symlink
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
                        return String(output[range]).dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                // Silently fail for async version
            }
        }
        
        return nil
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

        // Check if this is a migration from old vt script
        let vtPath = "/usr/local/bin/vt"
        var isMigration = false
        if FileManager.default.fileExists(atPath: vtPath) {
            if let vtAttributes = try? FileManager.default.attributesOfItem(atPath: vtPath),
               let fileType = vtAttributes[.type] as? FileAttributeType,
               fileType != .typeSymbolicLink {
                isMigration = true
            }
        }

        // Show update confirmation dialog
        let alert = NSAlert()
        alert.messageText = isMigration ? "Migrate VT Command Line Tools" : "Update VT Command Line Tools"
        
        var informativeText = ""
        if isMigration {
            informativeText = """
            The VT command line tool needs to be migrated to the new unified binary system.
            
            This will replace the old vt script with a symlink to vibetunnel.
            """
        } else {
            informativeText = """
            A newer version of the VibeTunnel command line tools is available.

            Installed version: \(installedVersion ?? "unknown")
            Available version: \(bundledVersion ?? "unknown")
            """
        }
        
        informativeText += "\n\nWould you like to update now? Administrator privileges will be required."
        alert.informativeText = informativeText
        
        alert.addButton(withTitle: isMigration ? "Migrate" : "Update")
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

        // We no longer need a separate vt resource, only vibetunnel
        guard let vibetunnelResourcePath = Bundle.main.path(forResource: "vibetunnel", ofType: nil) else {
            logger.error("CLIInstaller: Could not find vibetunnel binary in app bundle")
            lastError = "The vibetunnel binary could not be found in the application bundle."
            showError("The vibetunnel binary could not be found in the application bundle.")
            isInstalling = false
            return
        }

        let vtTargetPath = "/usr/local/bin/vt"
        let vibetunnelTargetPath = "/usr/local/bin/vibetunnel"
        
        logger.info("CLIInstaller: vibetunnel resource path: \(vibetunnelResourcePath)")
        logger.info("CLIInstaller: vt target path: \(vtTargetPath)")
        logger.info("CLIInstaller: vibetunnel target path: \(vibetunnelTargetPath)")

        // Show confirmation dialog (removed duplicate replacement dialog)
        let confirmAlert = NSAlert()
        confirmAlert.messageText = "Install CLI Tools"
        confirmAlert
            .informativeText =
            "This will install the 'vibetunnel' binary to /usr/local/bin and create a 'vt' symlink for easy command line access. Administrator privileges are required."
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
        performInstallation(vibetunnelPath: vibetunnelResourcePath)
    }

    // MARK: - Private Implementation

    /// Performs the actual symlink creation with sudo privileges
    private func performInstallation(vibetunnelPath: String) {
        logger.info("CLIInstaller: Performing installation of vibetunnel and vt symlink")

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
        
        # Remove existing vt (whether it's a file or symlink)
        if [ -L "\(vtTargetPath)" ] || [ -f "\(vtTargetPath)" ]; then
            # Backup old vt script if it's not a symlink
            if [ -f "\(vtTargetPath)" ] && [ ! -L "\(vtTargetPath)" ]; then
                echo "Backing up old vt script to \(vtTargetPath).bak"
                mv "\(vtTargetPath)" "\(vtTargetPath).bak"
            else
                rm -f "\(vtTargetPath)"
            fi
            echo "Removed existing file at \(vtTargetPath)"
        fi

        # Create the vt symlink pointing to vibetunnel
        ln -s "\(vibetunnelTargetPath)" "\(vtTargetPath)"
        echo "Created symlink from \(vibetunnelTargetPath) to \(vtTargetPath)"
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
        alert.informativeText = "The 'vibetunnel' binary and 'vt' symlink have been installed. You can now use 'vt' from the terminal."
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
