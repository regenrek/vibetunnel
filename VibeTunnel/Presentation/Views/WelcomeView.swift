import SwiftUI

/// Welcome onboarding view for first-time users.
///
/// Presents a multi-page onboarding experience that introduces VibeTunnel's features,
/// guides through CLI installation, requests AppleScript permissions, and explains
/// dashboard security best practices. The view tracks completion state to ensure
/// it's only shown once.
///
/// ## Topics
///
/// ### Overview
/// The welcome flow consists of six pages:
/// - ``WelcomePageView`` - Introduction and app overview
/// - ``VTCommandPageView`` - CLI tool installation
/// - ``RequestPermissionsPageView`` - System permissions setup
/// - ``SelectTerminalPageView`` - Terminal selection and testing
/// - ``ProtectDashboardPageView`` - Dashboard security configuration
/// - ``AccessDashboardPageView`` - Remote access instructions
struct WelcomeView: View {
    @State private var currentPage = 0
    @Environment(\.dismiss)
    private var dismiss
    @AppStorage(AppConstants.UserDefaultsKeys.welcomeVersion)
    private var welcomeVersion = 0
    @State private var cliInstaller = CLIInstaller()
    @StateObject private var permissionManager = AppleScriptPermissionManager.shared

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

                // Page 3: Request Permissions
                if currentPage == 2 {
                    RequestPermissionsPageView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }

                // Page 4: Select Terminal
                if currentPage == 3 {
                    SelectTerminalPageView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }

                // Page 5: Protect Your Dashboard
                if currentPage == 4 {
                    ProtectDashboardPageView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }

                // Page 6: Accessing Dashboard
                if currentPage == 5 {
                    AccessDashboardPageView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut, value: currentPage)

            // Custom page indicators and navigation - Fixed height container
            VStack(spacing: 0) {
                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<6) { index in
                        Button {
                            withAnimation {
                                currentPage = index
                            }
                        } label: {
                            Circle()
                                .fill(index == currentPage ? Color.accentColor : Color.gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
                .frame(height: 32) // Fixed height for indicator area

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
                .frame(height: 60) // Fixed height for button area
            }
            .frame(height: 92) // Total fixed height: 32 + 60
        }
        .frame(width: 640, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Always start at the first page when the view appears
            currentPage = 0
        }
    }

    private var buttonTitle: String {
        currentPage == 5 ? "Finish" : "Next"
    }

    private func handleNextAction() {
        if currentPage < 5 {
            withAnimation {
                currentPage += 1
            }
        } else {
            // Finish action - save welcome version and close window
            welcomeVersion = AppConstants.currentWelcomeVersion
            
            // Close the window properly through the window controller
            if let window = NSApp.windows.first(where: { $0.contentViewController is NSHostingController<WelcomeView> }) {
                window.close()
            }
            
            // Open settings after a delay to ensure the window is fully closed
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                SettingsOpener.openSettings()
            }
        }
    }
}

// MARK: - Preview

struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeView()
    }
}
