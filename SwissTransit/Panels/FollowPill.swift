import SwiftUI
import TransitCore

/// The vehicle card, reduced to one glance, while the rest of the interface
/// is out of the way.
///
/// Full screen follow is a different question from the nearby-ride bar: that
/// one is an offer, this one is a status. A caption, the stop and when are the
/// whole of what a thumb needs while the map is doing the watching. Pull up
/// for the panel again; pull down to let go of the train.
struct FollowPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let vehicle: VehicleSnapshot
    let now: Timestamp
    /// Take the sheet back up to the vehicle panel. A tap does what the pull
    /// does, for anyone who does not read the handle as an invitation.
    let expand: () -> Void
    /// Stop following, for VoiceOver — which has no downward swipe to spare.
    let dismiss: () -> Void

    /// The same height as the live-ride bar. One statement under the handle,
    /// home indicator included. The sheet rounds this height in half while it
    /// stands here, so the ends are semicircles rather than a rounded rectangle.
    static let height: CGFloat = RidePill.height
    /// Landscape puts "next stop" on the same line as the name, so the bar
    /// no longer needs a second line of type under the handle.
    static let landscapeHeight: CGFloat = 84

    private var landscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        // Equal-width side columns, so the stop sits in the true middle of
        // the pill rather than in whatever is left between a narrow badge
        // and a wider time. Badge and time are centred on the pill's height.
        HStack(alignment: .center, spacing: 8) {
            ZStack(alignment: .leading) {
                whenLabel.hidden().accessibilityHidden(true)
                LineBadge(line: vehicle.line, mode: vehicle.mode)
            }
            Group {
                if landscape {
                    inlineStop
                } else {
                    stopBlock
                }
            }
                .frame(maxWidth: .infinity)
                .animation(rollAnimation, value: stopName)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: caption)
            ZStack(alignment: .trailing) {
                LineBadge(line: vehicle.line, mode: vehicle.mode)
                    .hidden()
                    .accessibilityHidden(true)
                whenLabel
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture { expand() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spoken)
        .accessibilityHint("Expands the vehicle card")
        .accessibilityAction { expand() }
        .accessibilityAction(named: "Stop following") { dismiss() }
        .accessibilityIdentifier("Follow pill")
    }

    /// Caption and name as one statement, so the landscape pill can be shorter.
    private var inlineStop: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            captionLabel
            stopNameSlot
        }
        .frame(maxWidth: .infinity)
    }

    /// Always two lines. The wider of caption and name is centred; the
    /// shorter starts on the same leading edge.
    private var stopBlock: some View {
        FollowStopStack(spacing: 1) {
            captionLabel
            stopNameSlot
        }
        .frame(maxWidth: .infinity)
    }

    private var whenLabel: some View {
        Text(whenText)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(whenDelayed ? Format.delayColor : Color.secondary)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: whenText)
            .fixedSize()
    }

    private var whenDelayed: Bool {
        if isStanding, vehicle.stops.indices.contains(vehicle.index) {
            return Format.delay(vehicle.stops[vehicle.index].delay, mode: vehicle.mode) != nil
        }
        return nextCall.map { Format.delay($0.delay, mode: vehicle.mode) != nil } ?? false
    }

    private var captionLabel: some View {
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .id(caption)
            .transition(.opacity)
            .fixedSize()
    }

    /// A one-line window the name rolls through. The outgoing stop leaves
    /// through the top and the next one comes in from below, so a new call
    /// reads as the train moving on rather than as a label that flickered.
    /// Clipped, so the departing name does not slide through the caption.
    private var stopNameSlot: some View {
        Text(stopName)
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .truncationMode(.tail)
            .id(stopName)
            .transition(stopTransition)
            .clipped()
    }

    private var stopTransition: AnyTransition {
        reduceMotion ? .opacity : .push(from: .bottom)
    }

    /// Ease rather than a spring: a bounce on a 60 Hz cap is what made the
    /// roll look like a stutter. High refresh is requested while this pill
    /// is up — see `AppModel.prefersHighFrameRate`.
    private var rollAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.42)
    }

    /// Standing at a platform is a different sentence from running towards one.
    private var isStanding: Bool {
        !vehicle.moving && vehicle.stops.indices.contains(vehicle.index)
    }

    private var caption: String {
        if isStanding { return isAtTerminus ? "terminal stop" : "currently at" }
        if nextIsTerminus { return "terminal stop" }
        return "next stop"
    }

    private var isAtTerminus: Bool {
        vehicle.stops.indices.contains(vehicle.index)
            && vehicle.index == vehicle.stops.count - 1
    }

    private var nextIsTerminus: Bool {
        Positioning.nextStopIndex(vehicle.stops, at: now) == vehicle.stops.count - 1
    }

    private var stopName: String {
        if isStanding { return vehicle.stops[vehicle.index].name }
        if let stop = nextCall { return stop.name }
        if vehicle.stops.indices.contains(vehicle.index) {
            return vehicle.stops[vehicle.index].name
        }
        return vehicle.to ?? "—"
    }

    private var whenText: String {
        if isStanding { return dwellText }
        if let stop = nextCall {
            return Self.relative(stop.displayedArrival, from: now, prefix: "in")
        }
        return "now"
    }

    /// How long the vehicle still holds this platform.
    ///
    /// A through stop is booked out at `dep`. A terminus holds until the
    /// layover, or for `Positioning.terminusHold` where there is not one —
    /// the same bound the panel prints as "stands until". A layover is stored
    /// one second short of the next departure so the two workings never
    /// overlap; display the departure itself.
    ///
    /// A one-minute halt never says "for 1 min": it is leaving, so it says so.
    /// A long stand counts down with "for" and only switches to leaving in
    /// that last minute.
    private var dwellText: String {
        let minutes = Self.minutes(from: now, to: dwellUntil)
        if minutes <= 0 { return "leaves now" }
        if minutes == 1 { return "leaves in 1 min" }
        if minutes < 60 { return "for \(minutes) min" }
        return "for \(minutes / 60) h \(minutes % 60) min"
    }

    private var dwellUntil: Timestamp {
        let stop = vehicle.stops[vehicle.index]
        if vehicle.index == vehicle.stops.count - 1 {
            let hold = Positioning.standsUntil(
                mode: vehicle.mode, arrived: stop.arr, layover: vehicle.layover
            )
            return vehicle.layover == nil ? hold : hold + 1
        }
        return stop.dep
    }

    private var nextCall: Call? {
        Positioning.nextStopIndex(vehicle.stops, at: now).map { vehicle.stops[$0] }
    }

    /// "in 4 min" on the move. Zero is "now" — a train that has arrived at
    /// the next call is there.
    private static func relative(
        _ stamp: Timestamp, from now: Timestamp, prefix: String
    ) -> String {
        let minutes = Self.minutes(from: now, to: stamp)
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "\(prefix) \(minutes) min" }
        return "\(prefix) \(minutes / 60) h \(minutes % 60) min"
    }

    private static func minutes(from now: Timestamp, to stamp: Timestamp) -> Int {
        Clock.remainingMinutes(until: stamp, from: now)
    }

    private var spoken: String {
        "\(vehicle.line). \(caption.capitalized) \(stopName), \(whenText)."
    }
}

/// Two lines in the middle of the pill. The wider of caption and name is
/// centred; the shorter shares its leading edge. So "Frutigen, Winklen"
/// centres the pair and "next stop" hangs from the F, while "currently at"
/// over "Thun" centres the caption and the name starts under the c.
private struct FollowStopStack: Layout {
    var spacing: CGFloat = 1

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let caption = subviews[0].sizeThatFits(.unspecified)
        let name = subviews[1].sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        let width = proposal.width ?? max(caption.width, name.width)
        return CGSize(
            width: width,
            height: caption.height + spacing + name.height
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let caption = subviews[0].sizeThatFits(.unspecified)
        let name = subviews[1].sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        )
        let pairWidth = max(caption.width, name.width)
        let leading = bounds.midX - pairWidth / 2
        subviews[0].place(
            at: CGPoint(x: leading, y: bounds.minY),
            proposal: ProposedViewSize(width: caption.width, height: caption.height)
        )
        subviews[1].place(
            at: CGPoint(x: leading, y: bounds.maxY - name.height),
            proposal: ProposedViewSize(width: name.width, height: name.height)
        )
    }
}

#Preview("Next stop") {
    Color.black
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let now = Int(Date().timeIntervalSince1970)
            FollowPill(
                vehicle: VehicleSnapshot(
                    id: "preview-s44", mode: .train, category: "S", line: "S44",
                    to: "Thun", from: "Solothurn", lon: 7.65, lat: 46.59,
                    moving: true, index: 0, stops: [
                        Call(key: "burgdorf", name: "Burgdorf", lat: 47.06, lon: 7.63,
                             arr: now - 60, dep: now),
                        Call(key: "uetendorf", name: "Uetendorf", lat: 46.77, lon: 7.57,
                             arr: now + 60, dep: now + 90)
                    ]
                ),
                now: now,
                expand: {},
                dismiss: {}
            )
            .presentationDetents([.height(FollowPill.height)])
            .presentationCornerRadius(FollowPill.height)
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}

#Preview("Currently at") {
    Color.black
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let now = Int(Date().timeIntervalSince1970)
            FollowPill(
                vehicle: VehicleSnapshot(
                    id: "preview-ic6", mode: .train, category: "IC", line: "IC6",
                    to: "Basel SBB", from: "Brig", lon: 7.63, lat: 46.29,
                    moving: false, index: 0, stops: [
                        Call(key: "visp", name: "Visp", lat: 46.29, lon: 7.88,
                             arr: now - 60, dep: now + 12 * 60),
                        Call(key: "spiez", name: "Spiez", lat: 46.69, lon: 7.68,
                             arr: now + 20 * 60, dep: now + 21 * 60)
                    ]
                ),
                now: now,
                expand: {},
                dismiss: {}
            )
            .presentationDetents([.height(FollowPill.height)])
            .presentationCornerRadius(FollowPill.height)
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}

#Preview("Leaves in 1 min") {
    Color.black
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let now = Int(Date().timeIntervalSince1970)
            FollowPill(
                vehicle: VehicleSnapshot(
                    id: "preview-re11", mode: .train, category: "RE", line: "RE11",
                    to: "Bern", from: "Thun", lon: 7.57, lat: 46.77,
                    moving: false, index: 0, stops: [
                        Call(key: "uetendorf", name: "Uetendorf", lat: 46.77, lon: 7.57,
                             arr: now - 30, dep: now + 50),
                        Call(key: "thun", name: "Thun", lat: 46.75, lon: 7.63,
                             arr: now + 6 * 60, dep: now + 7 * 60)
                    ]
                ),
                now: now,
                expand: {},
                dismiss: {}
            )
            .presentationDetents([.height(FollowPill.height)])
            .presentationCornerRadius(FollowPill.height)
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}
