import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ConnectionManager.self) var connectionManager
    @State private var showingFilePicker = false
    @State private var showingCastPlayer = false
    @State private var selectedCastFile: URL?
    
    var body: some View {
        Group {
            if connectionManager.isConnected, connectionManager.serverConfig != nil {
                SessionListView()
            } else {
                ConnectionView()
            }
        }
        .animation(.default, value: connectionManager.isConnected)
        .onOpenURL { url in
            // Handle cast file opening
            if url.pathExtension == "cast" {
                selectedCastFile = url
                showingCastPlayer = true
            }
        }
        .sheet(isPresented: $showingCastPlayer) {
            if let castFile = selectedCastFile {
                CastPlayerView(castFileURL: castFile)
            }
        }
    }
}