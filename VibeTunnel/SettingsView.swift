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
        .general: CGSize(width: 500, height: 400),
        .advanced: CGSize(width: 500, height: 500),
        .debug: CGSize(width: 600, height: 650),
        .about: CGSize(width: 500, height: 550)
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

                    Divider()

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
                    Text("Application")
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
                                .frame(width: 80)
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
                                        Button("Copy URL") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(publicUrl, forType: .string)
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
                }

                Section {
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
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        Task {
            // Stop the current server if running
            if let server = appDelegate.httpServer, server.isRunning {
                try? await server.stop()
            }

            // Create and start new server with the new port
            let newServer = TunnelServer(port: port)
            appDelegate.setHTTPServer(newServer)

            do {
                try await newServer.start()
                print("Server restarted on port \(port)")

                // Restart session monitoring with new port
                SessionMonitor.shared.stopMonitoring()
                SessionMonitor.shared.startMonitoring()
            } catch {
                print("Failed to restart server on port \(port): \(error)")
                // Show error alert
                await MainActor.run {
                    serverErrorMessage = "Could not start server on port \(port): \(error.localizedDescription)"
                    showingServerErrorAlert = true
                }
            }
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
}

extension String? {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}

/// Debug settings tab for development and troubleshooting
struct DebugSettingsView: View {
    @State private var httpServer: TunnelServer?
    @State private var serverMonitor = ServerMonitor.shared
    @State private var lastError: String?
    @State private var testResult: String?
    @State private var isTesting = false
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("logLevel") private var logLevel = "info"

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
                                        .fill(isServerRunning ? .green : .red)
                                        .frame(width: 8, height: 8)
                                }
                                Text(isServerRunning ? "Server is running on port \(serverPort)" : "Server is stopped")
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
                }

                Section {
                    // Server Information
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Status") {
                            HStack {
                                Image(systemName: isServerRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(isServerRunning ? .green : .secondary)
                                Text(isServerRunning ? "Running" : "Stopped")
                            }
                        }

                        LabeledContent("Port") {
                            Text("\(serverPort)")
                        }

                        LabeledContent("Base URL") {
                            Text("http://127.0.0.1:\(serverPort)")
                                .font(.system(.body, design: .monospaced))
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
                            Text("Server Logs")
                            Spacer()
                            Button("Open Console") {
                                openConsole()
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("View server logs in Console.app")
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
                } header: {
                    Text("Developer Tools")
                        .font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Debug Settings")
            .task {
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    httpServer = appDelegate.httpServer
                }
            }
        }
    }

    private func toggleServer(_ shouldStart: Bool) async {
        lastError = nil

        if shouldStart {
            do {
                try await serverMonitor.startServer()
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            do {
                try await serverMonitor.stopServer()
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
        path: "/health",
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
