import SwiftUI
import Combine
import SwiftTerm

struct TerminalView: View {
    let session: Session
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel: TerminalViewModel
    @State private var fontSize: CGFloat = 14
    @State private var showingFontSizeSheet = false
    @State private var showingRecordingSheet = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var isInputFocused: Bool
    
    init(session: Session) {
        self.session = session
        self._viewModel = StateObject(wrappedValue: TerminalViewModel(session: session))
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Theme.Colors.terminalBackground
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
                        Button(action: { viewModel.clearTerminal() }) {
                            Label("Clear", systemImage: "clear")
                        }
                        
                        Button(action: { showingFontSizeSheet = true }) {
                            Label("Font Size", systemImage: "textformat.size")
                        }
                        
                        Button(action: { viewModel.copyBuffer() }) {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        
                        Divider()
                        
                        if viewModel.castRecorder.isRecording {
                            Button(action: { 
                                viewModel.stopRecording()
                                showingRecordingSheet = true
                            }) {
                                Label("Stop Recording", systemImage: "stop.circle.fill")
                                    .foregroundColor(.red)
                            }
                        } else {
                            Button(action: { viewModel.startRecording() }) {
                                Label("Start Recording", systemImage: "record.circle")
                            }
                        }
                        
                        Button(action: { showingRecordingSheet = true }) {
                            Label("Export Recording", systemImage: "square.and.arrow.up")
                        }
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
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if viewModel.terminalCols > 0 && viewModel.terminalRows > 0 {
                        HStack(spacing: Theme.Spacing.xs) {
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
                            .fill(session.isRunning ? Theme.Colors.successAccent : Theme.Colors.terminalForeground.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text(session.isRunning ? "Running" : "Exited")
                            .font(Theme.Typography.terminalSystem(size: 12))
                            .foregroundColor(session.isRunning ? Theme.Colors.successAccent : Theme.Colors.terminalForeground.opacity(0.5))
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
                                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: viewModel.recordingPulse)
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
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.connect()
            isInputFocused = true
        }
        .onDisappear {
            viewModel.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
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
    }
    
    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.lg) {
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
        VStack(spacing: Theme.Spacing.lg) {
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
            .background(Theme.Colors.terminalBackground)
            .focused($isInputFocused)
            
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

@MainActor
class TerminalViewModel: ObservableObject {
    @Published var isConnecting = true
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var terminalViewId = UUID()
    @Published var terminalCols: Int = 0
    @Published var terminalRows: Int = 0
    @Published var isAutoScrollEnabled = true
    @Published var recordingPulse = false
    
    let session: Session
    let castRecorder: CastRecorder
    private var bufferWebSocketClient: BufferWebSocketClient?
    var cancellables = Set<AnyCancellable>()
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
        
        // Subscribe to terminal events
        bufferWebSocketClient?.subscribe(to: session.id) { [weak self] event in
            Task { @MainActor in
                self?.handleWebSocketEvent(event)
            }
        }
        
        // Monitor connection status
        bufferWebSocketClient?.$isConnected
            .sink { [weak self] connected in
                Task { @MainActor in
                    self?.isConnecting = false
                    self?.isConnected = connected
                    if !connected {
                        self?.errorMessage = "WebSocket disconnected"
                    } else {
                        self?.errorMessage = nil
                    }
                }
            }
            .store(in: &cancellables)
        
        // Monitor connection errors
        bufferWebSocketClient?.$connectionError
            .compactMap { $0 }
            .sink { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                    self?.isConnecting = false
                }
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    private func loadSnapshot() async {
        guard let snapshotURL = APIClient.shared.snapshotURL(for: session.id) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: snapshotURL)
            if let snapshot = String(data: data, encoding: .utf8) {
                // Feed the snapshot to the terminal
                terminalCoordinator?.feedData(snapshot)
            }
        } catch {
            print("Failed to load terminal snapshot: \(error)")
        }
    }
    
    func disconnect() {
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
            
        case .output(let timestamp, let data):
            // Feed output data directly to the terminal
            terminalCoordinator?.feedData(data)
            // Record output if recording
            castRecorder.recordOutput(data)
            
        case .resize(let timestamp, let dimensions):
            // Parse dimensions like "120x30"
            let parts = dimensions.split(separator: "x")
            if parts.count == 2,
               let cols = Int(parts[0]),
               let rows = Int(parts[1]) {
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
            } catch {
                print("Failed to resize terminal: \(error)")
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
}