import AppKit
import SwiftUI

/// About view displaying application information, version details, and credits.
///
/// This view provides information about VibeTunnel including version numbers,
/// build details, developer credits, and links to external resources like
/// GitHub repository and support channels.
struct AboutView: View {
    var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ??
            Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "VibeTunnel"
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                appInfoSection
                descriptionSection
                linksSection

                Spacer(minLength: 40)

                copyrightSection
            }
            .frame(maxWidth: .infinity)
            .standardPadding()
        }
        .scrollContentBackground(.hidden)
    }

    private var appInfoSection: some View {
        VStack(spacing: 16) {
            InteractiveAppIcon()

            Text(appName)
                .font(.largeTitle)
                .fontWeight(.medium)

            Text("Version \(appVersion)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private var descriptionSection: some View {
        Text("Turn any browser into your terminal & command your agents on the go.")
            .font(.body)
            .foregroundStyle(.secondary)
    }

    private var linksSection: some View {
        VStack(spacing: 12) {
            HoverableLink(url: "https://vibetunnel.sh", title: "Website", icon: "globe")
            HoverableLink(url: "https://github.com/amantus-ai/vibetunnel", title: "View on GitHub", icon: "link")
            HoverableLink(
                url: "https://github.com/amantus-ai/vibetunnel/issues",
                title: "Report an Issue",
                icon: "exclamationmark.bubble"
            )
            HoverableLink(url: "https://x.com/VibeTunnel", title: "Follow @VibeTunnel", icon: "bird")
        }
    }

    private var copyrightSection: some View {
        VStack(spacing: 8) {
            // Credits
            VStack(spacing: 4) {
                Text("Brought to you by")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    CreditLink(name: "@badlogic", url: "https://mariozechner.at/")

                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    CreditLink(name: "@mitsuhiko", url: "https://lucumr.pocoo.org/")

                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    CreditLink(name: "@steipete", url: "https://steipete.me")
                }
            }
            
            Text("© 2025 • MIT Licensed")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 32)
    }
}

/// Hoverable link component with underline animation.
///
/// This component displays a link with an icon that shows an underline on hover
/// and changes the cursor to a pointing hand for better user experience.
struct HoverableLink: View {
    let url: String
    let title: String
    let icon: String

    @State private var isHovering = false

    private var destinationURL: URL {
        URL(string: url) ?? URL(fileURLWithPath: "/")
    }

    var body: some View {
        Link(destination: destinationURL) {
            Label(title, systemImage: icon)
                .underline(isHovering, color: .accentColor)
        }
        .buttonStyle(.link)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

/// Interactive app icon component with shadow effects and website link.
///
/// This component displays the VibeTunnel app icon with dynamic shadow effects that respond
/// to user interaction. It includes hover effects for visual feedback and opens the
/// VibeTunnel website when clicked.
struct InteractiveAppIcon: View {
    @State private var isHovering = false
    @State private var isPressed = false
    @Environment(\.colorScheme)
    private var colorScheme

    var body: some View {
        ZStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .scaleEffect(isPressed ? 0.95 : (isHovering ? 1.05 : 1.0))
                .shadow(
                    color: shadowColor,
                    radius: shadowRadius,
                    x: 0,
                    y: shadowOffset
                )
                .animation(.easeInOut(duration: 0.2), value: isHovering)
                .animation(.easeInOut(duration: 0.1), value: isPressed)

            // Invisible button overlay for click handling
            Button(action: openWebsite) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 128, height: 128)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .pointingHandCursor()
        .onHover { hovering in
            isHovering = hovering
        }
        .pressEvents(
            onPress: { isPressed = true },
            onRelease: { isPressed = false }
        )
    }

    private var shadowColor: Color {
        if colorScheme == .dark {
            .black.opacity(isHovering ? 0.6 : 0.4)
        } else {
            .black.opacity(isHovering ? 0.3 : 0.2)
        }
    }

    private var shadowRadius: CGFloat {
        isHovering ? 20 : 12
    }

    private var shadowOffset: CGFloat {
        isHovering ? 8 : 4
    }

    private func openWebsite() {
        guard let url = URL(string: "https://vibetunnel.ai") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Credit Link Component

/// Credit link component for individual contributors.
///
/// This component displays a contributor's handle as a clickable link
/// that opens their website when clicked.
struct CreditLink: View {
    let name: String
    let url: String
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            if let linkURL = URL(string: url) {
                NSWorkspace.shared.open(linkURL)
            }
        }, label: {
            Text(name)
                .font(.caption)
                .underline(isHovering, color: .accentColor)
        })
        .buttonStyle(.link)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview("About View") {
    AboutView()
        .frame(width: 570, height: 600)
}
