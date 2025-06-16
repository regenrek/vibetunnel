import AppKit
import SwiftUI

/// Main entry point for the VibeTunnel macOS application
@main
struct VibeTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate
    @State private var sessionMonitor = SessionMonitor.shared
    @State private var serverMonitor = ServerMonitor.shared

    var body: some Scene {
        #if os(macOS)
            // Hidden WindowGroup to make Settings work in MenuBarExtra-only apps
            // This is a workaround for FB10184971
            WindowGroup("HiddenWindow") {
                HiddenWindowView()
            }
            .windowResizability(.contentSize)
            .defaultSize(width: 1, height: 1)
            .windowStyle(.hiddenTitleBar)
            
            // Welcome Window
            WindowGroup("Welcome", id: "welcome") {
                WelcomeView()
            }
            .windowResizability(.contentSize)
            .defaultSize(width: 580, height: 480)
            .windowStyle(.hiddenTitleBar)
            
            Settings {
                SettingsView()
            }
            .commands {
                CommandGroup(after: .appInfo) {
                    SettingsLink(label: {
                        Text("About VibeTunnel")
                    })
                    .simultaneousGesture(TapGesture().onEnded {
                        // Navigate to About tab after settings opens
                        Task {
                            try? await Task.sleep(for: .milliseconds(100))
                            NotificationCenter.default.post(
                                name: .openSettingsTab,
                                object: SettingsTab.about
                            )
                        }
                    })
                }
            }

            MenuBarExtra {
                MenuBarView()
                    .environment(sessionMonitor)
                    .environment(serverMonitor)
            } label: {
                Image("menubar")
                    .renderingMode(.template)
            }
        #endif
    }
}

// MARK: - App Delegate

/// Manages app lifecycle, single instance enforcement, and core services
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var sparkleUpdaterManager: SparkleUpdaterManager?
    private let serverManager = ServerManager.shared
    private let sessionMonitor = SessionMonitor.shared
    private let serverMonitor = ServerMonitor.shared
    private let ngrokService = NgrokService.shared

    /// Distributed notification name used to ask an existing instance to show the Settings window.
    private static let showSettingsNotification = Notification.Name("sh.vibetunnel.vibetunnel.showSettings")

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
            
            // Check if app needs to be moved to Applications folder
            let applicationMover = ApplicationMover()
            applicationMover.checkAndOfferToMoveToApplications()
        }

        // Initialize Sparkle updater manager
        sparkleUpdaterManager = SparkleUpdaterManager.shared

        // Configure activation policy based on settings (default to menu bar only)
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        // Show welcome screen on first launch
        let hasSeenWelcome = UserDefaults.standard.bool(forKey: "hasSeenWelcome")
        if !hasSeenWelcome && !isRunningInTests && !isRunningInPreview {
            showWelcomeScreen()
        }


        // Listen for update check requests
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCheckForUpdatesNotification),
            name: Notification.Name("checkForUpdates"),
            object: nil
        )
        

        // Initialize and start HTTP server using ServerManager
        Task {
            do {
                print("Attempting to start HTTP server using ServerManager...")
                await serverManager.start()
                
                print("HTTP server started successfully on port \(serverManager.port)")
                print("Server is running: \(serverManager.isRunning)")
                print("Server mode: \(serverManager.serverMode.displayName)")

                // Start monitoring sessions after server starts
                sessionMonitor.startMonitoring()

                // Test the server after a short delay
                try await Task.sleep(for: .milliseconds(500))
                if let url = URL(string: "http://127.0.0.1:\(serverManager.port)/api/health") {
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


    private func handleSingleInstanceCheck() {
        let runningApps = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")

        if runningApps.count > 1 {
            // Send notification to existing instance to show settings
            DistributedNotificationCenter.default().post(name: Self.showSettingsNotification, object: nil)

            // Show alert that another instance is running
            Task { @MainActor in
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
        SettingsOpener.openSettings()
    }

    @objc
    private func handleCheckForUpdatesNotification() {
        sparkleUpdaterManager?.checkForUpdates()
    }
    
    /// Shows the welcome screen
    private func showWelcomeScreen() {
        // Initialize the welcome window controller (singleton will handle the rest)
        _ = WelcomeWindowController.shared
        WelcomeWindowController.shared.show()
    }
    
    /// Public method to show welcome screen (can be called from settings)
    static func showWelcomeScreen() {
        WelcomeWindowController.shared.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop session monitoring
        sessionMonitor.stopMonitoring()

        // Stop HTTP server
        Task {
            await serverManager.stop()
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


