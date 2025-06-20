import Observation
import SwiftTerm
import SwiftUI

/// Interactive terminal view for a session.
///
/// Displays a full terminal emulator using SwiftTerm with support for
/// input, output, recording, and font size adjustment.
struct TerminalView: View {
    let session: Session
    @Environment(\.dismiss) var dismiss
    @State private var viewModel: TerminalViewModel
    @State private var fontSize: CGFloat = 14
    @State private var showingFontSizeSheet = false
    @State private var showingRecordingSheet = false
    @State private var showingTerminalWidthSheet = false
    @State private var showingTerminalThemeSheet = false
    @State private var selectedTerminalWidth: Int?
    @State private var selectedTheme = TerminalTheme.selected
    @State private var keyboardHeight: CGFloat = 0
    @State private var showScrollToBottom = false
    @FocusState private var isInputFocused: Bool

    init(session: Session) {
        self.session = session
        self._viewModel = State(initialValue: TerminalViewModel(session: session))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                selectedTheme.background
                    .ignoresSafeArea()

                // Terminal content
                VStack(spacing: 0) {
                    if viewModel.isConnecting {
                        loadingView
                    } else if let error = viewModel.errorMessage {
                        errorView(error)
                    } else {
                        terminalContent
                    }
                }
            }
            .navigationTitle(session.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .bottomBar)
            .toolbarBackground(.visible, for: .bottomBar)
            .toolbarBackground(Theme.Colors.cardBackground, for: .bottomBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(Theme.Colors.primaryAccent)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { viewModel.clearTerminal() }, label: {
                            Label("Clear", systemImage: "clear")
                        })

                        Button(action: { showingFontSizeSheet = true }, label: {
                            Label("Font Size", systemImage: "textformat.size")
                        })

                        Button(action: { showingTerminalWidthSheet = true }, label: {
                            Label("Terminal Width", systemImage: "arrow.left.and.right")
                        })
                        
                        Button(action: { viewModel.toggleFitToWidth() }, label: {
                            Label(viewModel.fitToWidth ? "Fixed Width" : "Fit to Width", 
                                  systemImage: viewModel.fitToWidth ? "arrow.left.and.right.square" : "arrow.left.and.right.square.fill")
                        })

                        Button(action: { showingTerminalThemeSheet = true }, label: {
                            Label("Theme", systemImage: "paintbrush")
                        })

                        Button(action: { viewModel.copyBuffer() }, label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        })

                        Divider()

                        if viewModel.castRecorder.isRecording {
                            Button(action: {
                                viewModel.stopRecording()
                                showingRecordingSheet = true
                            }, label: {
                                Label("Stop Recording", systemImage: "stop.circle.fill")
                                    .foregroundColor(.red)
                            })
                        } else {
                            Button(action: { viewModel.startRecording() }, label: {
                                Label("Start Recording", systemImage: "record.circle")
                            })
                        }

                        Button(action: { showingRecordingSheet = true }, label: {
                            Label("Export Recording", systemImage: "square.and.arrow.up")
                        })
                        .disabled(viewModel.castRecorder.events.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(Theme.Colors.primaryAccent)
                    }
                }
            }
            .sheet(isPresented: $showingFontSizeSheet) {
                FontSizeSheet(fontSize: $fontSize)
            }
            .sheet(isPresented: $showingRecordingSheet) {
                RecordingExportSheet(recorder: viewModel.castRecorder, sessionName: session.displayName)
            }
            .sheet(isPresented: $showingTerminalWidthSheet) {
                TerminalWidthSheet(selectedWidth: $selectedTerminalWidth, isResizeBlockedByServer: viewModel.isResizeBlockedByServer)
                    .onAppear {
                        selectedTerminalWidth = viewModel.terminalCols
                    }
            }
            .sheet(isPresented: $showingTerminalThemeSheet) {
                TerminalThemeSheet(selectedTheme: $selectedTheme)
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if viewModel.terminalCols > 0 && viewModel.terminalRows > 0 {
                        HStack(spacing: Theme.Spacing.extraSmall) {
                            Image(systemName: "rectangle.split.3x1")
                                .font(.caption)
                                .foregroundColor(Theme.Colors.terminalForeground.opacity(0.5))
                            Text("\(viewModel.terminalCols) × \(viewModel.terminalRows)")
                                .font(Theme.Typography.terminalSystem(size: 12))
                                .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                        }
                    }

                    Spacer()

                    // Session status
                    HStack(spacing: 4) {
                        Circle()
                            .fill(session.isRunning ? Theme.Colors.successAccent : Theme.Colors.terminalForeground
                                .opacity(0.3)
                            )
                            .frame(width: 6, height: 6)
                        Text(session.isRunning ? "Running" : "Exited")
                            .font(Theme.Typography.terminalSystem(size: 12))
                            .foregroundColor(session.isRunning ? Theme.Colors.successAccent : Theme.Colors
                                .terminalForeground.opacity(0.5)
                            )
                    }

                    if let pid = session.pid {
                        Spacer()

                        Text("PID: \(pid)")
                            .font(Theme.Typography.terminalSystem(size: 12))
                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.5))
                            .onTapGesture {
                                UIPasteboard.general.string = String(pid)
                                HapticFeedback.notification(.success)
                            }
                    }
                }

                // Recording indicator
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.castRecorder.isRecording {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .overlay(
                                    Circle()
                                        .fill(Color.red.opacity(0.3))
                                        .frame(width: 16, height: 16)
                                        .scaleEffect(viewModel.recordingPulse ? 1.5 : 1.0)
                                        .animation(
                                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                            value: viewModel.recordingPulse
                                        )
                                )
                            Text("REC")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.red)
                        }
                        .onAppear {
                            viewModel.recordingPulse = true
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.connect()
            isInputFocused = true
        }
        .onDisappear {
            viewModel.disconnect()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: UIResponder.keyboardWillShowNotification)
        ) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                withAnimation(Theme.Animation.standard) {
                    keyboardHeight = keyboardFrame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(Theme.Animation.standard) {
                keyboardHeight = 0
            }
        }
        .onChange(of: selectedTerminalWidth) { oldValue, newValue in
            if let width = newValue, width != viewModel.terminalCols {
                // Calculate appropriate height based on aspect ratio
                let aspectRatio = Double(viewModel.terminalRows) / Double(viewModel.terminalCols)
                let newHeight = Int(Double(width) * aspectRatio)
                viewModel.resize(cols: width, rows: newHeight)
            }
        }
        .onChange(of: viewModel.isAtBottom) { oldValue, newValue in
            // Update scroll button visibility
            withAnimation(Theme.Animation.smooth) {
                showScrollToBottom = !newValue
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.large) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primaryAccent))
                .scaleEffect(1.5)

            Text("Connecting to session...")
                .font(Theme.Typography.terminalSystem(size: 14))
                .foregroundColor(Theme.Colors.terminalForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(Theme.Colors.errorAccent)

            Text("Connection Error")
                .font(.headline)
                .foregroundColor(Theme.Colors.terminalForeground)

            Text(error)
                .font(Theme.Typography.terminalSystem(size: 12))
                .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                viewModel.connect()
            }
            .terminalButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var terminalContent: some View {
        VStack(spacing: 0) {
            // Terminal hosting view
            TerminalHostingView(
                session: session,
                fontSize: $fontSize,
                theme: selectedTheme,
                onInput: { text in
                    viewModel.sendInput(text)
                },
                onResize: { cols, rows in
                    viewModel.terminalCols = cols
                    viewModel.terminalRows = rows
                    viewModel.resize(cols: cols, rows: rows)
                },
                viewModel: viewModel
            )
            .id(viewModel.terminalViewId)
            .background(selectedTheme.background)
            .focused($isInputFocused)
            .scrollToBottomOverlay(
                isVisible: showScrollToBottom,
                action: {
                    viewModel.scrollToBottom()
                    showScrollToBottom = false
                }
            )

            // Keyboard toolbar
            if keyboardHeight > 0 {
                TerminalToolbar(
                    onSpecialKey: { key in
                        viewModel.sendInput(key.rawValue)
                    },
                    onDismissKeyboard: {
                        isInputFocused = false
                    },
                    onRawInput: { input in
                        viewModel.sendInput(input)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// View model for terminal session management.
@MainActor
@Observable
class TerminalViewModel {
    var isConnecting = true
    var isConnected = false
    var errorMessage: String?
    var terminalViewId = UUID()
    var terminalCols: Int = 0
    var terminalRows: Int = 0
    var isAutoScrollEnabled = true
    var recordingPulse = false
    var isResizeBlockedByServer = false
    var isAtBottom = true
    var fitToWidth = false

    let session: Session
    let castRecorder: CastRecorder
    private var bufferWebSocketClient: BufferWebSocketClient?
    private var connectionStatusTask: Task<Void, Never>?
    private var connectionErrorTask: Task<Void, Never>?
    weak var terminalCoordinator: TerminalHostingView.Coordinator?

    init(session: Session) {
        self.session = session
        self.castRecorder = CastRecorder(sessionId: session.id, width: 80, height: 24)
        setupTerminal()
    }

    private func setupTerminal() {
        // Terminal setup now handled by SimpleTerminalView
    }

    func startRecording() {
        castRecorder.startRecording()
    }

    func stopRecording() {
        castRecorder.stopRecording()
    }

    func connect() {
        isConnecting = true
        errorMessage = nil

        // Create WebSocket client if needed
        if bufferWebSocketClient == nil {
            bufferWebSocketClient = BufferWebSocketClient()
        }

        // Connect to WebSocket
        bufferWebSocketClient?.connect()

        // Load initial snapshot after a brief delay to ensure terminal is ready
        Task { @MainActor in
            // Wait for terminal view to be initialized
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            await loadSnapshot()
        }

        // Subscribe to terminal events
        bufferWebSocketClient?.subscribe(to: session.id) { [weak self] event in
            Task { @MainActor in
                self?.handleWebSocketEvent(event)
            }
        }

        // Monitor connection status
        connectionStatusTask?.cancel()
        connectionStatusTask = Task { [weak self] in
            guard let client = self?.bufferWebSocketClient else { return }
            while !Task.isCancelled {
                let connected = client.isConnected
                await MainActor.run {
                    self?.isConnecting = false
                    self?.isConnected = connected
                    if !connected {
                        self?.errorMessage = "WebSocket disconnected"
                    } else {
                        self?.errorMessage = nil
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5 seconds
            }
        }

        // Monitor connection errors
        connectionErrorTask?.cancel()
        connectionErrorTask = Task { [weak self] in
            guard let client = self?.bufferWebSocketClient else { return }
            while !Task.isCancelled {
                if let error = client.connectionError {
                    await MainActor.run {
                        self?.errorMessage = error.localizedDescription
                        self?.isConnecting = false
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5 seconds
            }
        }
    }

    @MainActor
    private func loadSnapshot() async {
        do {
            let snapshot = try await APIClient.shared.getSessionSnapshot(sessionId: session.id)
            
            // Process the snapshot events
            if let header = snapshot.header {
                // Initialize terminal with dimensions from header
                terminalCols = header.width
                terminalRows = header.height
                print("Snapshot header: \(header.width)x\(header.height)")
            }
            
            // Feed all output events to the terminal
            for event in snapshot.events {
                if event.type == .output {
                    // Feed the actual terminal output data
                    terminalCoordinator?.feedData(event.data)
                }
            }
        } catch {
            print("Failed to load terminal snapshot: \(error)")
        }
    }

    func disconnect() {
        connectionStatusTask?.cancel()
        connectionErrorTask?.cancel()
        bufferWebSocketClient?.unsubscribe(from: session.id)
        bufferWebSocketClient?.disconnect()
        bufferWebSocketClient = nil
        isConnected = false
    }

    @MainActor
    private func handleWebSocketEvent(_ event: TerminalWebSocketEvent) {
        switch event {
        case .header(let width, let height):
            // Initial terminal setup
            print("Terminal initialized: \(width)x\(height)")
            terminalCols = width
            terminalRows = height
            // The terminal will be resized when created

        case .output(_, let data):
            // Feed output data directly to the terminal
            if let coordinator = terminalCoordinator {
                coordinator.feedData(data)
            } else {
                // Queue the data to be fed once coordinator is ready
                print("Warning: Terminal coordinator not ready, queueing data")
                Task {
                    // Wait a bit for coordinator to be initialized
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    if let coordinator = self.terminalCoordinator {
                        coordinator.feedData(data)
                    }
                }
            }
            // Record output if recording
            castRecorder.recordOutput(data)

        case .resize(_, let dimensions):
            // Parse dimensions like "120x30"
            let parts = dimensions.split(separator: "x")
            if parts.count == 2,
               let cols = Int(parts[0]),
               let rows = Int(parts[1])
            {
                // Update terminal dimensions
                terminalCols = cols
                terminalRows = rows
                print("Terminal resize: \(cols)x\(rows)")
                // Record resize event
                castRecorder.recordResize(cols: cols, rows: rows)
            }

        case .exit(let code):
            // Session has exited
            isConnected = false
            if code != 0 {
                errorMessage = "Session exited with code \(code)"
            }
            // Stop recording if active
            if castRecorder.isRecording {
                stopRecording()
            }
        }
    }

    func sendInput(_ text: String) {
        Task {
            do {
                try await SessionService.shared.sendInput(to: session.id, text: text)
            } catch {
                print("Failed to send input: \(error)")
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        Task {
            do {
                try await SessionService.shared.resizeTerminal(sessionId: session.id, cols: cols, rows: rows)
                // If resize succeeded, ensure the flag is cleared
                isResizeBlockedByServer = false
            } catch {
                print("Failed to resize terminal: \(error)")
                // Check if the error is specifically about resize being disabled
                if case APIError.resizeDisabledByServer = error {
                    isResizeBlockedByServer = true
                }
            }
        }
    }

    func clearTerminal() {
        // Reset the terminal by recreating it
        terminalViewId = UUID()
        HapticFeedback.impact(.medium)
    }

    func copyBuffer() {
        // Terminal copy is handled by SwiftTerm's built-in functionality
        HapticFeedback.notification(.success)
    }
    
    func scrollToBottom() {
        // Signal the terminal to scroll to bottom
        isAutoScrollEnabled = true
        isAtBottom = true
        // The actual scrolling is handled by the terminal coordinator
        terminalCoordinator?.scrollToBottom()
    }
    
    func updateScrollState(isAtBottom: Bool) {
        self.isAtBottom = isAtBottom
        self.isAutoScrollEnabled = isAtBottom
    }
    
    func toggleFitToWidth() {
        fitToWidth.toggle()
        HapticFeedback.impact(.light)
        
        if fitToWidth {
            // Calculate optimal width to fit the screen
            let screenWidth = UIScreen.main.bounds.width
            let padding: CGFloat = 32 // Account for UI padding
            let charWidth: CGFloat = 9 // Approximate character width
            let optimalCols = Int((screenWidth - padding) / charWidth)
            
            // Resize to fit
            resize(cols: optimalCols, rows: terminalRows)
        }
    }
}
