import AppKit
import SwiftUI

@main
struct VibeTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    var body: some Scene {
        #if os(macOS)
            Settings {
                SettingsView()
            }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("About VibeTunnel") {
                        showAboutInSettings()
                    }
                }
            }
        #endif
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var sparkleUpdaterManager: SparkleUpdaterManager?
    private var statusItem: NSStatusItem?
    private(set) var httpServer: TunnelServerDemo?

    /// Distributed notification name used to ask an existing instance to show the Settings window.
    private static let showSettingsNotification = Notification.Name("com.amantus.vibetunnel.showSettings")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let processInfo = ProcessInfo.processInfo
        let isRunningInTests = processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isRunningInPreview = processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let isRunningInDebug = processInfo.environment["DYLD_INSERT_LIBRARIES"]?
            .contains("libMainThreadChecker.dylib") ?? false

        // Handle single instance check before doing anything else
        if !isRunningInPreview, !isRunningInTests, !isRunningInDebug {
            handleSingleInstanceCheck()
            registerForDistributedNotifications()
        }

        // Initialize Sparkle updater manager
        sparkleUpdaterManager = SparkleUpdaterManager.shared

        // Configure activation policy based on settings (default to menu bar only)
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        // Setup status item (menu bar icon)
        setupStatusItem()

        // Show settings on first launch or when no window is open
        if !showInDock {
            // For menu bar apps, we need to ensure the settings window is accessible
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if NSApp.windows.isEmpty || NSApp.windows.allSatisfy({ !$0.isVisible }) {
                    NSApp.openSettings()
                }
            }
        }

        // Listen for update check requests
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCheckForUpdatesNotification),
            name: Notification.Name("checkForUpdates"),
            object: nil
        )

        // Initialize and start HTTP server
        let serverPort = UserDefaults.standard.integer(forKey: "httpServerPort")
        httpServer = TunnelServerDemo(port: serverPort > 0 ? serverPort : 8080)
        
        Task {
            do {
                try await httpServer?.start()
                print("HTTP server started automatically on port \(httpServer?.port ?? 8080)")
            } catch {
                print("Failed to start HTTP server: \(error)")
            }
        }
    }
    
    func setHTTPServer(_ server: TunnelServerDemo?) {
        httpServer = server
    }

    private func handleSingleInstanceCheck() {
        let runningApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")

        if runningApps.count > 1 {
            // Send notification to existing instance to show settings
            DistributedNotificationCenter.default().post(name: Self.showSettingsNotification, object: nil)

            // Show alert that another instance is running
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "VibeTunnel is already running"
                alert
                    .informativeText = "Another instance of VibeTunnel is already running. This instance will now quit."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()

                // Terminate this instance
                NSApp.terminate(nil)
            }
            return
        }
    }

    private func registerForDistributedNotifications() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowSettingsNotification),
            name: Self.showSettingsNotification,
            object: nil
        )
    }

    /// Shows the Settings window when another VibeTunnel instance asks us to.
    @objc
    private func handleShowSettingsNotification(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.openSettings()
    }

    @objc
    private func handleCheckForUpdatesNotification() {
        sparkleUpdaterManager?.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop HTTP server
        Task {
            try? await httpServer?.stop()
        }
        
        // Remove distributed notification observer
        let processInfo = ProcessInfo.processInfo
        let isRunningInTests = processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isRunningInPreview = processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let isRunningInDebug = processInfo.environment["DYLD_INSERT_LIBRARIES"]?
            .contains("libMainThreadChecker.dylib") ?? false

        if !isRunningInPreview, !isRunningInTests, !isRunningInDebug {
            DistributedNotificationCenter.default().removeObserver(
                self,
                name: Self.showSettingsNotification,
                object: nil
            )
        }

        // Remove update check notification observer
        NotificationCenter.default.removeObserver(
            self,
            name: Notification.Name("checkForUpdates"),
            object: nil
        )
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(named: "menubar")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        // Create menu
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let aboutItem = NSMenuItem(title: "About VibeTunnel", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc
    private func statusItemClicked() {
        // Left click shows menu
    }

    @objc
    private func showSettings() {
        NSApp.openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func showAbout() {
        showAboutInSettings()
    }
}

/// Shows the About section in the Settings window
private func showAboutInSettings() {
    NSApp.openSettings()
    Task {
        // Small delay to ensure the settings window is fully initialized
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        NotificationCenter.default.post(
            name: .openSettingsTab,
            object: SettingsTab.about
        )
    }
    NSApp.activate(ignoringOtherApps: true)
}
