import SwiftUI

struct WelcomeView: View {
    @State private var currentPage = 0
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var cliInstaller = CLIInstaller()
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom page view implementation for macOS
            ZStack {
                // Page 1: Welcome
                if currentPage == 0 {
                    WelcomePageView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }
                
                // Page 2: VT Command
                if currentPage == 1 {
                    VTCommandPageView(cliInstaller: cliInstaller)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }
                
                // Page 3: Accessing Dashboard
                if currentPage == 2 {
                    AccessDashboardPageView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }
            }
            .animation(.easeInOut, value: currentPage)
            
            // Custom page indicators and navigation
            VStack(spacing: 16) {
                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(index == currentPage ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut, value: currentPage)
                    }
                }
                .padding(.top, 12)
                
                // Navigation button
                HStack {
                    Spacer()
                    
                    Button(action: handleNextAction) {
                        Text(buttonTitle)
                            .frame(minWidth: 80)
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 640, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var buttonTitle: String {
        currentPage == 2 ? "Finish" : "Next"
    }
    
    private func handleNextAction() {
        if currentPage < 2 {
            withAnimation {
                currentPage += 1
            }
        } else {
            // Finish action - open Settings
            hasSeenWelcome = true
            dismiss()
            SettingsOpener.openSettings()
        }
    }
}

// MARK: - Welcome Page
struct WelcomePageView: View {
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            // App icon
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 156, height: 156)
                .shadow(radius: 10)
            
            VStack(spacing: 20) {
                Text("Welcome to VibeTunnel")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                
                Text("Remote control terminals from any device through a secure tunnel.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                
                Text("You'll be quickly guided through the basics of VibeTunnel.\nThis screen can always be opened from the settings.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - VT Command Page
struct VTCommandPageView: View {
    var cliInstaller: CLIInstaller
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // App icon
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 156, height: 156)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text("Capturing Terminal Apps")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                
                Text("VibeTunnel can capture any terminal app or terminal.\nJust prefix it with the `vt` command and it will show up on the dashboard.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
                
                Text("For example, to remote control Claude Code, type:")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("vt claude")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                
                // Install VT Binary button
                VStack(spacing: 12) {
                    if cliInstaller.isInstalled {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("CLI tool is installed")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button("Install VT Command Line Tool") {
                            Task {
                                await cliInstaller.install()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(cliInstaller.isInstalling)
                        
                        if cliInstaller.isInstalling {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    
                    if let error = cliInstaller.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .frame(maxWidth: 300)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            cliInstaller.checkInstallationStatus()
        }
    }
}

// MARK: - Access Dashboard Page
struct AccessDashboardPageView: View {
    @AppStorage("ngrokEnabled") private var ngrokEnabled = false
    @AppStorage("serverPort") private var serverPort = "4020"
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // App icon
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 156, height: 156)
                .shadow(radius: 10)
            
            VStack(spacing: 16) {
                Text("Accessing Your Dashboard")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                
                Text("To access your terminals from any device, create a tunnel from your device.\n\nThis can be done via **ngrok** in settings or **Tailscale** (recommended).")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
                
                VStack(spacing: 12) {
                    // Open Dashboard button
                    Button(action: {
                        let dashboardURL = URL(string: "http://127.0.0.1:\(serverPort)")!
                        NSWorkspace.shared.open(dashboardURL)
                    }) {
                        HStack {
                            Image(systemName: "safari")
                            Text("Open Dashboard")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    // Tailscale link button
                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://tailscale.com/")!)
                    }) {
                        HStack {
                            Image(systemName: "link")
                            Text("Learn more about Tailscale")
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            
            // Credits
            VStack(spacing: 4) {
                Text("VibeTunnel is open source and brought to you by")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 4) {
                    Button("@badlogic") {
                        NSWorkspace.shared.open(URL(string: "https://mariozechner.at/")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("@mitsuhiko") {
                        NSWorkspace.shared.open(URL(string: "https://lucumr.pocoo.org/")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("@steipete") {
                        NSWorkspace.shared.open(URL(string: "https://steipete.me")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(.bottom, 8)
        }
        .padding()
    }
}

// MARK: - Preview
struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeView()
    }
}
