import Foundation
import SwiftUI

@main
struct SwissTransitWatchApp: App {
    @State private var model = WatchTransitModel()
    @Environment(\.scenePhase) private var scenePhase

    /// Xcode 27 watch previews run through the Playgrounds/JIT host. Treat
    /// either marker as a preview: the injected canvas supplies the visible
    /// root, while starting location work or overriding UIKit's host traits
    /// behind it can crash the beta preview layout pass.
    private static var isPreviewProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
                .task {
                    if !Self.isPreviewProcess, scenePhase == .active {
                        model.enterForeground()
                    }
                }
                .preferredColorScheme(Self.isPreviewProcess ? nil : .dark)
        }
        .onChange(of: scenePhase) { _, phase in
            guard !Self.isPreviewProcess else { return }
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
