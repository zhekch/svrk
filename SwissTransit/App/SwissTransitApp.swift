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
        //
        // And the loops go down with them. iOS freezes a backgrounded process
        // in its own time, and everything drawn between leaving the screen and
        // being frozen is drawn for nobody. See `AppModel.suspend`.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.resume()
            case .inactive:
                // Stop producers immediately for Control Center, app switching
                // and the first half of a background transition. Persistence
                // waits for `.background`, so that ordinary active → inactive
                // → background sequence does not write the same caches twice.
                model.suspend()
            case .background:
                model.suspend()
                Task { await model.persist() }
            @unknown default:
                model.suspend()
            }
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
