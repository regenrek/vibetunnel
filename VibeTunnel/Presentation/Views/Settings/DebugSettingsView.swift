import AppKit
import os.log
import SwiftUI

/// Debug settings tab for development and troubleshooting
struct DebugSettingsView: View {
    @State private var serverMonitor = ServerMonitor.shared
    @AppStorage("debugMode")
    private var debugMode = false
    @AppStorage("logLevel")
    private var logLevel = "info"
    @AppStorage("serverMode")
    private var serverModeString = ServerMode.rust.rawValue
    @State private var serverManager = ServerManager.shared
    @State private var isServerHealthy = false
    @State private var heartbeatTask: Task<Void, Never>?
    @State private var showPurgeConfirmation = false

    private let logger = Logger(subsystem: "sh.vibetunnel.vibetunnel", category: "DebugSettings")

    private var isServerRunning: Bool {
        serverMonitor.isRunning
    }

    private var serverPort: Int {
        serverMonitor.port
    }

    var body: some View {
        NavigationStack {
            Form {
                ServerSection(
                    isServerHealthy: isServerHealthy,
                    isServerRunning: isServerRunning,
                    serverPort: serverPort,
                    serverModeString: $serverModeString,
                    serverManager: serverManager,
                    getCurrentServerMode: getCurrentServerMode
                )

                DebugOptionsSection(
                    debugMode: $debugMode,
                    logLevel: $logLevel
                )

                DeveloperToolsSection(
                    showPurgeConfirmation: $showPurgeConfirmation,
                    showServerConsole: showServerConsole,
                    openConsole: openConsole,
                    showApplicationSupport: showApplicationSupport
                )
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Debug Settings")
            .onAppear {
                // Ensure ServerMonitor is synced with ServerManager
                serverMonitor.updateStatus()
                // Start heartbeat monitoring
                startHeartbeatMonitoring()
            }
            .onDisappear {
                // Stop heartbeat monitoring when view disappears
                heartbeatTask?.cancel()
                heartbeatTask = nil
            }
            .onChange(of: serverManager.isRunning) { _, _ in
                // Restart heartbeat monitoring when server state changes
                startHeartbeatMonitoring()
            }
            .onChange(of: serverModeString) { _, _ in
                // Clear health status when switching modes
                isServerHealthy = false
            }
            .alert("Purge All User Defaults?", isPresented: $showPurgeConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Purge", role: .destructive) {
                    purgeAllUserDefaults()
                }
            } message: {
                Text(
                    "This will remove all stored preferences and reset the app to its default state. The app will quit after purging."
                )
            }
        }
    }

    // MARK: - Private Methods

    // toggleServer function removed - server now runs continuously with auto-recovery

    private func startHeartbeatMonitoring() {
        // Cancel any existing heartbeat task
        heartbeatTask?.cancel()

        // Start a new heartbeat monitoring task
        heartbeatTask = Task {
            while !Task.isCancelled {
                // Check server health
                let healthy = await checkServerHealth()

                // Update UI on main actor
                await MainActor.run {
                    isServerHealthy = healthy
                }

                // Wait before next heartbeat
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func checkServerHealth() async -> Bool {
        guard isServerRunning else { return false }

        do {
            guard let url = URL(string: "http://127.0.0.1:\(serverPort)/api/health") else {
                return false
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.0 // Quick timeout for heartbeat

            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Server not responding or error
            logger.error("Server health check failed: \(error.localizedDescription)")
        }

        return false
    }

    private func purgeAllUserDefaults() {
        // Get the app's bundle identifier
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            // Remove all UserDefaults for this app
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            UserDefaults.standard.synchronize()

            // Quit the app after a short delay to ensure the purge completes
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func getCurrentServerMode() -> String {
        // If server is switching, show transitioning state
        if serverManager.isSwitching {
            return "Switching..."
        }

        // Always use the configured mode from settings to ensure immediate UI update
        return ServerMode(rawValue: serverModeString)?.displayName ?? "None"
    }

    private func openConsole() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
    }

    private func showApplicationSupport() {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDirectory = appSupport.appendingPathComponent("VibeTunnel")
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appDirectory.path)
        }
    }

    private func showServerConsole() {
        // Create a new window for the server console
        let consoleWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        consoleWindow.title = "Server Console"
        consoleWindow.center()

        let consoleView = ServerConsoleView()
            .onDisappear {
                // This will be called when the window closes
            }
        consoleWindow.contentView = NSHostingView(rootView: consoleView)

        let windowController = NSWindowController(window: consoleWindow)
        windowController.showWindow(nil)
    }
}

// MARK: - Server Section

private struct ServerSection: View {
    let isServerHealthy: Bool
    let isServerRunning: Bool
    let serverPort: Int
    @Binding var serverModeString: String
    let serverManager: ServerManager
    let getCurrentServerMode: () -> String

    @State private var portConflict: PortConflict?
    @State private var isCheckingPort = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Server Information
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Status") {
                        if isServerHealthy || isServerRunning {
                            HStack {
                                Image(systemName: isServerHealthy ? "checkmark.circle.fill" :
                                    "exclamationmark.circle.fill"
                                )
                                .foregroundStyle(isServerHealthy ? .green : .orange)
                                Text(isServerHealthy ? "Healthy" : "Unhealthy")
                            }
                        } else {
                            Text("Stopped")
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Port") {
                        Text("\(serverPort)")
                    }

                    LabeledContent("Bind Address") {
                        Text(serverManager.bindAddress)
                            .font(.system(.body, design: .monospaced))
                    }

                    LabeledContent("Base URL") {
                        let baseAddress = serverManager.bindAddress == "0.0.0.0" ? "127.0.0.1" : serverManager
                            .bindAddress
                        if let serverURL = URL(string: "http://\(baseAddress):\(serverPort)") {
                            Link("http://\(baseAddress):\(serverPort)", destination: serverURL)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            Text("http://\(baseAddress):\(serverPort)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Divider()

                // Server Status
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("HTTP Server")
                            Circle()
                                .fill(isServerHealthy ? .green : (isServerRunning ? .orange : .red))
                                .frame(width: 8, height: 8)
                            if isServerRunning && !isServerHealthy {
                                TextShimmer(text: "...", font: .caption)
                                    .frame(width: 20, height: 8)
                            }
                        }
                        Text(isServerHealthy ? "Server is running on port \(serverPort)" :
                            isServerRunning ? "Server starting... (checking health)" : "Server is stopped"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Show restart button for all server modes
                    Button("Restart") {
                        Task {
                            await serverManager.manualRestart()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()

                // Server Mode Configuration
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server Mode")
                        Text("Multiple server implementations cause reasons™.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { ServerMode(rawValue: serverModeString) ?? .rust },
                        set: { newMode in
                            serverModeString = newMode.rawValue
                            Task {
                                await serverManager.switchMode(to: newMode)
                            }
                        }
                    )) {
                        ForEach(ServerMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(serverManager.isSwitching)
                }

                // Server mode switching status with consistent height
                HStack {
                    if serverManager.isSwitching {
                        TextShimmer(text: "Switching server mode...", font: .caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Port conflict warning
                if let conflict = portConflict {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)

                            Text("Port \(conflict.port) is used by \(conflict.process.name)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        if !conflict.alternativePorts.isEmpty {
                            HStack(spacing: 4) {
                                Text("Try port:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(conflict.alternativePorts.prefix(3), id: \.self) { port in
                                    Button(String(port)) {
                                        serverManager.port = String(port)
                                        Task {
                                            await serverManager.restart()
                                        }
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding(.vertical, 4)
            .onAppear {
                Task {
                    await checkPortAvailability()
                }
            }
            .onChange(of: serverPort) { _, _ in
                Task {
                    await checkPortAvailability()
                }
            }
        } header: {
            Text("HTTP Server")
                .font(.headline)
        }
    }

    private func checkPortAvailability() async {
        isCheckingPort = true
        defer { isCheckingPort = false }

        let port = Int(serverPort)

        // Only check if it's not the port we're already successfully using
        if serverManager.isRunning && Int(serverManager.port) == port {
            portConflict = nil
            return
        }

        if let conflict = await PortConflictResolver.shared.detectConflict(on: port) {
            // Only show warning for non-VibeTunnel processes
            // tty-fwd and other VibeTunnel instances will be auto-killed by ServerManager
            if case .reportExternalApp = conflict.suggestedAction {
                portConflict = conflict
            } else {
                // It's our own process, will be handled automatically
                portConflict = nil
            }
        } else {
            portConflict = nil
        }
    }
}

// MARK: - Debug Options Section

private struct DebugOptionsSection: View {
    @Binding var debugMode: Bool
    @Binding var logLevel: String

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Debug mode", isOn: $debugMode)
                Text("Enable additional logging and debugging features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Log Level")
                    Spacer()
                    Picker("", selection: $logLevel) {
                        Text("Error").tag("error")
                        Text("Warning").tag("warning")
                        Text("Info").tag("info")
                        Text("Debug").tag("debug")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Text("Set the verbosity of application logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Debug Options")
                .font(.headline)
        }
    }
}

// MARK: - Developer Tools Section

private struct DeveloperToolsSection: View {
    @Binding var showPurgeConfirmation: Bool
    let showServerConsole: () -> Void
    let openConsole: () -> Void
    let showApplicationSupport: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Server Console")
                    Spacer()
                    Button("Show Console") {
                        showServerConsole()
                    }
                    .buttonStyle(.bordered)
                }
                Text("View real-time server logs from the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("System Logs")
                    Spacer()
                    Button("Open Console") {
                        openConsole()
                    }
                    .buttonStyle(.bordered)
                }
                Text("View all application logs in Console.app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Application Support")
                    Spacer()
                    Button("Show in Finder") {
                        showApplicationSupport()
                    }
                    .buttonStyle(.bordered)
                }
                Text("Open the application support directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Welcome Screen")
                    Spacer()
                    Button("Show Welcome") {
                        #if !SWIFT_PACKAGE
                            AppDelegate.showWelcomeScreen()
                        #endif
                    }
                    .buttonStyle(.bordered)
                }
                Text("Display the welcome screen again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("User Defaults")
                    Spacer()
                    Button("Purge All") {
                        showPurgeConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                Text("Remove all stored preferences and reset to defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Developer Tools")
                .font(.headline)
        }
    }
}
