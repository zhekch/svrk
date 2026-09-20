import ActivityKit
import SwiftUI
import TransitActivity
import WidgetKit

@main
struct SwissTransitLiveActivity: WidgetBundle {
    var body: some Widget {
        TripLiveActivityWidget()
    }
}

struct TripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLockScreenView(
                attributes: context.attributes, state: context.state, isStale: context.isStale
            )
                .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { EmptyView() }
                DynamicIslandExpandedRegion(.trailing) { EmptyView() }
                DynamicIslandExpandedRegion(.bottom) {
                    TripIslandExpandedView(
                        attributes: context.attributes, state: context.state, isStale: context.isStale
                    )
                }
            } compactLeading: {
                TripIslandCompactLeading(
                    line: context.attributes.line, mode: context.attributes.mode
                )
            } compactTrailing: {
                TripIslandCompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                TripIslandMinimal(
                    state: context.state, mode: context.attributes.mode, isStale: context.isStale
                )
            }
        }
    }
}

#Preview("Departure", as: .content, using: TripActivityAttributes.previewDeparture) {
    TripLiveActivityWidget()
} contentStates: {
    TripActivityAttributes.ContentState.previewOnTime
    TripActivityAttributes.ContentState.previewDelayed
    TripActivityAttributes.ContentState.previewCancelled
}

#Preview("Arrival", as: .content, using: TripActivityAttributes.previewArrival) {
    TripLiveActivityWidget()
} contentStates: {
    TripActivityAttributes.ContentState.previewArrival
}

#Preview("Island delayed", as: .dynamicIsland(.expanded), using: TripActivityAttributes.previewDeparture) {
    TripLiveActivityWidget()
} contentStates: {
    TripActivityAttributes.ContentState.previewDelayed
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: TripActivityAttributes.previewArrival) {
    TripLiveActivityWidget()
} contentStates: {
    TripActivityAttributes.ContentState.previewArrival
}
