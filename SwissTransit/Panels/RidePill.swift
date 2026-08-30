import Combine
import SwiftUI
import TransitCore

/// "RE1 to Brig" or "Bern · Platform 7" — the sheet, at its smallest.
///
/// Deliberately the smallest thing that can carry that: a status dot and the
/// name. The app has worked out something the person holding it
/// already knows — they can see the train they are sitting in — so it has no
/// business taking the screen to announce it. What it *does* know that they do
/// not is where the train is going, how late it is and what it is made of, and
/// all of that is one pull away in the panel that already exists.
///
/// It is a *detent* of that panel's sheet rather than a badge floating over the
/// map, and that is the whole design. A badge can only imitate the pull: it
/// follows the finger a little, decides at the end of the gesture, and then
/// swaps itself for a different view. As a detent the pull is the sheet's own —
/// the offer grows into the panel it was promising, at whatever speed the
/// finger chose, and lands wherever the finger lets go.
///
/// Nothing here draws a background, a border or a grab handle. The sheet draws
/// all three, which is what "native" means and is the one thing a hand-rolled
/// capsule cannot keep doing when the platform's own chrome changes underneath
/// it. No chevron either: the handle above it already says which way it goes.
///
/// Pushing it off the screen is the other half. An offer that cannot be
/// declined is an interruption, and a badge naming the wrong train — the one on
/// the next track, at a station, running alongside — is exactly the case the
/// fit cannot rule out on its own. That is the sheet's own downward swipe from
/// this height, and `ContentView` reads a dismissal from it as "not my train".
///
/// Pushing the *panel* back down is not that, and the difference is the whole
/// of this height's job. The bar is where the sheet rests for as long as the
/// ride lasts: pull up for the panel, push down and the bar is still there,
/// swipe down again and it is gone. Taking the offer used to retire it, so
/// closing the panel left bare map and no way back to the train underneath the
/// phone — the app throwing away the one thing it had worked out.
struct RidePill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let offer: RideWatch.Offer
    /// Take the offer. A tap does what the pull does, for anyone who does not
    /// read the handle as an invitation.
    let open: () -> Void
    /// Decline it, for VoiceOver — which has no downward swipe to spare.
    let dismiss: () -> Void

    /// The dot's own pulse. Starts lit, so the first frame of the badge is the
    /// bright one rather than the faded one.
    @State private var lit = true
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// The height the sheet stands at while it has only the offer to make.
    ///
    /// A constant rather than a measurement: it is one line of text under the
    /// system's own handle, and a detent that moved as the destination name
    /// changed would re-lay the sheet out for nothing. It has to clear the home
    /// indicator, which is inside this height rather than under it.
    static let height: CGFloat = 100

    var body: some View {
        // Centred, and at the size of something meant to be read at a glance
        // from a phone lying on a table in a moving train. It used to be a
        // subheadline hard against the left margin, which is how a row in a
        // list is set — but this is not a row in a list. It is one statement
        // occupying the whole width the sheet has, and left-aligning it left a
        // hand-span of empty capsule to its right that read as a truncation.
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(lit ? 1 : 0.42)
            offerText
        }
        .font(.title3)
        // Long line-and-destination pairs shrink rather than clip the line
        // itself: the number is the half that identifies the train.
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 20)
        // Clear of the handle the sheet draws for itself, and pinned to the top
        // of the detent so the row does not drift as the home indicator's inset
        // comes and goes between devices.
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        // Enough motion to announce a new offer, then a static compositor for
        // the rest of a ride. The task is cancelled with the view and restarted
        // if the offer or either power preference changes.
        .task(id: pulseTaskID) { await pulse() }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(spoken)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction { open() }
        .accessibilityAction(named: dismissName) { dismiss() }
    }

    private var shouldPulse: Bool { !reduceMotion && !lowPower }
    private var pulseTaskID: String { "\(offer.id):\(shouldPulse)" }

    @MainActor private func pulse() async {
        lit = true
        guard shouldPulse else { return }
        for _ in 0..<3 {
            withAnimation(.easeInOut(duration: 0.45)) { lit = false }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            withAnimation(.easeInOut(duration: 0.45)) { lit = true }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        }
    }

    @ViewBuilder private var offerText: some View {
        switch offer {
        case let .ride(ride):
            Text(ride.line)
                .fontWeight(.semibold)
            if let destination = ride.to, !destination.isEmpty {
                Text("to \(destination)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case let .nearby(board):
            Text(board.title)
                .fontWeight(.semibold)
        }
    }

    /// Said in full, because the badge's whole trick — a dot standing in for
    /// the word "live" — is a visual one.
    private var spoken: String {
        switch offer {
        case let .ride(ride):
            var said = "You appear to be on the \(ride.line)"
            if let destination = ride.to, !destination.isEmpty { said += " to \(destination)" }
            return said + "."
        case let .nearby(board):
            return "You are near \(board.title)."
        }
    }

    private var accessibilityHint: String {
        switch offer {
        case .ride: return "Opens this service and follows it on the map"
        case .nearby: return "Opens departures for this place"
        }
    }

    private var dismissName: String {
        switch offer {
        case .ride: return "Not my service"
        case .nearby: return "Not this place"
        }
    }
}

#Preview("On a train") {
    Color.black
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            RidePill(
                offer: .ride(RideWatch.Ride(
                    id: "preview-re1", line: "RE1", mode: .train,
                    to: "Brig", shift: 42, metres: 61
                )),
                open: {}, dismiss: {}
            )
            .presentationDetents([.height(RidePill.height), .large])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}
