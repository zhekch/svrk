import Combine
import SwiftUI
import TransitCore


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
            if showsLiveDot {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(lit ? 1 : 0.42)
            }
            offerText
        }
        .font(.title3)
        // Long line-and-destination pairs shrink rather than clip the line
        // itself: the number is the half that identifies the train.
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 20)
        // The handle and home indicator belong to the sheet chrome. The offer
        // itself occupies the remaining statement-sized space rather than
        // being pinned under the handle, so both train and station names sit
        // at the visual centre of the compact detent.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        .accessibilityIdentifier("Live ride pill")
    }

    private var showsLiveDot: Bool {
        if case .ride = offer { return true }
        return false
    }

    private var shouldPulse: Bool { showsLiveDot && !reduceMotion && !lowPower }
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
            .presentationCornerRadius(RidePill.height)
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
}
