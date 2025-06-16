import SwiftUI
import Combine

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

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

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

            DebugSettingsView()
                .tabItem {
                    Label(SettingsTab.debug.displayName, systemImage: SettingsTab.debug.icon)
                }
                .tag(SettingsTab.debug)

            AboutView()
                .tabItem {
                    Label(SettingsTab.about.displayName, systemImage: SettingsTab.about.icon)
                }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 200, idealWidth: 200, minHeight: 400, idealHeight: 400)
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
            }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autostart")
    private var autostart = false
    @AppStorage("showNotifications")
    private var showNotifications = true
    @AppStorage("showInDock")
    private var showInDock = false

    private let startupManager = StartupManager()

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
                    // Show in Dock
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show in Dock", isOn: showInDockBinding)
                        Text("Display VibeTunnel in the Dock. When disabled, VibeTunnel runs as a menu bar app only.")
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
}

struct AdvancedSettingsView: View {
    @AppStorage("debugMode")
    private var debugMode = false
    @AppStorage("serverPort")
    private var serverPort = "8080"
    @AppStorage("updateChannel")
    private var updateChannelRaw = UpdateChannel.stable.rawValue

    @State private var isCheckingForUpdates = false

    var updateChannel: UpdateChannel {
        UpdateChannel(rawValue: updateChannelRaw) ?? .stable
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    .padding(.top, 8)
                } header: {
                    Text("Updates")
                        .font(.headline)
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Server port:")
                            TextField("", text: $serverPort)
                                .frame(width: 80)
                                .onChange(of: serverPort) { oldValue, newValue in
                                    // Validate port number
                                    if let port = Int(newValue), port > 0, port < 65536 {
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
    
    private func restartServerWithNewPort(_ port: Int) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        
        Task {
            // Stop the current server if running
            if let server = appDelegate.httpServer, server.isRunning {
                try? await server.stop()
            }
            
            // Create and start new server with the new port
            let newServer = TunnelServerDemo(port: port)
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
                    let alert = NSAlert()
                    alert.messageText = "Failed to Restart Server"
                    alert.informativeText = "Could not start server on port \(port): \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }
}

// Helper class to observe server state
@MainActor
class ServerObserver: ObservableObject {
    @Published var httpServer: TunnelServerDemo?
    @Published var isServerRunning = false
    @Published var serverPort = 8080
    
    private var cancellable: AnyCancellable?
    
    init() {
        setupServerConnection()
    }
    
    func setupServerConnection() {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            httpServer = appDelegate.httpServer
            isServerRunning = appDelegate.httpServer?.isRunning ?? false
            serverPort = appDelegate.httpServer?.port ?? 8080
            
            // Observe server state changes
            cancellable = httpServer?.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isServerRunning = self?.httpServer?.isRunning ?? false
                    self?.serverPort = self?.httpServer?.port ?? 8080
                }
            }
        }
    }
}

struct DebugSettingsView: View {
    @StateObject private var serverObserver = ServerObserver()
    @State private var lastError: String?
    @State private var testResult: String?
    @State private var isTesting = false
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("logLevel") private var logLevel = "info"
    
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
                                    if serverObserver.isServerRunning {
                                        Circle()
                                            .fill(.green)
                                            .frame(width: 8, height: 8)
                                    }
                                }
                                Text(serverObserver.isServerRunning ? "Server is running on port \(serverObserver.serverPort)" : "Server is stopped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { serverObserver.isServerRunning },
                                set: { newValue in
                                    Task {
                                        await toggleServer(newValue)
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                        }
                        
                        if serverObserver.isServerRunning, let serverURL = URL(string: "http://localhost:\(serverObserver.serverPort)") {
                            Link("Open in Browser", destination: serverURL)
                                .font(.caption)
                        }
                        
                        if let lastError = lastError {
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
                                Image(systemName: serverObserver.isServerRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(serverObserver.isServerRunning ? .green : .secondary)
                                Text(serverObserver.isServerRunning ? "Running" : "Stopped")
                            }
                        }
                        
                        LabeledContent("Port") {
                            Text("\(serverObserver.serverPort)")
                        }
                        
                        LabeledContent("Base URL") {
                            Text("http://localhost:\(serverObserver.serverPort)")
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
                        ForEach(apiEndpoints, id: \.path) { endpoint in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(endpoint.method)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.blue)
                                        .frame(width: 45, alignment: .leading)
                                    
                                    Text(endpoint.path)
                                        .font(.system(.caption, design: .monospaced))
                                    
                                    Spacer()
                                    
                                    if serverObserver.isServerRunning && endpoint.isTestable {
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
                        
                        if let testResult = testResult {
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
            .onAppear {
                serverObserver.setupServerConnection()
            }
        }
    }
    
    private func toggleServer(_ shouldStart: Bool) async {
        lastError = nil
        
        if shouldStart {
            // Create a new server if needed
            if serverObserver.httpServer == nil {
                let newServer = TunnelServerDemo(port: serverObserver.serverPort)
                serverObserver.httpServer = newServer
                // Store reference in AppDelegate
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.setHTTPServer(newServer)
                }
            }
            
            do {
                try await serverObserver.httpServer?.start()
                serverObserver.isServerRunning = true
            } catch {
                lastError = error.localizedDescription
                serverObserver.isServerRunning = false
            }
        } else {
            do {
                try await serverObserver.httpServer?.stop()
                serverObserver.isServerRunning = false
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
                let url = URL(string: "http://localhost:\(serverObserver.serverPort)\(endpoint.path)")!
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
                try? await Task.sleep(nanoseconds: 5_000_000_000)
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

// API Endpoint data
struct APIEndpoint {
    let method: String
    let path: String
    let description: String
    let isTestable: Bool
}

let apiEndpoints = [
    APIEndpoint(method: "GET", path: "/", description: "Web interface - displays server status", isTestable: true),
    APIEndpoint(method: "GET", path: "/health", description: "Health check - returns OK if server is running", isTestable: true),
    APIEndpoint(method: "GET", path: "/info", description: "Server information - returns version and uptime", isTestable: true),
    APIEndpoint(method: "GET", path: "/sessions", description: "List tty-fwd sessions", isTestable: true),
    APIEndpoint(method: "POST", path: "/sessions", description: "Create new terminal session", isTestable: false),
    APIEndpoint(method: "GET", path: "/sessions/:id", description: "Get specific session information", isTestable: false),
    APIEndpoint(method: "DELETE", path: "/sessions/:id", description: "Close a terminal session", isTestable: false),
    APIEndpoint(method: "POST", path: "/execute", description: "Execute command in a session", isTestable: false)
]

#Preview {
    SettingsView()
}
