//
//  VibeTunnelApp.swift
//  VibeTunnel
//
//  Created by Peter Steinberger on 15.06.25.
//

import SwiftUI
import AppKit

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
                    AboutWindowController.shared.showWindow()
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
    
    /// Distributed notification name used to ask an existing instance to show the Settings window.
    private static let showSettingsNotification = Notification.Name("com.amantus.vibetunnel.showSettings")
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let processInfo = ProcessInfo.processInfo
        let isRunningInTests = processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isRunningInPreview = processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let isRunningInDebug = processInfo.environment["DYLD_INSERT_LIBRARIES"]?.contains("libMainThreadChecker.dylib") ?? false
        
        // Handle single instance check before doing anything else
        if !isRunningInPreview, !isRunningInTests, !isRunningInDebug {
            handleSingleInstanceCheck()
            registerForDistributedNotifications()
        }
        
        // Initialize Sparkle updater manager
        sparkleUpdaterManager = SparkleUpdaterManager()
        
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
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
        
        // Listen for update check requests
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCheckForUpdatesNotification),
            name: Notification.Name("checkForUpdates"),
            object: nil)
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
                alert.informativeText = "Another instance of VibeTunnel is already running. This instance will now quit."
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
            object: nil)
    }
    
    /// Shows the Settings window when another VibeTunnel instance asks us to.
    @objc
    private func handleShowSettingsNotification(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    @objc private func handleCheckForUpdatesNotification() {
        sparkleUpdaterManager?.checkForUpdates()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Remove distributed notification observer
        let processInfo = ProcessInfo.processInfo
        let isRunningInTests = processInfo.environment["XCTestConfigurationFilePath"] != nil
        let isRunningInPreview = processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let isRunningInDebug = processInfo.environment["DYLD_INSERT_LIBRARIES"]?.contains("libMainThreadChecker.dylib") ?? false
        
        if !isRunningInPreview, !isRunningInTests, !isRunningInDebug {
            DistributedNotificationCenter.default().removeObserver(
                self,
                name: Self.showSettingsNotification,
                object: nil)
        }
        
        // Remove update check notification observer
        NotificationCenter.default.removeObserver(
            self,
            name: Notification.Name("checkForUpdates"),
            object: nil)
    }
    
    // MARK: - Status Item
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: "VibeTunnel")
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        
        // Create menu
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About VibeTunnel", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func statusItemClicked() {
        // Left click shows menu
    }
    
    @objc private func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func showAbout() {
        AboutWindowController.shared.showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }
}
