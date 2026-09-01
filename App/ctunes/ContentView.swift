import PlexKit
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut, .linking:
                AuthView(model: model)
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding your server…").foregroundStyle(.secondary)
                }
            case .connectFailed:
                ConnectFailedView(model: model)
            case .signedIn:
                LibraryView(model: model)
            }
        }
        .task { await model.bootstrap() }
    }
}

struct ConnectFailedView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach your server", systemImage: "network.slash")
        } description: {
            Text(model.errorMessage ?? "No Plex server answered.")
        } actions: {
            Button("Try again") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent)
            Button("Sign out") { Task { await model.signOut() } }
        }
    }
}

#Preview {
    ContentView()
}
