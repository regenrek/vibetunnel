import SwiftTerm
import SwiftUI

/// UIKit bridge for the SwiftTerm terminal emulator.
///
/// Wraps SwiftTerm's TerminalView in a UIViewRepresentable to integrate
/// with SwiftUI, handling terminal configuration, input/output, and resizing.
struct TerminalHostingView: UIViewRepresentable {
    let session: Session
    @Binding var fontSize: CGFloat
    let onInput: (String) -> Void
    let onResize: (Int, Int) -> Void
    var viewModel: TerminalViewModel
    @State private var isAutoScrollEnabled = true

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminal = SwiftTerm.TerminalView()

        // Configure terminal appearance
        terminal.backgroundColor = UIColor(Theme.Colors.terminalBackground)
        terminal.nativeForegroundColor = UIColor(Theme.Colors.terminalForeground)
        terminal.nativeBackgroundColor = UIColor(Theme.Colors.terminalBackground)

        // Set up delegates
        // SwiftTerm's TerminalView uses terminalDelegate, not delegate
        terminal.terminalDelegate = context.coordinator

        // Configure terminal options
        terminal.allowMouseReporting = false
        terminal.optionAsMetaKey = true

        // Enable URL detection
        // SwiftTerm doesn't have built-in link detection API
        // URL detection would need to be implemented manually

        // Configure font
        updateFont(terminal, size: fontSize)

        // Start with default size
        let cols = Int(UIScreen.main.bounds.width / 9) // Approximate char width
        let rows = 24
        terminal.resize(cols: cols, rows: rows)

        return terminal
    }

    func updateUIView(_ terminal: SwiftTerm.TerminalView, context: Context) {
        updateFont(terminal, size: fontSize)

        // Update terminal content from viewModel
        context.coordinator.terminal = terminal
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onInput: onInput,
            onResize: onResize,
            viewModel: viewModel
        )
    }

    private func updateFont(_ terminal: SwiftTerm.TerminalView, size: CGFloat) {
        let font: UIFont = if let customFont = UIFont(name: Theme.Typography.terminalFont, size: size) {
            customFont
        } else if let fallbackFont = UIFont(name: Theme.Typography.terminalFontFallback, size: size) {
            fallbackFont
        } else {
            UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // SwiftTerm uses the font property directly
        terminal.font = font
    }

    @MainActor
    class Coordinator: NSObject {
        let onInput: (String) -> Void
        let onResize: (Int, Int) -> Void
        let viewModel: TerminalViewModel
        weak var terminal: SwiftTerm.TerminalView?

        init(
            onInput: @escaping (String) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            viewModel: TerminalViewModel
        ) {
            self.onInput = onInput
            self.onResize = onResize
            self.viewModel = viewModel
            super.init()

            // Set the coordinator reference on the viewModel
            Task { @MainActor in
                viewModel.terminalCoordinator = self
            }
        }

        func feedData(_ data: String) {
            Task { @MainActor in
                guard let terminal else { return }

                // Store current scroll position before feeding data
                let wasAtBottom = viewModel.isAutoScrollEnabled

                // Feed the output to the terminal
                terminal.feed(text: data)

                // Auto-scroll to bottom if enabled
                if wasAtBottom {
                    // SwiftTerm automatically scrolls when feeding data at bottom
                    // No explicit API needed for auto-scrolling
                }
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            if let string = String(bytes: data, encoding: .utf8) {
                onInput(string)
            }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {
            // SwiftTerm doesn't expose detailed scroll position tracking
            // The position parameter represents the relative scroll position
            // // Check if user manually scrolled away from bottom
            // if let terminal = terminal {
            //    let buffer = terminal.buffer
            //    let totalRows = buffer.lines.count
            //    let viewportHeight = terminal.rows
            //    let maxScroll = Double(max(0, totalRows - viewportHeight))
            //
            //    // If user scrolled away from bottom (with some tolerance)
            //    let isAtBottom = position >= maxScroll - 5
            //
            //    Task { @MainActor in
            //        if !isAtBottom && viewModel.isAutoScrollEnabled {
            //            // User manually scrolled up - disable auto-scroll
            //            viewModel.isAutoScrollEnabled = false
            //        } else if isAtBottom && !viewModel.isAutoScrollEnabled {
            //            // User scrolled back to bottom - re-enable auto-scroll
            //            viewModel.isAutoScrollEnabled = true
            //        }
            //    }
            // }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            // Handle title change if needed
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            // Handle directory update if needed
        }

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            // Open URL
            if let url = URL(string: link) {
                DispatchQueue.main.async {
                    UIApplication.shared.open(url)
                }
            }
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            // Handle clipboard copy
            if let string = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = string
            }
        }

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
            // Handle range change if needed
        }
    }
}

/// Add conformance with proper isolation
extension TerminalHostingView.Coordinator: @preconcurrency SwiftTerm.TerminalViewDelegate {}
