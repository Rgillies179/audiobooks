import SwiftUI

@main
struct ShelfApp: App {
    @State private var library: Library
    @State private var player: Player

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _player = State(initialValue: Player(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(player)
                .preferredColorScheme(.dark)
                .tint(.accent)
        }
    }
}

extension Color {
    static let accent = Color(red: 1.0, green: 0.64, blue: 0.24)
}

struct RootView: View {
    @Environment(Player.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            LibraryView { book in
                player.load(book, autoplay: true)
                showPlayer = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayer { showPlayer = true }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.savePosition() }
        }
    }
}
