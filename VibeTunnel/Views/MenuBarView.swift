//
//  MenuBarView.swift
//  VibeTunnel
//
//  SwiftUI menu bar implementation
//

import SwiftUI

struct MenuBarView: View {
    @Environment(SessionMonitor.self) var sessionMonitor
    @AppStorage("showInDock") private var showInDock = false
    
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
            
            // About button
            Button(action: {
                showAboutInSettings()
            }) {
                Label("About VibeTunnel", systemImage: "info.circle")
            }
            .buttonStyle(MenuButtonStyle())
            
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

struct SessionCountView: View {
    let count: Int
    
    var body: some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundColor(.secondary)
            Text(sessionText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
    
    private var sessionText: String {
        count == 1 ? "1 active session" : "\(count) active sessions"
    }
}

// MARK: - Session List View

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

// MARK: - Helper Functions

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

