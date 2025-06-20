import SwiftUI
import UIKit

/// Design system for the VibeTunnel app.
///
/// Centralizes all visual styling including colors, typography,
/// spacing, corner radii, and animations for consistent UI.
enum Theme {
    // MARK: - Colors

    /// Color palette for the app.
    enum Colors {
        // Terminal-inspired colors
        static let terminalBackground = Color(hex: "0A0E14")
        static let terminalForeground = Color(hex: "B3B1AD")
        static let terminalSelection = Color(hex: "273747")

        // Accent colors
        static let primaryAccent = Color(hex: "39BAE6")
        static let secondaryAccent = Color(hex: "59C2FF")
        static let successAccent = Color(hex: "AAD94C")
        static let warningAccent = Color(hex: "FFB454")
        static let errorAccent = Color(hex: "F07178")

        // UI colors
        static let cardBackground = Color(hex: "0D1117")
        static let cardBorder = Color(hex: "1C2128")
        static let headerBackground = Color(hex: "010409")
        static let overlayBackground = Color.black.opacity(0.7)

        // Additional UI colors for FileBrowser
        static let terminalAccent = primaryAccent
        static let terminalGray = Color(hex: "8B949E")
        static let terminalDarkGray = Color(hex: "161B22")
        static let terminalWhite = Color.white

        // Terminal ANSI colors
        static let ansiBlack = Color(hex: "01060E")
        static let ansiRed = Color(hex: "EA6C73")
        static let ansiGreen = Color(hex: "91B362")
        static let ansiYellow = Color(hex: "F9AF4F")
        static let ansiBlue = Color(hex: "53BDFA")
        static let ansiMagenta = Color(hex: "FAE994")
        static let ansiCyan = Color(hex: "90E1C6")
        static let ansiWhite = Color(hex: "C7C7C7")

        // Bright ANSI colors
        static let ansiBrightBlack = Color(hex: "686868")
        static let ansiBrightRed = Color(hex: "F07178")
        static let ansiBrightGreen = Color(hex: "C2D94C")
        static let ansiBrightYellow = Color(hex: "FFB454")
        static let ansiBrightBlue = Color(hex: "59C2FF")
        static let ansiBrightMagenta = Color(hex: "FFEE99")
        static let ansiBrightCyan = Color(hex: "95E6CB")
        static let ansiBrightWhite = Color(hex: "FFFFFF")
    }

    // MARK: - Typography

    /// Typography styles for the app.
    enum Typography {
        static let terminalFont = "SF Mono"
        static let terminalFontFallback = "Menlo"
        static let uiFont = "SF Pro Display"

        static func terminal(size: CGFloat) -> Font {
            Font.custom(terminalFont, size: size)
                .monospaced()
        }

        static func terminalSystem(size: CGFloat) -> Font {
            Font.system(size: size, design: .monospaced)
        }
    }

    // MARK: - Spacing

    /// Consistent spacing values.
    enum Spacing {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
        static let extraExtraLarge: CGFloat = 32
    }

    // MARK: - Corner Radius

    /// Standard corner radius values.
    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 16
        static let card: CGFloat = 12
    }

    // MARK: - Animation

    /// Animation presets.
    enum Animation {
        static let quick = SwiftUI.Animation.easeInOut(duration: 0.2)
        static let standard = SwiftUI.Animation.easeInOut(duration: 0.3)
        static let smooth = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.8)
    }

    // MARK: - Shadows

    enum CardShadow {
        static let color = Color.black.opacity(0.3)
        static let radius: CGFloat = 8
        static let xOffset: CGFloat = 0
        static let yOffset: CGFloat = 2
    }

    enum ButtonShadow {
        static let color = Color.black.opacity(0.2)
        static let radius: CGFloat = 4
        static let xOffset: CGFloat = 0
        static let yOffset: CGFloat = 1
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let alpha, red, green, blue: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (alpha, red, green, blue) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (alpha, red, green, blue) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (alpha, red, green, blue) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (alpha, red, green, blue) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

// MARK: - View Modifiers

extension View {
    func terminalCard() -> some View {
        self
            .background(Theme.Colors.cardBackground)
            .cornerRadius(Theme.CornerRadius.card)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.card)
                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
            )
            .shadow(
                color: Theme.CardShadow.color,
                radius: Theme.CardShadow.radius,
                x: Theme.CardShadow.xOffset,
                y: Theme.CardShadow.yOffset
            )
    }

    func glowEffect(color: Color = Theme.Colors.primaryAccent) -> some View {
        self
            .shadow(color: color.opacity(0.5), radius: 10)
            .shadow(color: color.opacity(0.3), radius: 20)
    }

    func terminalButton() -> some View {
        self
            .foregroundColor(Theme.Colors.terminalForeground)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
            .background(Theme.Colors.primaryAccent.opacity(0.1))
            .cornerRadius(Theme.CornerRadius.medium)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                    .stroke(Theme.Colors.primaryAccent, lineWidth: 1)
            )
    }
}

// MARK: - Haptic Feedback

@MainActor
struct HapticFeedback {
    static func impact(_ style: ImpactStyle) {
        let generator = UIImpactFeedbackGenerator(style: style.uiKitStyle)
        generator.impactOccurred()
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    static func notification(_ type: NotificationType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type.uiKitType)
    }

    /// SwiftUI-native style enums
    enum ImpactStyle {
        case light
        case medium
        case heavy
        case soft
        case rigid

        var uiKitStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light: .light
            case .medium: .medium
            case .heavy: .heavy
            case .soft: .soft
            case .rigid: .rigid
            }
        }
    }

    enum NotificationType {
        case success
        case warning
        case error

        var uiKitType: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success: .success
            case .warning: .warning
            case .error: .error
            }
        }
    }
}

// MARK: - SwiftUI Haptic View Modifiers

extension View {
    /// Provides haptic feedback when the view is tapped
    func hapticOnTap(_ style: HapticFeedback.ImpactStyle = .light) -> some View {
        self.onTapGesture {
            HapticFeedback.impact(style)
        }
    }

    /// Provides haptic feedback when a value changes
    func hapticOnChange(of value: some Equatable, style: HapticFeedback.ImpactStyle = .light) -> some View {
        self.onChange(of: value) { _, _ in
            HapticFeedback.impact(style)
        }
    }

    /// Provides selection haptic feedback when a value changes
    func hapticSelection(on value: some Equatable) -> some View {
        self.onChange(of: value) { _, _ in
            HapticFeedback.selection()
        }
    }

    /// Provides notification haptic feedback
    func hapticNotification(_ type: HapticFeedback.NotificationType, when condition: Bool) -> some View {
        self.onChange(of: condition) { _, newValue in
            if newValue {
                HapticFeedback.notification(type)
            }
        }
    }
}
