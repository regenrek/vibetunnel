import AppKit
import SwiftUI

@main
struct VibeTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate
    @State private var sessionMonitor = SessionMonitor.shared

    var body: some Scene {
        #if os(macOS)
            Settings {
                SettingsView()
            }
            .defaultSize(width: 500, height: 450)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("About VibeTunnel") {
                        showAboutInSettings()
                    }
                }
            }
        
            MenuBarExtra {
                MenuBarView()
                    .environment(sessionMonitor)
            } label: {
                Image("menubar")
                    .renderingMode(.template)
            }
        #endif
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var sparkleUpdaterManager: SparkleUpdaterManager?
    private(set) var httpServer: TunnelServerDemo?
    private let sessionMonitor = SessionMonitor.shared

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

        // Show settings on first launch or when no window is open
        if !showInDock {
            // For menu bar apps, we need to ensure the settings window is accessible
            Task {
                try? await Task.sleep(for: .milliseconds(500))
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
        let serverPort = UserDefaults.standard.integer(forKey: "serverPort")
        httpServer = TunnelServerDemo(port: serverPort > 0 ? serverPort : 4020)
        
        Task {
            do {
                print("Attempting to start HTTP server on port \(httpServer?.port ?? 4020)...")
                try await httpServer?.start()
                print("HTTP server started successfully on port \(httpServer?.port ?? 4020)")
                print("Server is running: \(httpServer?.isRunning ?? false)")
                
                // Start monitoring sessions after server starts
                sessionMonitor.startMonitoring()
                
                // Test the server after a short delay
                try await Task.sleep(for: .milliseconds(500))
                if let url = URL(string: "http://127.0.0.1:\(httpServer?.port ?? 4020)/health") {
                    let (_, response) = try await URLSession.shared.data(from: url)
                    if let httpResponse = response as? HTTPURLResponse {
                        print("Server health check response: \(httpResponse.statusCode)")
                    }
                }
            } catch {
                print("Failed to start HTTP server: \(error)")
                print("Error type: \(type(of: error))")
                print("Error description: \(error.localizedDescription)")
                if let nsError = error as NSError? {
                    print("NSError domain: \(nsError.domain)")
                    print("NSError code: \(nsError.code)")
                    print("NSError userInfo: \(nsError.userInfo)")
                }
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
        // Stop session monitoring
        sessionMonitor.stopMonitoring()
        
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

}

/// Shows the About section in the Settings window
private func showAboutInSettings() {
    NSApp.openSettings()
    Task {
        // Small delay to ensure the settings window is fully initialized
        try? await Task.sleep(for: .milliseconds(100))
        NotificationCenter.default.post(
            name: .openSettingsTab,
            object: SettingsTab.about
        )
    }
    NSApp.activate(ignoringOtherApps: true)
}
