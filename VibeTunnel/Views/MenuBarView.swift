//
//  MenuBarView.swift
//  VibeTunnel
//
//  SwiftUI menu bar implementation
//

import SwiftUI

/// Main menu bar view displaying session status and app controls
struct MenuBarView: View {
    @Environment(SessionMonitor.self) var sessionMonitor
    @AppStorage("showInDock") private var showInDock = false
    @State private var showHelpMenu = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session count header
            SessionCountView(count: sessionMonitor.sessionCount)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            
            // Session list
            if sessionMonitor.sessionCount > 0 {
                SessionListView(sessions: sessionMonitor.sessions)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            
            Divider()
                .padding(.vertical, 4)
            
            // Help menu
            Button(action: {
                showHelpMenu.toggle()
            }) {
                HStack {
                    Label("Help", systemImage: "questionmark.circle")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(MenuButtonStyle())
            .popover(isPresented: $showHelpMenu, arrowEdge: .trailing) {
                HelpMenuView(showAboutInSettings: showAboutInSettings)
            }
            
            // Settings button
            Button(action: {
                NSApp.openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }) {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(MenuButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            
            Divider()
                .padding(.vertical, 4)
            
            // Quit button
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(MenuButtonStyle())
            .keyboardShortcut("q", modifiers: .command)
        }
        .frame(minWidth: 200)
    }
}

// MARK: - Session Count View

/// Displays the count of active SSH sessions
struct SessionCountView: View {
    let count: Int
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            Text(sessionText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private var sessionText: String {
        count == 1 ? "1 active session" : "\(count) active sessions"
    }
}

// MARK: - Session List View

/// Lists active SSH sessions with truncation for large lists
struct SessionListView: View {
    let sessions: [String: SessionMonitor.SessionInfo]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(activeSessions.prefix(5)), id: \.key) { session in
                SessionRowView(session: session)
            }
            
            if activeSessions.count > 5 {
                HStack {
                    Text("  • ...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
    
    private var activeSessions: [(key: String, value: SessionMonitor.SessionInfo)] {
        sessions.filter { $0.value.isRunning }
            .sorted { $0.value.started_at > $1.value.started_at }
    }
}

// MARK: - Session Row View

/// Individual row displaying session information
struct SessionRowView: View {
    let session: (key: String, value: SessionMonitor.SessionInfo)
    
    var body: some View {
        HStack {
            Text("  • \(sessionName)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
    
    private var sessionName: String {
        session.value.name.isEmpty ? session.value.cmdline.first ?? "Unknown" : session.value.name
    }
}

// MARK: - Menu Button Style

/// Custom button style for menu items with hover effects
struct MenuButtonStyle: ButtonStyle {
    @State private var isHovered = false
    
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Help Menu View

/// Help menu with links and app information
struct HelpMenuView: View {
    @Environment(\.dismiss) private var dismiss
    let showAboutInSettings: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Website
            Button(action: {
                dismiss()
                if let url = URL(string: "http://vibetunnel.sh") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Label("Website", systemImage: "globe")
            }
            .buttonStyle(MenuButtonStyle())
            
            // Report Issue
            Button(action: {
                dismiss()
                if let url = URL(string: "https://github.com/amantus-ai/vibetunnel/issues") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Label("Report Issue", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(MenuButtonStyle())
            
            Divider()
                .padding(.vertical, 4)
            
            // Check for Updates
            Button(action: {
                dismiss()
                SparkleUpdaterManager.shared.checkForUpdates()
            }) {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(MenuButtonStyle())
            
            // Version
            HStack {
                Text("Version \(appVersion)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            // About
            Button(action: {
                dismiss()
                showAboutInSettings()
            }) {
                Label("About VibeTunnel", systemImage: "info.circle")
            }
            .buttonStyle(MenuButtonStyle())
        }
        .frame(minWidth: 200)
        .padding(.vertical, 4)
    }
    
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

// MARK: - Helper Functions

/// Shows the About section in the Settings window
@MainActor
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

