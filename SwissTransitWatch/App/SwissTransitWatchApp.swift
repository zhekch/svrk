import SwiftUI

@main
struct SwissTransitWatchApp: App {
    @State private var model = WatchTransitModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
                .task {
                    if scenePhase == .active {
                        model.enterForeground()
                    }
                }
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.enterForeground()
            case .inactive, .background:
                model.leaveForeground()
            @unknown default:
                model.leaveForeground()
            }
        }
        .backgroundTask(
            .urlSession(WatchTimetableDownloadCoordinator.sessionIdentifier)
        ) {
            await WatchNationalTimetableService.handleBackgroundSessionEvents()
        }
    }
}
