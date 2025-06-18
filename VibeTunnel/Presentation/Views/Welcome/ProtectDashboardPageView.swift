import SwiftUI

/// Fourth page explaining dashboard security and access protection.
///
/// This view allows users to set up password protection for their dashboard
/// when accessing it over the network. It provides secure password entry
/// with confirmation and validation.
///
/// ## Topics
///
/// ### Overview
/// The dashboard protection page includes:
/// - Password and confirmation fields
/// - Password validation (minimum 6 characters)
/// - Secure storage in keychain
/// - Automatic network mode switching when password is set
/// - Option to skip password protection
///
/// ### Security
/// - Passwords are stored securely in the system keychain
/// - Network access is automatically enabled when a password is set
/// - Dashboard remains localhost-only without password
struct ProtectDashboardPageView: View {
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isPasswordSet = false

    private let dashboardKeychain = DashboardKeychain.shared

    var body: some View {
        VStack(spacing: 30) {
            // App icon
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 156, height: 156)
                .shadow(radius: 10)

            VStack(spacing: 16) {
                Text("Protect Your Dashboard")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text(
                    "If you want to access your dashboard over the network, set a password now.\nOtherwise, it will only be accessible via localhost."
                )
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)

                // Password fields
                VStack(spacing: 12) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onChange(of: password) { _, _ in
                            // Reset password saved state when user starts typing
                            if isPasswordSet {
                                isPasswordSet = false
                            }
                        }

                    SecureField("Confirm Password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onChange(of: confirmPassword) { _, _ in
                            // Reset password saved state when user starts typing
                            if isPasswordSet {
                                isPasswordSet = false
                            }
                        }

                    if showError {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if isPasswordSet {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Password saved securely")
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    } else {
                        Button("Set Password") {
                            setPassword()
                        }
                        .buttonStyle(.bordered)
                        .disabled(password.isEmpty)
                    }

                    Text("Leave empty to skip password protection")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func setPassword() {
        showError = false

        guard !password.isEmpty else {
            return
        }

        guard password == confirmPassword else {
            errorMessage = "Passwords do not match"
            showError = true
            return
        }

        guard password.count >= 6 else {
            errorMessage = "Password must be at least 6 characters"
            showError = true
            return
        }

        if dashboardKeychain.setPassword(password) {
            isPasswordSet = true
            UserDefaults.standard.set(true, forKey: "dashboardPasswordEnabled")

            // When password is set for the first time, automatically switch to network mode
            let currentMode = DashboardAccessMode(rawValue: UserDefaults.standard
                .string(forKey: "dashboardAccessMode") ?? ""
            ) ?? .localhost
            if currentMode == .localhost {
                UserDefaults.standard.set(DashboardAccessMode.network.rawValue, forKey: "dashboardAccessMode")
            }
        } else {
            errorMessage = "Failed to save password to keychain"
            showError = true
        }
    }
}

// MARK: - Preview

struct ProtectDashboardPageView_Previews: PreviewProvider {
    static var previews: some View {
        ProtectDashboardPageView()
            .frame(width: 640, height: 480)
            .background(Color(NSColor.windowBackgroundColor))
    }
}
