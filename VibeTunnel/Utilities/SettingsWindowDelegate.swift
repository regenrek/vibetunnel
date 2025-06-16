import AppKit
import SwiftUI

/// A window delegate that handles animated resizing of the settings window
class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()
    
    private override init() {
        super.init()
    }
    
    /// Animates the window to a new size
    func animateWindowResize(to newSize: CGSize, duration: TimeInterval = 0.3) {
        guard let window = NSApp.windows.first(where: { $0.title.contains("Settings") || $0.title.contains("Preferences") }) else {
            return
        }
        
        // Calculate the new frame maintaining the window's top-left position
        var newFrame = window.frame
        let heightDifference = newSize.height - newFrame.height
        newFrame.size = newSize
        newFrame.origin.y -= heightDifference // Keep top edge in place
        
        // Animate the frame change
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        // Clean up if needed
    }
}

/// A view modifier that sets up the window delegate for animated resizing
struct AnimatedWindowResizing: ViewModifier {
    let size: CGSize
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                setupWindowDelegate()
                // Initial resize without animation
                SettingsWindowDelegate.shared.animateWindowResize(to: size, duration: 0)
            }
            .onChange(of: size) { _, newSize in
                SettingsWindowDelegate.shared.animateWindowResize(to: newSize)
            }
    }
    
    private func setupWindowDelegate() {
        Task { @MainActor in
            // Small delay to ensure window is created
            try? await Task.sleep(for: .milliseconds(100))
            
            if let window = NSApp.windows.first(where: { $0.title.contains("Settings") || $0.title.contains("Preferences") }) {
                window.delegate = SettingsWindowDelegate.shared
                // Disable window resizing by user
                window.styleMask.remove(.resizable)
            }
        }
    }
}

extension View {
    func animatedWindowResizing(size: CGSize) -> some View {
        modifier(AnimatedWindowResizing(size: size))
    }
}