import SwiftUI

/// Third page requesting AppleScript automation and accessibility permissions.
///
/// This view guides users through granting necessary permissions for VibeTunnel
/// to function properly. It handles both AppleScript permissions for terminal
/// automation and accessibility permissions for sending commands.
///
/// ## Topics
///
/// ### Overview
/// The permissions page includes:
/// - AppleScript permission request and status
/// - Accessibility permission request and status
/// - Terminal application selector
/// - Real-time permission status updates
///
/// ### Requirements
/// - ``AppleScriptPermissionManager`` for AppleScript permissions
/// - ``AccessibilityPermissionManager`` for accessibility permissions
/// - Terminal selection stored in UserDefaults
struct RequestPermissionsPageView: View {
    @StateObject private var appleScriptManager = AppleScriptPermissionManager.shared
    @State private var accessibilityUpdateTrigger = 0

    private var hasAccessibilityPermission: Bool {
        // This will cause a re-read whenever accessibilityUpdateTrigger changes
        _ = accessibilityUpdateTrigger
        return AccessibilityPermissionManager.shared.hasPermission()
    }

    var body: some View {
        VStack(spacing: 30) {
            // App icon
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .frame(width: 156, height: 156)
                .shadow(radius: 10)

            VStack(spacing: 16) {
                Text("Request Permissions")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text(
                    "VibeTunnel needs AppleScript to start new terminal sessions\nand accessibility to send commands."
                )
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)

                // Permissions buttons
                VStack(spacing: 16) {
                    // Automation permission
                    if appleScriptManager.checkPermissionStatus() {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Automation permission granted")
                                .foregroundColor(.secondary)
                        }
                        .font(.body)
                        .frame(maxWidth: 250)
                        .frame(height: 32)
                    } else {
                        Button("Grant Automation Permission") {
                            appleScriptManager.requestPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .frame(width: 250, height: 32)
                    }

                    // Accessibility permission
                    if hasAccessibilityPermission {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Accessibility permission granted")
                                .foregroundColor(.secondary)
                        }
                        .font(.body)
                        .frame(maxWidth: 250)
                        .frame(height: 32)
                    } else {
                        Button("Grant Accessibility Permission") {
                            AccessibilityPermissionManager.shared.requestPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .frame(width: 250, height: 32)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            // Force a re-render to check accessibility permission
            accessibilityUpdateTrigger += 1
        }
        .task {
            // Perform a silent check that won't trigger dialog
            _ = await appleScriptManager.silentPermissionCheck()
        }
    }
}

// MARK: - Preview

struct RequestPermissionsPageView_Previews: PreviewProvider {
    static var previews: some View {
        RequestPermissionsPageView()
            .frame(width: 640, height: 480)
            .background(Color(NSColor.windowBackgroundColor))
    }
}
