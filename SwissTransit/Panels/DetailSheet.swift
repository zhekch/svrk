import SwiftUI
import TransitCore

/// Whatever the last tap selected: a vehicle, a board, or a piece of track.
struct DetailSheet: View {
    @Bindable var model: AppModel
    /// Dismissal is owned by the presenter.  Keeping the selection alive until
    /// the sheet has gone away prevents the panel from being replaced while
    /// UIKit is laying out its dismissal transition.
    let dismiss: () -> Void

    /// The granularity the measured card height is rounded up to.
    private static let foldStep: CGFloat = 2

    var body: some View {
        NavigationStack {
            Group {
                switch model.selection {
                case .none:
                    ContentUnavailableView("Nothing selected", systemImage: "hand.tap")
                case .vehicle:
                    if let vehicle = model.selectedVehicle {
                        // A train standing at its terminus is shown as the
                        // working it leaves as, not the one it arrived on — that
                        // is the departure somebody on the platform is waiting
                        // for. See `AppModel.departingVehicle`.
                        VehiclePanel(
                            model: model,
                            vehicle: model.departingVehicle ?? vehicle,
                            arrivedAs: model.departingVehicle == nil ? nil : vehicle
                        )
                    } else if model.selectedVehicleMissing {
                        // Asked for, and there is no such vehicle. Nearly
                        // always a run that has finished, or one the board
                        // listed by a name the fleet folded into another
                        // working. See `AppModel.selectedVehicleMissing`.
                        ContentUnavailableView(
                            "Not running",
                            systemImage: "clock.badge.xmark",
                            description: Text("This service is not on the map right now.")
                        )
                    } else {
                        ProgressView()
                    }
                case let .station(board):
                    // No subtitle: "Departures and arrivals" captioned two
                    // sections already headed Departures and Arrivals, and the
                    // line it cost is a line of the board.
                    BoardPanel(model: model, title: board.name,
                               subtitle: nil,
                               now: board.now, entries: board.departures,
                               serving: board.serving)
                case let .platform(board):
                    BoardPanel(
                        model: model,
                        title: board.name,
                        subtitle: platformSubtitle(board),
                        now: board.now, entries: board.departures,
                        serving: board.serving
                    )
                case let .track(lines):
                    TrackPanel(model: model, lines: lines)
                case let .line(line):
                    LinePanel(model: model, line: line)
                case let .choices(options):
                    ChoicePanel(model: model, options: options)
                }
            }
            .toolbar {
                // The item is always here and only its *content* comes and
                // goes. Adding and removing the `ToolbarItem` itself re-runs
                // the navigation bar's own layout, which with the model
                // changing underneath it is the loop UIKit reports as
                // "observation tracking feedback loop detected".
                //
                // Empty rather than hidden where there is nowhere to go back
                // *to*: an `opacity(0)` label still leaves the bar drawing the
                // glass capsule behind it, so the button was invisible and its
                // background was not. The sheet is opened by tapping the map,
                // and on that first panel a back button would either do
                // nothing or close it, which is what Done is for.
                ToolbarItem(placement: .topBarLeading) {
                    if model.canGoBack {
                        Button { model.goBack() } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.backward")
                                    .font(.body.weight(.semibold))
                                Text("Back")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss)
                }
            }
        }
        // Read here rather than in `ContentView`: preferences do not cross out
        // of a sheet into the view that presents it, so the height travels on
        // the model instead.
        //
        // Quantised, and that is the whole point of it. Writing the height
        // resizes the sheet, which re-lays out the card, which measures again —
        // so two values a point apart alternate forever, and a threshold does
        // not help because each change clears it. Landing every measurement on
        // the same step makes the second pass a no-op and the loop ends.
        .onPreferenceChange(PanelFoldKey.self) { fold in
            guard fold > 0 else { return }
            let step = (fold / Self.foldStep).rounded() * Self.foldStep
            if model.panelFold != step { model.panelFold = step }
        }
    }

    private func platformSubtitle(_ board: PlatformBoard) -> String {
        if board.stationOnly {
            // Said plainly rather than passed off as a platform board: where the
            // timetable does not split a station into platforms, these are the
            // station's departures.
            return "Whole station's departures"
        }
        let noun = board.rail ? "Platform" : "Stop"
        if let code = board.code, !code.isEmpty { return "\(noun) \(code)" }
        if let assigned = board.assigned {
            // Ours, not signage — and the panel says so, because a letter that
            // looks like a sign and is not would send somebody to the wrong kerb.
            return "\(noun) \(assigned) (auto generated)"
        }
        return noun
    }
}
