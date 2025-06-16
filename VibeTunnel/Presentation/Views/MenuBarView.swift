import SwiftUI

/// Main menu bar view displaying session status and app controls
struct MenuBarView: View {
    @Environment(SessionMonitor.self) var sessionMonitor
    @Environment(ServerMonitor.self) var serverMonitor
    @AppStorage("showInDock") private var showInDock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Server status header
            ServerStatusView(isRunning: serverMonitor.isRunning, port: serverMonitor.port)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Open Dashboard button
            Button(action: {
                let dashboardURL = URL(string: "http://127.0.0.1:\(serverMonitor.port)")!
                NSWorkspace.shared.open(dashboardURL)
            }) {
                Label("Open Dashboard", systemImage: "safari")
            }
            .buttonStyle(MenuButtonStyle())
            .disabled(!serverMonitor.isRunning)

            Divider()
                .padding(.vertical, 4)

            // Session count header
            SessionCountView(count: sessionMonitor.sessionCount)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Session list
            if sessionMonitor.sessionCount > 0 {
                SessionListView(sessions: sessionMonitor.sessions)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .frame(minWidth: 280)
            }

            Divider()
                .padding(.vertical, 4)

            // Help menu with submenu indicator
            HStack {
                Menu {
                    // Show Tutorial
                    Button(action: {
                        AppDelegate.showWelcomeScreen()
                    }) {
                        Label("Show Tutorial", systemImage: "book")
                    }
                    
                    // Website
                    Button(action: {
                        if let url = URL(string: "http://vibetunnel.sh") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("Website", systemImage: "globe")
                    }

                    // Report Issue
                    Button(action: {
                        if let url = URL(string: "https://github.com/amantus-ai/vibetunnel/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("Report Issue", systemImage: "exclamationmark.triangle")
                    }

                    // Check for Updates
                    Button(action: {
                        SparkleUpdaterManager.shared.checkForUpdates()
                    }) {
                        Label("Check for Updates…", systemImage: "arrow.down.circle")
                    }

                    // Version (non-interactive)
                    Text("Version \(appVersion)")
                        .foregroundColor(.secondary)

                    Divider()

                    // About
                    SettingsLink {
                        Label("About VibeTunnel", systemImage: "info.circle")
                    }
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
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.001))
            )

            // Settings button
            SettingsLink {
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

// MARK: - Server Status View

/// Displays the HTTP server status
struct ServerStatusView: View {
    let isRunning: Bool
    let port: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusText: String {
        isRunning ? "Server running on port \(port)" : "Server stopped"
    }
}

// MARK: - Session Count View

/// Displays the count of active SSH sessions
struct SessionCountView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(sessionText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
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
        sessions.filter(\.value.isRunning)
            .sorted { $0.value.startedAt > $1.value.startedAt }
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
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var sessionName: String {
        let name = session.value.name.isEmpty ? session.value.cmdline.first ?? "Unknown" : session.value.name
        // Truncate long session names
        if name.count > 35 {
            let prefix = String(name.prefix(20))
            let suffix = String(name.suffix(10))
            return "\(prefix)...\(suffix)"
        }
        return name
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

