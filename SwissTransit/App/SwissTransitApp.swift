import SwiftUI
import MapboxMaps

@main
struct SwissTransitApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Set before any map is created. Without it the SDK renders nothing and
        // says so only in the log, which reads as a blank map.
        if let token = Secrets.mapboxAccessToken {
            MapboxOptions.accessToken = token
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .preferredColorScheme(.dark)
        }
        // Routed legs written out on the way to the background, which is the
        // only moment the app reliably gets before it is killed. Losing them
        // costs nothing but correctness — they are recomputed — but recomputing
        // them is the pause this exists to remove.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await model.persist() }
        }
    }
}

/// A canvas-friendly map shell. It intentionally does not start the fleet
/// refresh task, so Xcode previews remain local and deterministic.
private struct MainMapPreview: View {
    @State private var model = AppModel()

    init() {
        if let token = Secrets.mapboxAccessToken {
            MapboxOptions.accessToken = token
        }
    }

    var body: some View {
        ContentView(model: model)
            .preferredColorScheme(.dark)
    }
}

#Preview("Main map") {
    MainMapPreview()
}
