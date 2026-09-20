import SwiftUI
import TransitCore

/// Whatever the last tap selected: a vehicle, a board, or a piece of track.
struct DetailSheet: View {
    @Bindable var model: AppModel
    /// Whether the sheet is standing at `.large`. Landscape compact cards hide
    /// the navigation chrome and the inner list; pulling up restores both.
    var expanded: Bool = true
    /// Dismissal is owned by the presenter.  Keeping the selection alive until
    /// the sheet has gone away prevents the panel from being replaced while
    /// UIKit is laying out its dismissal transition.
    let dismiss: () -> Void
    /// What the panel stands on. Clear in a sheet (the glass is already there).
    /// The landscape board is just a view, so it names the grey it sits on.
    var background: Color = .clear
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var landscapeCompact: Bool { verticalSizeClass == .compact && !expanded }

    private var isVehicle: Bool {
        switch model.selection {
        case .vehicle, .service: return true
        default: return false
        }
    }

    private var isBoard: Bool {
        switch model.selection {
        case .station, .platform: return true
        default: return false
        }
    }

    /// Compact vehicle cards hide the bar so the overview sits on the sheet.
    /// Landscape boards hide it because the station name and Done live on the
    /// chip row instead.
    private var hideNavigationBar: Bool {
        (landscapeCompact && isVehicle) || (verticalSizeClass == .compact && isBoard)
    }

    /// The granularity the measured card height is rounded up to.
    private static let foldStep: CGFloat = 2

    var body: some View {
        NavigationStack {
            panel
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
                // Landscape compact vehicle card: one blur window, no navigation
                // chrome. The line number and Done live in the bar we are hiding.
                .toolbar(hideNavigationBar ? .hidden : .automatic, for: .navigationBar)
        }
        .modifier(ClearNavigationBackground(style: background))
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
            model.updatePanelFold(step)
        }
    }

    /// Whatever is selected, without the chrome that carries it.
    private var panel: some View {
        ZStack {
            if background != .clear {
                background.ignoresSafeArea()
            }
            switch model.selection {
            case .none:
                // The sheet can outlive the selection by a frame — Done,
                // a swipe, a collapse onto the ride bar. Drawing a
                // "Nothing selected" page there is a flash of an empty
                // menu on the way out.
                Color.clear
            case .vehicle, .service:
                if let vehicle = model.selectedVehicle {
                    // A train standing at its terminus is shown as the
                    // working it leaves as, not the one it arrived on — that
                    // is the departure somebody on the platform is waiting
                    // for. See `AppModel.departingVehicle`.
                    VehiclePanel(
                        model: model,
                        vehicle: model.departingVehicle ?? vehicle,
                        arrivedAs: model.departingVehicle == nil ? nil : vehicle,
                        boardDeparture: {
                            if case let .service(_, departure) = model.selection {
                                return departure
                            }
                            return nil
                        }(),
                        compactOverview: landscapeCompact
                    )
                    .menuAppearance()
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
                    .menuAppearance()
                } else {
                    ProgressView()
                        .menuAppearance()
                }
            case let .station(board):
                // No subtitle: "Departures and arrivals" captioned two
                // sections already headed Departures and Arrivals, and the
                // line it cost is a line of the board.
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    BoardPanel(model: model, title: board.name,
                               subtitle: nil,
                               now: model.clock.nowSeconds(), entries: board.departures,
                               serving: board.serving, isLoading: board.isLoading,
                               dismiss: dismiss)
                }
            case let .platform(board):
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    BoardPanel(
                        model: model,
                        title: board.name,
                        subtitle: platformSubtitle(board),
                        now: model.clock.nowSeconds(), entries: board.departures,
                        serving: board.serving, isLoading: board.isLoading,
                        dismiss: dismiss
                    )
                }
            case let .track(lines):
                TrackPanel(model: model, lines: lines)
            case let .line(line):
                LinePanel(model: model, line: line)
            case let .choices(options):
                ChoicePanel(model: model, options: options)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .menuAnimation(value: model.selectedVehicle != nil)
        .menuAnimation(value: model.selectedVehicleMissing)
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

/// Animate content at its layout owner so inserted rows and their neighbours
/// move together. Callers use visible structure, never the map's ticking clock,
/// as the trigger; ordinary countdown refreshes should not restart the motion.
extension View {
    func menuAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(MenuAnimation(value: value))
    }

    func menuAppearance() -> some View {
        modifier(MenuAppearance())
    }
}

private struct MenuAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : MenuMotion.animation, value: value)
    }
}

enum MenuMotion {
    static let animation = Animation.smooth(duration: 0.45)
}

private struct MenuAppearance: ViewModifier {
    func body(content: Content) -> some View {
        // Scaling a material-backed list resamples its entire background and
        // makes an ordinary data update look like a flash of the whole sheet.
        content.transition(.opacity)
    }
}

/// NavigationStack's default fill is black. Clear it in a sheet so the glass
/// shows through; in the landscape board, paint the same grey the lists sit on.
private struct ClearNavigationBackground: ViewModifier {
    let style: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.containerBackground(style, for: .navigation)
        } else {
            content.background(style.ignoresSafeArea())
        }
    }
}

extension Color {
    /// Grouped-list grey. Dark mode's `systemGroupedBackground` is black;
    /// this is the surface the inset rows sit on.
    static let menuSurface = Color(uiColor: .systemGray5)
}
