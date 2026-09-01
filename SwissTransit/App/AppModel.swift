import Foundation
import Observation
import SwiftUI
import Network
import os
import TransitCore

/// What the panel is currently showing.
enum Selection: Equatable {
    case none
    case vehicle(String)
    /// A departure offered by a board but not presently represented by a map
    /// vehicle. The time distinguishes a recurring trip on adjacent days and
    /// identifies the stop-time row the reader tapped.
    case service(String, departure: Timestamp)
    case station(StationBoard)
    case platform(PlatformBoard)
    case track([RelationStore.LineOnWay])
    /// One line, whole: everywhere it goes, drawn on the map and listed in
    /// order. Opened from a line named in a panel rather than from the map —
    /// see `AppModel.openRoute(relation:)`.
    case line(RouteLine)
    /// Several things were under one tap and the person who made it gets to
    /// say which they meant. See `ChoicePanel`.
    case choices([TapChoice])
}

/// What the locate button is doing, and so what it says.
///
/// Three states rather than two because "put me on the map" and "turn the map
/// the way I am facing" are different requests, and every other map on this
/// phone answers them from the same button. Each press is the next one along.
enum LocateMode {
    /// The camera is wherever it was left. The map does not follow.
    case unfocused
    /// The camera is following the user, north up.
    case focused
    /// The camera is following the user and turning with them.
    case bearing
}

/// Which live transit sources the app is allowed to ask.
///
/// This is one authority for every network producer rather than a refresh
/// switch beside several requests that ignored it. The on-device timetable is
/// enough to keep the map useful in every mode.
enum TransitDataMode: String, CaseIterable, Identifiable, Sendable {
    /// The national realtime feed, disruptions and engineering works, plus
    /// proactive OJP timing and formation lookups for vehicles in view.
    case all = "All"
    /// Keep GTFS-Realtime current, but ask OJP and the formation service only
    /// for a vehicle somebody opens.
    case onDemand = "On demand"
    /// No live transit-data requests at all.
    case off = "Off"

    var id: String { rawValue }

    /// GTFS-Realtime is the one continuous source retained by On demand. Five
    /// minutes keeps it useful without turning that smaller mode into a hidden
    /// high-frequency download.
    var refreshInterval: TimeInterval? { self == .off ? nil : 300 }

    var detail: String {
        switch self {
        case .all:
            return "All live data, including disruptions and engineering works."
        case .onDemand:
            return "GTFS Realtime, with OJP and train formations only for vehicles you open."
        case .off:
            return "No live transit-data requests. The on-device timetable still draws the map."
        }
    }
}

extension Duration {
    /// The whole thing as seconds, which `Duration` will only give in halves.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// One cold launch, told in the order it happens.
struct BootProgress: Equatable {
    /// The steps of `AppModel.start()`, in the order it takes them.
    ///
    /// The weights are roughly how long each one costs on a device with a
    /// warm container — the packed read dominates, and a bar that spends
    /// nine tenths of its life in one step is a bar that looks stuck. They
    /// do not have to be right to the millisecond; they have to stop the
    /// bar from lying about which half of the wait is left.
    enum Stage: Int, CaseIterable, Equatable {
        case reading
        case caches
        case learned
        case disruptions
        case drawing
        case ready

        var title: String {
            switch self {
            case .reading: return "Reading the transit network"
            case .caches: return "Opening the route cache"
            case .learned: return "Recalling known trains"
            case .disruptions: return "Reading stored notices"
            case .drawing: return "Placing today's services"
            case .ready: return "Ready"
            }
        }

        var detail: String {
            switch self {
            case .reading: return "Stops, route relations and the railway graph"
            case .caches: return "Routed legs kept from earlier runs"
            case .learned: return "Formations and layouts this app has been told"
            case .disruptions: return "Stored notices, before the network answers"
            case .drawing: return "From the printed timetable — no network needed"
            case .ready: return "Opening the map"
            }
        }

        /// How much of the wait this step is, before it starts.
        var start: Double {
            switch self {
            case .reading: return 0
            case .caches: return 0.50
            case .learned: return 0.66
            case .disruptions: return 0.72
            case .drawing: return 0.80
            case .ready: return 1
            }
        }
    }

    var stage: Stage = .reading {
        didSet {
            guard stage != oldValue else { return }
            let now = Date()
            spent.append(Step(stage: oldValue, seconds: now.timeIntervalSince(entered)))
            entered = now
        }
    }

    /// How far through the whole launch, 0 to 1. Read straight off the
    /// stage: nothing inside a step reports on itself, and a bar that
    /// creeps inside a step it cannot measure is a bar making things up.
    var fraction: Double { stage.start }

    // MARK: - What it actually cost

    /// When the step now running began, and what every finished one took.
    ///
    /// The weights above are a guess, and a guess is all a progress bar needs.
    /// This is not for the bar — it is for the question the bar cannot answer:
    /// a cold launch on a phone is several times a warm one on a desk, the
    /// files are mapped rather than read so the cost is page faults nobody can
    /// see, and without a number per step the only way to find the slow one is
    /// to guess again. Logged once, at `.ready`.
    struct Step: Equatable {
        var stage: Stage
        var seconds: TimeInterval
    }

    private var entered = Date()
    private var spent: [Step] = []
    private let began = Date()

    /// A line per step and a total, in milliseconds.
    func report() -> String {
        let steps = spent
            .map { String(format: "%@ %.0fms", String(describing: $0.stage), $0.seconds * 1000) }
            .joined(separator: ", ")
        return String(format: "%@ | total %.0fms", steps, Date().timeIntervalSince(began) * 1000)
    }
}

@MainActor
@Observable
final class AppModel {
    let fleet: Fleet
    let clock = Clock()

    private(set) var loaded: Fleet.Loaded?
    private(set) var status = FleetStatus.empty
    private(set) var isLoading = true
    private(set) var isRefreshing = false

    /// What the cold launch is doing, and how far through it is.
    ///
    /// `isLoading` on its own is the same boolean problem `isRefreshing` had:
    /// a cold launch reads 59 MB of packed data, opens three on-disk caches and
    /// replays a snapshot, and for all of it the curtain said one unchanging
    /// sentence over a black screen. The stages below are the steps `start()`
    /// already runs in order — the only new thing is that each one says so
    /// before it begins. See `LoadingCurtain`.
    private(set) var boot = BootProgress()


    /// What the refresh in progress is doing, sampled off the fleet's monitor.
    ///
    /// `isRefreshing` on its own is a boolean over a wait that can run to
    /// minutes, and a boolean that never changes is indistinguishable from a
    /// hang. This is the same fact with the detail left in. See
    /// `RefreshProgress`.
    private(set) var progress = RefreshProgress()

    /// What the platform says is left of the SIRI-ET budget, refreshed
    /// whenever a call is answered. A 429 is otherwise a four-character error
    /// message with no way to tell "wait a minute" from "wait until midnight".
    private(set) var limits: OTDClient.Limits?

    /// What the map draws this frame.
    private(set) var vehicles: [VehicleSnapshot] = []

    /// The vehicles that are close enough to be drawn as vehicles rather than
    /// as dots, with their bodies laid out along the track they are on.
    ///
    /// Built here rather than in the map for two reasons. It is the same work
    /// either way and this is where the frame already is — and a tap has to be
    /// answered against the shape that was actually drawn, which means the
    /// answer and the drawing have to come from one list rather than from two
    /// that agree most of the time.
    private(set) var vehicleShapes: [VehicleFootprint] = []
    /// The last footprint built for each vehicle, by id.
    ///
    /// Read by the map as well as by taps: the followed vehicle's footprint is
    /// translated per display refresh rather than rebuilt, so the map needs the
    /// one the model last produced. See `MapCoordinator.followFrame`.
    private(set) var shapesByID: [String: VehicleFootprint] = [:]

    /// Which tick `vehicles` and `vehicleShapes` were last built for, and which
    /// one `stops` last changed on.
    ///
    /// **Deliberately not observed.** They exist so the map can tell "I have
    /// already drawn this" from "there is something new", and the whole point
    /// is that asking the question is free — an observed read taken inside
    /// `updateUIView` is a *dependency*, and a dependency on something that
    /// changes thirty times a second is a SwiftUI update thirty times a second.
    ///
    /// That was the shape of the fault this pair fixes. `TransitMap.updateUIView`
    /// calls `draw()`, `draw()` read `model.vehicles`, and SwiftUI recorded the
    /// read: every tick's write of `vehicles` then invalidated the
    /// representable, which called `updateUIView`, which rebuilt and re-uploaded
    /// every vehicle, every footprint and every extrusion slab a second time.
    /// The map was doing two full frames of work per tick and the tick counter
    /// still read thirty, because the counter measures the loop rather than the
    /// renderer underneath it.
    @ObservationIgnored private(set) var frameVersion = 0
    @ObservationIgnored private(set) var stopsVersion = 0

    /// Fixed cableway infrastructure in and around the viewport, sourced from
    /// the full service day rather than only the vehicles alive this minute.
    @ObservationIgnored private(set) var cableways = Cableway.Plan()
    @ObservationIgnored private(set) var cablewaysRevision = 0
    private var cablewaysViewport: BBox?
    private var cablewaysDay: Int?

    /// What each vehicle is made of: the shipped table of what every line
    /// normally runs, plus whatever the formation service has told us about
    /// individual trains since.
    let layouts = VehicleLayoutStore(
        url: URL.applicationSupportDirectory.appendingPathComponent("vehicle-layouts.json")
    )

    /// Which of the vehicles on the map this phone is inside, if any.
    ///
    /// Owned here rather than by the view because it is fed from two places at
    /// once — the map's location stream and the draw loop's own tick — and
    /// neither of them is a `body`. See `RideWatch`.
    let rides = RideWatch()
    private(set) var stops: [StopPlace] = []
    /// The individual platforms and kerbs, laid out so no two plates cover each
    /// other. Only from `plateMinZoom`; below that the stop dot is the whole
    /// story and hundreds of plates are noise.
    private(set) var plates: [PlacedPlate] = []
    /// Bumped whenever `plates` is rebuilt, so the map can skip the work of
    /// rebuilding features that have not changed.
    private(set) var plateRevision = 0
    private(set) var selectedGeometry: JourneyGeometry?
    /// Advances only when the highlighted route changes. The map uses this
    /// rather than treating every live-position tick as a route update.
    private(set) var selectedGeometryRevision = 0
    private(set) var selectedVehicle: VehicleSnapshot?

    /// Set when a vehicle was asked for by id and the fleet has no such
    /// vehicle — as against not having been asked yet.
    ///
    /// The panel shows a spinner while a selection is being fetched, which is
    /// right, and it has no other way to tell "still coming" from "there is
    /// nothing to come". A board row naming a run the fleet cannot resolve
    /// therefore span for ever. The lookup itself is fixed — see
    /// `Fleet.drawnJourney` — and this is the guard that stops any *future*
    /// unresolvable id doing the same thing: a dead end is a sentence, not a
    /// spinner.
    private(set) var selectedVehicleMissing = false

    /// The halves of a splitting train that the reader is *not* standing in,
    /// each drawn from where the two part company.
    ///
    /// A train that splits is filed as two workings coupled for the first part
    /// of the run, and the map has only ever known about the one that was
    /// tapped. So an RE from Bern drew a line to Brig and said nothing at all
    /// about Zweisimmen, when half the train the reader is looking at is going
    /// there. Only the branches are kept: every working lists the trunk, and
    /// drawing it twice makes the shared part look heavier than the parts that
    /// differ.
    ///
    /// A list rather than one, because the reader's own train is not always one
    /// of the halves. The S44 into Burgdorf ends there and parts into two
    /// workings, one for Solothurn and one for Sumiswald-Grünen, and neither of
    /// them is the journey on the panel.
    private(set) var selectedBranches: [RouteBranch] = []

    struct RouteBranch: Equatable, Identifiable {
        var id: String { journeyID ?? destination ?? splitAt }
        /// From the separation onward, so the trunk stays drawn once.
        var path: [Coord]
        /// Where each of the branch's own calls sits on that line, so its stops
        /// are marked the way the rest of the route's are.
        var stops: [Coord]
        /// The calls themselves, which is what the stop list under the panel
        /// shows once a reader picks this direction.
        var calls: [Call]
        /// Whether the line follows mapped track or is a chord between stops —
        /// the same distinction the main route draws solid or dashed.
        var exact: Bool
        var destination: String?
        var journeyID: String?
        /// The coaches that go this way, where the formation says which.
        var coaches: ClosedRange<Int>?
        var splitAt: String
    }

    /// The working the selected vehicle *becomes*, while it stands at the
    /// terminus it arrived on holding the platform for a later departure.
    ///
    /// A train sitting in Bern that came in as the IR16 from Zürich is, to
    /// anybody looking at it, the IR16 that leaves for Zürich in eight minutes.
    /// The panel says the second and notes the first, because what the marker
    /// was tapped as is over and the departure has not happened yet.
    private(set) var departingVehicle: VehicleSnapshot?

    /// How tall the detail sheet has to be to show a panel's summary and none
    /// of the list under it. Written by `DetailSheet`, read by `ContentView`.
    var panelFold: CGFloat = 0

    /// What the selected train is made of, where the formation service knows.
    ///
    /// A separate interface with a separate token, asked once per train and
    /// held — see `FormationService`. Nil for everything it has nothing for,
    /// which is every bus, every tram, and the trains of the companies outside
    /// the eleven that publish. A silence, and the panel simply omits the
    /// section rather than explaining itself.
    private(set) var formation: TrainFormation?
    /// Which train `formation` describes, so a panel re-reading fifteen times a
    /// second asks the network once.
    private var formationKey: FormationKey?
    private let formations = FormationService(token: Secrets.formationToken)

    /// How full the selected vehicle is, where OJP publishes a forecast.
    ///
    /// Nil for everything it has nothing for, which is most buses and every
    /// operator that does not count passengers. A silence, and the panel omits
    /// the meter rather than drawing an empty train.
    private(set) var vehicleLoad: JourneyLoad?

    /// What OJP last said about the selected vehicle's timings.
    ///
    /// Nil means one of two different things and the panel has to tell them
    /// apart: either the run publishes no live data — it has no journey
    /// reference to ask under, which is 20.7% of a weekday — or nothing has been
    /// asked yet. Neither is a claim that the train is running to time.
    private(set) var liveTiming: JourneyTiming?

    /// When the drawn timetable window was last checked against the clock.
    private var lastWindowCheck: Double = 0
    /// Which journey `vehicleLoad` describes, so a panel re-reading fifteen
    /// times a second asks the network once.
    private var loadKey: LoadService.Key?
    private let loads = LoadService(token: Secrets.ojpToken)
    /// Foreground requests belonging to the selected panel. These used to be
    /// fire-and-forget tasks, so changing selection or leaving the app did not
    /// cancel their sockets and stale answers could still mutate the new card.
    private var selectionTask: Task<Void, Never>?
    private var occupancyTask: Task<Void, Never>?
    private var occupancyVehicleID: String?
    private var occupancyRequestGeneration: UInt64 = 0
    private var formationTask: Task<Void, Never>?
    private var formationRequestGeneration: UInt64 = 0
    private var branchTask: Task<Void, Never>?
    private var branchRequestGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0

    /// Disruption notices, from both halves of SIRI-SX. See `SituationService`.
    private let situations = SituationService(token: Secrets.sxToken)
    /// What is wrong with the vehicle on the panel, worst first.
    private(set) var vehicleDisruptions: [Situation] = []
    /// What is wrong at the stop whose board is open.
    private(set) var stopDisruptions: [Situation] = []

    /// The two halves, split by which feed they came from and shown in
    /// different places.
    ///
    /// A broken-down train and a footbridge closed for the autumn are both
    /// "disruptions" to the feed and are nothing alike to a passenger. The
    /// incident wire goes above the stop list, where it can change whether the
    /// list is worth reading at all; the works catalogue goes below it, because
    /// it is background a reader may want and never the first thing they need.
    var vehicleAlerts: [Situation] { vehicleDisruptions.filter { !$0.planned } }
    var vehicleWorks: [Situation] { vehicleDisruptions.filter(\.planned) }
    var stopAlerts: [Situation] { stopDisruptions.filter { !$0.planned } }
    var stopWorks: [Situation] { stopDisruptions.filter(\.planned) }

    /// Where the formation stands for whatever the panel is showing.
    ///
    /// The difference between "this is a bus" and "this is a train the service
    /// covers and has nothing for right now" is the whole reason this exists.
    /// Drawn as a silence, the second reads as the app being broken — the
    /// operator's own app has the formation, so where is ours? Saying it costs
    /// one line and answers the question.
    enum FormationState: Equatable {
        /// Not something the service answers about at all: a bus, a tram, or a
        /// railway outside the eleven that publish. No line is drawn.
        case notApplicable
        case loading
        case ready(TrainFormation)
        /// Asked, and the service had nothing.
        case unavailable
    }

    private(set) var formationState: FormationState = .notApplicable

    /// The moments the map can be asked to draw.
    ///
    /// A year, from the packed timetable — see `Fleet.drawableSpan`. The
    /// modest default stands only for the moment before the file is open,
    /// which is well before the time control can be reached.
    private(set) var timeSpan: ClosedRange<Date> = {
        let now = Date()
        return now.addingTimeInterval(-3600)...now.addingTimeInterval(3600)
    }()

    /// How far either side of now the control may go, in minutes.
    var scrubRange: ClosedRange<Double> {
        let now = Date().timeIntervalSince1970
        let low = (timeSpan.lowerBound.timeIntervalSince1970 - now) / 60
        let high = (timeSpan.upperBound.timeIntervalSince1970 - now) / 60
        return low...high
    }

    var selection: Selection = .none {
        didSet {
            // Nothing to do when it lands on what it already was. Dismissing the
            // sheet writes `.none` back through its own binding on top of the
            // `.none` Done just set, and that second write used to clear the
            // history and start another refresh underneath a navigation bar
            // already being torn down.
            guard selection != oldValue else { return }
            // A tap on the map starts a fresh trail. Only the panels navigate,
            // and they say so by going through `push`.
            if !isNavigating, !history.isEmpty { history.removeAll() }
            if case .vehicle = selection {
                vehicleFollow = .centred
            } else {
                vehicleFollow = .off
            }
            // A frame, not just a refresh. What is selected decides the ring
            // round a vehicle, the outline on a platform and the highlighted
            // station, and all three are drawn on the tick — which below zoom 9
            // is once a second. Waiting that long to acknowledge a tap reads as
            // a tap that did not land. Coalesced, so a sheet writing `.none`
            // back over its own dismissal still costs one.
            cancelSelectionWork(clearPresentation: true)
            requestTick()
            scheduleSelectionRefresh()
        }
    }

    /// Where the sheet has been, so a panel opened from another panel can go
    /// back to it.
    ///
    /// A tap on the map is a new question and clears this; following a link
    /// inside the sheet — this train, what else calls there, which of those is
    /// running — is one continuous line of enquiry, and losing your place in it
    /// meant finding the marker on the map again.
    private(set) var history: [Selection] = []
    private var isNavigating = false

    /// Bumped every time a panel opens another panel.
    ///
    /// The sheet collapses back to its resting height when it does, because
    /// following a link is nearly always a question about somewhere *else* —
    /// this train stops at Thun, what else calls there — and the answer is on
    /// the map behind a sheet that is still standing at full height.
    private(set) var navigations = 0

    var canGoBack: Bool { !history.isEmpty }

    /// Bumped when a tap answered with nothing while a panel was open.
    ///
    /// A tap on bare map with a panel open means "close this", and closing has
    /// to happen the way Done closes it: dismiss the sheet first, and clear the
    /// selection from `onDismiss`, once UIKit has finished with the transition.
    ///
    /// Writing `.none` here instead is what froze the app. It swaps the panel
    /// for the empty one *underneath* a custom-detent sheet that is already
    /// mid-dismissal, so the sheet re-measures against content that changed out
    /// from under it — and while a vehicle is being followed the map is pushing
    /// a new frame every 33 ms into the same layout pass. The main thread never
    /// comes back out of the `CATransaction` commit: sampled there it is 100%
    /// inside `_UIHostingView.layoutSubviews`, adding and removing the panel's
    /// scroll view from the window over and over. It looks like a hang and ends
    /// as a watchdog kill. See the note on `detailSheetPresented` in
    /// `ContentView`, which records the same failure on the Done path.
    private(set) var dismissRequests = 0

    /// Close whatever is open, without touching the selection.
    func requestDismiss() {
        guard selection != .none else { return }
        dismissRequests += 1
    }

    /// Open something from inside a panel, keeping what it was opened from.
    private func push(_ next: Selection) {
        guard next != selection else { return }
        if selection != .none { history.append(selection) }
        withoutClearingHistory { selection = next }
        navigations += 1
    }

    /// Replace what is on screen with a better answer to the same question —
    /// a board refilled from the mirror — without it counting as a move.
    private func replace(_ next: Selection) {
        withoutClearingHistory { selection = next }
    }

    private func withoutClearingHistory(_ body: () -> Void) {
        isNavigating = true
        body()
        isNavigating = false
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        withoutClearingHistory { selection = previous }
        navigations += 1
        // Put the map back where it was too. Coming forward moves the camera to
        // whatever was opened, so coming back to a stop list and leaving the map
        // on the station three stops away is half a move: the panel says one
        // place and the map shows another.
        Task { await focusOnSelection() }
    }

    /// Move the camera to whatever is selected, where that has a position.
    ///
    /// A vehicle is looked up rather than remembered — it has been moving all
    /// the while the panel it was opened from was on screen, and the point worth
    /// showing is where it is now, not where it was when it was tapped.
    private func focusOnSelection() async {
        switch selection {
        case .none, .track, .choices:
            // Neither has one point. A track is every way under the tap, and a
            // list of choices is the tap itself — and in both cases the map is
            // already looking at exactly the right place.
            return
        case let .line(line):
            // A line has no single point either, but unlike those two it has an
            // extent — and the extent is the answer. Coming back to it from a
            // stop three towns along has to put the whole run on screen again,
            // or Back leaves the panel describing Domodossola to Bern with the
            // map still parked on one platform in Kandersteg.
            onFrameRoute?(line.geometry?.path ?? [])
        case let .vehicle(id):
            guard let vehicle = await fleet.journey(id: id, at: clock.nowSeconds()) else { return }
            onFocus?(Coord(lon: vehicle.lon, lat: vehicle.lat), max(zoom, 14))
        case .service:
            // A scheduled service has no honest current point to centre on and
            // no map vehicle to follow.
            return
        case let .station(board):
            onFocus?(Coord(lon: board.lon, lat: board.lat), max(zoom, 14))
        case let .platform(board):
            onFocus?(Coord(lon: board.lon, lat: board.lat), max(zoom, 14))
        }
    }

    /// Open what the compact location offer is naming, and go to it.
    ///
    /// These are the same selections a map tap would make, so everything
    /// downstream — the panel, the highlighted route, the formation lookup —
    /// is the code that already exists rather than a second path through it.
    func openOffer() {
        guard let offer = rides.offering else { return }
        switch offer {
        case let .ride(ride):
            openRide(ride)

        case let .nearby(board):
            switch board {
            case let .station(station):
                selection = .station(station)
                onFocus?(board.coordinate, max(zoom, 14))
                if station.departures.isEmpty {
                    let now = clock.nowSeconds()
                    Task { [weak self] in
                        await self?.fillStationFromMirror(placeId: station.id, at: now)
                    }
                }
            case let .platform(platform):
                selection = .platform(platform)
                onFocus?(board.coordinate, max(zoom, 14))
            }
        }
    }

    /// Open a service offer. The camera needs one special rule when the map is
    /// already following it: the follower owns the centre, so only zoom here.
    private func openRide(_ ride: RideWatch.Ride) {
        // The offer is not consumed by being taken. It stays the bar the sheet
        // stands on, so closing this panel lands back on the train rather than
        // on nothing. Only a swipe off the bottom retires it — `RideWatch`.
        selection = .vehicle(ride.id)
        Task { [weak self] in
            guard let self,
                  let vehicle = await fleet.journey(id: ride.id, at: clock.nowSeconds())
            else { return }
            guard case let .vehicle(selected) = selection, selected == ride.id else { return }
            // Closer than `focusOnSelection` goes for a tap. A tap already had
            // the vehicle on screen; this one may be arriving from a map
            // showing the whole country, and the train is the subject.
            //
            // Following owns the camera centre every display frame. Starting a
            // second ease with a centre of its own made the train jump in front
            // of the sheet and then spring back as those two writers alternated.
            // Let the follower place it and animate only the independent zoom.
            if isFollowingVehicle {
                onZoom?(max(zoom, 15))
            } else {
                onFocus?(Coord(lon: vehicle.lon, lat: vehicle.lat), max(zoom, 15))
            }
        }
    }

    /// Modes the user has switched off.
    var hiddenModes: Set<Mode> = Settings.choices("hiddenModes", or: []) {
        didSet {
            guard hiddenModes != oldValue else { return }
            Settings.set(hiddenModes, "hiddenModes")
        }
    }
    var showStops = Settings.bool("showStops", or: true) {
        didSet {
            guard showStops != oldValue else { return }
            Settings.set(showStops, "showStops")
        }
    }

    /// Whether vehicles may become flat footprints or solid models when the
    /// map is close enough. Off leaves every mode as a dot and also removes the
    /// fixed structures and ropes drawn for cableways.
    var detailedVehicles = Settings.bool("detailedVehicles", or: true) {
        didSet {
            guard detailedVehicles != oldValue else { return }
            Settings.set(detailedVehicles, "detailedVehicles")
            if detailedVehicles, started, !backgroundWorkSuspended,
               powerFactor == 1, dataMode == .all {
                startLearning()
            } else if !detailedVehicles {
                learningTask?.cancel()
                learningTask = nil
            }
            requestTick()
        }
    }

    /// Whether each wagon is drawn with its outline, nose tick and attitude.
    ///
    /// Debug: heading, grade and the euler triple handed to the renderer, so a
    /// coach sitting on its tail can be told apart from one whose heading
    /// never turned. Off by default; the features are not built while it is.
    var showWagonHitboxes = Settings.bool("showWagonHitboxes", or: false) {
        didSet {
            guard showWagonHitboxes != oldValue else { return }
            Settings.set(showWagonHitboxes, "showWagonHitboxes")
            requestTick()
        }
    }

    /// Whether the frame readout is drawn over the map.
    var showDiagnostics = Settings.bool("showDiagnostics", or: false) {
        didSet {
            guard showDiagnostics != oldValue else { return }
            Settings.set(showDiagnostics, "showDiagnostics")
            // Battery level costs a notification subscription, so it is only
            // asked for while somebody is reading it.
            DeviceLoad.watchBattery(showDiagnostics)
        }
    }

    /// What the last frame actually did. Written only while the readout is on,
    /// because an `@Observable` write invalidates every view that reads it and
    /// this one would fire thirty times a second.
    private(set) var frameStats = FrameStats()

    struct FrameStats: Equatable {
        var vehicles = 0
        var shapes = 0
        /// Polygons pushed to the shape source — bodies plus everything painted
        /// on them, which is the number that actually costs a frame.
        var parts = 0
        var stops = 0
        var tracks = 0
        /// Frames the map actually rendered, per second.
        ///
        /// Not the same thing as the tick rate and not derived from it. Mapbox
        /// renders on its own thread from data already uploaded, so panning and
        /// zooming stay at the display's rate whatever this app is doing — the
        /// two numbers are only ever equal when nothing but the vehicles is
        /// moving, because then a render happens per tick and no more.
        var renderFps = 0.0
        /// Model updates per second: how often positions are recomputed and new
        /// geometry pushed to the map. This is what decides whether a vehicle
        /// glides or steps; it has nothing to do with how smoothly the map
        /// scrolls under a finger.
        var ticks = 0.0
        /// What the tick loop is currently asking for — a function of zoom and
        /// of the smooth-movement setting. A number below it is the interesting
        /// case; a number at it means there is nothing to fix.
        var targetTicks = 0.0
        var zoom = 0.0
        var centre = Coord(lon: 0, lat: 0)
        var metresPerPoint = 0.0
        var learnedTrains = 0
        var learnedLines = 0
        var asked = 0
        /// Background formation requests in the last minute.
        ///
        /// One caller of one interface, and it stays because it answers a
        /// different question from `net` below: this is the app deciding to go
        /// and look something up, which is a behaviour worth watching on its
        /// own. `net` is everything the app asks for, formations included.
        var askRate = 0
        /// Every request the app makes, and what it costs — see `NetworkMeter`.
        var net = NetworkMeter.Reading()
        /// What the open vehicle is being drawn from, in words. The one line
        /// that makes a wrong drawing reportable: without it "that train looks
        /// wrong" cannot be told from "that train is wrong", because the drawing
        /// does not say whether it came from the shipped table or from the
        /// service, or how long it thinks the train is.
        var selected = ""
        /// What the ride watch makes of the last minute of fixes. See
        /// `RideWatch.summary`.
        var ride = ""
        var load = DeviceLoad.Sample()
        /// Where a tick's milliseconds actually go. See `TickCost`.
        var cost = TickCost()

        /// The tick, broken into the four things it does, in milliseconds.
        ///
        /// `ticks` says the loop is behind; it cannot say what it is behind *on*,
        /// and the four candidates fail in completely different ways. The fleet
        /// figure in particular is wall clock across an `await`, not work: the
        /// query itself is a fraction of a millisecond, so a large number there is
        /// the tick queued behind something else on the fleet actor — a live
        /// refresh parsing the national feed, a timetable window being expanded, a
        /// board being built — rather than the query being slow. Knowing which of
        /// those it is, from a real phone, is the whole reason this is on screen.
        ///
        /// Smoothed the same way `smoothedFrameSeconds` is, so one slow tick reads
        /// as a bump rather than as a collapse.
        struct TickCost: Equatable {
            /// Waiting for `Fleet.vehicles` — queueing included.
            var fleet = 0.0
            /// Building the footprints, on the main actor.
            var shapes = 0.0
            /// Handing the frame to the renderer: `onFrame`, which is the whole of
            /// `MapCoordinator.draw`.
            var push = 0.0
            /// Everything after the frame goes out — the camera, the measurement.
            var rest = 0.0

            var total: Double { fleet + shapes + push + rest }

            /// Folded in at the same weight as the frame clock beside it.
            mutating func blend(fleet: Double, shapes: Double, push: Double, rest: Double) {
                func ease(_ held: Double, _ found: Double) -> Double {
                    held == 0 ? found : held * 0.85 + found * 0.15
                }
                self.fleet = ease(self.fleet, fleet)
                self.shapes = ease(self.shapes, shapes)
                self.push = ease(self.push, push)
                self.rest = ease(self.rest, rest)
            }
        }
    }

    /// How the camera is attached to the vehicle that is open.
    ///
    /// Three states rather than two, and the same three the locate button
    /// already offers for *you* — because they are the same three questions
    /// about somebody else. "Where is it", "keep it in front of me", and "show
    /// me what the driver sees" are different requests, and the last one is the
    /// only way a map answers "which side does it leave from" without words.
    ///
    /// A freshly opened vehicle starts centred; this is where the reader has
    /// moved that camera attachment since.
    enum VehicleFollow: Equatable {
        /// Open, and the camera is wherever it was left.
        case off
        /// The camera holds the vehicle, north up.
        case centred
        /// And turns with it, so the vehicle always runs up the screen.
        case bearing

        /// The next one along, which is what another tap on the same vehicle
        /// asks for.
        var next: VehicleFollow {
            switch self {
            case .off: return .centred
            case .centred: return .bearing
            case .bearing: return .off
            }
        }
    }

    private(set) var vehicleFollow: VehicleFollow = .off {
        didSet { repaceIfNeeded() }
    }

    /// Whether the camera is currently chasing the selected vehicle at all.
    var isFollowingVehicle: Bool { vehicleFollow != .off }

    /// How close a tap on the open vehicle goes when it is spent on getting
    /// nearer, per mode.
    ///
    /// Two numbers rather than one because the modes are recognisable at very
    /// different scales — the same reason a vehicle stops being a dot at a zoom
    /// of its own; see `VehicleShape.emergeAt`. A bus is twelve metres and at
    /// anything less than 18 it is still a marker rather than a bus. A train is
    /// two hundred, and 18 puts it longer than the screen it is standing on, so
    /// the close look at a train is a zoom further out than the close look at a
    /// bus is.
    static func closeZoom(for mode: Mode) -> Double {
        mode == .train ? 17 : 18
    }

    /// How much further out than `closeZoom` the camera has to be before a tap
    /// is spent on the approach.
    ///
    /// Without it, a map parked a hundredth of a zoom short of the number would
    /// charge a whole tap for a movement nobody could see — and the tap it
    /// charged is the one that locks the heading.
    private static let closeZoomSlack = 0.5

    /// Another tap on the vehicle that is already open.
    ///
    /// It is not a re-selection — the panel is already showing that train — so
    /// it is spent on the only thing left to ask about it, which is how closely
    /// the camera should hold it. Round the three states and back to the start,
    /// so nothing needs a second control and nothing is a dead end.
    ///
    /// Except from far out, where the tap buys the approach instead. Selecting
    /// a vehicle from a country zoom leaves it a dot in the middle of the
    /// screen, and the state the cycle would have advanced to — the camera
    /// turning with a marker too small to have a visible heading — says nothing
    /// there. So the first tap out there goes *in*, to the zoom that vehicle is
    /// actually recognisable at, and the tap after that finds the map close
    /// enough for the bearing lock to mean what it says.
    ///
    /// One tap, one movement: the approach does not also advance the follow
    /// state, it only makes sure something is holding the vehicle while the
    /// camera closes on it — a dot at zoom 13 has left the screen long before
    /// an ease to 18 has finished.
    ///
    /// Returns whether the tap was spent on the approach rather than on the
    /// cycle, which is the difference between "the camera moved" and "the way
    /// it is held changed".
    @discardableResult
    func tappedOpenVehicle() -> Bool {
        if let closer = approachZoom() {
            if vehicleFollow == .off { vehicleFollow = .centred }
            onZoom?(closer)
            return true
        }
        vehicleFollow = vehicleFollow.next
        return false
    }

    /// The zoom a tap on the open vehicle should close to, or nil if the map is
    /// already near enough that the tap means something else.
    ///
    /// The mode is read from the viewport's own vehicles first: `selectedVehicle`
    /// is written on the panel's slower cadence and is briefly the vehicle
    /// *before* this one, or nil, in exactly the moments a second tap lands in.
    /// Unknown either way, the tap falls through to the cycle rather than
    /// guessing a zoom.
    private func approachZoom() -> Double? {
        // Not out of the bearing lock. Reaching it means the map was already
        // close enough to have skipped the approach, and a tap there is the
        // reader asking to be let go of — turning it into a zoom would make the
        // cycle a place with no way out.
        guard case let .vehicle(id) = selection, vehicleFollow != .bearing else { return nil }
        let found = vehicles.first { $0.id == id }
            ?? (selectedVehicle?.id == id ? selectedVehicle : nil)
        guard let mode = found?.mode else { return nil }
        let target = Self.closeZoom(for: mode)
        guard zoom < target - Self.closeZoomSlack else { return nil }
        return target
    }

    /// Called by the map when a gesture begins, which is the only reliable
    /// signal that the camera moved because somebody moved it. A camera set
    /// from here fires the same change notifications as a drag does, so the
    /// notifications cannot be used to tell the two apart.
    ///
    /// Moving the map by hand always means "let go of it", whichever state the
    /// following had got to — and it leaves the selection alone, so tapping the
    /// vehicle again picks the cycle back up from the beginning.
    func mapWasDragged() {
        guard vehicleFollow != .off else { return }
        vehicleFollow = .off
    }

    /// The vehicle the camera should be on this frame, and the instant on the
    /// map's own clock its position was computed for.
    ///
    /// The timestamp is not decoration. A tick reads the clock once at the top
    /// and calls this at the bottom, and everything in between — the viewport
    /// query, the stop lookup, the panel's own refresh — takes a varying few
    /// milliseconds. A follower that stamps the arrival with the wall clock is
    /// therefore measuring its own latency into every interval it derives, and
    /// deriving a speed from it. See `MapCoordinator.follow`.
    var onRecentre: ((VehicleSnapshot, Double) -> Void)?

    private var frameStatsAt = Date.distantPast
    private var lastFrameAt: Date?
    private var smoothedFrameSeconds = 0.0
    private var renderFps = 0.0

    /// Told by the map how often it is actually painting.
    ///
    /// Measured there because only the renderer knows: this app pushes data and
    /// Mapbox decides when to draw, and the gap between the two is exactly the
    /// thing worth being able to see. A map that scrolls at 120 while the
    /// vehicles step at 17 is not a slow map, it is a slow *model*, and one
    /// number for both said the wrong thing about which.
    func recordRenderRate(_ perSecond: Double) {
        renderFps = perSecond
    }

    /// Whether OpenRailwayMap's platform footprints and station blobs are drawn.
    ///
    /// Setting it invalidates the plate layout, because the two are one
    /// decision: a numbered plate is left off wherever a footprint says the same
    /// thing, so turning the shapes off has to bring the numbers back.
    var showRailwayShapes = Settings.bool("showRailwayShapes", or: true) {
        didSet {
            guard showRailwayShapes != oldValue else { return }
            Settings.set(showRailwayShapes, "showRailwayShapes")
            platesViewport = nil
            requestTick()
        }
    }

    /// Whether those tiles are actually arriving.
    ///
    /// The shapes are the one thing on this map that needs a network. Suppressing
    /// a plate on the strength of a shape that never loaded would leave a
    /// platform with no marker at all, so the suppression waits for evidence:
    /// the plates stand down once a tile has been seen and come back if the
    /// source starts failing.
    private(set) var railwayShapesDrawn = false

    func railwayShapes(arrived: Bool) {
        guard arrived != railwayShapesDrawn else { return }
        railwayShapesDrawn = arrived
        platesViewport = nil
        requestTick()
    }

    /// One selector governs all live transit requests. In particular, Off also
    /// cancels foreground OJP/formation work; those requests no longer sit
    /// outside the setting that claims to turn live data off.
    var dataMode: TransitDataMode = Settings.choice("dataMode", or: .all) {
        didSet {
            guard dataMode != oldValue else { return }
            Settings.set(dataMode, "dataMode")
            applyDataMode()
        }
    }
    var isOnWiFi = true

    /// A development entry point: where to open, and what to select.
    struct DebugStart {
        var lat: Double
        var lon: Double
        var zoom: Double
        var selectNearest: Bool
        /// Select the nearest *vehicle* rather than whatever is under the point.
        ///
        /// A tap at a station coordinate lands on the station, which is right —
        /// but it makes the vehicle panel the one screen that cannot be opened
        /// from a command line, and it is the one most often being looked at.
        var selectVehicle: Bool
        /// A rotated or tilted start, so the viewport arithmetic that depends on
        /// bearing can be reproduced from a command line rather than by twisting
        /// two fingers on a simulator.
        var bearing: Double?
        var pitch: Double?
    }
    private(set) var debugStart: DebugStart?

    /// Consume the debug start, so it applies once rather than fighting the user
    /// for the camera on every frame.
    func takeDebugStart() -> DebugStart? {
        // Do not publish a mutation when there is nothing to consume. This is
        // called from `updateUIView`; writing nil over nil invalidates that view
        // again and turns a lifecycle redraw into a permanent feedback loop.
        guard let start = debugStart else { return nil }
        debugStart = nil
        return start
    }

    // MARK: - Pretending to be on board

    /// `-rideDemo 20` — feed the ride watch a trail taken off a real vehicle,
    /// twenty seconds behind where the timetable puts it.
    ///
    /// The one part of this feature that cannot be checked from a desk is the
    /// part that matters: a phone travelling with a train. So the trail is
    /// synthesised from a vehicle the map is already drawing — its own
    /// positions, wobbled by a few metres the way a fix is, and *stamped late*.
    /// That is what exercises the search the whole design turns on: the fit has
    /// to slide the timetable by the same number of seconds to find it again,
    /// and the readout prints what it found.
    ///
    /// The lag is the argument rather than a constant because it is the dial
    /// worth turning. Under `RideWatch.stale` seconds, or the trail is thrown
    /// away for being old before it is ever matched.
    private var rideDemoLag: Double = 0
    private var rideDemoID: String?
    private var rideDemoAt: Double = 0

    private func feedRideTrail() {
        guard rideDemoLag > 0 else { return }
        let now = Date().timeIntervalSince1970
        // A fix a second, which is about what a phone in motion produces.
        guard now - rideDemoAt >= 1 else { return }
        rideDemoAt = now

        // Whatever was picked first, for as long as it is still on the map —
        // a demo that hopped between trains would be testing the hysteresis
        // rather than the fit.
        let chosen = rideDemoID.flatMap { id in vehicles.first { $0.id == id } }
            ?? vehicles.first { $0.moving && $0.speed > 30 }
        guard let chosen else { return }
        rideDemoID = chosen.id

        // Twelve metres of wobble on a slow circle. Enough that the trail is
        // not a copy of the answer, and well inside what a fit tolerates.
        let angle = now.truncatingRemainder(dividingBy: 7) / 7 * 2 * .pi
        let perDegree = 111_320.0
        let across = max(0.2, cos(chosen.lat * .pi / 180))
        rides.received(RideFix(
            coord: Coord(
                lon: chosen.lon + sin(angle) * 12 / (perDegree * across),
                lat: chosen.lat + cos(angle) * 12 / perDegree
            ),
            at: now - rideDemoLag,
            speed: chosen.speed / 3.6,
            course: chosen.bearing,
            accuracy: 12
        ))
    }

    /// Called at the end of every tick, so the map redraws from the model's own
    /// loop rather than from SwiftUI's.
    ///
    /// `UIViewRepresentable.updateUIView` runs when SwiftUI decides the view
    /// needs updating, and SwiftUI only knows to do that for state read while
    /// evaluating a `body`. This map's state is read inside the coordinator, so
    /// nothing ever told SwiftUI to call it again: the sources were filled once,
    /// while empty, and never touched afterwards. The map computed 182 vehicles
    /// and drew none of them.
    var onFrame: (() -> Void)?

    /// Tell the map how fast the model intends to feed it, whenever that
    /// changes. Set by the coordinator, which owns the renderer.
    ///
    /// The SDK keeps its own display link and knows none of this. Left alone it
    /// asks for the panel's maximum — 120 Hz on a ProMotion phone — which is
    /// four to eight times the rate anything on the map is being recomputed at,
    /// and a display link is a *request* for a refresh rate as well as a source
    /// of callbacks: the screen is held there for as long as the link is alive.
    /// See `MapCoordinator.setRenderRate`.
    var onPace: ((Duration) -> Void)?

    /// Ask the map to move. Set by the coordinator.
    var onFocus: ((Coord, Double?) -> Void)?

    /// Pan the camera by a lon/lat delta, keeping zoom, bearing and pitch.
    ///
    /// Used when a selected vehicle is re-timed and the camera is not following
    /// it: the train has already jumped, and this is the camera catching up
    /// by the same vector so the thing the reader tapped does not leave the
    /// screen. Distinct from `onFocus` because that recentres, and recentring
    /// a train that was under the finger would be a second, larger movement
    /// than the jump itself.
    var onNudge: ((Double, Double) -> Void)?

    /// Ask the map to change zoom and nothing else, over the usual ease.
    ///
    /// Distinct from `onFocus` because the centre is already being written
    /// every display frame by the vehicle follower: an ease that carried a
    /// centre as well would be a second thing moving the camera sideways
    /// against the one that is holding the vehicle, and the two would fight for
    /// the length of the ease. Zoom alone is the only part of the camera the
    /// follower has no opinion about, so it is the only part safe to animate
    /// underneath it. See `tappedOpenVehicle`.
    var onZoom: ((Double) -> Void)?

    /// Ask the map to put a whole run on screen. Set by the coordinator, which
    /// owns the camera. Distinct from `onFocus` because a line is not a point:
    /// what it needs is the zoom that fits it, not a zoom chosen in advance.
    var onFrameRoute: (([Coord]) -> Void)?

    /// Ask the map for the next locate mode along. Set by the coordinator,
    /// which owns the camera and so is the only thing that can say whether the
    /// move was possible.
    var onLocate: (() -> Void)?

    /// Ask the map to tilt. Set by the coordinator, for the same reason: the
    /// camera is the coordinator's and nothing else may set one.
    var onTilt: ((Double) -> Void)?

    /// Which of the three the button is showing.
    ///
    /// Written by the coordinator rather than by the button, because the map
    /// drops out of following on its own the moment the camera is dragged — and
    /// a button that only changed on its own presses would keep claiming to
    /// follow a map that had stopped.
    var locateMode: LocateMode = .unfocused

    /// Whether the device has produced a position yet.
    ///
    /// The control is drawn from this rather than from the authorisation
    /// status, because the two answer different questions: permission granted
    /// with no fix yet is still a button that would do nothing, and saying so
    /// before the press is better than a press that goes nowhere.
    var hasLocationFix = false

    /// Whether the time control is on screen. Off by default: most of the time
    /// the answer wanted is "now", and a control for any other hour is clutter
    /// until it is asked for.
    var showTimeControl = false

    /// Whether the map clock is advancing.
    ///
    /// Held here rather than only inside the control, because hiding the
    /// control must not start the clock again — a paused map stays paused
    /// until somebody presses play, including across opening and closing the
    /// strip.
    var isClockPlaying = true {
        didSet {
            guard isClockPlaying != oldValue else { return }
            clock.setPlaying(isClockPlaying)
            requestTick()
        }
    }

    /// How strongly the railway network is drawn under everything else.
    ///
    /// A dial rather than a switch, because the right amount depends on the
    /// basemap and on what is being looked at: enough to see which line a train
    /// is on, not so much that the country turns into a diagram.
    var trackOpacity: Double = Settings.double("trackOpacity", or: 0.55, in: 0...1) {
        didSet {
            guard trackOpacity != oldValue else { return }
            Settings.set(trackOpacity, "trackOpacity")
        }
    }

    // MARK: - The third dimension

    /// Whether the map stands the country up.
    ///
    /// Off by default, and that is a considered default rather than caution.
    /// Relief needs a network — the elevation is Mapbox's raster tiles, not
    /// anything packed onto the device — and it is the one part of the map that
    /// simply is not there in a tunnel through the Lötschberg, which is exactly
    /// where somebody is most likely to be reading this app offline. On, and
    /// looking down a valley, it is also the single thing that most changes
    /// what the map is: half of why the Swiss network runs where it runs is
    /// invisible from directly above.
    var terrain3D = Settings.bool("terrain3D", or: false) {
        didSet {
            guard terrain3D != oldValue else { return }
            Settings.set(terrain3D, "terrain3D")
            requestTick()
        }
    }

    /// How much of the relief there is.
    ///
    /// A dial rather than a constant, for the same reason the track overlay is
    /// one: what reads well depends on where the camera is. At 1 the Alps are
    /// true and the Mittelland is flat — which is also true, and throws away
    /// the only cue that the line through Olten is on a slope at all. Past
    /// about 2 the country becomes a relief model and the trains climb walls.
    var terrainExaggeration = Settings.double("terrainExaggeration", or: 1.3, in: 0.5...2.5) {
        didSet {
            guard terrainExaggeration != oldValue else { return }
            Settings.set(terrainExaggeration, "terrainExaggeration")
            requestTick()
        }
    }

    /// Whether the buildings round a station are drawn with height.
    ///
    /// On, because they are what the vehicles are measured against. A tilted
    /// map with a flat basemap has nothing in it the height of a train, so a
    /// train drawn three metres tall reads as a smear; put the station building
    /// beside it at twenty and it is a train standing beside a building.
    var buildings3D = Settings.bool("buildings3D", or: true) {
        didSet {
            guard buildings3D != oldValue else { return }
            Settings.set(buildings3D, "buildings3D")
            requestTick()
        }
    }

    /// Whether a tilted, close-in map draws its vehicles as solids.
    var solidVehicles = Settings.bool("solidVehicles", or: true) {
        didSet {
            guard solidVehicles != oldValue else { return }
            Settings.set(solidVehicles, "solidVehicles")
            requestTick()
        }
    }

    /// Whether a wagon in a tunnel is drawn as a ghost.
    ///
    /// On: it fades to nothing over the portal so the mountain is not a
    /// train standing on the ridge. Off: tunnels are ignored and the body
    /// stays solid, which is the wrong place but useful when checking a
    /// rake against the hillside.
    var ghostTunnels = Settings.bool("ghostTunnels", or: true) {
        didSet {
            guard ghostTunnels != oldValue else { return }
            Settings.set(ghostTunnels, "ghostTunnels")
            requestTick()
        }
    }

    /// What time of day the Standard basemap is lit for. Ignored by the others,
    /// which have their own fixed palettes.
    ///
    /// The tick is asked for rather than left to the next one, because this is
    /// a control somebody is holding while watching the map: a setting that
    /// waits for whatever happens to move next reads as a control that does not
    /// work. See `MapCoordinator.applyLightPreset`, which is where it lands.
    var lightPreset: Terrain3D.LightPreset = Settings.choice("lightPreset", or: .night) {
        didSet {
            guard lightPreset != oldValue else { return }
            Settings.set(lightPreset, "lightPreset")
            requestTick()
        }
    }

    /// How far the camera is tilted, in degrees, set by the map as it moves.
    ///
    /// Reported coarsely — see `MapCoordinator.reportViewport` — because the
    /// only thing the model does with it is decide whether the vehicles are
    /// worth slicing into solids at all. The *fade* between flat and solid is
    /// driven off the camera directly, at the display's rate, because it has to
    /// keep up with a two-finger drag and this does not.
    var pitch = 0.0 {
        didSet {
            // A tick, because the slabs are built in `rebuildShapes` and the
            // camera has just changed whether they are worth building. Coalesced
            // — see `requestTick` — so a tilt that reports a hundred and fifty
            // times still costs whatever the run loop lets through.
            guard pitch != oldValue else { return }
            requestTick()
        }
    }

    /// Whether the map is drawing wagons as baked models rather than as stacks
    /// of extruded prisms.
    ///
    /// Set by the map once it knows — registering a model is the sort of thing
    /// that can be refused, and a device that refuses is one this app still has
    /// to draw a train on. Read here because it decides whether the geometry
    /// for the prisms is worth building at all, which is most of the cost of a
    /// tick: several hundred rings a frame that nothing is going to look at.
    var bakedModels = false {
        didSet {
            guard bakedModels != oldValue else { return }
            requestTick()
        }
    }

    /// How far the vehicles have stood up, 0 to 1.
    ///
    /// The one number both drawings share: the solids are drawn at this much
    /// opacity and the flat footprints at what is left of it, so tilting the
    /// map hands one picture over to the other rather than showing both.
    var solidity: Double {
        detailedVehicles && solidVehicles
            ? VehicleShape.solidity(pitch: pitch, zoom: zoom)
            : 0
    }

    /// Tilt the map by hand.
    ///
    /// A two-finger vertical drag has always done this and remains the fastest
    /// way; it is also the least-known gesture on any phone map, and everything
    /// above is invisible until somebody performs it.
    func tilt(to pitch: Double) { onTilt?(pitch) }

    /// Which of the two railway overlays is on screen.
    ///
    /// Off, the network is the app's own: drawn from the routing graph, two
    /// flat colours, right as a hint under the vehicles and near-invisible
    /// when the railway *is* what you are reading. On, it is OpenRailwayMap's
    /// own standard style from their vector tiles — orange main lines, yellow
    /// branches, olive narrow gauge, each with a casing. See `RailwayLines`.
    var highContrastTracks = Settings.bool("highContrastTracks", or: false) {
        didSet {
            guard highContrastTracks != oldValue else { return }
            Settings.set(highContrastTracks, "highContrastTracks")
            requestTick()
        }
    }

    /// Whether ORM's line tiles are actually arriving.
    ///
    /// The same bargain the platform shapes make, for the same reason: the
    /// graph overlay works with no signal and theirs does not, so the app's own
    /// network only stands down once a line tile has been seen — and comes back
    /// if the source starts failing. Otherwise switching to high contrast on a
    /// train in a tunnel would leave the map with no railway on it at all.
    private(set) var railwayLinesDrawn = false

    func railwayLines(arrived: Bool) {
        guard arrived != railwayLinesDrawn else { return }
        railwayLinesDrawn = arrived
        requestTick()
    }

    /// Whether the network drawn from the routing graph is the one on screen.
    var ownTracksDrawn: Bool { !(highContrastTracks && railwayLinesDrawn) }

    /// The viewport, set by the map as it moves.
    var viewport = BBox(west: 5.9, south: 45.8, east: 10.5, north: 47.8)
    var zoom = 7.4 {
        didSet { repaceIfNeeded() }
    }
    /// Metres of ground per screen point at the current camera.
    ///
    /// Reported by the map alongside the viewport, because the camera is the
    /// only thing that knows it — and every vehicle drawn to scale needs it, so
    /// deriving it again from the zoom here would be a second copy of an
    /// arithmetic that has already been got wrong once. See
    /// `MapCoordinator.metresPerPoint`.
    var metresPerPoint = 1_000.0

    private var refreshTask: Task<Void, Never>?
    /// The fetch itself, separately owned from the timer or button that asked
    /// for it. A manual refresh used to belong to a discarded view task, so it
    /// could keep downloading and decoding after the scene was suspended.
    /// Keeping one operation here also makes simultaneous timer/button asks
    /// join the same transfer instead of racing an `isRefreshing` check.
    private var refreshOperationTask: Task<Void, Never>?
    private var refreshOperationGeneration: UInt64 = 0
    private var situationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// The one task allowed to query and publish a moving frame. Kept separate
    /// from `tickTask`, which is only the clock that asks this pump for work.
    private var tickPumpTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Serialises the Fleet-side half of true background transitions. A merely
    /// inactive scene pauses presentation without touching the geometry worker.
    private var geometryLifecycleTask: Task<Void, Never>?
    /// True while the scene is actually backgrounded. Unlike
    /// `tickSchedulerSuspended`, this covers utility/network producers that do
    /// not draw frames. Keeping the state explicit also handles a background
    /// transition while `start()` is suspended in one of its disk reads.
    private var backgroundWorkSuspended = false
    /// Whether there is a route to the network at all. Read by the background
    /// formation sweep, which otherwise spends a request every second and a
    /// half discovering the same thing.
    private(set) var isOnline = true

    init() {
        // The last national fleet, packed. It used to be the response itself —
        // 150 MB of XML that every launch parsed again in front of a curtain
        // saying "Loading the network" over data already on the device. See
        // `FleetCache`; a file with XML in it is still read, whatever it is
        // called, which is how a recorded snapshot is replayed.
        let snapshot = URL.applicationSupportDirectory.appendingPathComponent("fleet.bin")
        fleet = Fleet(snapshotURL: snapshot)
    }

    // MARK: - Launch

    private static let log = Logger(subsystem: "com.kexts.swisstransit", category: "boot")

    /// Where the map opens, decided before anything is drawn.
    ///
    /// Resolved once, here, rather than by the map and the model separately:
    /// the two have to agree, because one sets the camera and the other decides
    /// which slice of the timetable that camera needs. See `OpeningCamera`.
    let opening = OpeningCamera.resolve()

    /// The region the first draw is clipped to, or `nil` for the country.
    ///
    /// A debug start overrides it with `nil`. `-startLat` moves the camera
    /// after the fleet is drawn, so a clipped draw would be a clip of the
    /// wrong place — and the whole point of those arguments is a reproducible
    /// screenshot, which a fleet still filling in is not.
    private func openingClip() -> BBox? {
        guard UserDefaults.standard.object(forKey: "startLat") == nil else { return nil }
        return opening.clip
    }

    /// The rest of the country, and the rails under it, once the map is up.
    ///
    /// Both of these used to be in front of the reader. Together they were 74%
    /// of a launch — a national timetable expansion and a corridor match for
    /// every running train — and neither is needed to draw the viewport that is
    /// about to appear. They are needed *soon*: a pan two valleys over wants
    /// the fleet already built, and a zoom out to the whole network wants the
    /// trains already on their rails. Soon is what a background task is for.
    ///
    /// Ordered, not parallel. Completing the fleet first means the geometry
    /// warm that follows covers the whole country rather than the viewport it
    /// would have found a moment earlier — and both run on the fleet actor
    /// anyway, so racing them would only interleave them badly.
    private func finishOpening(at moment: Date) {
        openingTask?.cancel()
        guard !backgroundWorkSuspended else {
            openingFinished = false
            openingTask = nil
            return
        }
        openingTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let grew = await self.fleet.completeTimetable()
            if Task.isCancelled || self.backgroundWorkSuspended { return }
            if grew {
                let status = await self.fleet.currentStatus()
                guard !Task.isCancelled, !self.backgroundWorkSuspended else { return }
                self.status = status
                self.requestTick()
            }
            let expanded = Date().timeIntervalSince(started)

            // Opening is complete once the timetable exists. The national
            // geometry pass below is only a speculative cache warm, so a
            // Low-Power transition may cancel it without making resume repeat
            // the timetable expansion or pretending launch is unfinished.
            self.openingFinished = true

            // National geometry is a speculative warm: a cold viewport now
            // queues the same work off the frame. Keep the complete timetable
            // in Low Power/thermal states, but do not precompute rails the
            // reader may never pan to while the phone is asking us to back off.
            if self.powerFactor == 1 {
                await self.fleet.warmTrainGeometry(
                    inBackground: Timestamp(moment.timeIntervalSince1970)
                )
            }
            if Task.isCancelled || self.backgroundWorkSuspended { return }
            // Last, because these are the only ones that never finish, and
            // the two that do should not be queued behind them.
            if self.powerFactor == 1 {
                self.keepRefining()
                self.keepTimingsLive()
            }
            Self.log.notice(
                "opened: country in \(expanded * 1000, format: .fixed(precision: 0))ms, rails in \(Date().timeIntervalSince(started) * 1000 - expanded * 1000, format: .fixed(precision: 0))ms"
            )
            self.openingTask = nil
        }
    }

    private var openingTask: Task<Void, Never>?
    private var openingFinished = false

    /// Keep the vehicles in view standing on their real paths, ahead of a tap.
    ///
    /// A vehicle is drawn on its corridor path and moved onto its refined one
    /// the moment somebody touches it, and the two are far enough apart that
    /// the tap read as the map teleporting the train — up to 3.5 km of it. See
    /// `Fleet.refineDrawn`. This does the refining before the finger arrives,
    /// so there is nothing left to correct.
    ///
    /// A loop rather than something hung off the viewport's `didSet`: the
    /// viewport is re-read on every pass, so a pan is followed rather than
    /// interrupted, and there is no state to keep about which box is being
    /// worked on. When there is nothing left in view to refine it idles, which
    /// is the ordinary case — a settled map costs a check every quarter second.
    private func keepRefining() {
        refineTask?.cancel()
        guard !backgroundWorkSuspended else { refineTask = nil; return }
        refineTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.backgroundWorkSuspended, self.powerFactor == 1 else {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let more = await self.fleet.refineDrawn(
                    in: self.viewport, at: Timestamp(self.clock.now())
                )
                if more {
                    // Positions moved, so the frame is stale. Only when
                    // something actually changed: ticking on every idle pass
                    // would have this competing with the draw loop forever.
                    self.requestTick()
                } else {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    private var refineTask: Task<Void, Never>?

    /// Ask OJP where the vehicles on screen really are, ahead of a tap.
    ///
    /// The other half of the same fix `keepRefining` is: a vehicle used to move
    /// the moment somebody touched it, and the cure is to have already done
    /// whatever the touch was going to do.
    ///
    /// What the touch does is fetch delays. The map draws from `timetable.bin`
    /// corrected by a national tick every minute or five, and until this
    /// existed the only thing that ever asked OJP about an individual run was
    /// opening it — so a run a minute down was drawn a minute's travel ahead of
    /// itself, and the tap was the first and only moment anything put it right.
    /// That is the train that teleports backwards when you touch it, and it is
    /// every mode, because everything runs a little late.
    ///
    /// Paced rather than run flat out. `LoadService` already refuses a
    /// background request that would eat into what a panel needs, but refusing
    /// is not the same as being cheap: this is one request per vehicle against
    /// a budget of fifty a minute, and it is the reader's data as well as the
    /// platform's. So it takes the nearest to the middle of the screen first
    /// and leaves `liveTimingGap` between requests — the vehicle somebody is
    /// most likely to reach for is right within a few seconds, a screenful
    /// inside a minute or two, and then it idles, because a run that has been
    /// asked about is `monitored` and drops out of the set.
    ///
    /// It does not fix every case on its own, and is not meant to. What lands
    /// while the reader is already looking still lands, and that is what
    /// `Journey.settle` is for: this makes the correction rare, and the glide
    /// makes the rare one survivable.
    private func keepTimingsLive() {
        liveTimingTask?.cancel()
        guard !backgroundWorkSuspended, dataMode == .all else {
            liveTimingTask = nil
            return
        }
        liveTimingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.backgroundWorkSuspended, self.powerFactor == 1 else {
                    try? await Task.sleep(for: .seconds(6))
                    continue
                }
                let asked = await self.sweepLiveTimings()
                // A pass that found nothing costs one check a second. A pass
                // that worked has already paced itself, so it goes straight
                // round again and follows the viewport rather than sitting out
                // a pan.
                if asked == 0 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    private var liveTimingTask: Task<Void, Never>?

    /// How long a run stays asked-about before the sweep will spend another
    /// request on it. Matches `LoadService`'s own hold on a forecast: past it
    /// the service would go back to the network anyway.
    private static let liveTimingHold: TimeInterval = 240

    /// How long the sweep waits between requests.
    ///
    /// The budget is fifty a minute and `LoadService` already keeps fourteen of
    /// them back for whatever the reader opens, so the ceiling here is
    /// thirty-six — but a ceiling is not a target. Running at it would spend a
    /// screenful in twenty seconds and then spend the rest of the minute being
    /// refused, and it is the reader's data as well as the platform's budget.
    /// Two and a half seconds is about twenty a minute: nearest the middle
    /// first, so the vehicles somebody is likely to tap are right within a few
    /// seconds, and a whole screenful inside a minute or two.
    private static let liveTimingGap = Duration.milliseconds(2500)
    private var sweptTimings: [LoadService.Key: Date] = [:]

    /// One pass of that sweep. Returns how many runs it actually asked about.
    private func sweepLiveTimings() async -> Int {
        guard !backgroundWorkSuspended, dataMode == .all, powerFactor == 1,
              await loads.isConfigured else { return 0 }
        let now = Timestamp(clock.nowSeconds())
        let candidates = await fleet.awaitingLiveTiming(in: viewport, at: now)
        guard !candidates.isEmpty else { return 0 }

        var asked = 0
        for candidate in candidates {
            if Task.isCancelled || backgroundWorkSuspended || powerFactor > 1 { return asked }
            let key = LoadService.Key(journeyID: candidate.ref, day: candidate.day)
            if let at = sweptTimings[key],
               Date().timeIntervalSince(at) < Self.liveTimingHold { continue }

            // `background: true` is refused rather than queued once the minute
            // is down to what a tap needs — and a refusal is the whole budget
            // speaking, not this one run, so the pass ends rather than walking
            // the rest of the screen into the same wall. The key is left
            // unmarked so a later pass picks it up.
            if case .failed = await loads.load(for: key, background: true) { return asked }
            sweptTimings[key] = Date()
            asked += 1

            if let timing = await loads.timing(for: key),
               await fleet.applyTiming(timing, to: candidate.id, at: Date()) > 0 {
                // The vehicle moved, so the frame is stale. It moves as a glide
                // rather than a jump — see `Journey.settle` — which is what
                // makes doing this behind the reader's back acceptable at all.
                requestTick()
            }
            try? await Task.sleep(for: Self.liveTimingGap)
        }

        // Bounded. A session spent panning a city would otherwise remember
        // every run it has ever asked about until the day turned.
        if sweptTimings.count > 4000 {
            let cutoff = Date().addingTimeInterval(-Self.liveTimingHold)
            sweptTimings = sweptTimings.filter { $0.value > cutoff }
        }
        return asked
    }


    func start() async {
        let directory = Bundle.main.resourceURL?.appendingPathComponent("Data")
            ?? Bundle.main.bundleURL

        boot.stage = .reading
        let result = await fleet.load(from: directory)
        loaded = result
        await fleet.configure(token: Secrets.realtimeToken)

        // Routed legs, kept between launches. Every one of these is a Dijkstra
        // over a 573,000-node graph that has already been run once, and the run
        // happens on the fleet actor — the same actor the draw loop and every
        // map tap go through. See `Fleet.openLegCache`.
        boot.stage = .caches
        await fleet.openLegCache(
            at: URL.applicationSupportDirectory.appendingPathComponent("leg-cache.json"),
            seededBy: directory.appendingPathComponent("leg-cache.json")
        )

        // What previous runs learned about individual trains, seeded with what
        // the app already knew when it was built. The seed matters more than it
        // looks: installing from Xcode wipes the container, so without it every
        // build starts the map back at the library's guesses and everything the
        // app had been told has to be learned again.
        //
        // Read before the first frame, so a train whose formation is already
        // known is never drawn from the guess and corrected a moment later.
        boot.stage = .learned
        layouts.load(seededBy: Bundle.main.url(
            forResource: "vehicle-layouts", withExtension: "json"
        ))

        // And the formations themselves, kept between launches. The layout
        // store remembers what a train is *shaped* like; this remembers the
        // answer that shape came from, so opening a train the map already asked
        // about in the background costs nothing at all.
        await formations.keepAnswers(
            in: URL.applicationSupportDirectory.appendingPathComponent("formations")
        )

        // Disruptions. The line join needs the operator register the fleet
        // already loaded, and the stored notices are read before the first
        // fetch so a launch has something to say in the seconds before the
        // network answers.
        boot.stage = .disruptions
        await situations.configure(token: Secrets.sxToken)
        // Before `keepAnswers`, so a catalogue stored by an earlier session is
        // not read back in when the setting says it is not wanted.
        await situations.setIncludesPlanned(dataMode == .all)
        let names = await fleet.operatorNamer()
        await situations.nameOperators(with: names)
        await situations.keepAnswers(
            in: URL.applicationSupportDirectory.appendingPathComponent("situations")
        )

        // Draw the country from the printed timetable, which needs no network
        // at all and is never stale in the way a stored snapshot is.
        //
        // This is the change that makes SIRI-ET optional. The app used to open
        // on whatever fleet was last downloaded — an hour old, a day old, or
        // nothing on a first launch — and then spend 7 MB catching up. The
        // timetable knows what is *scheduled* to be running at this moment for
        // any moment of the year, so the map is right from the first frame and
        // the network is spent only on the train somebody actually taps.
        //
        // The stored snapshot is still the fallback, for a build with no
        // timetable in it and for the runs the timetable cannot know about.
        //
        // And drawn for the *viewport*, not for the country. See
        // `OpeningCamera`: expanding the window nationally builds 25,518
        // journeys and half a million calls, of which a phone opened on one
        // canton draws about a thousand. The rest are built behind the map
        // rather than in front of it — `finishOpening` below.
        boot.stage = .drawing
        let moment = Date(timeIntervalSince1970: clock.now())
        var drew = await fleet.drawTimetable(at: moment, in: openingClip())
        // A viewport with no service in it is a real answer — a rural valley at
        // four in the morning — and it must not be mistaken for a build with no
        // timetable. Ask for the country before falling back to the snapshot.
        if !drew, openingClip() != nil {
            drew = await fleet.drawTimetable(at: moment)
        }
        if !drew {
            _ = await fleet.replayCachedSnapshot()
        }
        status = await fleet.currentStatus()
        await updateScrubRange()
        boot.stage = .ready
        Self.log.notice("boot: \(self.boot.report(), privacy: .public), opened \(self.opening.where_.rawValue, privacy: .public)")
        isLoading = false
        // The stop register has just been read off disk, so whatever an
        // earlier tick cached for this box was cached against an empty store.
        stopsViewport = nil
        await requestTickAndWait()
        finishOpening(at: moment)

        // A development affordance: `-startOffsetMinutes 180` launches the map
        // three hours ahead. Switzerland's network is asleep between one and
        // five in the morning, so without this the only way to see the app do
        // anything is to be awake at the right time.
        let startOffset = UserDefaults.standard.integer(forKey: "startOffsetMinutes")
        if startOffset != 0 {
            clock.setOffset(Double(startOffset) * 60)
        }
        // `-startLat 46.948 -startLon 7.439 -startZoom 13` opens on a place, and
        // `-selectNearest 1` picks whatever is running there. Together they make
        // a screenshot of the detail panel reproducible instead of a matter of
        // tapping in the right pixel at the right moment. `-startBearing 135`
        // and `-startPitch 60` do the same for a rotated or tilted map, which is
        // where the viewport is hardest to get right.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "startLat") != nil {
            debugStart = DebugStart(
                lat: defaults.double(forKey: "startLat"),
                lon: defaults.double(forKey: "startLon"),
                zoom: defaults.object(forKey: "startZoom") != nil
                    ? defaults.double(forKey: "startZoom") : 13,
                selectNearest: defaults.bool(forKey: "selectNearest"),
                selectVehicle: defaults.bool(forKey: "selectVehicle"),
                bearing: defaults.object(forKey: "startBearing") != nil
                    ? defaults.double(forKey: "startBearing") : nil,
                pitch: defaults.object(forKey: "startPitch") != nil
                    ? defaults.double(forKey: "startPitch") : nil
            )
        }

        // `-highContrastTracks 1` opens with OpenRailwayMap's own colours on,
        // so a screenshot of that overlay is a command rather than two taps
        // nobody can repeat. The same family as `-openSheet`.
        //
        // Applied only where the argument was actually given. Assigned
        // unconditionally it read a *bare* key that nothing but a launch
        // argument ever writes, got `false` back, and wrote that over the
        // setting the user had stored under `setting.` — which is to say every
        // remembered overlay was switched off a moment after being restored.
        // See `Settings` for why the two live in different namespaces.
        if defaults.object(forKey: "highContrastTracks") != nil {
            highContrastTracks = defaults.bool(forKey: "highContrastTracks")
        }
        // `-trackOpacity 100` sets the overlay dial, in per cent, for the same
        // reason: an overlay screenshot is about how strongly it is drawn.
        if defaults.object(forKey: "trackOpacity") != nil {
            trackOpacity = min(max(defaults.double(forKey: "trackOpacity") / 100, 0), 1)
        }

        // `-terrain3D 1` opens with the relief on, and `-terrainRelief 180`
        // sets how much of it there is, in per cent. Same family, and terrain
        // needs them more than anything else here does: it is the one setting
        // that is off by default, so a screenshot of a tilted valley is
        // otherwise two taps nobody can repeat exactly. Pair them with
        // `-startPitch`, which is what makes any of it visible.
        if defaults.object(forKey: "terrain3D") != nil {
            terrain3D = defaults.bool(forKey: "terrain3D")
        }
        if defaults.object(forKey: "terrainRelief") != nil {
            terrainExaggeration = min(max(defaults.double(forKey: "terrainRelief") / 100, 0.5), 2.5)
        }
        // `-solidVehicles 0` holds the vehicles flat on a tilted map, which is
        // the only way to photograph the two drawings side by side.
        if defaults.object(forKey: "solidVehicles") != nil {
            solidVehicles = defaults.bool(forKey: "solidVehicles")
        }
        if defaults.object(forKey: "ghostTunnels") != nil {
            ghostTunnels = defaults.bool(forKey: "ghostTunnels")
        }

        // `-rideDemo 20` puts a synthetic passenger on a real train. See
        // `feedRideTrail`, which also explains why the number is a lag.
        rideDemoLag = defaults.double(forKey: "rideDemo")
        if rideDemoLag > 0 {
            // The demo has to work at three in the morning like everything else
            // here, which means it has to work with the clock wound forward —
            // and the trail is synthesised against that same clock, so the one
            // reason to insist on real time does not apply to it.
            rides.ignoresClock = true
        }

        // `-openBoard Bern` opens a station's departure board, so a screenshot
        // of one is a command rather than a search typed by hand at the right
        // moment. It takes the top *station* the search finds, which is the row
        // a reader would have tapped. The same family as `-selectVehicle`.
        if let wanted = defaults.string(forKey: "openBoard"), !wanted.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                searchQuery = wanted
                // Past the search debounce and the walk over 33,000 stop names.
                try? await Task.sleep(for: .seconds(2))
                await openTopResult()
            }
        }

        watchPower()
        started = true
        // `start()` can outlive a trip to the background because its disk and
        // actor work is intentionally asynchronous. Do not resurrect loops for
        // a scene that entered the background while that work was in flight.
        if !backgroundWorkSuspended {
            watchNetwork()
            startTicking()
            if powerFactor == 1 { startLearning() }
            restartRefreshLoop()
            restartSituationLoop()
        }
    }

    /// Whether `start` has finished. Read by `resume`, which must not bring the
    /// loops up in front of the data they are loops over: the scene can go
    /// inactive and back before the packed timetable has finished being read,
    /// and a refresh loop started there would fetch against an empty fleet with
    /// a cadence nobody had configured yet.
    private var started = false

    private func watchNetwork() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnWiFi = !path.usesInterfaceType(.cellular)
                self?.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-path"))
        pathMonitor = monitor
    }

    // MARK: - Refreshing

    private func restartRefreshLoop() {
        refreshTask?.cancel()
        guard !backgroundWorkSuspended else { refreshTask = nil; return }
        guard let interval = dataMode.refreshInterval else { return }
        refreshTask = Task { [weak self] in
            // The stored snapshot has just been replayed, so the first fetch can
            // wait a moment and let the map settle.
            try? await Task.sleep(for: .seconds(2))
            // A deadline rather than a sleep after the work, for the same
            // reason the frame loop keeps one. Sleeping the interval *after* a
            // refresh makes the period `refresh + interval`: a fetch that takes
            // six minutes on a five-minute cadence is an eleven-minute cycle
            // spent refreshing more than half the time, which is what "it says
            // refreshing constantly" turns out to mean. A refresh that overruns
            // its interval now simply starts the next one when it is done —
            // that is as fast as the app can go, and `refreshSeconds` on the
            // status says so out loud rather than quietly stretching the
            // five-minute interval the data modes use.
            var next = ContinuousClock.now
            while !Task.isCancelled {
                await self?.refreshNow()
                next += .seconds(interval)
                let now = ContinuousClock.now
                if next < now { next = now }
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }

    /// Poll the disruption wire on its own clock.
    ///
    /// It used to ride on the estimated-timetable loop, which was fine when
    /// that loop ran every minute and is not fine now. The two are three orders
    /// of magnitude apart in cost — 7 MB against 30 KB — so they have no
    /// business sharing a cadence, and while they did, slowing the feed down
    /// silently slowed incident notices with it and turning the feed off
    /// stopped them altogether.
    ///
    /// The service keeps its own intervals and no-ops until they are up, so
    /// this only has to knock often enough for the shorter of them.
    private func restartSituationLoop() {
        situationTask?.cancel()
        guard !backgroundWorkSuspended, dataMode == .all else {
            situationTask = nil
            return
        }
        situationTask = Task { [weak self] in
            var next = ContinuousClock.now
            while !Task.isCancelled {
                if await self?.situations.refresh() == true {
                    await self?.refreshDisruptions()
                }
                next += .seconds(60)
                let now = ContinuousClock.now
                if next < now { next = now }
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }

    func refreshNow() async {
        guard dataMode != .off, !backgroundWorkSuspended else { return }
        if let running = refreshOperationTask {
            await running.value
            return
        }

        refreshOperationGeneration &+= 1
        let generation = refreshOperationGeneration
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation)
        }
        refreshOperationTask = operation
        await operation.value
        if refreshOperationGeneration == generation {
            refreshOperationTask = nil
        }
    }

    private func performRefresh(generation: UInt64) async {
        guard generation == refreshOperationGeneration,
              !backgroundWorkSuspended, !Task.isCancelled
        else { return }
        isRefreshing = true
        startWatchingProgress()
        defer {
            if generation == refreshOperationGeneration {
                stopWatchingProgress()
                isRefreshing = false
            }
        }

        _ = await fleet.refresh()
        guard generation == refreshOperationGeneration,
              !Task.isCancelled, !backgroundWorkSuspended
        else { return }
        let refreshedStatus = await fleet.currentStatus()
        guard generation == refreshOperationGeneration,
              !Task.isCancelled, !backgroundWorkSuspended
        else { return }
        status = refreshedStatus
        let refreshedLimits = await fleet.limits()
        guard generation == refreshOperationGeneration,
              !Task.isCancelled, !backgroundWorkSuspended
        else { return }
        limits = refreshedLimits
        let refreshedSpan = await drawableTimeSpan()
        guard generation == refreshOperationGeneration,
              !Task.isCancelled, !backgroundWorkSuspended
        else { return }
        if let refreshedSpan { timeSpan = refreshedSpan }
        stopsViewport = nil
        // Disruptions are not refreshed here any more — they have their own
        // loop, because they cost 30 KB and this costs 7 MB. See
        // `restartSituationLoop`.
        await requestTickAndWait()
        guard generation == refreshOperationGeneration,
              !Task.isCancelled, !backgroundWorkSuspended
        else { return }
        // Written after the draw rather than before it: whatever this refresh
        // made the map route is already in memory and costs nothing to lose,
        // and the file write is not worth putting in front of a frame.
        await fleet.saveLegCache()
        guard generation == refreshOperationGeneration,
              !Task.isCancelled, !backgroundWorkSuspended
        else { return }
        layouts.save()
    }

    private func cancelRefreshOperation() {
        refreshOperationGeneration &+= 1
        refreshOperationTask?.cancel()
        refreshOperationTask = nil
        stopWatchingProgress()
        isRefreshing = false
    }

    /// Copy the fleet's progress onto the model while a refresh is running.
    ///
    /// Four times a second rather than on the frame loop. The figures are read
    /// under a lock and land on an `@Observable` property, so every sample that
    /// changes anything is a view update; at fifteen a second that is a redraw
    /// of the status pill for every chunk off the socket, to animate a byte
    /// count nobody can read that fast.
    private func startWatchingProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = fleet.monitor.current
                if sample != progress { progress = sample }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopWatchingProgress() {
        progressTask?.cancel()
        progressTask = nil
        // One last read, so the panel ends on what actually happened rather
        // than on whatever the last quarter-second sample caught.
        progress = fleet.monitor.current
    }

    /// Apply a live-data choice immediately, including to work already owned
    /// by the model. Changing to Off is therefore a cancellation boundary, not
    /// merely a promise that the next timer will do nothing.
    private func applyDataMode() {
        refreshTask?.cancel()
        refreshTask = nil
        situationTask?.cancel()
        situationTask = nil
        liveTimingTask?.cancel()
        liveTimingTask = nil
        learningTask?.cancel()
        learningTask = nil

        if dataMode == .off {
            cancelRefreshOperation()
            cancelSelectionWork(clearPresentation: false)
        }

        guard started, !backgroundWorkSuspended else { return }
        restartRefreshLoop()

        let applying = dataMode
        Task { @MainActor [weak self, situations] in
            await situations.setIncludesPlanned(applying == .all)
            guard let self, self.dataMode == applying,
                  !self.backgroundWorkSuspended else { return }
            if applying == .all {
                self.restartSituationLoop()
                if self.powerFactor == 1 {
                    self.startLearning()
                    if self.openingFinished { self.keepTimingsLive() }
                }
            }
            if applying != .off, self.selection != .none {
                self.scheduleSelectionRefresh()
            }
            await self.refreshDisruptions()
        }
    }

    /// The learned formations as a file, for handing to whoever wants to keep
    /// them past a reinstall. Saves first, so what is shared is what is known.
    func exportLayouts() -> URL? { layouts.exported() }

    /// Put the routed legs and the learned formations on disk before the app is
    /// suspended.
    func persist() async {
        await fleet.saveLegCache()
        layouts.save()
    }

    /// Pause the moving presentation while a system surface covers the app.
    ///
    /// Inactivity is not necessarily backgrounding. The screenshot editor,
    /// Control Center and other short system interruptions all pass through it.
    /// Cancelling geometry, live-data requests and selection work for those
    /// covers made the next active frame pay the full resume cost, and repeated
    /// screenshots repeatedly restarted that work. Only the tick producer and
    /// its in-flight frame need to stop; Mapbox independently pauses its display
    /// link when the scene deactivates.
    func pausePresentation() {
        guard !tickSchedulerSuspended else { return }
        tickTask?.cancel(); tickTask = nil
        tickSchedulerSuspended = true
        invalidateTickWork(requestingFreshFrame: false)
        // Announce the rate again after the cover lifts. The map coordinator
        // temporarily caps its renderer while inactive.
        announcedInterval = nil
        pacedInterval = nil
    }

    /// Stop everything that costs anything, because the app is backgrounded.
    ///
    /// iOS suspends a backgrounded process soon enough, and that alone stops
    /// the loops — but "soon enough" is not "now", and the seconds in between
    /// are spent recomputing a national fleet and re-uploading it to a renderer
    /// nobody can see.
    ///
    /// The larger cost is on the way back. Every loop here is paced off a
    /// deadline rather than a sleep, which is right while it is running and
    /// wrong across a suspension: a process frozen mid-sleep and thawed twenty
    /// minutes later wakes to a deadline twenty minutes past, and the first
    /// thing it does is the one frame it was careful never to do — catch up.
    /// Cancelled and restarted, the deadline is simply taken again from now.
    func suspend() {
        // `pausePresentation` normally ran for the preceding `.inactive`, but
        // background can be delivered directly and must be complete on its own.
        guard !backgroundWorkSuspended else { return }
        backgroundWorkSuspended = true
        pausePresentation()
        let previousGeometryTransition = geometryLifecycleTask
        geometryLifecycleTask = Task { [fleet] in
            _ = await previousGeometryTransition?.value
            await fleet.cancelBackgroundGeometry()
        }
        openingTask?.cancel(); openingTask = nil
        refineTask?.cancel(); refineTask = nil
        liveTimingTask?.cancel(); liveTimingTask = nil
        learningTask?.cancel(); learningTask = nil
        settleGeneration &+= 1
        settleTask?.cancel(); settleTask = nil
        settling = false
        cancelSelectionWork(clearPresentation: false)
        refreshTask?.cancel(); refreshTask = nil
        cancelRefreshOperation()
        situationTask?.cancel(); situationTask = nil
        searchTask?.cancel(); searchTask = nil
        pathMonitor?.cancel(); pathMonitor = nil
    }

    /// Back on screen. A transient cover needs only a fresh frame; a real
    /// background departure restores the rest of the producers as well.
    func resume() {
        guard backgroundWorkSuspended else {
            resumePresentation()
            return
        }
        backgroundWorkSuspended = false
        let previousGeometryTransition = geometryLifecycleTask
        geometryLifecycleTask = Task { @MainActor [weak self, fleet] in
            _ = await previousGeometryTransition?.value
            await fleet.resumeBackgroundGeometry()
            guard let self, !self.backgroundWorkSuspended else { return }
            // What the phone thinks of us may well have changed while we were
            // away — a background app does not get the notification it was not
            // running to hear.
            self.readPower()
            self.resumePresentation()
            guard self.started else { return }
            self.watchNetwork()
            self.restartRefreshLoop()
            self.restartSituationLoop()
            if self.selection != .none {
                self.scheduleSelectionRefresh()
            }
            // Suspension cancels the debounced lookup. The text field keeps
            // its value, so arrange the answer again instead of leaving an
            // eligible query showing whichever results happened to land
            // before the app went away.
            if self.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                self.scheduleSearch()
            }
            if self.powerFactor == 1 {
                self.startLearning()
                if self.openingFinished {
                    self.keepRefining()
                    self.keepTimingsLive()
                }
            }
            if !self.openingFinished {
                self.finishOpening(at: Date(timeIntervalSince1970: self.clock.now()))
            }
        }
    }

    /// Restart only the frame producer after an inactive foreground cover.
    /// The fresh request makes the map current immediately instead of waiting
    /// for the first cadence deadline.
    private func resumePresentation() {
        guard tickSchedulerSuspended else { return }
        tickSchedulerSuspended = false
        guard started else { return }
        startTicking()
        requestTick()
    }

    /// What the app can draw, which with a timetable in the bundle is the whole
    /// packed year and does not move as the clock is scrubbed.
    ///
    /// Re-read after a redraw all the same: without a timetable the span is the
    /// edges of the snapshot in hand, and that does change when one lands.
    private func updateScrubRange() async {
        guard let span = await drawableTimeSpan() else { return }
        timeSpan = span
    }

    private func drawableTimeSpan() async -> ClosedRange<Date>? {
        guard let span = await fleet.drawableSpan() else { return nil }
        let low = Date(timeIntervalSince1970: TimeInterval(span.lowerBound))
        let high = Date(timeIntervalSince1970: TimeInterval(span.upperBound))
        return low...high
    }

    // MARK: - The frame loop

    /// Positions are recomputed continuously so vehicles glide between refreshes
    /// rather than jumping once a minute.
    ///
    /// Fifteen times a second rather than sixty: a vehicle covers a metre or two
    /// in that time, which is well under a pixel at any zoom this map uses, and
    /// the work is a bbox query over several hundred journeys plus a source
    /// update. Sixty would spend four times the energy to move nothing visible.
    private func startTicking() {
        guard !tickSchedulerSuspended else { return }
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            // A deadline rather than a delay. Sleeping for the frame interval
            // *after* the work makes the period `work + interval`: twenty-five
            // milliseconds of drawing plus a thirty-three millisecond sleep is
            // seventeen frames a second, not thirty, and asking for a higher
            // rate by shortening the sleep only ever closes part of the gap.
            var next = ContinuousClock.now
            while !Task.isCancelled {
                guard let self else { return }
                self.requestCadenceTick()
                let interval = self.frameInterval
                self.pacedInterval = interval
                self.announce(interval)
                next += interval
                // A frame that overran does not get made up for by running the
                // next several back to back; that spirals under exactly the
                // load that caused it.
                let now = ContinuousClock.now
                if next < now { next = now }
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }

    /// The interval the sleeping loop is currently counting down.
    private var pacedInterval: Duration?

    /// The interval the map has already been told about, so it is told on a
    /// change rather than on every frame. Setting a display link's frame rate
    /// range is cheap but not free, and this runs thirty times a second.
    @ObservationIgnored private var announcedInterval: Duration?

    private func announce(_ interval: Duration) {
        guard announcedInterval != interval else { return }
        announcedInterval = interval
        onPace?(interval)
    }

    /// Start again from now, if the rate the loop is keeping is no longer the
    /// rate that is wanted.
    ///
    /// A deadline the loop is already inside cannot be shortened, and that only
    /// became something worth saying once one of the deadlines was a whole
    /// second. Zoom in from 8 to 13 and the loop is asleep until its second is
    /// up: the map arrives at the new zoom and then does nothing at all for as
    /// much as a second before the first frame of vehicles appears. Restarting
    /// ticks immediately and re-reads the rate, so crossing the threshold in
    /// either direction takes effect on the crossing rather than at the end of
    /// whatever the old rate had already committed to.
    ///
    /// Guarded on the interval rather than on the zoom, so the ordinary drift
    /// of a pinch — which changes the zoom on every frame and the rate on none
    /// of them — costs one `Duration` comparison and nothing else.
    private func repaceIfNeeded() {
        guard let pacedInterval, pacedInterval != frameInterval else { return }
        // On the next turn rather than here, because here can be inside the
        // very tick being restarted: a frame can move the camera — the debug
        // start eases, and following sets it every refresh — and a camera that
        // moves reports a zoom back. Cancelling the loop task from inside its
        // own `tick()` leaves that tick running with its loop already dead.
        //
        // Cleared rather than left, so the several camera events one gesture
        // produces queue one restart between them instead of one apiece; the
        // loop writes it again as soon as it is ticking at the new rate.
        self.pacedInterval = nil
        // A rate change is also a presentation-boundary change. In particular,
        // zoom can cross the point where geometry or full vehicle shapes are
        // requested while a Fleet query is suspended. Do not let that old frame
        // land after the new camera; the replacement is queued now and the pump
        // remains globally serial while the cancelled query unwinds.
        invalidateTickWork(requestingFreshFrame: true)
        Task { @MainActor [weak self] in self?.startTicking() }
    }

    /// How long to wait before drawing again, after the phone has had its say.
    ///
    /// `wantedInterval` below is the rate the *picture* wants, and it is a
    /// statement about motion: how far the fastest thing on screen travels
    /// between two frames. This is the rate the picture actually gets, and the
    /// difference between the two is everything the map cannot see — a sheet
    /// standing over it, a battery the reader has asked to be careful with, a
    /// chassis that has begun throttling itself.
    ///
    /// Kept separate rather than folded into the bands below, because the two
    /// answer different questions and a single expression mixing them would be
    /// readable as neither.
    var frameInterval: Duration {
        // A sheet over the map is a map nobody is looking at. It is still
        // there — SwiftUI keeps the view alive underneath — so without this the
        // loop goes on querying the viewport and re-uploading every vehicle
        // thirty times a second behind an opaque panel. The still-map rate is
        // the right one rather than stopping altogether: whatever is behind the
        // sheet has to be correct the instant it comes down, and a second is
        // well inside the dismissal.
        if mapObscured { return .seconds(1) }
        let wanted = wantedInterval
        guard powerFactor > 1 else { return wanted }
        // Never past the rate the map already keeps when it is a picture of the
        // country. Below that it stops feeling live, and a map that has stopped
        // feeling live is one the reader keeps prodding to check it is still
        // working — which costs more than the frames just saved.
        return min(Self.throttleFloor, wanted * powerFactor)
    }

    /// The rate the picture wants, before the phone gets a say.
    ///
    /// Fifteen a second is right for a map of dots and stays the default. It is
    /// not right for a map of vehicles: at zoom 17 a train covers seventy points
    /// a second, so fifteen frames is fifteen visible jumps. The rate rises
    /// with the zoom rather than with anything else, because the zoom is what
    /// decides both how far a vehicle moves on screen and how few of them are
    /// on it — the frames cost most where they are needed least.
    ///
    /// Asking for more than the loop can do makes the picture *worse*, and
    /// following is where that was learned. Sixty was tried, on the reasoning
    /// that following puts the whole map in motion rather than one dot on it,
    /// so every step is held for two refreshes and smears. The device answered
    /// twenty: a tick is a viewport query, a layout pass and a source upload,
    /// and none of that fits in sixteen milliseconds. The camera then moved
    /// twenty times a second instead of thirty and the map was jerkier than
    /// before. A rate that is not met is not a rate.
    ///
    /// Thirty is what this loop actually sustains at the zooms following
    /// happens at, so thirty is what it asks for.
    ///
    /// It falls away at the bottom as well as rising at the top, and for the
    /// mirror-image reason. Below zoom 9 the map is a picture of the country:
    /// nothing on it moves a pixel in a second, and the tick that would have
    /// advanced it is the most expensive one there is, because the viewport
    /// holds most of the running fleet. See `stillZoom`.
    private var wantedInterval: Duration {
        // Following comes first and ignores the rest, including the zoom floor
        // below. The camera is locked to a vehicle, so the rate the model
        // produces positions at is the rate the *whole map* moves at, and a map
        // stepping once a second is not a map anybody can read.
        if isFollowingVehicle { return .milliseconds(33) }
        // Far enough back that nothing visibly moves.
        //
        // A tick is not free at any zoom: `Fleet.vehicles` walks every running
        // journey in the country asking where it is, and at zoom 8 the answer
        // for nearly all of them is inside the box. That is fifteen thousand
        // positions a tick to advance a screenful of dots by a tenth of a pixel
        // — at zoom 8 a fast train covers about 0.4 points a second, so between
        // two of the old sixty-six-millisecond ticks it moved a fortieth of a
        // point. Once a second is still finer than the screen can show, and it
        // is fifteen times less work.
        if zoom < Self.stillZoom { return .seconds(1) }
        guard detailedVehicles, zoom >= VehicleShape.minZoom else {
            return .milliseconds(66)
        }
        return Self.pace(
            noFasterThan: zoom >= 14 ? .milliseconds(33) : .milliseconds(50),
            movingAt: fastestDrawn, metresPerPoint: metresPerPoint
        )
    }

    // MARK: - Backing off

    /// Whether something opaque is standing over the map.
    ///
    /// Written by `ContentView` for the sheets that take the whole screen, and
    /// deliberately not for the map settings sheet — that one is short on
    /// purpose, so the map stays visible while a slider is changing it, and a
    /// map you are watching change is the last thing to slow down.
    ///
    /// Out of observation: nothing draws from it, and a write that invalidated
    /// the view hierarchy every time a sheet opened would be paying for the
    /// saving twice.
    @ObservationIgnored var mapObscured = false {
        didSet {
            guard mapObscured != oldValue else { return }
            repaceIfNeeded()
        }
    }

    /// The multiplier the phone's own state puts on every frame interval.
    ///
    /// One is "no opinion". **Two** is Low Power Mode or a chassis reporting
    /// `.serious`: in the first the reader has asked for the battery to last,
    /// in the second the phone has already begun throttling itself, and the
    /// honest answer from something drawing a map thirty times a second is to
    /// draw it fifteen. **Four** is `.critical`, where iOS is dimming the
    /// screen and slowing the cores on its own and the only useful thing left
    /// is to stop asking.
    ///
    /// `.fair` is deliberately not in here. It is where a phone sits through
    /// ordinary use on a warm day, and halving the frame rate of the common
    /// case would be paying the cost of a thermal defence without there being
    /// a thermal problem.
    @ObservationIgnored private var powerFactor = 1.0

    /// The slowest the throttle may make the map, whatever the multipliers say.
    /// The same rate `stillZoom` already runs the country at, so the floor is
    /// one the map is known to be readable at rather than a new guess.
    private static let throttleFloor = Duration.seconds(1)

    /// Held only so the registrations outlive the call that made them.
    @ObservationIgnored private var powerObservers: [NSObjectProtocol] = []

    /// Watch what the phone says about its own state, and repace on a change.
    ///
    /// Both notifications, because the two are independent: Low Power Mode is
    /// the reader's decision and the thermal state is the hardware's, and
    /// either alone is reason enough to back off. Read once here as well as
    /// subscribed — a notification only reports a *change*, so an app launched
    /// with Low Power Mode already on would otherwise never hear about it.
    ///
    /// Both values were already being sampled for the diagnostics readout, and
    /// were used for nothing else: the app knew it was cooking the phone and
    /// went on asking for thirty frames a second anyway. See `DeviceLoad`.
    private func watchPower() {
        readPower()
        for name in [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
        ] {
            powerObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.readPower() }
            })
        }
    }

    private func readPower() {
        let info = ProcessInfo.processInfo
        let thermal: Double
        switch info.thermalState {
        case .critical: thermal = 4
        case .serious: thermal = 2
        default: thermal = 1
        }
        let factor = max(thermal, info.isLowPowerModeEnabled ? 2 : 1)
        guard factor != powerFactor else { return }
        let previous = powerFactor
        powerFactor = factor
        repaceIfNeeded()

        // These three are speculative improvements, not foreground answers.
        // Stop their timers and propagate cancellation into their coalesced
        // network requests while the reader or the hardware is asking for less
        // work; resume them from a fresh deadline once that pressure clears.
        if factor > 1 {
            refineTask?.cancel(); refineTask = nil
            liveTimingTask?.cancel(); liveTimingTask = nil
            learningTask?.cancel(); learningTask = nil
            // Once the timetable is usable, the rest of opening is only the
            // national geometry warm. Stop its producer first, then discard
            // queued speculative jobs; urgent viewport/selection geometry and
            // the build already executing are deliberately preserved.
            if openingFinished {
                openingTask?.cancel()
                openingTask = nil
            }
            Task { [fleet] in await fleet.cancelSpeculativeGeometry() }
        } else if previous > 1, started, !backgroundWorkSuspended {
            startLearning()
            if openingFinished {
                keepRefining()
                keepTimingsLive()
            } else if openingTask == nil {
                finishOpening(at: Date(timeIntervalSince1970: clock.now()))
            }
        }
    }

    /// How often the map has to be redrawn for the fastest thing on it to move
    /// smoothly, given how much ground a point of screen covers.
    ///
    /// **The rate was a zoom bucket, and the zoom is only half of the
    /// question.** Thirty ticks a second past zoom 14 is right for an intercity
    /// at line speed under a close camera and enormous for everything else: at
    /// zoom 14 a city tram at 20 km/h moves **0.057 of a point per tick**, so
    /// the map rebuilds and re-uploads every vehicle feature, every footprint
    /// polygon and every wagon placement seventeen times to advance a tram by
    /// one pixel.
    ///
    /// That is the shape of a *power* problem rather than a CPU one, which is
    /// how it presents: the parsing, tessellation and upload all happen on the
    /// renderer's own threads and the GPU, so the app's own CPU reads under a
    /// fifth while the phone reports serious energy use and gets hot — and a
    /// hot phone is throttled, which is where the dropped ticks come back from.
    ///
    /// So the rate is derived from movement instead: fast enough that nothing
    /// on screen advances more than `paceStepPoints` between two ticks, and no
    /// faster. It can only ever *lengthen* the interval — `noFasterThan` is the
    /// rate the zoom already asked for, and this never goes above it — so a
    /// close camera on a fast train is drawn exactly as it was, and the frames
    /// it gives back are the ones that were moving a tram a twentieth of a
    /// pixel.
    static func pace(
        noFasterThan floor: Duration, movingAt kmh: Double, metresPerPoint: Double
    ) -> Duration {
        guard kmh > 0, metresPerPoint > 0 else { return paceSlowest }
        let pointsPerSecond = (kmh / 3.6) / metresPerPoint
        guard pointsPerSecond > 0 else { return paceSlowest }
        // Quantised to a display frame, so an interval that drifts by a
        // millisecond as a vehicle accelerates does not restart the loop on
        // every tick. See `repaceIfNeeded`.
        let frames = (paceStepPoints / pointsPerSecond / paceQuantum).rounded(.down)
        let wanted = Duration.milliseconds(Int(frames * paceQuantum * 1000))
        return min(max(wanted, floor), paceSlowest)
    }

    /// How far the fastest thing on screen may move between two ticks.
    ///
    /// Well under a point, because a point is where stepping becomes something
    /// the eye can catch and this has to be a bound nobody can see rather than
    /// one that is usually fine. At two fifths, a vehicle crosses a pixel over
    /// three ticks at the slowest rate this allows.
    private static let paceStepPoints = 0.4

    /// The longest this will ever stretch the interval, whatever the
    /// arithmetic says.
    ///
    /// Nothing on the map moves a pixel in a seventh of a second at the zooms
    /// this applies to, but the map is not only the vehicles: a pinch, a
    /// selection, a label settling and the emerge animation all land on the
    /// same tick, and those are judged by hand rather than by how far a tram
    /// got. Six or seven a second is where the map still answers immediately.
    private static let paceSlowest = Duration.milliseconds(150)

    /// One frame of a 60 Hz display, which is the finest step worth asking for.
    private static let paceQuantum = 1.0 / 60

    /// The speed of the fastest vehicle currently drawn, in km/h.
    ///
    /// Read by `pace`, written once a tick from the fleet the tick just drew.
    /// Out of observation: it changes every tick and nothing renders it.
    @ObservationIgnored private var fastestDrawn = 0.0

    /// The zoom below which the map is a picture of the country rather than of
    /// a place, and redrawing it faster than once a second buys nothing.
    private static let stillZoom = 9.0

    /// How close two vehicles have to be on the ground before the second of
    /// them is only ever painted underneath the first.
    ///
    /// **Pulled back far enough, a dot stops being a position and becomes an
    /// area.** At zoom 6 a point of screen covers a kilometre, so Zurich, Bern,
    /// Geneva and Basel are two or three points wide apiece and each holds two
    /// or three hundred services. Measured over the shipped timetable on a
    /// weekday morning, 5,819 vehicles are in view and about 1,200 of them land
    /// anywhere a reader could tell apart; the rest are built into features,
    /// serialised, handed to the renderer, tessellated and painted, every tick,
    /// to put colour inside a disc that was already that colour. Asking for one
    /// dot per dot leaves 21% of the fleet at zoom 6 and 11% at zoom 5. See
    /// `Fleet.thinTheHidden`, which does the dropping.
    ///
    /// The dot's own radius is the distance, read off the curve the layer is
    /// drawn with so the two cannot drift apart.
    ///
    /// Nothing is thinned once vehicles can carry line numbers. The renderer
    /// may hide a number that has no collision-free position, but it needs the
    /// complete set to reconsider placement as the camera moves. Eased out over
    /// the zoom below that rather than switched off at it, so the dots it was
    /// holding back arrive across a pinch instead of all in the one frame that
    /// crosses zoom 11.
    private static func dotSpacing(at zoom: Double, metresPerPoint: Double) -> Double {
        let room = min(1, max(0, VehicleDot.labelMinZoom - zoom))
        guard room > 0 else { return 0 }
        return VehicleDot.radius(atZoom: zoom) * metresPerPoint * room
    }

    /// Whether the one frame pump is running, and whether another frame was
    /// requested while it was suspended in Fleet.
    @ObservationIgnored private var tickRunning = false
    @ObservationIgnored private var tickPending = false

    /// Monotonic identities for requests and for the lifetime they belong to.
    ///
    /// Request identities let an awaited caller wait for *its frame or a newer
    /// one*, while the epoch invalidates an in-flight frame across suspension or
    /// a pace change. The pump remains single-file even while an invalidated
    /// Fleet call is unwinding; a replacement is pending, never run beside it.
    @ObservationIgnored private var tickRequestedGeneration: UInt64 = 0
    @ObservationIgnored private var tickFinishedGeneration: UInt64 = 0
    @ObservationIgnored private var tickEpoch: UInt64 = 0
    @ObservationIgnored private var tickSchedulerSuspended = false

    private struct TickWaiter {
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    @ObservationIgnored private var tickWaiters: [TickWaiter] = []

    /// Ask for a redraw because a setting changed.
    ///
    /// Coalesced, and that is the whole point of it. A `Slider` emits a value
    /// for every frame of the drag, and a `Task { await tick() }` per value
    /// queued one full tick per frame on the main actor — each of them
    /// re-reading the fleet and rebuilding the geometry for every vehicle in
    /// view. Measured at zoom 10 over central Switzerland, one drag left 239
    /// ticks in flight and took ten seconds to drain: a main thread that far
    /// behind cannot answer a tap, which is the Done button that does nothing
    /// and the memory that climbs while the backlog is held.
    ///
    /// At most one runs at a time, and a request arriving while one is running
    /// buys exactly one more — so the last value of a drag is always the one
    /// that ends up drawn, and the queue cannot grow past two.
    func requestTick() {
        _ = enqueueTick()
    }

    /// The frame clock is only a producer. It must go through the same pump as
    /// settings, refreshes and selection changes or its direct `tick()` can
    /// overtake one of theirs at an `await`.
    private func requestCadenceTick() {
        _ = enqueueTick()
    }

    /// Ask for a frame and wait until that request, or a newer coalesced request,
    /// has been presented. Startup and a selected vehicle's live retiming need
    /// this ordering; ordinary callers deliberately remain fire-and-forget.
    private func requestTickAndWait() async {
        let generation = enqueueTick()
        guard tickFinishedGeneration < generation else { return }
        await withCheckedContinuation { continuation in
            // The pump can complete only by returning to this actor, but keep the
            // second check beside registration so the barrier stays correct if
            // its implementation ever stops inheriting MainActor isolation.
            if tickFinishedGeneration >= generation {
                continuation.resume()
            } else {
                tickWaiters.append(TickWaiter(
                    generation: generation, continuation: continuation
                ))
            }
        }
    }

    @discardableResult
    private func enqueueTick() -> UInt64 {
        tickRequestedGeneration &+= 1
        let generation = tickRequestedGeneration
        guard !tickSchedulerSuspended else {
            // An awaited refresh may finish after the scene resigned active. It
            // must not hang waiting for a renderer that is deliberately asleep.
            finishTickRequests(through: generation)
            return generation
        }
        tickPending = true
        startTickPumpIfNeeded()
        return generation
    }

    private func startTickPumpIfNeeded() {
        guard !tickSchedulerSuspended, !tickRunning, tickPending else { return }
        tickRunning = true
        tickPumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainTickRequests()
        }
    }

    /// The sole caller of `performTick`. A request made while it is running only
    /// replaces the pending identity; there is no second task to publish first.
    private func drainTickRequests() async {
        defer {
            tickRunning = false
            tickPumpTask = nil
            // Cancellation is used to invalidate the frame already in Fleet.
            // Start its replacement only after that call has returned, keeping
            // the expensive actor work globally serial as well as publication.
            if !tickSchedulerSuspended, tickPending {
                startTickPumpIfNeeded()
            }
        }

        while !Task.isCancelled, !tickSchedulerSuspended, tickPending {
            tickPending = false
            let generation = tickRequestedGeneration
            let epoch = tickEpoch
            if await performTick(generation: generation, epoch: epoch) {
                finishTickRequests(through: generation)
            }
        }
    }

    private func finishTickRequests(through generation: UInt64) {
        if generation > tickFinishedGeneration {
            tickFinishedGeneration = generation
        }
        guard !tickWaiters.isEmpty else { return }
        var waiting: [TickWaiter] = []
        waiting.reserveCapacity(tickWaiters.count)
        for waiter in tickWaiters {
            if waiter.generation <= generation {
                waiter.continuation.resume()
            } else {
                waiting.append(waiter)
            }
        }
        tickWaiters = waiting
    }

    /// Make work sampled for an old presentation lifetime unable to publish.
    /// A fresh request stays pending behind it for re-pacing; suspension instead
    /// finishes barriers because no renderer will run until `resume`.
    private func invalidateTickWork(requestingFreshFrame: Bool) {
        tickEpoch &+= 1
        tickPending = false
        tickPumpTask?.cancel()
        if requestingFreshFrame, !tickSchedulerSuspended {
            _ = enqueueTick()
        } else {
            finishTickRequests(through: tickRequestedGeneration)
        }
    }

    /// How long a tick takes to get from reading the clock to handing the
    /// renderer the geometry it read the clock for, smoothed over many of them.
    ///
    /// This is the whole of the "jittery" half of the complaint, and it is not
    /// a frame-rate problem — it happens at a rock-steady thirty ticks a
    /// second. A position is a function of an instant, so a tick that samples
    /// `t` and uploads at `t + l` draws the fleet exactly `l` seconds behind
    /// where it should be. A *constant* `l` is invisible: everything is late by
    /// the same fraction of a second and nothing about the picture says so. A
    /// `l` that varies is drawn as varying speed — the fleet surges when a tick
    /// is quick and stalls when one is slow, thirty times a second.
    ///
    /// And `l` varied a lot, because the upload used to sit at the end of a
    /// queue of unrelated `await`s: the track refresh, the stop query, the
    /// plate layout, and — whenever a vehicle was open, which is exactly when
    /// somebody is watching one move — two more hops through the fleet actor to
    /// re-read the panel's copy. Those are now after the frame rather than in
    /// front of it, which removes most of the variance; this removes the rest
    /// of the *offset* by sampling that much ahead, so what is uploaded is
    /// right for the moment it actually reaches the screen rather than for the
    /// moment the tick began.
    private var presentationLead = 0.0

    /// The tick's four parts, smoothed, waiting for the next readout sample.
    /// Deliberately not observed — see where it is written in `tick`.
    @ObservationIgnored private var tickCost = FrameStats.TickCost()

    /// Which vehicles the renderer is currently drawing as solid meshes.
    ///
    /// Written by `MapCoordinator` after it has decided, read by
    /// `rebuildShapes` on the tick after that. A vehicle standing up as a mesh
    /// has every polygon of its trim thrown away — see
    /// `VehicleShapes.features` — so building the trim for it is work the map
    /// pays for and no layer can spend. Skipping it takes a screenful of
    /// vehicles from about twenty-eight polygons apiece to about four.
    ///
    /// **One tick behind, and it has to be.** Whether a vehicle stands up
    /// depends on whether every one of its wagons has a registered mesh, which
    /// is only known once the meshes have been asked for — inside the draw
    /// this same tick. The set is the same from one frame to the next except
    /// where a mesh has just been baked or the camera has just come down, and
    /// the second of those clears it at the moment it happens rather than a
    /// frame later: see `MapCoordinator.applySolidity`.
    ///
    /// Out of observation, like the frame versions beside it: it is read
    /// inside the tick, and a write that invalidated the view would put the
    /// map back into the loop this exists to shorten.
    @ObservationIgnored var standingVehicles: Set<String> = []

    /// The most the sampling is allowed to run ahead, in seconds.
    ///
    /// A ceiling rather than a target. The lead is a measurement, and a
    /// measurement taken across a stall — a backgrounded app, a style reload —
    /// would otherwise throw the whole fleet forward by however long the stall
    /// was. A sixth of a second is past anything a healthy tick spends and far
    /// under anything that would show as vehicles running ahead of themselves.
    private static let maxPresentationLead = 1.0 / 6

    /// Everything a moving frame is allowed to read after its first suspension.
    ///
    /// Fleet is another actor. While it answers, the main actor can accept a new
    /// viewport, zoom, selection or renderer capability. Reading any of those
    /// again below would make a frame whose positions were queried for one camera
    /// and whose footprints were built for another. A snapshot keeps an old frame
    /// coherent; the coalesced request behind it then draws the newest state.
    private struct TickFrame {
        let generation: UInt64
        let epoch: UInt64
        let askedAt: ContinuousClock.Instant
        let sampled: Double
        let precise: Double
        let now: Timestamp
        let fraction: Double
        let viewport: BBox
        let zoom: Double
        let metresPerPoint: Double
        let detailed: Bool
        let query: BBox
        let selectedID: String?
        let followedID: String?
        let hiddenModes: Set<Mode>
        let dotSpacing: Double
        let shapesPossible: Bool
        let solidShapes: Bool
        let bakedModels: Bool
        let standingVehicles: Set<String>
        let spreadVehicles: Bool
        let pixelsPerPoint: Double
    }

    private func captureTickFrame(generation: UInt64, epoch: UInt64) -> TickFrame {
        let askedAt = ContinuousClock.now
        let sampled = clock.now()
        let precise = sampled + presentationLead
        let now = Timestamp(precise.rounded(.down))
        let box = viewport
        let frameZoom = zoom
        let frameMetresPerPoint = metresPerPoint
        let canDrawShapes = detailedVehicles && frameZoom >= VehicleShape.minZoom
        let selectedID: String? = {
            if case let .vehicle(id) = selection { return id }
            return nil
        }()
        let followedID = isFollowingVehicle ? selectedID : nil
        let spacing = Self.dotSpacing(
            at: frameZoom, metresPerPoint: frameMetresPerPoint
        )

        return TickFrame(
            generation: generation,
            epoch: epoch,
            askedAt: askedAt,
            sampled: sampled,
            precise: precise,
            now: now,
            fraction: precise - Double(now),
            viewport: box,
            zoom: frameZoom,
            metresPerPoint: frameMetresPerPoint,
            detailed: frameZoom >= 10,
            query: canDrawShapes
                ? box.padded(byMetres: VehicleShape.longestVehicleMetres)
                : box,
            selectedID: selectedID,
            followedID: followedID,
            hiddenModes: hiddenModes,
            dotSpacing: spacing,
            shapesPossible: canDrawShapes,
            solidShapes: detailedVehicles && solidVehicles
                && VehicleShape.solidity(pitch: pitch, zoom: frameZoom) > 0,
            bakedModels: bakedModels,
            standingVehicles: standingVehicles,
            spreadVehicles: true,
            pixelsPerPoint: UIScreen.main.nativeScale
        )
    }

    private func frameIsCurrent(_ frame: TickFrame) -> Bool {
        !tickSchedulerSuspended
            && frame.epoch == tickEpoch
            && frame.generation > tickFinishedGeneration
            && !Task.isCancelled
    }

    /// Query and publish one immutable frame. Called only by
    /// `drainTickRequests`, which is what makes the awaits below globally serial.
    private func performTick(generation: UInt64, epoch: UInt64) async -> Bool {
        let frame = captureTickFrame(generation: generation, epoch: epoch)
        // Four marks, so the readout can say which of the tick's four parts
        // the loop is actually behind on. The first covers everything up to
        // the fleet answering — the window check as well as the query — because
        // both are the same thing from the frame's point of view: the tick
        // suspended on an actor it does not own. See `FrameStats.TickCost`.
        // The timetable is expanded around a moment, not for all time, so the
        // window has to follow the clock. Checked here because this is the one
        // place that sees every way the clock can move — the second hand, the
        // scrubber, and the jump the time picker makes — but rate-limited to a
        // wall-clock second, because the check itself is an actor hop and this
        // runs fifteen times of those a second.
        if frame.sampled - lastWindowCheck > 1
            || abs(frame.sampled - lastWindowCheck) > 60 {
            let redrawn = await fleet.redrawTimetableIfNeeded(
                at: Date(timeIntervalSince1970: frame.sampled)
            )
            guard frameIsCurrent(frame) else { return false }
            lastWindowCheck = frame.sampled
            if redrawn {
                status = await fleet.currentStatus()
                await updateScrubRange()
                guard frameIsCurrent(frame) else { return false }
            }
        }
        var found = await fleet.vehicles(
            in: frame.query, at: frame.now, fraction: frame.fraction,
            withGeometry: frame.detailed, including: frame.selectedID,
            hiding: frame.hiddenModes, noCloserThan: frame.dotSpacing
        )
        guard frameIsCurrent(frame) else { return false }
        let answeredAt = ContinuousClock.now
        found.sort {
            $0.mode.drawOrder == $1.mode.drawOrder
                ? $0.id < $1.id
                : $0.mode.drawOrder < $1.mode.drawOrder
        }
        found = collapsedPointVehicles(found, selectedID: frame.selectedID)
        // What the next interval is paced off. See `pace`.
        var fastest = 0.0
        for vehicle in found where vehicle.speed > fastest { fastest = vehicle.speed }
        fastestDrawn = fastest
        vehicles = found
        rebuildShapes(found, for: frame)
        frameVersion &+= 1
        let shapedAt = ContinuousClock.now

        #if DEBUG
        Diagnostics.sample(
            now: frame.now, zoom: frame.zoom, viewport: frame.viewport,
            drawn: found.count, onTrack: found.count { $0.onTrack },
            fleet: status.vehicles
        )
        #endif

        // The frame goes out here, immediately behind the positions it is made
        // of, and everything else this tick does happens after it.
        //
        // Nothing below this line moves. The stops, the plates, the railway
        // overlay and the drawn route are all fixed geometry that changes when
        // the camera crosses a band or a selection changes, and each is guarded
        // by its own revision in `MapCoordinator` — so letting them land one
        // tick later costs a frame on something that was not going to look any
        // different, and *not* letting them costs several milliseconds of
        // varying delay on the one thing that does move. See `presentationLead`.
        //
        // `setCamera` lands on the very next rendered frame; a source update
        // goes to the renderer and lands on a later one. Moving the camera
        // first therefore published a camera for tick N against geometry still
        // showing tick N-1, so the followed vehicle was drawn one tick's travel
        // off centre — and back on centre the frame after, thirty times a
        // second. That is the "constantly going a bit back and forth".
        //
        // Issued after `onFrame` the camera can only ever lag the geometry, and
        // lagging by less than a frame is invisible where alternating either
        // side of it is not.
        onFrame?()
        let pushedAt = ContinuousClock.now

        // Keep the camera on whatever is being watched.
        //
        // From `vehicles` rather than from `selectedVehicle`, and that is the
        // whole difference between panning and lurching. `selectedVehicle` is
        // the panel's copy, and it is deliberately refreshed at most once a
        // second — see `panelCadence`, which exists so a card whose words have
        // not changed does not invalidate a sheet thirty times a second. Read
        // for the camera, that cadence *is* the pan: one jump per second
        // however smoothly the vehicle underneath it is drawn.
        //
        // The query above names this id as `including:`, so a train that was
        // just re-timed out of the viewport is still in `vehicles` and still
        // has a position the follower can ease toward. Without that it was
        // simply gone: the camera stayed put and the thing the reader tapped
        // vanished.
        if let followedID = frame.followedID,
           isFollowingVehicle,
           case let .vehicle(currentID) = selection,
           currentID == followedID,
           let watched = found.first(where: { $0.id == followedID }) {
            // The whole snapshot, and `precise` rather than the wall clock:
            // the follower needs the vehicle's bearing and its label every
            // refresh, and finding them by walking `vehicles` sixty or a
            // hundred and twenty times a second is a linear scan of the
            // viewport on the main thread for a value that changes once a tick.
            onRecentre?(watched, frame.precise)
        }

        // What that just cost, measured at the only place that can measure it:
        // between reading the clock and handing the result to the renderer.
        // Heavily smoothed, because the lead has to be steadier than the thing
        // it is correcting for — a lead that chased every slow tick would be a
        // second source of the jitter rather than the cure for it.
        let served = clock.now() - frame.sampled
        if served > 0, served < 1 {
            presentationLead = min(
                Self.maxPresentationLead, max(0, presentationLead * 0.9 + served * 0.1)
            )
        }

        // The frame is finished and measured here. What is left below is
        // settled off the frame's clock — see `settleSoon`.
        // Into a plain field, not into `frameStats`. The published stats are
        // written four times a second precisely so the view showing them is
        // not invalidated thirty; folding the split in here would undo that.
        // `recordFrame` picks it up on its own cadence.
        if showDiagnostics {
            let endedAt = ContinuousClock.now
            tickCost.blend(
                fleet: (answeredAt - frame.askedAt).seconds * 1000,
                shapes: (shapedAt - answeredAt).seconds * 1000,
                push: (pushedAt - shapedAt).seconds * 1000,
                rest: (endedAt - pushedAt).seconds * 1000
            )
        }
        recordFrame()
        // Asked for on every tick, including the half-dozen taken by hand — a
        // setting changed, a refresh landed, a live timing applied — because
        // each of those wants the fixed geometry brought up with it. Asking is
        // free and coalesced; it is the *waiting* that was expensive.
        settleSoon()
        return true
    }

    /// Whether a settling pass is already running, so the frame loop asking for
    /// one on every tick queues at most one at a time.
    private var settling = false
    private var settleTask: Task<Void, Never>?
    private var settleGeneration: UInt64 = 0

    /// Ask for the fixed geometry to be brought up to date, without waiting.
    ///
    /// **The frame must not be held up by things that are not moving.** Every
    /// `await` below hops onto the fleet actor and back onto the main actor,
    /// and the tick is suspended across the pair of them: the wall clock runs
    /// whether or not the main thread has anything to do, and the tick's period
    /// is what the frame rate is measured from. That is how a map can render a
    /// perfectly steady sixty and still tick at twenty-five — the frame is not
    /// working, it is waiting.
    ///
    /// And waiting for nothing, nearly always. The tracks, the tunnels, the
    /// plates and the stops are each guarded on the viewport, so on a map
    /// nobody is panning every one of them looks at the box, finds it has not
    /// moved and returns — but the *hop* to find that out is paid all the same,
    /// four times, thirty times a second, in front of the vehicles.
    ///
    /// So the vehicles go out on the tick and this is started beside them
    /// rather than behind them. It is `@MainActor` like everything else here,
    /// so it interleaves at its own await points and never races the frame; and
    /// it is coalesced, so a pass that takes longer than a tick is not asked
    /// for again until it has finished. Everything in it is idempotent and
    /// guarded on its own revision, which is what makes skipping a request
    /// harmless: the next tick asks again.
    private func settleSoon() {
        guard !backgroundWorkSuspended, !settling else { return }
        settling = true
        settleGeneration &+= 1
        let generation = settleGeneration
        settleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.settleWhatDoesNotMove()
            guard self.settleGeneration == generation else { return }
            self.settling = false
            self.settleTask = nil
        }
    }

    /// The stops, the plates, the rails, the bores and the open vehicle's card.
    ///
    /// Split out of `tick` so that none of it is on the frame's clock. See
    /// `settleSoon`, which explains why that matters more than it looks.
    private func settleWhatDoesNotMove() async {
        guard !backgroundWorkSuspended, !Task.isCancelled else { return }
        let box = viewport
        let now = Timestamp(clock.now().rounded(.down))
        let plateMark = plateRevision
        let trackMark = tracks.count
        let routeMark = selectedGeometryRevision
        let cablewayMark = cablewaysRevision

        await refreshTracksIfNeeded()
        guard !backgroundWorkSuspended, !Task.isCancelled else { return }
        await refreshTunnelsIfNeeded()
        guard !backgroundWorkSuspended, !Task.isCancelled else { return }
        await refreshCablewaysIfNeeded(at: now)
        guard !backgroundWorkSuspended, !Task.isCancelled else { return }

        // Fed generously and filtered by the layers themselves: the three stop
        // bands each carry their own zoom range, so the source only has to hold
        // what any of them might want. Below 12 only railway stations are drawn
        // at all, so only those are fetched.
        // Guarded, unlike `vehicles`: a vehicle moves every tick so the array
        // genuinely differs each time, but the stops in view only change when
        // the camera crosses a zoom band or pans onto new ground. Writing them
        // fifteen times a second regardless invalidated every view reading
        // them for a value that had not changed — and re-uploading fifteen
        // hundred unchanged stop features to the renderer alongside it, which
        // is what `stopsVersion` now spares the map.
        //
        // **And only when the view has moved**, which is the guard the plates,
        // the tunnels and the rails beside it have always had and this one did
        // not. `stopsVersion` spared the *renderer* the re-upload, but the ask
        // itself still ran on every tick: a hop onto the fleet actor, a walk of
        // the stop grid over every cell in the box, an array of up to fifteen
        // hundred `StopPlace`s built, and then that array compared element by
        // element against the one already held — thirty times a second, to
        // arrive at "the same stops as last time" on all but the few ticks
        // where the camera actually moved.
        //
        // The tick *waits* on that, so it is on the frame's clock whether or
        // not it is on the main thread, and the vehicles are what is being
        // held up. Guarded, a map nobody is panning does none of it.
        let band: Int = !showStops ? 0 : (zoom >= 12 ? 2 : (zoom >= 8 ? 1 : 0))
        let stillInside = band == stopsBand && stopsViewport.map {
            $0.contains(lon: box.west, lat: box.south)
                && $0.contains(lon: box.east, lat: box.north)
        } == true
        var restated = false
        if !stillInside {
            // Generously, so the next pan of a few points is inside the box
            // already fetched rather than another walk of the grid — and over
            // the circle the screen turns inside rather than over the screen,
            // so that turning the map is not a pan at all. See `BBox.turned`.
            let generous = box.turned().padded(by: 0.25)
            let foundStops: [StopPlace]
            // The caps rise with the box, so the density at which they bite is
            // the one they were chosen for rather than one two-and-a-half times
            // tighter. They are a guard against a pathological ask, not a
            // budget: at the zoom band 2 covers, a viewport holding two
            // thousand stop places is a viewport of central Zurich.
            switch band {
            case 2: foundStops = await fleet.stopPlaces.within(generous, limit: 3000)
            case 1: foundStops = await fleet.stopPlaces.within(generous, railOnly: true, limit: 800)
            default: foundStops = []
            }
            stopsBand = band
            stopsViewport = generous
            if stops != foundStops {
                stops = foundStops
                stopsVersion &+= 1
                restated = true
            }
        }

        await refreshPlatesIfNeeded()
        guard !backgroundWorkSuspended, !Task.isCancelled else { return }

        let panelSelection = selection
        let panelGeneration = selectionGeneration
        if case let .vehicle(id) = panelSelection {
            await loadVehicle(
                id: id, at: now,
                expected: panelSelection, generation: panelGeneration
            )
            guard !backgroundWorkSuspended, !Task.isCancelled else { return }
        } else if case let .service(id, departure) = panelSelection {
            await loadVehicle(
                id: id, at: now, boardDeparture: departure,
                expected: panelSelection, generation: panelGeneration
            )
            guard !backgroundWorkSuspended, !Task.isCancelled else { return }
        }

        // A second frame only if one of them actually produced something. Each
        // source is guarded on its own revision, so this costs a handful of
        // integer comparisons on the ticks where nothing changed — which is
        // nearly all of them, on a map nobody is panning.
        if restated || plateRevision != plateMark || tracks.count != trackMark
            || cablewaysRevision != cablewayMark
            || selectedGeometryRevision != routeMark {
            onFrame?()
        }

        // Whether this phone is on one of the vehicles it has just drawn.
        //
        // Called every tick and rate-limited inside, because the thing that
        // decides when to ask is the age of the trail rather than the frame —
        // and it returns immediately on all but one tick in sixty. The ask
        // itself is not awaited: it walks the fleet, and a frame cannot.
        feedRideTrail()
        rides.consider(fleet: fleet, clock: clock)
    }

    /// The open vehicle, as one line of evidence.
    private func selectedSummary() -> String {
        guard case let .vehicle(id) = selection,
              let vehicle = vehicles.first(where: { $0.id == id })
        else { return "" }
        let layout = layouts.layout(for: vehicle, modeColour: vehicle.mode.hex)
        let source = layout.source == .observed ? "service" : "library"
        return "\(vehicle.line) \(layout.name ?? "?") · \(layout.units.count)×"
            + " \(Int(layout.length.rounded()))m · \(source)"
            + " · \(vehicle.onTrack ? "on track" : "chord")"
    }

    /// Measure the draw loop and publish it, for the readout.
    ///
    /// Rate-limited hard. The whole point of the numbers is what the loop is
    /// doing at thirty frames a second, and writing them at thirty frames a
    /// second would invalidate the view showing them just as often — which
    /// would make the readout the most expensive thing on the screen and the
    /// figures it prints untrue of a map without it.
    private func recordFrame() {
        let now = Date()
        if let last = lastFrameAt {
            let elapsed = now.timeIntervalSince(last)
            // An exponential average, so a single stalled frame does not read
            // as a collapse and a recovery does not read as a spike.
            smoothedFrameSeconds = smoothedFrameSeconds == 0
                ? elapsed
                : smoothedFrameSeconds * 0.85 + elapsed * 0.15
        }
        lastFrameAt = now

        guard showDiagnostics, now.timeIntervalSince(frameStatsAt) >= 0.25 else { return }
        frameStatsAt = now
        frameStats = FrameStats(
            vehicles: vehicles.count,
            shapes: vehicleShapes.count,
            parts: vehicleShapes.reduce(0) { $0 + $1.parts.count },
            stops: stops.count,
            tracks: tracks.count,
            renderFps: renderFps,
            ticks: smoothedFrameSeconds > 0 ? 1 / smoothedFrameSeconds : 0,
            targetTicks: 1 / max(0.001, frameInterval.seconds),
            zoom: zoom,
            centre: Coord(
                lon: (viewport.west + viewport.east) / 2,
                lat: (viewport.south + viewport.north) / 2
            ),
            metresPerPoint: metresPerPoint,
            learnedTrains: layouts.count,
            learnedLines: layouts.patternCount,
            asked: askedFormations.count,
            askRate: recentAsks.count,
            net: NetworkMeter.shared.reading(),
            selected: selectedSummary(),
            ride: rides.summary,
            // Sampled on its own clock — see `DeviceLoad`, which will not do
            // the syscalls more than once a second whoever asks.
            load: DeviceLoad.sample(),
            cost: tickCost
        )
    }

    /// How many vehicles may be drawn as shapes in one frame.
    ///
    /// Not a rendering limit — it is a limit on the work of *building* them,
    /// which happens on the main actor fifteen times a second. In practice the
    /// zoom that makes a vehicle worth drawing also makes the viewport small
    /// enough that this is never reached; it is here so that a tilted camera
    /// looking down a valley at zoom 13, which can hold a great many
    /// intercities at once, degrades to dots rather than to a dropped frame.
    private static let shapeLimit = 260

    /// Lay out every vehicle that is big enough on screen to be worth it.
    /// Whether anything on screen could be drawn as a vehicle rather than a dot.
    var shapesPossible: Bool { detailedVehicles && zoom >= VehicleShape.minZoom }

    /// How far through the change from dot to drawing each vehicle is.
    ///
    /// The threshold is a decision — this vehicle is long enough on screen to
    /// be worth drawing, or it is not — and what used to happen was that the
    /// decision was smeared across a zoom band: `emergence` ramped from 0 to 1
    /// over the zooms either side of it, so a map parked in the middle of that
    /// band held the whole fleet at half opacity indefinitely, and a slow
    /// pinch dragged every vehicle in the country in and out for as long as
    /// the finger was moving. Opacity was doing the job of a switch.
    ///
    /// So the switch is a switch, and the *animation* is put on a clock of its
    /// own: crossing the threshold starts a change that takes
    /// `VehicleShape.emergeSeconds` and finishes whether or not the camera
    /// moves again. Zoom decides; time draws.
    private var emerging: [String: Double] = [:]
    /// When `emerging` was last stepped, so the step is in seconds rather than
    /// in frames. A dropped frame must not slow the change down.
    private var lastEmergeStep: TimeInterval?

    private struct PointVehicleKey: Hashable {
        var mode: Mode
        var line: String
        var operatorName: String
        var lon: Int
        var lat: Int
    }

    /// Co-located runs of a service with no drawable route are one map object.
    ///
    /// An elevator may have a timetable row every few minutes and every one of
    /// those rows can be alive during the terminus hold. They all occupy the
    /// same point and no picture can distinguish them, so retain one dot — or
    /// the selected one, if the reader already picked a particular run.
    private func collapsedPointVehicles(
        _ candidates: [VehicleSnapshot], selectedID: String?
    ) -> [VehicleSnapshot] {
        var result: [VehicleSnapshot] = []
        result.reserveCapacity(candidates.count)
        var representative: [PointVehicleKey: Int] = [:]

        for vehicle in candidates {
            guard !VehicleShape.hasDrawableRoute(
                vehicle, vehicleLength: 0
            ) else {
                result.append(vehicle)
                continue
            }

            // A hundred-thousandth of a degree is roughly a metre here. The
            // lift rows in question are exactly co-located; rounding only
            // absorbs harmless coordinate noise without merging neighbouring
            // platforms or two different service numbers.
            let key = PointVehicleKey(
                mode: vehicle.mode,
                line: vehicle.line,
                operatorName: vehicle.operatorName ?? "",
                lon: Int((vehicle.lon * 100_000).rounded()),
                lat: Int((vehicle.lat * 100_000).rounded())
            )
            if let index = representative[key] {
                if vehicle.id == selectedID { result[index] = vehicle }
            } else {
                representative[key] = result.count
                result.append(vehicle)
            }
        }
        return result
    }

    private func rebuildShapes(_ candidates: [VehicleSnapshot], for frame: TickFrame) {
        guard frame.shapesPossible else {
            if !vehicleShapes.isEmpty { vehicleShapes = []; shapesByID = [:] }
            // `emerging` is deliberately kept. Zoom 12.5 is where shapes are
            // allowed at all, and it is also where a long train crosses its own
            // floor — so clearing here would make the one gesture this exists
            // for, pinching in past that zoom, the one gesture that snaps.
            // Only the clock is reset, so the first frame back steps by nothing
            // and the change starts from where it was left.
            lastEmergeStep = nil
            // No body is visible to carry a lateral transition across this
            // boundary. Re-entering shape range should establish the vehicles
            // now in view, not resume offsets belonging to an old viewport.
            lateralOffsets = [:]
            spreadVehicleIDs = []
            return
        }
        // Clamped, because the gap across a backgrounded app is minutes and a
        // step that size is the change happening between two frames — which is
        // the right answer, but by way of a number worth not multiplying by.
        let now = Date.timeIntervalSinceReferenceDate
        let dt = min(0.25, max(0, now - (lastEmergeStep ?? now)))
        lastEmergeStep = now
        let step = VehicleShape.emergeSeconds > 0 ? dt / VehicleShape.emergeSeconds : 1
        let selectedID = frame.selectedID

        let sideways = spread(
            candidates, enabled: frame.spreadVehicles, elapsed: dt
        )
        let ringedID = selectedID.flatMap { id -> String? in
            ringSelection(
                of: candidates.first { $0.id == id },
                following: frame.followedID == id,
                at: frame.precise
            ) ? id : nil
        }
        // Slicing a vehicle into slabs costs about as much again as drawing it
        // flat, and on a map looking straight down nothing would ever look at
        // the result. Asked once for the whole rebuild rather than per vehicle:
        // it is a fact about the camera, and the camera does not move between
        // two vehicles of the same tick.
        let solid = frame.solidShapes

        var built: [VehicleFootprint] = []
        built.reserveCapacity(min(candidates.count, Self.shapeLimit))
        var byID: [String: VehicleFootprint] = [:]
        // Rebuilt rather than pruned: a vehicle that has left the feed has to
        // leave this too, and rebuilding is one pass over the same list the
        // loop below already walks.
        var stillEmerging: [String: Double] = [:]
        stillEmerging.reserveCapacity(emerging.count)
        for vehicle in candidates {
            if built.count >= Self.shapeLimit { break }
            let layout = layouts.layout(for: vehicle, modeColour: vehicle.mode.hex)
            // With no meaningful line behind the point there is nowhere honest
            // to put a body. Leave the dot in place; the point collapse above
            // has already reduced identical elevator runs to one of those.
            guard VehicleShape.hasDrawableRoute(
                vehicle, vehicleLength: layout.length
            ) else {
                stillEmerging[vehicle.id] = 0
                continue
            }
            // The decision, taken on the same two numbers the footprint takes
            // it on, before anything is built: this vehicle is long enough on
            // screen to be drawn, or it is a dot.
            let threshold = VehicleShape.emergeAt(
                bodies: layout.units.count, hanging: Cableway.hangs(vehicle)
            )
            let target: Double = layout.length / frame.metresPerPoint >= threshold ? 1 : 0
            // A vehicle seen for the first time snaps. Panning onto a station
            // full of trains is not fifty vehicles arriving; they were already
            // there, and animating them in is the map inventing an event.
            let shown: Double
            if let current = emerging[vehicle.id] {
                let delta = target - current
                shown = abs(delta) <= step ? target : current + (delta < 0 ? -step : step)
            } else {
                shown = target
            }
            // Tracked even at nothing. Dropping the entry would make the next
            // frame treat the vehicle as newly seen, and newly seen snaps —
            // which is every vehicle waiting below its threshold snapping into
            // being the moment the reader zooms in.
            stillEmerging[vehicle.id] = shown
            guard shown > 0 else { continue }
            guard let shape = VehicleShape.footprint(
                of: vehicle, layout: layout, metresPerPoint: frame.metresPerPoint,
                pixelsPerPoint: frame.pixelsPerPoint,
                selected: vehicle.id == selectedID,
                ringed: vehicle.id == ringedID,
                lateralOffset: sideways[vehicle.id] ?? 0,
                solid: solid, extruded: !frame.bakedModels,
                emerged: shown,
                // Nothing but bodies for a vehicle the renderer is drawing as
                // a mesh: the rest of its flat drawing cannot be painted by
                // anything. See `standingVehicles`.
                bodiesOnly: frame.standingVehicles.contains(vehicle.id)
            ) else { continue }
            built.append(shape)
            byID[vehicle.id] = shape
        }
        emerging = stillEmerging
        vehicleShapes = built
        shapesByID = byID
    }

    /// Whether the selection ring is still worth drawing round the vehicle.
    ///
    /// The ring answers one question — *which one did I tap* — and it is worth
    /// a bright yellow line round a train only for as long as that question is
    /// open. Two things close it. A map that has taken hold of the vehicle and
    /// is moving with it has already answered: the train in the middle of the
    /// screen, the one everything else is sliding past, is plainly the one. And
    /// a train that is moving is being *watched*, which is when a line drawn
    /// over its own livery is most in the way.
    ///
    /// So the ring stands down only where both are true, and only after a
    /// second — long enough to see what was picked before it goes. Anything
    /// that reopens the question brings it back at once and starts the second
    /// again: the train stopping, since a train standing among others at a
    /// platform is exactly the case where which one is not obvious, and the
    /// camera letting go, since then nothing else is saying which train this is.
    private func ringSelection(
        of vehicle: VehicleSnapshot?, following: Bool, at now: Double
    ) -> Bool {
        guard let vehicle, vehicle.moving, following else {
            ringHeldFrom = nil
            return true
        }
        guard let since = ringHeldFrom else {
            ringHeldFrom = now
            return true
        }
        // A clock scrubbed backwards, or a new day loaded, would otherwise hold
        // the ring on for as long as the jump was.
        if now < since { ringHeldFrom = now; return true }
        return now - since < Self.ringHolds
    }

    /// How long the selection ring stays once the map is carrying the vehicle.
    private static let ringHolds = 1.0
    private var ringHeldFrom: Double?

    /// Where each vehicle sits across its alignment, in metres.
    ///
    /// Vehicles heading for the same stop from the same direction can be drawn
    /// one on top of another, and where that happens they are ranked and fanned
    /// about their shared line at track spacing.
    ///
    /// **Only where the app has no rail for them.** This is the one thing on
    /// the map that moves a body off the line it was placed on, and it was
    /// doing it to vehicles that had already been placed properly. A train
    /// standing at a platform has been routed over the points onto that
    /// platform's own track by `GeometryBuilder.bend` — the measured business
    /// of `TrackPlacementTests`, 95% of calls on the rail the feed names — and
    /// then this slid it 4.6 m sideways for its place in a fan. At Bern every
    /// train standing at the station shares a group, so each ended up a track
    /// or more off its own rail while its dot and its route line stayed behind
    /// on it: the body and the line the body runs along came apart by exactly
    /// one track spacing, which is one platform. That is the "trains don't
    /// follow the platforms they are assigned" report, and the fan was all of
    /// it — nothing else displaces a footprint from its centreline.
    ///
    /// So `onTrack` decides. It is false only for a vehicle drawn on the
    /// straight line between two stops, which is the case the fan was written
    /// for and the only one where the shared line is an invention rather than a
    /// railway: several vehicles on one made-up chord really do stack. A
    /// vehicle on mapped geometry is left exactly where the geometry put it,
    /// and two of those overlapping is the honest drawing — it says there are
    /// two trains here, where a fanned one says there is a train on a platform
    /// it is not on.
    ///
    /// Two things make what is left stable enough to look at. The rank comes
    /// from the **platform** wherever the feed states one — which is real
    /// information, and means a vehicle booked for platform 3 and one booked
    /// for platform 7 keep their relative order for the whole approach —
    /// falling back to the vehicle's own id where it does not. And the result
    /// is eased rather than applied: a vehicle joining or leaving the group
    /// changes everyone's rank, and without the easing the whole fan would jump
    /// sideways when it did. The easing is also what walks an already-placed
    /// vehicle back to zero rather than snapping it there.
    private func spread(
        _ candidates: [VehicleSnapshot], enabled: Bool, elapsed: TimeInterval
    ) -> [String: Double] {
        guard enabled else {
            if !lateralOffsets.isEmpty { lateralOffsets = [:] }
            if !spreadVehicleIDs.isEmpty { spreadVehicleIDs = [] }
            return [:]
        }

        // Grouped by where they are going, which way they are pointing, and
        // whether they are on rails — a bus must not be pushed aside by a
        // train it happens to be running beside.
        var groups: [String: [VehicleSnapshot]] = [:]
        for vehicle in candidates {
            // Only where nothing else has decided which rail this is. See above.
            guard !vehicle.stops.isEmpty, !vehicle.onTrack else { continue }
            let ahead = min(max(0, vehicle.moving ? vehicle.index + 1 : vehicle.index),
                            vehicle.stops.count - 1)
            let target = vehicle.stops[ahead]
            // Quarter turns: trains approaching a station from opposite ends
            // are on different sides of it and have nothing to sort out.
            let facing = Int((vehicle.bearing / 90).rounded()) % 4
            let key = "\(target.key)|\(facing)|\(vehicle.mode.isRail)"
            groups[key, default: []].append(vehicle)
        }

        var wanted: [String: Double] = [:]
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted { a, b in
                let left = Self.rank(of: a), right = Self.rank(of: b)
                return left == right ? a.id < b.id : left < right
            }
            let middle = Double(ordered.count - 1) / 2
            for (index, vehicle) in ordered.enumerated() {
                // Clamped, so a platform full of terminating services does not
                // fling the outer ones across the town.
                let places = min(4, max(-4, Double(index) - middle))
                wanted[vehicle.id] = places * VehicleShape.trackSpacing
            }
        }

        // Match the old twelve-percent step at thirty frames a second, but make
        // it a function of elapsed time. Thermal throttling or one slow Fleet
        // query must not make the fan take several times longer to settle.
        let easedFraction = elapsed > 0
            ? 1 - pow(1 - Self.spreadEasingPerFrame, elapsed * 30)
            : 0

        // Ease toward it, and forget vehicles that have gone. A vehicle newly
        // panned into view appears at its established place, as before; one that
        // was already visible at zero and has just acquired a neighbour starts
        // at zero rather than snapping a whole track sideways.
        var next: [String: Double] = [:]
        next.reserveCapacity(candidates.count)
        for vehicle in candidates {
            let target = wanted[vehicle.id] ?? 0
            let current = lateralOffsets[vehicle.id]
                ?? (spreadVehicleIDs.contains(vehicle.id) ? 0 : target)
            let eased = abs(target - current) < 0.05
                ? target
                : current + (target - current) * easedFraction
            if eased != 0 { next[vehicle.id] = eased }
        }
        lateralOffsets = next
        spreadVehicleIDs = Set(candidates.lazy.map(\.id))
        return next
    }

    /// The old easing at its reference rate. Converted to elapsed time above.
    private static let spreadEasingPerFrame = 0.12
    private var lateralOffsets: [String: Double] = [:]
    /// Includes vehicles currently at zero, which `lateralOffsets` omits.
    private var spreadVehicleIDs: Set<String> = []

    /// What orders one vehicle against another across the tracks.
    ///
    /// The booked platform where the feed states one, because that is the only
    /// real evidence about which track a train will be on and it does not
    /// change during the approach. A letter or a missing value falls back to
    /// something stable but arbitrary, which is still better than an order that
    /// reshuffles every time the group changes.
    private static func rank(of vehicle: VehicleSnapshot) -> Int {
        guard !vehicle.stops.isEmpty else { return 1_000 }
        let ahead = min(max(0, vehicle.moving ? vehicle.index + 1 : vehicle.index),
                        vehicle.stops.count - 1)
        if let platform = vehicle.stops[ahead].platform,
           let number = Int(platform.prefix { $0.isNumber }) {
            return number
        }
        return abs(vehicle.id.hashValue % 64) + 1_000
    }

    /// Re-ask what is wrong with whatever the panel is showing.
    ///
    /// Cheap — three dictionary lookups against an index built at fetch time —
    /// so it is run on every selection change and every time the notices
    /// themselves are re-read, rather than cached against the selection.
    private func refreshDisruptions() async {
        guard dataMode == .all else {
            vehicleDisruptions = []
            stopDisruptions = []
            return
        }
        let now = clock.nowSeconds()
        let expected = selection
        let generation = selectionGeneration
        guard selectionIsCurrent(expected, generation: generation),
              !Task.isCancelled else { return }

        switch expected {
        case let .station(board):
            let found = await situations.forStop(ref: board.id, at: now)
            guard selectionIsCurrent(expected, generation: generation),
                  !Task.isCancelled else { return }
            vehicleDisruptions = []
            stopDisruptions = found
        case let .platform(board):
            let found = await situations.forStop(ref: board.id, at: now)
            guard selectionIsCurrent(expected, generation: generation),
                  !Task.isCancelled else { return }
            vehicleDisruptions = []
            stopDisruptions = found
        case .vehicle, .service:
            guard let vehicle = departingVehicle ?? selectedVehicle else {
                vehicleDisruptions = []
                stopDisruptions = []
                return
            }
            let found = await situations.forVehicle(
                id: vehicle.id,
                parts: (vehicle.parts ?? []).map(\.id),
                line: vehicle.line,
                operatorName: vehicle.operatorName,
                // Every stop it calls at, so a notice about a closed stop
                // reaches the vehicles that will be turned back at it.
                stopRefs: vehicle.stops.compactMap(\.ref),
                at: now
            )
            guard selectionIsCurrent(expected, generation: generation),
                  !Task.isCancelled else { return }
            stopDisruptions = []
            vehicleDisruptions = found
        case .none, .track, .line, .choices:
            // A line's notices are not asked for. The situations index answers
            // for a stop or for a working, and a relation is neither: it is the
            // shape of a line, and every disruption on it belongs to one of the
            // stops or services the panel already links to.
            vehicleDisruptions = []
            stopDisruptions = []
        }
    }

    private func scheduleSelectionRefresh() {
        guard !backgroundWorkSuspended else { return }
        selectionTask?.cancel()
        let expected = selection
        let generation = selectionGeneration
        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSelection(expected, generation: generation)
            if self.selectionIsCurrent(expected, generation: generation) {
                self.selectionTask = nil
            }
        }
    }

    private func cancelSelectionWork(clearPresentation: Bool) {
        selectionGeneration &+= 1
        selectionTask?.cancel(); selectionTask = nil
        occupancyTask?.cancel(); occupancyTask = nil
        occupancyRequestGeneration &+= 1
        occupancyVehicleID = nil
        formationTask?.cancel(); formationTask = nil
        formationRequestGeneration &+= 1
        branchTask?.cancel(); branchTask = nil
        branchRequestGeneration &+= 1

        // Reset request identities even when presentation is retained across a
        // brief suspension. Resume then retries anything whose waiter was
        // cancelled instead of mistaking the old key for a completed answer.
        loadKey = nil
        formationKey = nil
        panelReadAt = .distantPast
        guard clearPresentation else { return }
        selectedVehicle = nil
        selectedVehicleMissing = false
        departingVehicle = nil
        vehicleLoad = nil
        liveTiming = nil
        formation = nil
        formationState = .notApplicable
        vehicleDisruptions = []
        stopDisruptions = []
        setSelectedGeometry(nil)
        setSelectedBranches([])
    }

    private func selectionIsCurrent(_ expected: Selection, generation: UInt64) -> Bool {
        generation == selectionGeneration
            && selection == expected
            && !backgroundWorkSuspended
    }

    private func occupancyRequestIsCurrent(
        _ request: UInt64, vehicleID: String,
        expected: Selection, generation: UInt64
    ) -> Bool {
        dataMode != .off
            && selectionIsCurrent(expected, generation: generation)
            && request == occupancyRequestGeneration
            && vehicleID == occupancyVehicleID
    }

    private func formationRequestIsCurrent(
        _ request: UInt64, key: FormationKey,
        expected: Selection, generation: UInt64
    ) -> Bool {
        dataMode != .off
            && selectionIsCurrent(expected, generation: generation)
            && request == formationRequestGeneration
            && key == formationKey
    }

    private func branchRequestIsCurrent(
        _ request: UInt64, key: FormationKey,
        expected: Selection, generation: UInt64
    ) -> Bool {
        dataMode != .off
            && selectionIsCurrent(expected, generation: generation)
            && request == branchRequestGeneration
            && key == formationKey
    }

    private func refreshSelection(_ expected: Selection, generation: UInt64) async {
        guard selectionIsCurrent(expected, generation: generation),
              !Task.isCancelled else { return }
        switch expected {
        case .none, .station, .platform, .track, .choices:
            selectedVehicle = nil
            selectedVehicleMissing = false
            departingVehicle = nil
            clearFormation()
            setSelectedGeometry(nil)
            setSelectedBranches([])
            // Cleared for a board, left alone for nothing-selected. A board has
            // no card to measure and would otherwise open at the height of
            // whichever vehicle was looked at last; `.none` is the sheet on its
            // way out, and resizing a sheet as it leaves is what froze it. See
            // `ContentView.resting`.
            if expected != .none { panelFold = 0 }
        case let .line(line):
            // The one selection that is *not* a vehicle and still draws a line.
            // The route layer was built for a journey, but nothing in it is
            // about a journey: it takes a path and the indices its stops sit
            // at, and a relation has both. So a line with nothing running on it
            // is drawn by exactly the code that draws the train you tapped.
            selectedVehicle = nil
            selectedVehicleMissing = false
            departingVehicle = nil
            clearFormation()
            setSelectedGeometry(line.geometry)
            panelFold = 0
        case let .vehicle(id):
            await loadVehicle(
                id: id, at: clock.nowSeconds(),
                expected: expected, generation: generation
            )
        case let .service(id, departure):
            await loadVehicle(
                id: id, at: clock.nowSeconds(), boardDeparture: departure,
                expected: expected, generation: generation
            )
            guard selectionIsCurrent(expected, generation: generation),
                  !Task.isCancelled else { return }
            if let geometry = await fleet.boardJourneyGeometry(
                id: id, departure: departure
            ) {
                guard selectionIsCurrent(expected, generation: generation),
                      !Task.isCancelled else { return }
                setSelectedGeometry(geometry)
                // Keep the Source section in step with the line on the map.
                // The timetable card was published before the route build so
                // the sheet remained interactive while this task suspended.
                if var vehicle = selectedVehicle {
                    vehicle.geometry = geometry
                    selectedVehicle = vehicle
                }
            }
        }
        guard selectionIsCurrent(expected, generation: generation),
              !Task.isCancelled else { return }
        await refreshDisruptions()
    }

    /// How often the vehicle panel may re-read while nothing in it has changed.
    ///
    /// It still has to move: the card counts down to the next arrival and marks
    /// the call being stood at, and both are read off the clock rather than out
    /// of the snapshot. A second is finer than anything the card prints.
    private static let panelCadence: TimeInterval = 1
    private var panelReadAt = Date.distantPast

    private func loadVehicle(
        id: String, at now: Timestamp, boardDeparture: Timestamp? = nil,
        expected: Selection, generation: UInt64
    ) async {
        let found = await fleet.journey(
            id: id, at: now, boardDeparture: boardDeparture
        )
        guard selectionIsCurrent(expected, generation: generation),
              !Task.isCancelled else { return }
        let departing = await outgoing(of: found, at: now)
        guard selectionIsCurrent(expected, generation: generation),
              !Task.isCancelled else { return }
        // Only where nothing was found *and* nothing is already on the panel: a
        // vehicle that has finished its run while being watched should keep the
        // card it had rather than replace it with an error.
        let missing = found == nil && selectedVehicle == nil
        if selectedVehicleMissing != missing { selectedVehicleMissing = missing }

        // The map highlights whatever the panel is describing. Drawing the run
        // that is over while the panel reads out the one about to leave is two
        // answers to one tap.
        let geometry = (departing ?? found)?.geometry
        setSelectedGeometry(geometry)

        // Held to the cadence unless the panel would actually read differently,
        // and that guard is the whole point of it.
        //
        // These two are read by `DetailSheet` and by nothing else, and a
        // snapshot carries where the vehicle *is* — which moves on every one of
        // the fifteen ticks a second. Writing them each tick invalidated the
        // sheet, the list inside it and the navigation bar above it fifteen
        // times a second for a card whose words had not changed: that is the
        // loop UIKit reports as "observation tracking feedback loop detected",
        // the memory that climbs while it runs, and the reason Done landed on a
        // main thread too far behind to dismiss anything. Where the vehicle is
        // belongs to `vehicles` and `selectedGeometry`, which the map draws
        // without SwiftUI in the way.
        let changed = !Self.readsAlike(selectedVehicle, found)
            || !Self.readsAlike(departingVehicle, departing)
        guard changed || Date().timeIntervalSince(panelReadAt) >= Self.panelCadence
        else { return }
        panelReadAt = Date()
        selectedVehicle = found
        departingVehicle = departing
        // A scheduled page is a timetable, not a live vehicle. Starting the
        // formation and occupancy requests here made sections appear while the
        // user was pulling the sheet open, changing its layout mid-gesture.
        // Selection cleanup already cleared those values; leave the card stable
        // while the route worker fills in the map independently.
        guard boardDeparture == nil else { return }
        loadFormation(
            of: departing ?? found, arriving: found,
            expected: expected, generation: generation
        )
        loadOccupancy(of: departing ?? found, expected: expected, generation: generation)
    }

    /// Ask how full the vehicle on the panel is.
    ///
    /// Keyed on the journey and its service day rather than on the read, for
    /// the same reason the formation is: this runs as often as the card can
    /// change, and a load forecast does not move between frames.
    private func loadOccupancy(
        of vehicle: VehicleSnapshot?, expected: Selection, generation: UInt64
    ) {
        guard dataMode != .off, let vehicle, !vehicle.stops.isEmpty else {
            occupancyTask?.cancel(); occupancyTask = nil
            occupancyRequestGeneration &+= 1
            occupancyVehicleID = nil
            loadKey = nil
            vehicleLoad = nil
            liveTiming = nil
            return
        }
        // The reference OJP knows this run by, which is not the same thing as
        // the id the fleet keys it under. A timetabled journey is stored under
        // its row in `timetable.bin` and carries the published reference
        // separately — and 20.7% of a weekday's trips carry none at all, which
        // is a run nothing can be asked about rather than a run that is on time.
        let id = vehicle.id
        guard occupancyVehicleID != id else { return }
        occupancyTask?.cancel()
        occupancyRequestGeneration &+= 1
        let request = occupancyRequestGeneration
        occupancyVehicleID = id
        occupancyTask = Task { @MainActor [weak self, fleet, loads] in
            guard let self else { return }
            defer {
                if self.occupancyRequestIsCurrent(
                    request, vehicleID: id, expected: expected, generation: generation
                ) {
                    self.occupancyTask = nil
                }
            }
            guard let handle = await fleet.journeyRef(for: id) else {
                guard self.occupancyRequestIsCurrent(
                    request, vehicleID: id, expected: expected, generation: generation
                ),
                      !Task.isCancelled else { return }
                self.vehicleLoad = nil
                self.liveTiming = nil
                return
            }
            guard self.occupancyRequestIsCurrent(
                request, vehicleID: id, expected: expected, generation: generation
            ), !Task.isCancelled
            else { return }
            let key = LoadService.Key(journeyID: handle.ref, day: handle.day)
            guard key != self.loadKey else { return }
            self.loadKey = key
            self.vehicleLoad = nil

            let answer = await loads.load(for: key)
            // The panel may have moved on while this was in flight, and
            // answering the old question over the new one is worse than not
            // answering at all.
            guard self.occupancyRequestIsCurrent(
                request, vehicleID: id, expected: expected, generation: generation
            ), !Task.isCancelled, self.loadKey == key
            else { return }
            if case let .load(found) = answer { self.vehicleLoad = found }

            // The same response carries the delays. Folding them onto the
            // stored journey is what turns a timetabled line on the map into a
            // live one — and it is the whole of the network cost of doing so:
            // about five kilobytes, for the one train being looked at.
            if let timing = await loads.timing(for: key) {
                guard self.occupancyRequestIsCurrent(
                    request, vehicleID: id, expected: expected, generation: generation
                ), !Task.isCancelled, self.loadKey == key
                else { return }
                let before = self.vehicles.first(where: { $0.id == id })
                let touched = await fleet.applyTiming(timing, to: id, at: Date())
                guard self.occupancyRequestIsCurrent(
                    request, vehicleID: id, expected: expected, generation: generation
                ), !Task.isCancelled, self.loadKey == key
                else { return }
                self.liveTiming = touched > 0 ? timing : nil
                if touched > 0 {
                    await self.requestTickAndWait()
                    guard self.occupancyRequestIsCurrent(
                        request, vehicleID: id, expected: expected, generation: generation
                    ), !Task.isCancelled, self.loadKey == key
                    else { return }
                    // Where the fold has put it, not where the glide has got to
                    // — see `Fleet.settledPosition`.
                    let settled = await fleet.settledPosition(
                        of: id, at: Timestamp(self.clock.nowSeconds())
                    )
                    guard self.occupancyRequestIsCurrent(
                        request, vehicleID: id, expected: expected, generation: generation
                    ), !Task.isCancelled, self.loadKey == key
                    else { return }
                    self.catchCameraUp(to: id, from: before, settlingAt: settled)
                }
            } else {
                guard self.occupancyRequestIsCurrent(
                    request, vehicleID: id, expected: expected, generation: generation
                ), !Task.isCancelled, self.loadKey == key
                else { return }
                self.liveTiming = nil
            }
        }
    }

    /// Move the camera onto a selected vehicle that just jumped, when the
    /// camera is not already following it.
    ///
    /// Opening a train asks OJP for its delays, and folding those onto the
    /// timetable can move it a long way in one tick. Following eases across
    /// that step on its own — see `MapCoordinator.follow`. With following off,
    /// the train would be left correcting itself out of shot and the camera
    /// looking at empty track, which is the thing this exists to catch. A small
    /// correction is left alone: the train is still under the finger, and
    /// panning for a few metres is fussier than the move.
    ///
    /// `settlingAt` is where the vehicle is *going*. The vehicle itself no
    /// longer jumps — a re-time is walked off over a fraction of a second, see
    /// `Journey.settle` — so what is drawn on this frame is still the old
    /// position, and measuring against it would find nothing to catch up to.
    /// The camera goes to the destination and the vehicle glides into it.
    private func catchCameraUp(
        to id: String, from previous: VehicleSnapshot?, settlingAt settled: Coord?
    ) {
        guard !isFollowingVehicle, case .vehicle(id) = selection else { return }
        let now = settled ?? vehicles.first(where: { $0.id == id })
            .map { Coord(lon: $0.lon, lat: $0.lat) }
        if let previous, let now {
            let metres = Geo.flatMetres(previous.lon, previous.lat, now.lon, now.lat)
            guard MapCoordinator.shouldCatchup(metres, metresPerPoint: metresPerPoint) else { return }
            onNudge?(now.lon - previous.lon, now.lat - previous.lat)
        } else if let now, previous == nil {
            // Was not in the viewport at all, so there is no vector to add —
            // just go to where it is.
            onFocus?(Coord(lon: now.lon, lat: now.lat), nil)
        }
    }

    /// Ask what the train on the panel is made of.
    ///
    /// Keyed on the train rather than on the read, because `loadVehicle` runs
    /// as often as the card can change and the formation cannot: a train is
    /// re-marshalled between workings, not between frames.
    private func loadFormation(
        of vehicle: VehicleSnapshot?, arriving: VehicleSnapshot?,
        expected: Selection, generation: UInt64
    ) {
        guard dataMode != .off, let vehicle, vehicle.mode == .train,
              !vehicle.stops.isEmpty else {
            clearFormation()
            return
        }

        // The leg the vehicle is on, which is not always the whole run.
        //
        // A Swiss service often changes train number partway — an S1 renumbered
        // at Gümligen, a Regio swapping numbers at Spiez — and `Chains` joins
        // those into the one vehicle a passenger sees. The formation service
        // does not: it answers per train number. Asking under the number the run
        // *started* with returns the formation of a train that finished an hour
        // ago, or nothing at all, so the leg being stood on is the one to ask
        // about.
        let leg = vehicle.parts?.first { $0.start <= vehicle.index && vehicle.index <= $0.end }
        let origin = leg.map { vehicle.stops[$0.start] } ?? vehicle.stops[0]
        let key = FormationKey(
            journeyID: vehicle.formationReference(leg: leg),
            operationDate: FormationKey.operationDate(of: origin.dep)
        )
        guard key != formationKey else { return }
        formationTask?.cancel(); formationTask = nil
        formationRequestGeneration &+= 1
        let request = formationRequestGeneration
        branchTask?.cancel(); branchTask = nil
        branchRequestGeneration &+= 1
        formationKey = key
        formation = nil
        // A train whose id carries no train number, or whose operator is not one
        // of the eleven, is not a question the service can be asked — so it is
        // not one the panel should raise.
        guard let key else {
            formationState = .notApplicable
            return
        }
        formationState = .loading

        // Every journey id this vehicle covers. A splitting train's separation
        // names both halves and one of them is usually this train's own onward
        // leg, so telling them apart means knowing what "this train" is.
        var mine = Set([vehicle.id])
        for part in vehicle.parts ?? [] { mine.insert(part.id) }

        formationTask = Task { @MainActor [weak self, formations, fleet] in
            guard let self else { return }
            defer {
                if self.formationRequestIsCurrent(
                    request, key: key, expected: expected, generation: generation
                ) {
                    self.formationTask = nil
                }
            }
            let answer = await formations.formation(for: key)
            // The panel may have moved on to another train while this was in
            // flight, and answering the old question over the new one is worse
            // than not answering at all.
            guard self.formationRequestIsCurrent(
                request, key: key, expected: expected, generation: generation
            ), !Task.isCancelled
            else { return }
            switch answer {
            case let .formation(raw):
                // The portions a splitting train is drawn from name their
                // destination by UIC and only sometimes in words; the register
                // has the rest. Asked in one hop, and only about the numbers
                // that are actually missing a name.
                let wanted = Set(raw.stops.flatMap(\.portions).compactMap {
                    $0.destination == nil ? $0.destinationUIC : nil
                })
                let names = wanted.isEmpty ? [:] : await fleet.stopNames(uic: wanted)
                guard self.formationRequestIsCurrent(
                    request, key: key, expected: expected, generation: generation
                ), !Task.isCancelled
                else { return }
                let found = raw.naming { names[$0] }
                self.formation = found
                self.formationState = .ready(found)

                // Write it down. This is the half of the layout database that
                // is not shipped: what the line usually runs is a guess good
                // enough to draw from, and this is the train itself. Recorded
                // against the train number, so the correction outlives both
                // this panel and this day — and the map is redrawn from it at
                // once, because the vehicle whose formation was just fetched is
                // on screen and is at this moment drawn from the guess.
                let learned = self.layouts.learn(
                    found, key: LayoutKey(key), at: Date(),
                    mode: vehicle.mode, category: vehicle.category, line: vehicle.line,
                    operatorName: vehicle.operatorName, modeColour: vehicle.mode.hex,
                    slot: self.layouts.slot(for: vehicle)
                )
                // At a terminus the panel describes the working the train
                // *becomes*, and that is the number the formation was fetched
                // under — but the marker on the map is still the working that
                // brought it in. Filed under only one of them, the map goes on
                // drawing the guess for the very train whose formation is on
                // screen beside it. It is one physical train; file it as both.
                if let arriving, arriving.id != vehicle.id,
                   let alsoKnownAs = self.layouts.key(for: arriving) {
                    self.layouts.learn(
                        found, key: alsoKnownAs, at: Date(),
                        mode: arriving.mode, category: arriving.category, line: arriving.line,
                        operatorName: arriving.operatorName, modeColour: arriving.mode.hex,
                        // The arriving working's own hour, not the departing
                        // one's. It is one physical train and two workings, and
                        // the whole point of a slot is that those are filed
                        // apart — a set that comes in at 09:58 and goes out at
                        // 10:04 belongs to both hours, once each.
                        slot: self.layouts.slot(for: arriving)
                    )
                }
                if learned { self.requestTick() }

                self.loadBranches(
                    of: found, for: key, of: vehicle, excluding: mine,
                    expected: expected, generation: generation
                )
            case .none, .failed:
                self.formation = nil
                self.formationState = .unavailable
                self.setSelectedBranches([])
            }
        }
    }

    // MARK: - Learning what is running

    /// How many trains one sweep asks about.
    ///
    /// The subscription allows fifty calls a minute. A screenful at the zoom
    /// the shapes appear at is a few dozen trains, so a sweep of thirty covers
    /// most of what somebody is looking at inside a minute — and paced at one
    /// every second and a half it uses about forty of the fifty, leaving the
    /// rest for the panel. See `FormationService.foregroundReserve`, which
    /// enforces that rather than trusting this arithmetic.
    private static let sweepSize = 30
    /// One request every two seconds, which is thirty a minute — comfortably
    /// inside the fifty the subscription allows, and leaving the rest for the
    /// panel. `FormationService.foregroundReserve` enforces the same thing from
    /// the other end rather than trusting this arithmetic.
    private static let sweepSpacing = Duration.milliseconds(2000)
    /// How long to wait when there is nothing worth asking about — the map is
    /// zoomed out, everything in view is already known, or there is no network.
    private static let sweepIdle = Duration.seconds(6)

    private var learningTask: Task<Void, Never>?
    /// Trains asked about since launch, so one sweep does not repeat another.
    /// A failure is removed again: it was not an answer about the train.
    private var askedFormations: Set<LayoutKey> = []
    /// When each of the last minute's background requests went out, so the
    /// readout can show the rate rather than a running total.
    private var recentAsks: [Date] = []

    /// Keep asking what the trains on screen are made of, a few at a time.
    ///
    /// The panel has always fetched the formation of the train somebody tapped,
    /// which is the right moment to spend a request on a train they care about
    /// — but it leaves everything else on screen drawn from the library's guess
    /// at what the line normally runs. This closes that gap in the background,
    /// nearest the middle of the screen first, and writes what it learns to the
    /// same store the tap does. Nothing waits on it: a train is drawn from the
    /// guess until the answer arrives and redrawn when it does.
    private func startLearning() {
        learningTask?.cancel()
        guard !backgroundWorkSuspended, dataMode == .all, detailedVehicles else {
            learningTask = nil
            return
        }
        learningTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.backgroundWorkSuspended, self.powerFactor == 1 else {
                    try? await Task.sleep(for: Self.sweepIdle)
                    continue
                }
                let batch = self.formationsWorthLearning(limit: Self.sweepSize)
                guard !batch.isEmpty else {
                    try? await Task.sleep(for: Self.sweepIdle)
                    continue
                }
                for vehicle in batch {
                    if Task.isCancelled || self.backgroundWorkSuspended || self.powerFactor > 1 {
                        break
                    }
                    await self.learnFormation(of: vehicle)
                    try? await Task.sleep(for: Self.sweepSpacing)
                }
            }
        }
    }

    /// The trains in view whose formation is not known yet, nearest the middle
    /// of the screen first.
    ///
    /// Nearest first because that is what somebody is looking at. Only trains
    /// being drawn as shapes, because a dot has nothing to correct: knowing
    /// that an S9 is six cars rather than four changes a drawing that is not
    /// being made.
    private func formationsWorthLearning(limit: Int) -> [VehicleSnapshot] {
        guard dataMode == .all, detailedVehicles, isOnline,
              shapesPossible, !vehicles.isEmpty else { return [] }
        let midLon = (viewport.west + viewport.east) / 2
        let midLat = (viewport.south + viewport.north) / 2

        var ranked: [(vehicle: VehicleSnapshot, distance: Double)] = []
        for vehicle in vehicles where vehicle.mode == .train {
            guard shapesByID[vehicle.id] != nil,
                  let key = layouts.key(for: vehicle),
                  !askedFormations.contains(key),
                  layouts.record(for: key) == nil
            else { continue }
            ranked.append((vehicle, Geo.flatMetres(vehicle.lon, vehicle.lat, midLon, midLat)))
        }
        return ranked.sorted { $0.distance < $1.distance }.prefix(limit).map(\.vehicle)
    }

    /// Ask about one train and file whatever comes back.
    private func learnFormation(of vehicle: VehicleSnapshot) async {
        // The leg being run, under the number the service files it by — the
        // same reading `loadFormation` does, and it has to be the same or a
        // formation learned here is never found again.
        let leg = vehicle.parts?.first { $0.start <= vehicle.index && vehicle.index <= $0.end }
        guard let origin = leg.map({ vehicle.stops[$0.start] }) ?? vehicle.stops.first,
              let key = FormationKey(
                  journeyID: vehicle.formationReference(leg: leg),
                  operationDate: FormationKey.operationDate(of: origin.dep)
              )
        else { return }

        let stored = LayoutKey(key)
        askedFormations.insert(stored)
        let sentAt = Date()
        recentAsks.append(sentAt)
        recentAsks.removeAll { sentAt.timeIntervalSince($0) >= 60 }

        switch await formations.formation(for: key, background: true) {
        case let .formation(raw):
            let changed = layouts.learn(
                raw, key: stored, at: Date(), mode: vehicle.mode,
                category: vehicle.category, line: vehicle.line,
                operatorName: vehicle.operatorName, modeColour: vehicle.mode.hex,
                slot: layouts.slot(for: vehicle)
            )
            // Only where the drawing actually differs from what is on screen.
            // A confirmation changes nothing to redraw.
            if changed { requestTick() }
        case .none:
            layouts.noteSilence(key: stored, at: Date())
        case .failed:
            // Throttled, offline, or asked to wait: not an answer about this
            // train, so it does not count as having been asked.
            askedFormations.remove(stored)
        }
    }

    /// Fetch the halves of a splitting train that this vehicle is not itself,
    /// and keep the part of each line that this train's own line does not
    /// already cover.
    ///
    /// Two ways of finding a half, in order of how much the service told us.
    ///
    /// **By journey id**, where the formation carries a separation
    /// relationship. That is the same spelling the feed keys journeys by, which
    /// matters: a train number would have to be searched for, and two services
    /// leaving one station at one minute are common enough that the search
    /// would sometimes find the wrong one.
    ///
    /// **By where and when it leaves**, where it does not. Half the splits in
    /// the country arrive with a null `relationships` and nothing but the coach
    /// goals — "1–4 to Solothurn, 5–8 to Sumiswald-Grünen" — and a portion with
    /// a destination and a parting station is still enough to recognise the
    /// working that carries it. See `Fleet.onward(from:notBefore:to:mode:at:)`.
    private func loadBranches(
        of formation: TrainFormation, for key: FormationKey, of vehicle: VehicleSnapshot,
        excluding mine: Set<String>, expected: Selection, generation: UInt64
    ) {
        guard let split = formation.split else {
            branchTask?.cancel(); branchTask = nil
            branchRequestGeneration &+= 1
            setSelectedBranches([])
            return
        }
        // Which working carries which portion, where the service says. Not
        // simply the first: at Spiez the RE from Bern parts into 4281 for
        // Domodossola and 6833 for Zweisimmen, and 4281 is the leg the feed has
        // already chained onto the very vehicle on the panel — so taking the
        // first named half drew the line this train was already drawn along and
        // put its own destination up as "the other half", which is a split
        // shown as no split at all.
        let named = (formation.separation?.branches ?? []).compactMap(\.journeyID)
        let moment = split.moment.map { Timestamp($0.timeIntervalSince1970) }
            ?? vehicle.stops.last?.arr ?? clock.nowSeconds()

        branchTask?.cancel()
        branchRequestGeneration &+= 1
        let request = branchRequestGeneration
        branchTask = Task { @MainActor [weak self, fleet, clock] in
            guard let self else { return }
            defer {
                if self.branchRequestIsCurrent(
                    request, key: key, expected: expected, generation: generation
                ) {
                    self.branchTask = nil
                }
            }
            var found: [RouteBranch] = []
            for portion in split.portions {
                guard self.branchRequestIsCurrent(
                    request, key: key, expected: expected, generation: generation
                ), !Task.isCancelled
                else { return }
                guard let destination = portion.destination else { continue }
                // A portion this vehicle is itself carrying on as is already
                // the line on the map and the stops in the list.
                if let mineDestination = vehicle.to,
                   Self.sameStop(mineDestination, destination) { continue }

                var other: VehicleSnapshot?
                for id in named where !mine.contains(id) {
                    let candidate = await fleet.journey(id: id, at: clock.nowSeconds())
                    guard self.branchRequestIsCurrent(
                        request, key: key, expected: expected, generation: generation
                    ), !Task.isCancelled else { return }
                    if let candidate, let to = candidate.to, Self.sameStop(to, destination) {
                        other = candidate
                        break
                    }
                }
                if other == nil {
                    other = await fleet.onward(
                        from: split.stopName, notBefore: moment, to: destination,
                        mode: vehicle.mode, at: clock.nowSeconds()
                    )
                    guard self.branchRequestIsCurrent(
                        request, key: key, expected: expected, generation: generation
                    ), !Task.isCancelled else { return }
                }
                guard let other, !mine.contains(other.id) else { continue }

                // A working that starts at the parting has nothing to cut; one
                // that ran the trunk too is cut there so the shared part is
                // drawn once.
                let cut = other.geometry.flatMap {
                    Self.branch(of: $0, stops: other.stops, from: split.stopName)
                }
                let calls = Self.calls(of: other, from: split.stopName)
                found.append(RouteBranch(
                    path: cut?.path ?? [], stops: cut?.stops ?? [], calls: calls,
                    exact: other.geometry?.source == .osmRoute,
                    destination: other.to ?? destination, journeyID: other.id,
                    coaches: portion.fromPosition...max(portion.fromPosition, portion.toPosition),
                    splitAt: split.stopName
                ))
            }
            // The panel may have moved on while this was in flight.
            guard self.branchRequestIsCurrent(
                request, key: key, expected: expected, generation: generation
            ), !Task.isCancelled
            else { return }
            self.setSelectedBranches(found)
        }
    }

    /// Whether two names are one place written two ways.
    ///
    /// The formation service and the realtime feed do not agree on punctuation
    /// or on what belongs in brackets — "Domodossola" against "Domodossola (I)"
    /// — so the comparison is on letters and digits alone.
    private static func sameStop(_ a: String, _ b: String) -> Bool {
        func key(_ name: String) -> String {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                         locale: Locale(identifier: "en_US"))
                .filter { $0.isLetter || $0.isNumber }
        }
        return key(a) == key(b)
    }

    /// A working's calls from a named stop onward, that stop included.
    private static func calls(of vehicle: VehicleSnapshot, from stopName: String) -> [Call] {
        guard let index = vehicle.stops.firstIndex(where: { sameStop($0.name, stopName) })
        else { return vehicle.stops }
        return Array(vehicle.stops[index...])
    }

    /// The part of a drawn line that runs from a named stop onward.
    ///
    /// `legs[i]` is where stop `i` sits in `path`, so the split is a cut at a
    /// known index rather than a search through the coordinates for whichever
    /// one is nearest the station.
    private static func branch(
        of geometry: JourneyGeometry, stops: [Call], from stopName: String
    ) -> (path: [Coord], stops: [Coord])? {
        guard let index = stops.firstIndex(where: {
            $0.name.compare(stopName, options: .caseInsensitive) == .orderedSame
        }), index < geometry.legs.count else { return nil }
        let start = geometry.legs[index]
        guard start >= 0, start < geometry.path.count - 1 else { return nil }
        let marks = geometry.legs[index...].compactMap { at -> Coord? in
            guard at >= 0, at < geometry.path.count else { return nil }
            return geometry.path[at]
        }
        return (Array(geometry.path[start...]), marks)
    }

    private func setSelectedBranches(_ branches: [RouteBranch]) {
        guard selectedBranches != branches else { return }
        selectedBranches = branches
        selectedGeometryRevision &+= 1
    }

    private func clearFormation() {
        formationTask?.cancel(); formationTask = nil
        formationRequestGeneration &+= 1
        branchTask?.cancel(); branchTask = nil
        branchRequestGeneration &+= 1
        formationKey = nil
        formation = nil
        formationState = .notApplicable
        setSelectedBranches([])
    }

    private func setSelectedGeometry(_ geometry: JourneyGeometry?) {
        guard selectedGeometry != geometry else { return }
        selectedGeometry = geometry
        selectedGeometryRevision &+= 1
    }

    /// Whether two snapshots of one journey would put the same words on the
    /// panel.
    private static func readsAlike(_ a: VehicleSnapshot?, _ b: VehicleSnapshot?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return asRead(a) == asRead(b)
        default: return false
        }
    }

    /// A snapshot with the fields only the map uses taken out.
    ///
    /// Position and heading because the panel never prints them, and speed
    /// because a km/h figure ticking over under a thumb is not worth rebuilding
    /// a list for — `panelCadence` brings it along inside the second. What is
    /// left is what the card is made of, and all of it is copy-on-write shared
    /// with the journey it came from, so the comparison is a pointer check.
    private static func asRead(_ vehicle: VehicleSnapshot) -> VehicleSnapshot {
        var vehicle = vehicle
        vehicle.lon = 0
        vehicle.lat = 0
        vehicle.bearing = 0
        vehicle.speed = 0
        // `progress` belongs with them and not with the words. It is how far
        // along the current leg the vehicle is, it moves on every one of the
        // fifteen ticks a second, and it says nothing a panel prints — so left
        // in, it makes every read differ from the last and the throttle above
        // stops throttling anything.
        vehicle.progress = 0
        return vehicle
    }

    /// The run that takes this vehicle out again, if it has arrived and is
    /// still standing there.
    ///
    /// Guarded on the vehicle actually being at the last call rather than on
    /// the layover alone: a layover is attached the moment the fleet is chained,
    /// long before the train it belongs to reaches the platform.
    private func outgoing(of vehicle: VehicleSnapshot?, at now: Timestamp) async -> VehicleSnapshot? {
        guard let vehicle,
              let next = vehicle.layover?.id,
              !vehicle.moving,
              vehicle.index == vehicle.stops.count - 1,
              let end = vehicle.stops.last, now >= end.arr
        else { return nil }
        return await fleet.journey(id: next, at: now)
    }

    // MARK: - Taps

    /// Answer a tap on the map, in the order a reader expects: a vehicle if one
    /// is under the finger, then a stop, then the track itself.
    /// How close a marker has to be drawn to a tap before it counts as being
    /// *under* the finger rather than merely near it, in points.
    private static let underFingerPoints = 6.0

    /// How far a railway station reaches when the alternative is the track it
    /// is built on, in points. Generous on purpose; see the last pass of
    /// `handleTap`.
    private static let stationReachPoints = 70.0

    /// And never further than this on the ground, whatever the zoom.
    ///
    /// Without it the same 70 points is three kilometres at zoom 10, and a tap
    /// meant for a line crossing open country would come back as the nearest
    /// village station. Four hundred metres is about the length of a main-line
    /// platform — near enough to be the station, far enough to be a miss.
    private static let stationReachCap = 400.0

    /// How many of any one kind of thing a picker will list.
    ///
    /// A tap in a station throat can be within reach of a dozen vehicles, and a
    /// list of a dozen is not a choice, it is a search. Four of each is more
    /// than the finger can plausibly have meant and short enough to read
    /// without scrolling.
    private static let choicesPerKind = 4

    func handleTap(
        lon: Double, lat: Double, metresPerPoint: Double,
        platformShapes: [String] = [], stationShapes: [String] = [],
        stopDots: [String] = [], solidTaps: [Coord] = []
    ) async {
        let now = clock.nowSeconds()

        // What OpenRailwayMap has drawn under the finger, resolved before
        // anything is ranked rather than after every marker has had its turn.
        //
        // A footprint answers because the tap is *inside* it — the renderer was
        // asked what is drawn within four points of the touch — so there is no
        // distance to weigh it by. Ranked last, it lost every time: a tap in the
        // middle of a platform at Bern came back as an S7 a hundred points away,
        // because the reach below floors at 25 metres and at platform zoom that
        // is half the screen. The slab was unselectable at any zoom.
        let footprint = await firstShapeBoard(platformShapes, at: now)

        // About a finger's width, in metres on the ground — except where the
        // finger is standing on a drawn platform. Then the markers are not being
        // *missed*, they are simply elsewhere, and only one genuinely under the
        // touch has a claim on it.
        let reach = footprint == nil
            ? max(25, metresPerPoint * 20)
            : metresPerPoint * Self.underFingerPoints

        // A plate is measured from where it is *drawn*, not from the kerb it
        // labels. The two are the same thing until the decluttering moves one,
        // and after that the drawn position is the only one the finger can aim
        // at — a plate nudged 40 px up a forecourt has to answer where it is.
        let plateReach = footprint == nil
            // Keep the hit target the size it is on screen. A 20-metre floor
            // becomes roughly a hundred points at platform zoom, so aiming at
            // Stop A also collected Stop B across the street and opened a
            // picker for two visibly separate plates. Ground distance therefore
            // has no minimum here: sixteen points stays sixteen points at every
            // zoom, which is the marker the person can actually see and aim at.
            ? metresPerPoint * 16
            : metresPerPoint * Self.underFingerPoints

        var best = await bestTap(
            lon: lon, lat: lat, at: now, reach: reach, plateReach: plateReach,
            metresPerPoint: metresPerPoint, footprint: footprint,
            stationShapes: stationShapes, stopDots: stopDots, solidTaps: solidTaps
        )

        // A tap on the vehicle that is already open is not a re-selection. The
        // panel is already showing it, and writing the same selection back does
        // nothing at all — `selection`'s own setter drops a write that does not
        // change anything — so the tap was being swallowed. It advances how the
        // camera is held to it instead; see `tappedOpenVehicle`.
        //
        // Before the picker, and deliberately. Tapping the thing you already
        // have open is the least ambiguous gesture on the map whatever else is
        // near it — and while the camera is following, the vehicle is in the
        // middle of the screen with the whole station drawn under it, so a list
        // would have come up on most of the taps this is for. Aiming at the
        // *other* train still ranks that one first and still gets the list.
        if case let .vehicle(id) = best, case let .vehicle(open) = selection, open == id {
            tappedOpenVehicle()
            return
        }

        // Where more than one thing is genuinely under the finger, all of them
        // are offered and the ranking above becomes the top row rather than the
        // answer. See `ChoicePanel` for why that is the honest way round.
        // Whether a list is even possible, decided before one is built.
        //
        // Building the list is a dozen departure boards — four of each kind it
        // offers — and where the answer is one vehicle under the finger every
        // one of them is thrown away by the ambiguity test below. That is the
        // commonest tap on the map paying for the rarest one. The test that
        // matters for a vehicle is *how many vehicles are in reach*, and that
        // is measured against footprints already built for this frame: no
        // timetable, no boards, nothing to wait for.
        if case .vehicle = best,
           vehicles.count(where: {
               distance(to: $0, lon: lon, lat: lat, lifted: solidTaps) <= reach
           }) <= 1 {
            selection = best
            return
        }

        do {
            let options = await tapChoices(
                lon: lon, lat: lat, at: now, reach: reach, plateReach: plateReach,
                platformShapes: platformShapes, stationShapes: stationShapes,
                stopDots: stopDots, solidTaps: solidTaps
            )
            // A codeless forecourt marker can be the same interchange as the
            // railway station beside it. Once the choice list has folded that
            // redundant marker into its parent, make the single-answer path
            // choose the same parent too; otherwise the list would be correct
            // but a direct tap would still open the duplicate stop board.
            if case let .platform(board) = best,
               let parent = Self.parentStation(for: board, among: options) {
                best = parent.selection
            }
            // A vehicle the ranking is already sure about is not an ambiguity.
            //
            // Standing at a platform, a train is inside the drawn slab, inside
            // the blob over the station, and on a track — none of which is
            // evidence that the tap was meant for any of them. It was meant for
            // the train, `bestTap` says so, and offering a list there made
            // opening a vehicle at a station cost two taps instead of one.
            //
            // Unless the ambiguity is *which* vehicle. Two trains overlapping
            // in a station throat is the case a list is genuinely for, and it
            // is the one case here where the ranking has nothing better than a
            // fifth of a metre to go on.
            let ambiguous: Bool
            if case .vehicle = best {
                ambiguous = options.count(where: { $0.kind == .vehicle }) > 1
            } else {
                ambiguous = options.count > 1
            }
            if ambiguous {
                selection = .choices(Self.ordered(options, first: best))
                return
            }
        }

        // Nothing under the finger, with something already open, is a request
        // to close it — and closing goes through the sheet rather than through
        // the selection. See `requestDismiss`.
        if best == .none {
            requestDismiss()
            return
        }

        selection = best
        // Drawn first, improved after. A stop the national feed does not carry
        // — a funicular, a small operator — has an empty board here and a
        // perfectly full one at the mirror, so an empty board is worth one
        // small request before it is believed. Not on the way in: a stop with
        // no service left today should not wait on the network to say so.
        if case let .station(board) = best, board.departures.isEmpty {
            await fillStationFromMirror(placeId: board.id, at: now)
        }
    }

    /// The list a picker shows: nearest first, and whatever the ranking picked
    /// at the top of it.
    ///
    /// Both, rather than either. Sorted by distance alone the suggestion is
    /// lost among things that merely happen to be a metre nearer; led by the
    /// suggestion alone the rest is in no order at all.
    static func ordered(_ options: [TapChoice], first: Selection) -> [TapChoice] {
        var sorted = options.sorted { $0.distance < $1.distance }
        if let index = sorted.firstIndex(where: { $0.selection == first }), index > 0 {
            sorted.insert(sorted.remove(at: index), at: 0)
        }
        return sorted
    }

    /// Everything within reach of a tap, for the picker to offer.
    ///
    /// Deliberately a second pass rather than something `bestTap` accumulates
    /// on its way through. That function is a chain of early returns whose
    /// order *is* its meaning — a plate beats a stop dot beats the rails — and
    /// threading a collector through it would have made every one of those
    /// decisions also a decision about the list. A tap happens once; the
    /// duplicated lookups cost nothing anybody can measure.
    private func tapChoices(
        lon: Double, lat: Double, at now: Timestamp,
        reach: Double, plateReach: Double,
        platformShapes: [String], stationShapes: [String], stopDots: [String],
        solidTaps: [Coord] = []
    ) async -> [TapChoice] {
        var out: [TapChoice] = []
        var seen = Set<String>()
        // A physical interchange can have separate official identifiers for
        // its modes and names that differ only by punctuation: the boat landing
        // `Spiez Schiffstation` and the bus stop `Spiez, Schiffstation`, for
        // example. Their boards are joined by `Fleet.partOfStation`; the picker
        // must present that joined place once as well. Platforms are excluded
        // deliberately — two bays with the same station name remain two things
        // somebody may need to choose between.
        var stationNames: [String] = []
        func add(_ choice: TapChoice) {
            guard seen.insert(choice.id).inserted else { return }
            if case let .station(board) = choice.selection {
                guard !stationNames.contains(where: { Self.sameStop($0, board.name) })
                else { return }
                stationNames.append(board.name)
            }
            out.append(choice)
        }

        // Vehicles, measured against the body that was drawn rather than
        // against the head — the same distance `nearestVehicle` uses, so a tap
        // on the eighth coach lists that train and not the bus behind it.
        var byDistance: [(vehicle: VehicleSnapshot, distance: Double)] = []
        for vehicle in vehicles {
            let d = distance(to: vehicle, lon: lon, lat: lat, lifted: solidTaps)
            if d <= reach { byDistance.append((vehicle, d)) }
        }
        byDistance.sort { $0.distance < $1.distance }
        for found in byDistance.prefix(Self.choicesPerKind) {
            add(.vehicle(found.vehicle, distance: found.distance))
        }

        // Drawn platforms. No distance to give: the renderer answered because
        // the touch was inside the shape, which is as near as anything gets.
        for id in platformShapes.prefix(Self.choicesPerKind) {
            guard let board = await fleet.shapeBoard(osmId: id, at: now) else { continue }
            add(.platform(board, kind: .area, distance: 0))
        }

        // Kerb plates, from where they are drawn.
        for plate in nearbyPlates(lon: lon, lat: lat, within: plateReach, limit: Self.choicesPerKind) {
            guard let board = await fleet.plateBoard(id: plate.stop.id, at: now) else { continue }
            add(.platform(
                board, kind: .marker,
                distance: Geo.flatMetres(plate.lon, plate.lat, lon, lat)
            ))
        }

        // The dots drawn on the track and the shaded blobs over stations, both
        // resolved by the OSM id the shape carries rather than by whichever
        // station happens to be nearest.
        for id in (stopDots + stationShapes).prefix(Self.choicesPerKind * 2) {
            guard let board = await fleet.stationBoard(osmId: id, at: now) else { continue }
            add(.station(board, rail: true, distance: 0))
        }

        // And the register's own stops, only those whose dot is on screen.
        let places = await fleet.stopPlaces.nearby(
            lon: lon, lat: lat, within: reach, limit: Self.choicesPerKind
        ) { $0.dotDrawn(at: zoom) }
        for place in places {
            guard let board = await fleet.stationBoard(placeId: place.id, at: now) else { continue }
            // `stationBoard` may promote a forecourt stop such as
            // “Mülenen, Bahnhof” to its railway parent. Describe the board we
            // are actually offering, not the child row that led us to it.
            let rail = await fleet.stopPlaces.place(id: board.id)?.rail ?? place.rail
            add(.station(
                board, rail: rail,
                distance: Geo.flatMetres(place.lon, place.lat, lon, lat)
            ))
        }

        // A codeless stop named as part of a railway station is the station's
        // bus/tram side, not a second place. Fold only marker points here:
        // coded/assigned Stop A/B rows and drawn platform areas remain
        // individually selectable.
        let gathered = out
        out.removeAll { choice in
            guard choice.kind == .marker,
                  case let .platform(board) = choice.selection
            else { return false }
            return Self.parentStation(for: board, among: gathered) != nil
        }

        // The rails are deliberately not offered.
        //
        // They are under almost every tap worth making — a bus stands on a road
        // carrying its own route relation, a train on a line carrying six — so
        // as a row they appeared nearly always, said the same thing nearly
        // always, and pushed the thing actually wanted down the list. "Which
        // lines run here" is still the answer to a tap on bare track, where it
        // is the only answer there is; see the end of `bestTap`.
        return out
    }

    /// The railway station that fully contains a generic codeless stop marker.
    ///
    /// This is deliberately narrower than proximity. A named or generated bay
    /// is useful on its own and a drawn platform is a physical target; only an
    /// unlabelled point whose name is the station or a comma-child of it is
    /// redundant.
    private static func parentStation(
        for stop: PlatformBoard, among choices: [TapChoice]
    ) -> TapChoice? {
        guard !stop.rail, !stop.stationOnly,
              stop.code?.isEmpty != false, stop.assigned?.isEmpty != false
        else { return nil }

        return choices.first { choice in
            guard choice.rail == true,
                  case let .station(station) = choice.selection,
                  Geo.flatMetres(stop.lon, stop.lat, station.lon, station.lat) <= 250
            else { return false }
            return Fleet.isGenericStationStop(
                stop.name, stationName: station.name
            )
        }
    }

    /// The one thing a tap would open if it had to choose, in the order a
    /// reader expects: a vehicle if one is under the finger, then a stop, then
    /// the track itself.
    private func bestTap(
        lon: Double, lat: Double, at now: Timestamp,
        reach: Double, plateReach: Double, metresPerPoint: Double,
        footprint: PlatformBoard?, stationShapes: [String], stopDots: [String],
        solidTaps: [Coord] = []
    ) async -> Selection {
        // Nearest wins, rather than vehicles always winning.
        //
        // Trying vehicles first and stops only if none was in range meant a
        // vehicle anywhere inside the radius beat a stop directly under the
        // finger. The radius was far too large as well (see `metresPerPoint`),
        // but the ordering was wrong on its own terms: what somebody is pointing
        // at is the nearest thing, not the highest-priority thing.
        //
        // A vehicle still gets a small edge, because it is drawn as the larger
        // marker and is the thing that moves — if the two are within a fifth of
        // each other, the dot is what was meant.
        let vehicle = nearestVehicle(lon: lon, lat: lat, within: reach, lifted: solidTaps)
        // To the body that was drawn, which is how `nearestVehicle` picked it.
        // Measured to the head instead, the two disagreed: a tap on the eighth
        // coach chose that intercity and then weighed it as four hundred metres
        // away, so it lost to every kerb on the forecourt.
        let vehicleDistance = vehicle.map {
            distance(to: $0, lon: lon, lat: lat, lifted: solidTaps)
        } ?? .infinity

        let plate = nearestPlate(lon: lon, lat: lat, within: plateReach)
        let plateDistance = plate.map { Geo.flatMetres($0.lon, $0.lat, lon, lat) } ?? .infinity

        // Only stops whose dot is actually on screen. The reach is a finger's
        // width in metres, which at zoom 10 is over a kilometre — so without
        // this the nearest thing to a tap aimed at a train is regularly a bus
        // stop nobody can see, several villages away.
        let place = await fleet.stopPlaces.nearest(lon: lon, lat: lat, within: reach) {
            $0.dotDrawn(at: zoom)
        }
        let placeDistance = place.map { Geo.flatMetres($0.lon, $0.lat, lon, lat) } ?? .infinity

        if let vehicle, vehicleDistance <= min(plateDistance, placeDistance) * 1.2 {
            return .vehicle(vehicle.id)
        }

        // The dot on the track, before the markers around it.
        //
        // It is drawn four points across on top of everything, so a finger on
        // one is aiming at that stop and nothing else — while a plate wins on
        // distance from as far off as its reach allows, which at zoom 18 is the
        // width of the forecourt. Tapping the pink circle at a tram stop was
        // coming back as bay C across the street. A plate genuinely under the
        // finger still wins: then both are being pointed at, and the plate is
        // the more specific answer.
        if plateDistance > metresPerPoint * Self.underFingerPoints {
            for id in stopDots {
                guard let board = await fleet.stationBoard(osmId: id, at: now) else { continue }
                return .station(board)
            }
        }
        // The platform before the station that contains it. At the zoom the
        // plates are drawn, "which bay" is the question being asked — the
        // station is one dot and it has sixty-seven of them.
        if let plate, plateDistance <= placeDistance,
           let board = await fleet.plateBoard(id: plate.stop.id, at: now) {
            return .platform(board)
        }
        if let place, let board = await fleet.stationBoard(placeId: place.id, at: now) {
            return .station(board)
        }
        if let plate, let board = await fleet.plateBoard(id: plate.stop.id, at: now) {
            return .platform(board)
        }
        // The drawn platform, before falling back to a marker that is merely
        // nearby. OpenRailwayMap's footprints are far easier to hit than any
        // marker — a platform is a long shape you can touch anywhere along its
        // length — and a touch inside one is a touch on that platform.
        //
        // The shape is resolved by *identity*. Its OpenStreetMap id is looked up
        // against the `ref`/`local_ref` the OSM element carries, which answers
        // with the track or tracks that shape actually serves. Position is not
        // involved, and that is the point: at Bern every platform is registered
        // near 7.4372E while the drawn footprints run out to 7.4384E, so the
        // register point nearest a tap on platform 7 is frequently platform 8 or
        // a bus kerb across the forecourt.
        if let footprint {
            return .platform(footprint)
        }

        if let vehicle {
            return .vehicle(vehicle.id)
        }

        // Then the dots on the track and the shaded blobs over stations, both
        // resolved the same way — by the OSM id the shape carries rather than by
        // whichever station happens to be nearest. That guess is how a tap on
        // Zytglogge came back Marzili.
        for id in stationShapes {
            guard let board = await fleet.stationBoard(osmId: id, at: now) else { continue }
            return .station(board)
        }

        // A station beats the rails it stands on, and from further out than
        // any marker's own reach.
        //
        // Frutigen is the case: a country station is one four-point dot laid
        // over two dozen drawn tracks, and the tracks are a target you cannot
        // miss. Answering "which lines run here" to a finger plainly placed on
        // the station is the wrong answer to the right gesture, and the only
        // way out of it was to zoom in until the dot was big enough to hit.
        //
        // Deliberately last, and deliberately rail-only. Everything genuinely
        // under the finger — a vehicle, a plate, a stop dot, a drawn platform —
        // has already had its chance above, so this can never take a tap off
        // any of them, and it will not offer a bus kerb across the forecourt in
        // place of the station.
        let stationReach = min(max(90, metresPerPoint * Self.stationReachPoints), Self.stationReachCap)
        if let station = await fleet.stopPlaces.nearest(
            lon: lon, lat: lat, within: stationReach, matching: { $0.rail && $0.dotDrawn(at: zoom) }
        ), let board = await fleet.stationBoard(placeId: station.id, at: now) {
            return .station(board)
        }

        // Nothing above the rails: ask which lines run *here*.
        //
        // The web app answers this by reading OpenRailwayMap's vector tiles for
        // the OSM way under the cursor and matching those ids against the
        // relations. There are no tiles here, and there do not need to be — the
        // relations carry the geometry themselves, so the same question is
        // answered by asking which of them passes within a finger's width. It is
        // exact rather than a tile lookup, and it works with no network at all.
        let lines = await fleet.linesNear(lon: lon, lat: lat, within: reach)
        if !lines.isEmpty { return .track(lines) }
        return .none
    }

    /// The first drawn platform footprint under a touch that a board can be
    /// built for.
    ///
    /// Topmost first — the query returns them in draw order — and the ones that
    /// resolve to nothing are skipped rather than swallowing the tap: a fill and
    /// its outline are two hits on one slab, and an OSM way with no usable `ref`
    /// is a shape the register cannot name.
    private func firstShapeBoard(_ ids: [String], at now: Timestamp) async -> PlatformBoard? {
        for id in ids {
            if let board = await fleet.shapeBoard(osmId: id, at: now) { return board }
        }
        return nil
    }

    /// The plate nearest a point, measured where it is drawn.
    /// Ask the mirror about a stop the feed had nothing for, and re-read the
    /// board if it answered.
    ///
    /// Guarded on the selection still being the same stop: the request takes a
    /// moment, and in that time the user may well have tapped something else.
    private func fillStationFromMirror(placeId: String, at now: Timestamp) async {
        guard dataMode == .all else { return }
        guard await fleet.fillFromMirror(placeId: placeId, at: now) else { return }
        guard case let .station(current) = selection, current.id == placeId else { return }
        guard let better = await fleet.stationBoard(placeId: placeId, at: now),
              !better.departures.isEmpty
        else { return }
        replace(.station(better))
    }

    /// Which station each drawn blob belongs to, for the map's merge.
    func stations(forShapes ids: [String]) async -> [String: String] {
        await fleet.stations(forShapes: ids)
    }

    func nearestPlate(lon: Double, lat: Double, within metres: Double) -> PlacedPlate? {
        var best: PlacedPlate?
        var bestDistance = metres
        for plate in plates {
            let d = Geo.flatMetres(plate.lon, plate.lat, lon, lat)
            if d < bestDistance {
                bestDistance = d
                best = plate
            }
        }
        return best
    }

    /// The plates within reach of a point, nearest first.
    func nearbyPlates(lon: Double, lat: Double, within metres: Double, limit: Int) -> [PlacedPlate] {
        plates
            .compactMap { plate -> (PlacedPlate, Double)? in
                let d = Geo.flatMetres(plate.lon, plate.lat, lon, lat)
                return d < metres ? (plate, d) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Open one of the things a tap landed on.
    ///
    /// Through `push`, so Back returns to the list rather than closing the
    /// sheet. The list exists because the first guess might be wrong, and a
    /// wrong guess you cannot back out of is worse than no list at all.
    func choose(_ option: TapChoice) {
        push(option.selection)
        // The same top-up a tap that landed straight on this stop would get.
        // The list is built from boards resolved before it was shown, and a
        // stop the national feed does not carry has an empty one — so without
        // this, going through the picker was the one route to a stop that
        // never asked the mirror.
        guard case let .station(board) = option.selection, board.departures.isEmpty
        else { return }
        Task { await fillStationFromMirror(placeId: board.id, at: clock.nowSeconds()) }
    }

    /// Open the panel for whatever is running nearest a point. Debug only; see
    /// `DebugStart.selectVehicle`.
    func selectNearestVehicle(lon: Double, lat: Double) {
        guard let vehicle = nearestVehicle(lon: lon, lat: lat, within: 4000) else { return }
        selection = .vehicle(vehicle.id)
    }

    /// The vehicle nearest a point — measured to its drawn body where it has
    /// one, and to its marker where it does not.
    ///
    /// The distinction is the whole of what a two-hundred-metre train changed
    /// about tapping. A dot is a point and the finger is aiming at the point;
    /// a train is a long object and the finger is aiming at whichever part of
    /// it is under it, which for most of the train is nowhere near the head.
    /// Measured from the head, the eighth coach of an IC was two hundred metres
    /// away and lost to the bus stop it was passing.
    /// How far a point is from a vehicle: from the body where one was drawn,
    /// and from the dot where it is still a dot.
    /// How far a tap landed from a vehicle, in metres on the ground.
    ///
    /// `lifted` is what makes the hitbox three-dimensional. A tap is answered
    /// against the *ground*: the touch is unprojected onto the map surface and
    /// compared with the body the vehicle occupies there. That is exactly right
    /// for a map lying flat and increasingly wrong as it is tilted, because a
    /// train standing four metres tall is drawn *above* the ground it stands
    /// on — so a finger on the roof of an IC unprojects to a point somewhere
    /// past the far rail, and the only place the train could actually be hit
    /// was the sleepers underneath it.
    ///
    /// `lifted` carries the same touch unprojected as though it had landed at
    /// each of several heights up the side of a vehicle; the nearest of them
    /// wins. The ground point is always among them, so nothing that could be
    /// tapped before stops being tappable — the box grew upwards, it did not
    /// move. See `MapCoordinator.solidTaps`, which owns the projection.
    func distance(
        to vehicle: VehicleSnapshot, lon: Double, lat: Double, lifted: [Coord] = []
    ) -> Double {
        guard let shape = shapesByID[vehicle.id] else {
            var best = Geo.flatMetres(vehicle.lon, vehicle.lat, lon, lat)
            for point in lifted {
                best = min(best, Geo.flatMetres(vehicle.lon, vehicle.lat, point.lon, point.lat))
            }
            return best
        }
        var best = shape.distance(lon: lon, lat: lat)
        for point in lifted {
            best = min(best, shape.distance(lon: point.lon, lat: point.lat))
        }
        return best
    }

    func nearestVehicle(
        lon: Double, lat: Double, within metres: Double, lifted: [Coord] = []
    ) -> VehicleSnapshot? {
        var best: VehicleSnapshot?
        var bestDistance = metres
        for vehicle in vehicles {
            let d = distance(to: vehicle, lon: lon, lat: lat, lifted: lifted)
            if d < bestDistance {
                bestDistance = d
                best = vehicle
            }
        }
        return best
    }

    func select(journey entry: BoardEntry) async {
        if entry.running {
            push(.vehicle(entry.id))
        } else {
            push(.service(entry.id, departure: entry.departure))
        }
    }

    // MARK: - Search

    /// Whether the search field is open. The button expands into it.
    var isSearching = false {
        didSet {
            guard !isSearching else { return }
            searchQuery = ""
            searchResults = SearchResults()
        }
    }

    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            scheduleSearch()
        }
    }

    private(set) var searchResults = SearchResults()
    private var searchTask: Task<Void, Never>?

    /// How long a keystroke waits before the fleet is asked.
    ///
    /// Every query walks 33,000 stop names and the whole chained fleet, on the
    /// actor the draw loop shares. At typing speed that is six or seven of them
    /// a second for answers nobody reads, and the one that matters is always
    /// the last. A sixth of a second is under the gap between keystrokes and
    /// over the gap between a keystroke and a glance at the list.
    private static let searchDebounce: Duration = .milliseconds(160)

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else {
            searchResults = SearchResults()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            let centre = Coord(
                lon: (viewport.west + viewport.east) / 2,
                lat: (viewport.south + viewport.north) / 2
            )
            let found = await fleet.search(query, near: centre, at: clock.nowSeconds())
            // The field may have moved on while the fleet was answering.
            guard !Task.isCancelled, query == searchQuery else { return }
            searchResults = found
        }
    }

    /// Take the first row, which is what the keyboard's Search key means.
    ///
    /// Stations before services, in the order the list draws them — anything
    /// else and the key would open something other than the row the reader is
    /// looking at.
    func openTopResult() async {
        if let station = searchResults.stations.first {
            await open(station: station)
        } else if let vehicle = searchResults.vehicles.first {
            await open(vehicle: vehicle)
        }
    }

    /// Open a station the search found.
    func open(station: StopPlace) async {
        isSearching = false
        let now = clock.nowSeconds()
        onFocus?(Coord(lon: station.lon, lat: station.lat), max(zoom, 14))
        guard let board = await fleet.stationBoard(placeId: station.id, at: now) else { return }
        push(.station(board))
        if board.departures.isEmpty {
            await fillStationFromMirror(placeId: station.id, at: now)
        }
    }

    /// Open a service the search found.
    ///
    /// The camera goes to where the vehicle is, or to where it starts when it
    /// has not left yet — which is the honest answer to "show me the 17:04" at
    /// ten to five, and the reason the hit carries a coordinate at all.
    func open(vehicle hit: VehicleHit) async {
        isSearching = false
        onFocus?(Coord(lon: hit.lon, lat: hit.lat), max(zoom, 12))
        push(.vehicle(hit.id))
    }

    /// Open the board for the stop a **call** names.
    ///
    /// By identity, not by proximity. A call carries the SLOID of the platform
    /// it is booked for, and the station that platform belongs to is a string
    /// operation on it — no distance involved. Asking for the nearest stop to
    /// the call's coordinate instead is how tapping `Thun` in an IC's stop list
    /// opened `Thun (See)`: the boat landing is a couple of hundred metres from
    /// the station's own point, well inside any radius wide enough to be useful.
    ///
    /// Falls back to the coordinate only where the feed gave the call no ref.
    func selectStation(call: Call) async {
        let now = clock.nowSeconds()
        let stationId = StopRegister.stationOf(call.ref)
        if !stationId.isEmpty, let board = await fleet.stationBoard(placeId: stationId, at: now) {
            let place = await fleet.stopPlaces.place(id: stationId)
            onFocus?(Coord(lon: place?.lon ?? call.lon, lat: place?.lat ?? call.lat), max(zoom, 14))
            push(.station(board))
            if board.departures.isEmpty {
                await fillStationFromMirror(placeId: stationId, at: now)
            }
            return
        }
        await selectStation(lon: call.lon, lat: call.lat)
    }

    /// Open a whole line, from a row that named it.
    ///
    /// The question the "lines running through here" list has always provoked
    /// and never answered: it says an RE1 to Bern calls at this platform, and
    /// the next thing anybody wants is *where does it go* — which at half past
    /// midnight, with nothing running and no board to read, was unanswerable.
    /// The relation knows, so this asks it.
    ///
    /// The camera is moved to the whole run rather than to a point, and moved
    /// before the panel is pushed rather than after: the sheet collapses to its
    /// resting height on a push, so the line is being framed against the map
    /// the reader is about to see.
    func openRoute(relation id: Int32) async {
        guard let line = await fleet.routeLine(relationId: id) else { return }
        onFrameRoute?(line.geometry?.path ?? [])
        push(.line(line))
    }

    /// Open the board for one stop on a drawn line.
    ///
    /// By identity where the stop could be resolved to a place, which is all of
    /// them that are listed: an unnamed call never becomes a row, so there is
    /// nothing here to fall back for. See `Fleet.routeLine(relationId:)`.
    func selectStation(stop: RouteStop) async {
        guard let placeId = stop.placeId else {
            await selectStation(lon: stop.lon, lat: stop.lat)
            return
        }
        let now = clock.nowSeconds()
        guard let board = await fleet.stationBoard(placeId: placeId, at: now) else {
            await selectStation(lon: stop.lon, lat: stop.lat)
            return
        }
        onFocus?(Coord(lon: stop.lon, lat: stop.lat), max(zoom, 14))
        push(.station(board))
        if board.departures.isEmpty {
            await fillStationFromMirror(placeId: placeId, at: now)
        }
    }

    /// Open the board for the stop nearest a point.
    ///
    /// Reached from a call in the vehicle panel, which is the question a reader
    /// actually has next: this train stops there at 05:41 — what else does?
    func selectStation(lon: Double, lat: Double) async {
        let now = clock.nowSeconds()
        guard let place = await fleet.stopPlaces.nearest(lon: lon, lat: lat, within: 400),
              let board = await fleet.stationBoard(placeId: place.id, at: now)
        else { return }
        onFocus?(Coord(lon: place.lon, lat: place.lat), max(zoom, 14))
        push(.station(board))
        if board.departures.isEmpty {
            await fillStationFromMirror(placeId: place.id, at: now)
        }
    }

    /// The railway network inside the viewport, for the overlay.
    ///
    /// Drawn from zoom 6, which is most of the country on screen. What changes
    /// as the map pulls back is not whether the network is there but *which* of
    /// it: below zoom 11 only main line and narrow gauge, because tram
    /// reservations and yard sidings at that scale are a grey haze over every
    /// city and hide the thing they are drawn on top of.
    private(set) var tracks: [RailNet.TrackLine] = []
    private var tracksViewport: BBox?
    private var tracksMask: UInt8 = 0
    private var tracksZoom: Double = 0

    /// Which bit of the graph's track-class mask means "tram", cached so the
    /// draw loop is not asking the fleet actor once per segment.
    private(set) var trackTramBit: UInt8 = 0
    /// The graph's bit for track that runs under something. Zero until the
    /// railway graph has been rebuilt with it — see `scripts/build-railnet.mjs`
    /// — and zero draws every line solid, which is what the map did before.
    private(set) var trackTunnelBit: UInt8 = 0

    /// Where the plates take over from the dots. Must match the map's own
    /// `plateMinZoom` — the two numbers are one handover.
    static let plateMinZoom = StopPlace.Dot.plateMinZoom

    private var platesViewport: BBox?
    private var platesZoom: Double = 0

    /// The box the stop dots were last fetched for, and which of the three
    /// zoom bands they were fetched in — none, railway stations only, or the
    /// lot. Both have to match for the held set to still be the right one.
    /// See the stop block in `tick`.
    private var stopsViewport: BBox?
    private var stopsBand: Int?

    /// Refresh the fixed cableway plan only when the held view or service day
    /// changes. Unlike cabins, none of this geometry moves between frames.
    private func refreshCablewaysIfNeeded(at now: Timestamp) async {
        guard detailedVehicles, !hiddenModes.contains(.cable) else {
            if !cableways.isEmpty {
                cableways = Cableway.Plan()
                cablewaysRevision &+= 1
            }
            cablewaysViewport = nil
            cablewaysDay = nil
            return
        }
        // Below the drawing floor the map hides the source, but the plan stays
        // cached. Clearing it here made a zoom-out/zoom-in cycle briefly fall
        // back to live vehicles only, so an idle direct line disappeared while
        // the indirect line with moving cabins survived.
        guard zoom >= VehicleShape.minZoom else { return }

        let date = Date(timeIntervalSince1970: TimeInterval(now))
        let zone = TimeZone(identifier: "Europe/Zurich") ?? .current
        let day = Int((date.timeIntervalSince1970
            + TimeInterval(zone.secondsFromGMT(for: date))) / 86_400)
        if day == cablewaysDay, let held = cablewaysViewport,
           held.contains(lon: viewport.west, lat: viewport.south),
           held.contains(lon: viewport.east, lat: viewport.north) {
            return
        }
        let generous = viewport.turned().padded(by: 0.4)
        let found = await fleet.cablewayPlan(in: generous, at: date)
        cablewaysViewport = generous
        cablewaysDay = day
        if cableways != found {
            cableways = found
            cablewaysRevision &+= 1
        }
    }

    /// Rebuild the plate layout when the view has actually moved.
    ///
    /// The decluttering works in *pixels*, because overlap is a property of the
    /// screen: two bays 20 m apart collide at zoom 15 and not at zoom 18. So a
    /// zoom change invalidates the layout even when the viewport has not moved,
    /// and a pan invalidates it only once it leaves the box already laid out.
    private func refreshPlatesIfNeeded() async {
        guard showStops, zoom >= Self.plateMinZoom else {
            if !plates.isEmpty {
                plates = []
                plateRevision += 1
                platesViewport = nil
            }
            return
        }
        if abs(zoom - platesZoom) < 0.25, let held = platesViewport,
           held.contains(lon: viewport.west, lat: viewport.south),
           held.contains(lon: viewport.east, lat: viewport.north) {
            return
        }
        let generous = viewport.turned().padded(by: 0.25)
        platesZoom = zoom
        plates = await fleet.platformPlates(
            in: generous, zoom: zoom, hidingDrawnTracks: showRailwayShapes && railwayShapesDrawn
        )
        plateRevision += 1
        platesViewport = generous
    }

    /// The bores in view, so the trains inside them can be put inside them.
    ///
    /// Kept apart from `tracks`, which is the railway *overlay* and is only
    /// fetched when somebody has asked to see the rails. This is not a drawing
    /// — nothing here is ever painted — it is the answer to "is this train
    /// under a mountain", and that question is asked whether or not the
    /// overlay is on. See `TunnelIndex`.
    private(set) var tunnels: [[Coord]] = []
    /// Bumped whenever `tunnels` is replaced, so the map can tell whether the
    /// index it built from them is still the right one without comparing a few
    /// thousand coordinates every frame.
    private(set) var tunnelRevision = 0
    private var tunnelsViewport: BBox?
    private var tunnelsZoom = 0.0

    func refreshTunnelsIfNeeded() async {
        if trackTunnelBit == 0 { trackTunnelBit = await fleet.trackKindBit("tunnel") }
        // Only where a vehicle would be drawn as a solid at all. Further out
        // than that a train is a dot, a dot has no height, and a dot on a
        // mountain is where the railway is — which is the truth as far as a
        // plan view is concerned.
        guard detailedVehicles, solidVehicles, ghostTunnels, trackTunnelBit != 0,
              zoom >= VehicleShape.solidMinZoom - 0.6
        else {
            if !tunnels.isEmpty { tunnels = []; tunnelRevision += 1; tunnelsViewport = nil }
            return
        }
        if abs(zoom - tunnelsZoom) < 1, let held = tunnelsViewport,
           held.contains(lon: viewport.west, lat: viewport.south),
           held.contains(lon: viewport.east, lat: viewport.north) {
            return
        }
        // Generously, and more generously than the track overlay is. A tunnel
        // is only useful whole: fetched to the edge of the screen, the
        // Lötschberg comes back as the two kilometres of it that happen to be
        // in view, its "portals" are wherever the box was cut, and a train
        // would be hung off an elevation taken from the middle of a mountain.
        let generous = viewport.turned().padded(by: 1.5)
        tunnels = await fleet.trackLines(
            in: generous, kindMask: trackTunnelBit
        ).map(\.points)
        tunnelRevision += 1
        tunnelsViewport = generous
        tunnelsZoom = zoom
    }

    func refreshTracksIfNeeded() async {
        if trackTramBit == 0 { trackTramBit = await fleet.trackKindBit("tram") }
        if trackTunnelBit == 0 { trackTunnelBit = await fleet.trackKindBit("tunnel") }
        // Nothing to build while OpenRailwayMap's own lines are the ones being
        // drawn: the segments would be uploaded, tessellated and then covered.
        guard ownTracksDrawn, trackOpacity > 0.01, zoom >= 6 else {
            if !tracks.isEmpty { tracks = [] ; tracksViewport = nil }
            return
        }
        // Only when the view has actually moved. The overlay is thousands of
        // segments and does not change between frames; rebuilding it fifteen
        // times a second would spend the whole budget on redrawing the same
        // rails.
        let wantedMask: UInt8 = zoom < 11 ? await fleet.mainLineMask() : 0
        if wantedMask == tracksMask, abs(zoom - tracksZoom) < 1, let held = tracksViewport,
           held.contains(lon: viewport.west, lat: viewport.south),
           held.contains(lon: viewport.east, lat: viewport.north) {
            return
        }
        let generous = viewport.turned().padded(by: 0.4)
        let mask = zoom < 11 ? await fleet.mainLineMask() : 0
        // The mask changes what is drawn, so crossing the threshold has to
        // rebuild even when the viewport has not moved.
        if mask != tracksMask { tracksViewport = nil }
        tracksMask = mask
        // Detail is a function of zoom, so a zoom change must rebuild even when
        // the viewport is still inside the box last fetched.
        if abs(zoom - tracksZoom) >= 1 { tracksViewport = nil }
        tracksZoom = zoom
        // How much detail is worth drawing, by how far back the map is.
        let (minLength, tolerance): (Double, Double) =
            zoom >= 13 ? (0, 0)
            : zoom >= 11 ? (60, 4)
            : zoom >= 9 ? (250, 15)
            : (900, 60)
        tracks = await fleet.trackLines(
            in: generous, kindMask: mask, minLength: minLength, simplify: tolerance
        )
        tracksViewport = generous
    }
}
