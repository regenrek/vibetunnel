import SwiftUI
import AppKit

/// Represents the available tabs in the Settings window
enum SettingsTab: String, CaseIterable {
    case general
    case advanced
    case debug
    case about

    var displayName: String {
        switch self {
        case .general: "General"
        case .advanced: "Advanced"
        case .debug: "Debug"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .advanced: "gearshape.2"
        case .debug: "hammer"
        case .about: "info.circle"
        }
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("openSettingsTab")
}

/// Main settings window with tabbed interface
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var contentSize: CGSize = .zero
    @AppStorage("debugMode") private var debugMode = false

    /// Define ideal sizes for each tab
    private let tabSizes: [SettingsTab: CGSize] = [
        .general: CGSize(width: 500, height: 520),
        .advanced: CGSize(width: 500, height: 520),
        .debug: CGSize(width: 500, height: 520),
        .about: CGSize(width: 500, height: 520)
    ]

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label(SettingsTab.general.displayName, systemImage: SettingsTab.general.icon)
                }
                .tag(SettingsTab.general)

            AdvancedSettingsView()
                .tabItem {
                    Label(SettingsTab.advanced.displayName, systemImage: SettingsTab.advanced.icon)
                }
                .tag(SettingsTab.advanced)

            if debugMode {
                DebugSettingsView()
                    .tabItem {
                        Label(SettingsTab.debug.displayName, systemImage: SettingsTab.debug.icon)
                    }
                    .tag(SettingsTab.debug)
            }

            AboutView()
                .tabItem {
                    Label(SettingsTab.about.displayName, systemImage: SettingsTab.about.icon)
                }
                .tag(SettingsTab.about)
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .animatedWindowSizing(size: contentSize)
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            contentSize = tabSizes[newTab] ?? CGSize(width: 500, height: 400)
        }
        .onAppear {
            contentSize = tabSizes[selectedTab] ?? CGSize(width: 500, height: 400)
        }
        .onChange(of: debugMode) { _, _ in
            // If debug mode is disabled and we're on the debug tab, switch to general
            if !debugMode && selectedTab == .debug {
                selectedTab = .general
            }
        }
    }
}

/// General settings tab for basic app preferences
struct GeneralSettingsView: View {
    @AppStorage("autostart")
    private var autostart = false
    @AppStorage("showNotifications")
    private var showNotifications = true
    @AppStorage("showInDock")
    private var showInDock = false
    @AppStorage("updateChannel")
    private var updateChannelRaw = UpdateChannel.stable.rawValue

    @State private var isCheckingForUpdates = false

    private let startupManager = StartupManager()

    var updateChannel: UpdateChannel {
        UpdateChannel(rawValue: updateChannelRaw) ?? .stable
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Launch at Login
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Launch at Login", isOn: launchAtLoginBinding)
                        Text("Automatically start VibeTunnel when you log into your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Show Notifications
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show notifications", isOn: $showNotifications)
                        Text("Display notifications for important events.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Application")
                        .font(.headline)
                }

                Section {
                    // Update Channel
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Update Channel")
                            Spacer()
                            Picker("", selection: updateChannelBinding) {
                                ForEach(UpdateChannel.allCases) { channel in
                                    Text(channel.displayName).tag(channel)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        Text(updateChannel.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Check for Updates
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check for Updates")
                            Text("Check for new versions of VibeTunnel")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Check Now") {
                            checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isCheckingForUpdates)
                    }
                } header: {
                    Text("Updates")
                        .font(.headline)
                }

                Section {
                    // Show in Dock
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show in Dock", isOn: showInDockBinding)
                        Text("Show VibeTunnel icon in the Dock.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Appearance")
                        .font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("General Settings")
        }
        .task {
            // Sync launch at login status
            autostart = startupManager.isLaunchAtLoginEnabled
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { autostart },
            set: { newValue in
                autostart = newValue
                startupManager.setLaunchAtLogin(enabled: newValue)
            }
        )
    }

    private var showInDockBinding: Binding<Bool> {
        Binding(
            get: { showInDock },
            set: { newValue in
                showInDock = newValue
                NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            }
        )
    }

    private var updateChannelBinding: Binding<UpdateChannel> {
        Binding(
            get: { updateChannel },
            set: { newValue in
                updateChannelRaw = newValue.rawValue
                // Notify the updater manager about the channel change
                NotificationCenter.default.post(
                    name: Notification.Name("UpdateChannelChanged"),
                    object: nil,
                    userInfo: ["channel": newValue]
                )
            }
        )
    }

    private func checkForUpdates() {
        isCheckingForUpdates = true
        NotificationCenter.default.post(name: Notification.Name("checkForUpdates"), object: nil)

        // Reset after a delay
        Task {
            try? await Task.sleep(for: .seconds(2))
            isCheckingForUpdates = false
        }
    }
}

/// Advanced settings tab for power user options
struct AdvancedSettingsView: View {
    @AppStorage("debugMode")
    private var debugMode = false
    @AppStorage("serverPort")
    private var serverPort = "4020"
    @AppStorage("ngrokEnabled")
    private var ngrokEnabled = false

    @State private var ngrokAuthToken = ""
    @State private var ngrokStatus: NgrokTunnelStatus?
    @State private var isStartingNgrok = false
    @State private var ngrokError: String?
    @State private var showingAuthTokenAlert = false
    @State private var showingKeychainAlert = false
    @State private var showingServerErrorAlert = false
    @State private var serverErrorMessage = ""

    private let ngrokService = NgrokService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Server port:")
                            Spacer()
                            TextField("", text: $serverPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.center)
                                .onChange(of: serverPort) { oldValue, newValue in
                                    // Validate port number
                                    if let port = Int(newValue), port > 0, port < 65_536 {
                                        restartServerWithNewPort(port)
                                    }
                                }
                        }
                        Text("The server will automatically restart when the port is changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Server")
                        .font(.headline)
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        // ngrok Enable Toggle
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Enable ngrok tunnel", isOn: $ngrokEnabled)
                                .onChange(of: ngrokEnabled) { oldValue, newValue in
                                    print("ngrok toggle changed from \(oldValue) to \(newValue)")
                                    if newValue {
                                        // Add a small delay to ensure auth token is saved to keychain
                                        Task {
                                            try? await Task.sleep(for: .milliseconds(100))
                                            await MainActor.run {
                                                checkAndStartNgrok()
                                            }
                                        }
                                    } else {
                                        stopNgrok()
                                        // Clear error only when user manually turns off the toggle
                                        if oldValue == true {
                                            ngrokError = nil
                                        }
                                    }
                                }
                            Text("Expose VibeTunnel to the internet using ngrok.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Auth Token - Always visible so users can set it before enabling
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Auth token:")
                                Spacer()
                                SecureField("", text: $ngrokAuthToken)
                                    .frame(width: 250)
                                    .textFieldStyle(.roundedBorder)
                                    .onAppear {
                                        ngrokAuthToken = ngrokService.authToken ?? ""
                                    }
                                    .onChange(of: ngrokAuthToken) { _, newValue in
                                        ngrokService.authToken = newValue.isEmpty ? nil : newValue
                                    }
                            }
                            HStack {
                                Text("Get your free auth token at")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("ngrok.com") {
                                    NSWorkspace.shared
                                        .open(URL(string: "https://dashboard.ngrok.com/auth/your-authtoken")!)
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }

                        // Status - Only show when ngrok is enabled
                        if ngrokEnabled {
                            if let publicUrl = ngrokService.publicUrl {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("Tunnel active")
                                            .font(.caption)
                                        Spacer()
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .help("Copy URL")
                                            .onTapGesture {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(publicUrl, forType: .string)
                                            }
                                        
                                        Button("Open Browser") {
                                            if let url = URL(string: publicUrl) {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    Text(publicUrl)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .foregroundStyle(.secondary)
                                }
                            } else if isStartingNgrok {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Starting ngrok tunnel...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Error display - Always visible if there's an error
                        if let error = ngrokError {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Error")
                                        .font(.caption)
                                }
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("ngrok Integration")
                        .font(.headline)
                } footer: {
                    Text(
                        "Alternatively, we recommend [Tailscale](https://tailscale.com/) to create a virtual network to access your Mac."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .tint(.blue)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Install CLI Tool")
                            Spacer()
                            Button("Install 'vt' Command") {
                                installCLITool()
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("Install the 'vt' command line tool to /usr/local/bin for terminal access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Debug mode", isOn: $debugMode)
                        Text("Enable additional logging and debugging features.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Advanced")
                        .font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Advanced Settings")
        }
        .onAppear {
            // Load existing auth token
            ngrokAuthToken = ngrokService.authToken ?? ""
            print("AdvancedSettingsView appeared - auth token present: \(!ngrokAuthToken.isEmpty)")
        }
        .alert("ngrok Auth Token Required", isPresented: $showingAuthTokenAlert) {
            Button("OK") { }
        } message: {
            Text("Please enter your ngrok auth token before enabling the tunnel. You can get a free auth token at ngrok.com")
        }
        .alert("Keychain Access Error", isPresented: $showingKeychainAlert) {
            Button("OK") { }
        } message: {
            Text("Failed to save the auth token to the keychain. Please check your keychain permissions and try again.")
        }
        .alert("Failed to Restart Server", isPresented: $showingServerErrorAlert) {
            Button("OK") { }
        } message: {
            Text(serverErrorMessage)
        }
    }

    private func restartServerWithNewPort(_ port: Int) {
        Task {
            // Update the port in ServerManager and restart
            ServerManager.shared.port = String(port)
            await ServerManager.shared.restart()
            print("Server restarted on port \(port)")

            // Restart session monitoring with new port
            SessionMonitor.shared.stopMonitoring()
            SessionMonitor.shared.startMonitoring()
        }
    }

    private func checkAndStartNgrok() {
        print("checkAndStartNgrok called")
        print("Local auth token state: '\(ngrokAuthToken)' (length: \(ngrokAuthToken.count))")
        print("Service auth token: '\(ngrokService.authToken ?? "nil")' (present: \(ngrokService.authToken != nil))")
        
        // First check the local state variable
        guard !ngrokAuthToken.isEmpty else {
            print("No auth token in local state")
            ngrokError = "Please enter your ngrok auth token first"
            ngrokEnabled = false
            showingAuthTokenAlert = true
            return
        }
        
        // Then verify it's saved in the service
        guard !ngrokService.authToken.isNilOrEmpty else {
            print("Auth token not saved in keychain")
            ngrokError = "Failed to save auth token. Please try again."
            ngrokEnabled = false
            showingKeychainAlert = true
            return
        }

        print("Starting ngrok with auth token present")
        isStartingNgrok = true
        ngrokError = nil

        Task {
            do {
                let port = Int(serverPort) ?? 4_020
                print("Starting ngrok on port \(port)")
                _ = try await ngrokService.start(port: port)
                isStartingNgrok = false
                ngrokStatus = await ngrokService.getStatus()
                print("ngrok started successfully")
            } catch {
                print("ngrok start error: \(error)")
                isStartingNgrok = false
                ngrokError = error.localizedDescription
                ngrokEnabled = false
            }
        }
    }

    private func stopNgrok() {
        Task {
            try? await ngrokService.stop()
            ngrokStatus = nil
            // Don't clear the error here - let it remain visible
        }
    }
    
    private func installCLITool() {
        let installer = CLIInstaller()
        installer.installCLITool()
    }
}

extension String? {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

/// Debug settings tab for development and troubleshooting
struct DebugSettingsView: View {
    @State private var serverMonitor = ServerMonitor.shared
    @State private var lastError: String?
    @State private var testResult: String?
    @State private var isTesting = false
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("logLevel") private var logLevel = "info"
    @AppStorage("serverMode") private var serverModeString = ServerMode.hummingbird.rawValue
    @StateObject private var serverManager = ServerManager.shared
    @State private var isServerHealthy = false
    @State private var heartbeatTask: Task<Void, Never>?
    @State private var showPurgeConfirmation = false

    private var isServerRunning: Bool {
        serverMonitor.isRunning
    }

    private var serverPort: Int {
        serverMonitor.port
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // HTTP Server Control
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("HTTP Server")
                                    Circle()
                                        .fill(isServerHealthy ? .green : (isServerRunning ? .orange : .red))
                                        .frame(width: 8, height: 8)
                                    if isServerRunning && !isServerHealthy {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                    }
                                }
                                Text(isServerHealthy ? "Server is running on port \(serverPort)" : 
                                     isServerRunning ? "Server starting... (checking health)" : "Server is stopped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { isServerRunning },
                                set: { newValue in
                                    Task {
                                        await toggleServer(newValue)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                        }

                        if isServerRunning, let serverURL = URL(string: "http://127.0.0.1:\(serverPort)") {
                            Link("Open in Browser", destination: serverURL)
                                .font(.caption)
                        }

                        if let lastError {
                            Text(lastError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("HTTP Server")
                        .font(.headline)
                } footer: {
                    Text("The HTTP server provides REST API endpoints for terminal session management.")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }

                Section {
                    // Server Mode Selector
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Server Mode")
                            Spacer()
                            Picker("", selection: Binding(
                                get: { ServerMode(rawValue: serverModeString) ?? .hummingbird },
                                set: { serverModeString = $0.rawValue }
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
                        
                        if serverManager.isSwitching {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Switching server mode...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Server Configuration")
                        .font(.headline)
                } footer: {
                    Text("Choose between the built-in Swift Hummingbird server or the Rust tty-fwd binary.")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                
                Section {
                    // Server Information
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Status") {
                            HStack {
                                Image(systemName: isServerHealthy ? "checkmark.circle.fill" : 
                                                 isServerRunning ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(isServerHealthy ? .green : 
                                                   isServerRunning ? .orange : .secondary)
                                Text(isServerHealthy ? "Healthy" : 
                                     isServerRunning ? "Unhealthy" : "Stopped")
                            }
                        }

                        LabeledContent("Port") {
                            Text("\(serverPort)")
                        }

                        LabeledContent("Base URL") {
                            Text("http://127.0.0.1:\(serverPort)")
                                .font(.system(.body, design: .monospaced))
                        }
                        
                        LabeledContent("Mode") {
                            Text(serverManager.currentServer?.serverType.displayName ?? "None")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Server Information")
                        .font(.headline)
                }

                Section {
                    // API Endpoints with test functionality
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(apiEndpoints) { endpoint in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(endpoint.method)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.blue)
                                        .frame(width: 45, alignment: .leading)

                                    Text(endpoint.path)
                                        .font(.system(.caption, design: .monospaced))

                                    Spacer()

                                    if isServerRunning && endpoint.isTestable {
                                        Button("Test") {
                                            testEndpoint(endpoint)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                        .disabled(isTesting)
                                    }
                                }

                                Text(endpoint.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }

                        if let testResult {
                            Text(testResult)
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.top, 4)
                        }
                    }
                } header: {
                    Text("API Endpoints")
                        .font(.headline)
                } footer: {
                    Text("Click 'Test' to send a request to the endpoint and see the response.")
                        .font(.caption)
                }

                // Debug Options
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

                // Developer Tools
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
                        Text("View real-time server logs from both Hummingbird and Rust servers")
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
                        Text("View all application logs in Console.app")
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
                        Text("Open the application support directory")
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
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                        Text("Remove all stored preferences and reset to defaults")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Developer Tools")
                        .font(.headline)
                }
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
                Button("Cancel", role: .cancel) { }
                Button("Purge", role: .destructive) {
                    purgeAllUserDefaults()
                }
            } message: {
                Text("This will remove all stored preferences and reset the app to its default state. The app will quit after purging.")
            }
        }
    }

    private func toggleServer(_ shouldStart: Bool) async {
        lastError = nil

        if shouldStart {
            do {
                try await serverMonitor.startServer()
                // Restart heartbeat monitoring after starting server
                startHeartbeatMonitoring()
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            do {
                try await serverMonitor.stopServer()
                // Clear health status immediately when stopping
                isServerHealthy = false
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func testEndpoint(_ endpoint: APIEndpoint) {
        isTesting = true
        testResult = nil

        Task {
            do {
                let url = URL(string: "http://127.0.0.1:\(serverPort)\(endpoint.path)")!
                var request = URLRequest(url: url)
                request.httpMethod = endpoint.method

                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    let statusEmoji = httpResponse.statusCode == 200 ? "✅" : "❌"
                    let preview = String(data: data, encoding: .utf8)?.prefix(100) ?? ""
                    testResult = "\(statusEmoji) \(httpResponse.statusCode) - \(preview)..."
                }
            } catch {
                testResult = "❌ Error: \(error.localizedDescription)"
            }

            isTesting = false

            // Clear result after 5 seconds
            Task {
                try? await Task.sleep(for: .seconds(5))
                testResult = nil
            }
        }
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
        consoleWindow.contentView = NSHostingView(rootView: consoleView)
        
        let windowController = NSWindowController(window: consoleWindow)
        windowController.showWindow(nil)
    }
    
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
            let url = URL(string: "http://127.0.0.1:\(serverPort)/api/health")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.0 // Quick timeout for heartbeat
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Server not responding or error
            print("Server health check failed: \(error.localizedDescription)")
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// API Endpoint data
/// Represents an API endpoint for testing in debug mode
struct APIEndpoint: Identifiable {
    let id: String
    let method: String
    let path: String
    let description: String
    let isTestable: Bool

    init(method: String, path: String, description: String, isTestable: Bool) {
        self.id = "\(method)_\(path)"
        self.method = method
        self.path = path
        self.description = description
        self.isTestable = isTestable
    }
}

let apiEndpoints = [
    APIEndpoint(method: "GET", path: "/", description: "Web interface - displays server status", isTestable: true),
    APIEndpoint(
        method: "GET",
        path: "/api/health",
        description: "Health check - returns OK if server is running",
        isTestable: true
    ),
    APIEndpoint(
        method: "GET",
        path: "/info",
        description: "Server information - returns version and uptime",
        isTestable: true
    ),
    APIEndpoint(method: "GET", path: "/sessions", description: "List tty-fwd sessions", isTestable: true),
    APIEndpoint(method: "POST", path: "/sessions", description: "Create new terminal session", isTestable: false),
    APIEndpoint(
        method: "GET",
        path: "/sessions/:id",
        description: "Get specific session information",
        isTestable: false
    ),
    APIEndpoint(method: "DELETE", path: "/sessions/:id", description: "Close a terminal session", isTestable: false),
    APIEndpoint(method: "POST", path: "/execute", description: "Execute command in a session", isTestable: false),
    APIEndpoint(method: "POST", path: "/api/ngrok/start", description: "Start ngrok tunnel", isTestable: true),
    APIEndpoint(method: "POST", path: "/api/ngrok/stop", description: "Stop ngrok tunnel", isTestable: true),
    APIEndpoint(method: "GET", path: "/api/ngrok/status", description: "Get ngrok tunnel status", isTestable: true)
]

#Preview {
    SettingsView()
}
