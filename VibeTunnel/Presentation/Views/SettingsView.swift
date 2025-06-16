import AppKit
import os.log
import SwiftUI

/// Represents the available tabs in the Settings window
enum SettingsTab: String, CaseIterable {
    case general
    case dashboard
    case advanced
    case debug
    case about

    var displayName: String {
        switch self {
        case .general: "General"
        case .dashboard: "Dashboard"
        case .advanced: "Advanced"
        case .debug: "Debug"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .dashboard: "server.rack"
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
    @AppStorage("debugMode")
    private var debugMode = false

    /// Define ideal sizes for each tab
    private let tabSizes: [SettingsTab: CGSize] = [
        .general: CGSize(width: 500, height: 520),
        .dashboard: CGSize(width: 500, height: 520),
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

            DashboardSettingsView()
                .tabItem {
                    Label(SettingsTab.dashboard.displayName, systemImage: SettingsTab.dashboard.icon)
                }
                .tag(SettingsTab.dashboard)

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

/// Dashboard settings tab for server and access configuration
struct DashboardSettingsView: View {
    @AppStorage("serverPort")
    private var serverPort = "4020"
    @AppStorage("ngrokEnabled")
    private var ngrokEnabled = false
    @AppStorage("dashboardPasswordEnabled")
    private var passwordEnabled = false
    @AppStorage("ngrokTokenPresent")
    private var ngrokTokenPresent = false
    @AppStorage("dashboardAccessMode")
    private var accessModeString = DashboardAccessMode.localhost.rawValue

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPasswordFields = false
    @State private var passwordError: String?
    @State private var passwordSaved = false

    @State private var ngrokAuthToken = ""
    @State private var ngrokStatus: NgrokTunnelStatus?
    @State private var isStartingNgrok = false
    @State private var ngrokError: String?
    @State private var showingAuthTokenAlert = false
    @State private var showingKeychainAlert = false
    @State private var showingServerErrorAlert = false
    @State private var serverErrorMessage = ""
    @State private var isTokenRevealed = false
    @State private var maskedToken = ""
    @State private var localIPAddress: String?

    private let dashboardKeychain = DashboardKeychain.shared
    private let ngrokService = NgrokService.shared
    private let logger = Logger(subsystem: "com.steipete.VibeTunnel", category: "DashboardSettings")

    private var accessMode: DashboardAccessMode {
        DashboardAccessMode(rawValue: accessModeString) ?? .localhost
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Password Protection
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Password protect dashboard", isOn: $passwordEnabled)
                            .onChange(of: passwordEnabled) { _, newValue in
                                if newValue && !dashboardKeychain.hasPassword() {
                                    showPasswordFields = true
                                } else if !newValue {
                                    // Clear password when disabled
                                    _ = dashboardKeychain.deletePassword()
                                    showPasswordFields = false
                                    passwordSaved = false
                                }
                            }

                        Text("Require a password to access the dashboard from remote connections.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if showPasswordFields || (passwordEnabled && !passwordSaved) {
                            VStack(spacing: 8) {
                                SecureField("Password", text: $password)
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Confirm Password", text: $confirmPassword)
                                    .textFieldStyle(.roundedBorder)

                                if let error = passwordError {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }

                                HStack {
                                    Button("Cancel") {
                                        showPasswordFields = false
                                        passwordEnabled = false
                                        password = ""
                                        confirmPassword = ""
                                        passwordError = nil
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Save Password") {
                                        savePassword()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(password.isEmpty)
                                }
                            }
                            .padding(.top, 4)
                        }

                        if passwordSaved {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Password saved")
                                    .font(.caption)
                                Spacer()
                                Button("Change Password") {
                                    showPasswordFields = true
                                    passwordSaved = false
                                    password = ""
                                    confirmPassword = ""
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Security")
                        .font(.headline)
                } footer: {
                    Text(
                        "When password protection is enabled, localhost connections can still access without a password. For remote access, any username is accepted - only the password is verified."
                    )
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                }

                Section {
                    // Access Mode
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Allow accessing the dashboard from:")
                            Spacer()
                            Picker("", selection: Binding(
                                get: { accessMode },
                                set: { newMode in
                                    accessModeString = newMode.rawValue
                                    restartServerWithNewBindAddress()
                                }
                            )) {
                                ForEach(DashboardAccessMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(accessMode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            // Show IP address when network access is enabled
                            if accessMode == .network {
                                if let ipAddress = localIPAddress {
                                    HStack(spacing: 4) {
                                        Text("Access from other devices at:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        
                                        Button(action: {
                                            let urlString = "http://\(ipAddress):\(serverPort)"
                                            if let url = URL(string: urlString) {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }) {
                                            Text("http://\(ipAddress):\(serverPort)")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                                .underline()
                                        }
                                        .buttonStyle(.plain)
                                        .cursor(.pointingHand)
                                        
                                        Button(action: {
                                            let urlString = "http://\(ipAddress):\(serverPort)"
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(urlString, forType: .string)
                                        }) {
                                            Image(systemName: "doc.on.doc")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Copy URL")
                                    }
                                } else {
                                    Text("Unable to determine local IP address")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }

                    // Port Configuration
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Server port:")
                            Spacer()
                            TextField("", text: $serverPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.center)
                                .onChange(of: serverPort) { _, newValue in
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
                    Text("Server Configuration")
                        .font(.headline)
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        // ngrok Enable Toggle
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Enable ngrok tunnel", isOn: $ngrokEnabled)
                                .onChange(of: ngrokEnabled) { oldValue, newValue in
                                    logger.debug("ngrok toggle changed from \(oldValue) to \(newValue)")
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
                                HStack(spacing: 4) {
                                    if isTokenRevealed {
                                        SecureField("", text: $ngrokAuthToken)
                                            .frame(width: 220)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: ngrokAuthToken) { _, newValue in
                                                ngrokService.authToken = newValue.isEmpty ? nil : newValue
                                                ngrokTokenPresent = !newValue.isEmpty
                                            }
                                    } else {
                                        TextField("", text: $maskedToken)
                                            .frame(width: 220)
                                            .textFieldStyle(.roundedBorder)
                                            .disabled(true)
                                            .onAppear {
                                                // Show masked placeholder if token exists
                                                if ngrokTokenPresent {
                                                    maskedToken = String(repeating: "•", count: 12)
                                                } else {
                                                    maskedToken = ""
                                                }
                                            }
                                    }
                                    Button(action: {
                                        toggleTokenVisibility()
                                    }, label: {
                                        Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
                                    })
                                    .buttonStyle(.plain)
                                    .help(isTokenRevealed ? "Hide token" : "Reveal token")
                                }
                            }
                            HStack {
                                Text("Get your free auth token at")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("ngrok.com") {
                                    if let url = URL(string: "https://dashboard.ngrok.com/auth/your-authtoken") {
                                        NSWorkspace.shared.open(url)
                                    }
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
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Dashboard Settings")
        }
        .onAppear {
            // Check password status
            if dashboardKeychain.hasPassword() {
                passwordSaved = true
                passwordEnabled = true
            }

            // Check if token exists without triggering keychain
            if ngrokService.hasAuthToken && !ngrokTokenPresent {
                ngrokTokenPresent = true
            }

            // Update masked field based on token presence
            if ngrokTokenPresent && !isTokenRevealed {
                maskedToken = String(repeating: "•", count: 12)
            }
            
            // Get local IP address
            updateLocalIPAddress()
        }
        .onChange(of: accessMode) { _, _ in
            // Update IP address when access mode changes
            updateLocalIPAddress()
        }
        .alert("ngrok Auth Token Required", isPresented: $showingAuthTokenAlert) {
            Button("OK") {}
        } message: {
            Text(
                "Please enter your ngrok auth token before enabling the tunnel. You can get a free auth token at ngrok.com"
            )
        }
        .alert("Keychain Access Error", isPresented: $showingKeychainAlert) {
            Button("OK") {}
        } message: {
            Text("Failed to save the auth token to the keychain. Please check your keychain permissions and try again.")
        }
        .alert("Failed to Restart Server", isPresented: $showingServerErrorAlert) {
            Button("OK") {}
        } message: {
            Text(serverErrorMessage)
        }
    }

    private func savePassword() {
        passwordError = nil

        guard !password.isEmpty else {
            passwordError = "Password cannot be empty"
            return
        }

        guard password == confirmPassword else {
            passwordError = "Passwords do not match"
            return
        }

        guard password.count >= 6 else {
            passwordError = "Password must be at least 6 characters"
            return
        }

        if dashboardKeychain.setPassword(password) {
            passwordSaved = true
            showPasswordFields = false
            password = ""
            confirmPassword = ""

            // When password is set for the first time, automatically switch to network mode
            if accessMode == .localhost {
                accessModeString = DashboardAccessMode.network.rawValue
                restartServerWithNewBindAddress()
            }
        } else {
            passwordError = "Failed to save password to keychain"
        }
    }

    private func restartServerWithNewPort(_ port: Int) {
        Task {
            // Update the port in ServerManager and restart
            ServerManager.shared.port = String(port)
            await ServerManager.shared.restart()
            logger.info("Server restarted on port \(port)")

            // Restart session monitoring with new port
            SessionMonitor.shared.stopMonitoring()
            SessionMonitor.shared.startMonitoring()
        }
    }

    private func restartServerWithNewBindAddress() {
        Task {
            // Update the bind address in ServerManager and restart
            ServerManager.shared.bindAddress = accessMode.bindAddress
            await ServerManager.shared.restart()
            logger.info("Server restarted with bind address \(accessMode.bindAddress)")

            // Restart session monitoring
            SessionMonitor.shared.stopMonitoring()
            SessionMonitor.shared.startMonitoring()
        }
    }

    private func checkAndStartNgrok() {
        logger.debug("checkAndStartNgrok called")

        // Check if we have a token in the keychain without accessing it
        guard ngrokTokenPresent || ngrokService.hasAuthToken else {
            logger.debug("No auth token stored")
            ngrokError = "Please enter your ngrok auth token first"
            ngrokEnabled = false
            showingAuthTokenAlert = true
            return
        }

        // If token hasn't been revealed yet, we need to access it from keychain
        if !isTokenRevealed && ngrokAuthToken.isEmpty {
            // This will trigger keychain access
            if let token = ngrokService.authToken {
                ngrokAuthToken = token
                logger.debug("Retrieved token from keychain for ngrok start")
            } else {
                logger.error("Failed to retrieve token from keychain")
                ngrokError = "Failed to access auth token. Please try again."
                ngrokEnabled = false
                showingKeychainAlert = true
                return
            }
        }

        logger.debug("Starting ngrok with auth token present")
        isStartingNgrok = true
        ngrokError = nil

        Task {
            do {
                let port = Int(serverPort) ?? 4_020
                logger.info("Starting ngrok on port \(port)")
                _ = try await ngrokService.start(port: port)
                isStartingNgrok = false
                ngrokStatus = await ngrokService.getStatus()
                logger.info("ngrok started successfully")
            } catch {
                logger.error("ngrok start error: \(error)")
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

    private func toggleTokenVisibility() {
        if isTokenRevealed {
            // Hide the token
            isTokenRevealed = false
            ngrokAuthToken = ""
            if ngrokTokenPresent {
                maskedToken = String(repeating: "•", count: 12)
            }
        } else {
            // Reveal the token - this will trigger keychain access
            if let token = ngrokService.authToken {
                ngrokAuthToken = token
                isTokenRevealed = true
            } else {
                // No token stored, just reveal the empty field
                ngrokAuthToken = ""
                isTokenRevealed = true
            }
        }
    }
    
    private func updateLocalIPAddress() {
        Task {
            if accessMode == .network {
                localIPAddress = NetworkUtility.getLocalIPAddress()
            } else {
                localIPAddress = nil
            }
        }
    }
}

/// Advanced settings tab for power user options
struct AdvancedSettingsView: View {
    @AppStorage("debugMode")
    private var debugMode = false
    @AppStorage("cleanupOnStartup")
    private var cleanupOnStartup = true

    var body: some View {
        NavigationStack {
            Form {
                // Integration section
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
                } header: {
                    Text("Integration")
                        .font(.headline)
                }
                
                // Advanced section
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Clean up old sessions on startup", isOn: $cleanupOnStartup)
                        Text("Automatically remove terminated sessions when the app starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Advanced")
                        .font(.headline)
                }
                
                // Debug section
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Debug mode", isOn: $debugMode)
                        Text("Enable additional logging and debugging features.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Debug")
                        .font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Advanced Settings")
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

    private let logger = Logger(subsystem: "com.steipete.VibeTunnel", category: "DebugSettings")

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
                                    isServerRunning ? "Server starting... (checking health)" : "Server is stopped"
                                )
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
                                    isServerRunning ? "exclamationmark.circle.fill" : "xmark.circle.fill"
                                )
                                .foregroundStyle(isServerHealthy ? .green :
                                    isServerRunning ? .orange : .secondary
                                )
                                Text(isServerHealthy ? "Healthy" :
                                    isServerRunning ? "Unhealthy" : "Stopped"
                                )
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
                            Text(getCurrentServerMode())
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
                            Text("Welcome Screen")
                            Spacer()
                            Button("Show Welcome") {
                                AppDelegate.showWelcomeScreen()
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("Display the welcome screen again")
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
            // Server changes are automatically observed through serverManager
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
                guard let url = URL(string: "http://127.0.0.1:\(serverPort)\(endpoint.path)") else {
                    testResult = "Invalid URL"
                    return
                }
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
            .onDisappear {
                // This will be called when the window closes
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    private func getCurrentServerMode() -> String {
        // If server is switching, show transitioning state
        if serverManager.isSwitching {
            return "Switching..."
        }
        
        // If server is running and we have a current server, use its type
        if isServerRunning, let serverType = serverManager.currentServer?.serverType {
            return serverType.displayName
        }
        
        // Otherwise, show the configured mode from settings
        return ServerMode(rawValue: serverModeString)?.displayName ?? "None"
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
