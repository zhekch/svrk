import SwiftUI
import UIKit
import MapboxMaps
import TransitCore

/// Basemaps.
///
/// The web app draws OpenStreetMap through CARTO, because every other layer it
/// shows is OSM too. Here the basemap is Mapbox's own — it is what the native
/// SDK renders, it is what the offline tile packs contain, and having one
/// vector source for both online and offline is the whole reason the offline
/// mode can be honest about what it holds.
enum Basemap: String, CaseIterable, Identifiable {
    case dark = "Dark"
    case light = "Light"
    case satellite = "Satellite"
    /// Mapbox Standard: the one with a third dimension of its own.
    ///
    /// Not a fourth colour scheme. Standard is a *style import* rather than a
    /// list of layers — it brings its own buildings, its own landmarks and its
    /// own lighting model, and it is asked for what to draw through named
    /// configuration values instead of through the layer list. Which is why
    /// Dark and Light are the only basemaps that take the building extrusions
    /// in `Terrain3D`, and Standard is the only one whose look changes with a
    /// time of day.
    case standard = "Standard"

    var id: String { rawValue }

    var styleURI: StyleURI {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .satellite: return .satelliteStreets
        // No constant for it in the SDK, which still ships the v11 list.
        // The URI is stable and documented; force-unwrapped because a literal
        // that cannot parse is a typo rather than a runtime condition.
        case .standard: return StyleURI(rawValue: "mapbox://styles/mapbox/standard")!
        }
    }

    /// Whether labels drawn over it need a light or dark halo.
    ///
    /// Standard answers this with its light preset rather than with itself —
    /// see `MapCoordinator.isDarkTheme`, which is what the layers actually ask.
    var isDark: Bool { self != .light }

    /// Whether this basemap draws buildings of its own.
    var hasOwnBuildings: Bool { self == .standard }

    /// Whether this app should install its own extruded building layer.
    ///
    /// Standard already draws modelled buildings. Satellite is a photograph of
    /// the roofs themselves, and the translucent boxes this layer adds sit
    /// over those roofs as a grey haze — so it is not asked for there either.
    var showsExtrudedBuildings: Bool {
        switch self {
        case .dark, .light: return true
        case .satellite, .standard: return false
        }
    }
}

/// The map, and everything drawn on it.
///
/// A `UIViewRepresentable` around the UIKit `MapView` rather than the SDK's
/// SwiftUI `Map`: the SwiftUI module ships with a notice saying its API is not
/// stable, and this map needs imperative control of its sources anyway —
/// several hundred vehicle features replaced fifteen times a second, layers
/// inserted at a chosen depth, and hit-testing that has to agree with what is
/// drawn.
struct TransitMap: UIViewRepresentable {
    @Bindable var model: AppModel
    let basemap: Basemap

    func makeCoordinator() -> MapCoordinator { MapCoordinator(model: model) }

    func makeUIView(context: Context) -> MapView {
        // Where the map was left, or where the phone already knows it is, or
        // the country. Read from the model rather than resolved here, because
        // the fleet was drawn for this exact camera and the two disagreeing
        // would mean opening on a viewport the timetable was not expanded for.
        // See `OpeningCamera`.
        let opening = model.opening
        let options = MapInitOptions(
            cameraOptions: CameraOptions(
                center: opening.coordinate,
                zoom: opening.zoom,
                bearing: opening.bearing,
                pitch: opening.pitch
            ),
            styleURI: basemap.styleURI
        )
        let mapView = MapView(frame: .zero, mapInitOptions: options)
        mapView.ornaments.options.scaleBar.visibility = .hidden
        // Under the controls, not under the status chip.
        //
        // The compass was at `.topLeading`, which is exactly where the pill
        // saying how many vehicles are drawn sits — two things stacked on the
        // same corner, the compass winning only when the map is rotated and the
        // chip unreadable underneath it either way. Ornaments are anchored to
        // the safe area, which is the same origin the SwiftUI header measures
        // from, so clearing the control column is arithmetic rather than a
        // guess: 4 pt of top padding, a 34 pt row, 8 pt of spacing, a second
        // 34 pt row, and a little air.
        mapView.ornaments.options.compass.position = .topTrailing
        mapView.ornaments.options.compass.margins = CGPoint(x: 12, y: 92)
        // Attribution beside the logo rather than opposite it. The bottom right
        // is where the locate button now lives — where every other map on this
        // phone puts it — and the two were sharing a corner.
        mapView.ornaments.options.attributionButton.position = .bottomLeading
        mapView.ornaments.options.attributionButton.margins = CGPoint(x: 96, y: 8)
        // Where you are, on a map of things coming towards you. The permission
        // prompt is the SDK's, driven by the usage description in the generated
        // Info.plist; declining leaves the puck off and changes nothing else.
        //
        // The puck *itself* is installed with the layers rather than here — see
        // `Coordinator.installPuck`, which is the only place that can know what
        // it has to sit on top of.
        mapView.location.options.puckBearing = .heading
        mapView.location.options.puckBearingEnabled = true
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.apply(basemap: basemap)
        context.coordinator.draw()
    }
}

/// Owns the map's sources and layers, and keeps them in step with the model.
@MainActor
final class MapCoordinator: NSObject {
    private let model: AppModel
    private weak var mapView: MapView?
    private var cancellables: Set<AnyCancelable> = []
    private var styleReady = false
    private var currentBasemap: Basemap?

    private enum ID {
        static let tracks = "transit-tracks"
        static let tracksTunnel = "transit-tracks-tunnel"
        static let vehicles = "transit-vehicles"
        static let stops = "transit-stops"
        static let route = "transit-route"
        static let routeStops = "transit-route-stops"
        static let platforms = "transit-platforms"
        static let leaders = "transit-platform-leaders"
    }

    /// Where the plates take over from the dots.
    ///
    /// 16 rather than 15: a stop's dot and the kerbs inside it should not both
    /// be on the map, and at 15 a town's worth of plates arrives while the dots
    /// are still the better summary. The local-stop dot layer stands down at
    /// exactly this zoom, so the handover has no gap and no overlap.
    /// Nonisolated because the zoom bands below are a plain enum with no actor
    /// of their own, and a handover threshold is a constant rather than state.
    nonisolated static let plateMinZoom = StopPlace.Dot.plateMinZoom

    /// Which basemap the layers are being built for.
    ///
    /// `currentBasemap` is only set once `apply(basemap:)` has run, and the
    /// first style finishes loading before that — so the first install has to
    /// name a default rather than unwrap. Dark is the app's own default, and a
    /// change re-runs the whole install anyway.
    private var theme: Basemap { currentBasemap ?? .dark }

    /// Which light preset the Standard basemap was last built for.
    ///
    /// Part of the style's identity rather than a setting applied to it: the
    /// preset decides whether the ground is light or dark, and every halo,
    /// every overlay palette and every casing this app installs is chosen from
    /// that. Changing it therefore reloads the style, exactly as changing the
    /// basemap does, so the layers are rebuilt against the ground they are
    /// actually going to be drawn on.
    private var currentPreset: Terrain3D.LightPreset?

    /// Whether what is under our layers is dark.
    ///
    /// `Basemap.isDark` cannot answer for Standard, which is dark at night and
    /// light at noon and is the same basemap either way.
    private var isDarkTheme: Bool {
        theme == .standard ? model.lightPreset.isDark : theme.isDark
    }

    init(model: AppModel) {
        self.model = model
    }

    func attach(to mapView: MapView) {
        self.mapView = mapView
        model.onFrame = { [weak self] in self?.draw() }
        model.onFocus = { [weak self] coord, zoom in
            self?.focus(
                on: CLLocationCoordinate2D(latitude: coord.lat, longitude: coord.lon),
                zoom: zoom
            )
        }
        model.onNudge = { [weak self] dlon, dlat in self?.nudge(dlon: dlon, dlat: dlat) }
        model.onZoom = { [weak self] zoom in self?.zoom(to: zoom) }
        model.onFrameRoute = { [weak self] path in self?.frame(path) }
        model.onLocate = { [weak self] in self?.advanceLocateMode() }
        model.onTilt = { [weak self] pitch in self?.tilt(to: pitch) }
        // Following a vehicle is a camera set per frame rather than a viewport
        // state: the viewport API follows the puck, and this follows an
        // arbitrary moving coordinate. Set rather than eased — an ease started
        // thirty times a second never finishes one before the next begins, and
        // the result lags the thing it is chasing by the length of the ease.
        model.onRecentre = { [weak self] vehicle, at in self?.follow(vehicle, at: at) }

        // The only trustworthy signal that the camera moved because somebody
        // moved it. A camera set from `onRecentre` raises exactly the same
        // change notifications a drag does, so the notifications cannot tell
        // them apart — but a gesture beginning can only be a person.
        mapView.gestures.delegate = self

        // Tilting is a two-finger drag up, and out of the box it is a gesture
        // you have to ask for three times. See `installTilt`.
        installTilt(on: mapView)

        // The map leaves following on its own the moment the camera is dragged
        // — `transitionsToIdleUponUserInteraction` is on by default — and that
        // is the only place the unfocused state comes from. Without this the
        // button would go on claiming to follow a map that had stopped.
        mapView.viewport.addStatusObserver(self)

        // Whether there is a fix to focus on, so the button can say so before
        // it is pressed rather than doing nothing when it is.
        mapView.location.onLocationChange.observe { [weak self] locations in
            // Guarded: this arrives with every location update and an
            // `@Observable` write notifies whether or not the value changed,
            // so an unguarded one re-ran `ContentView`'s body for nothing.
            let fix = !locations.isEmpty
            if self?.model.hasLocationFix != fix { self?.model.hasLocationFix = fix }

            // The same stream, read for a different question: not "where do I
            // draw the puck" but "which of these trains am I sitting in". Every
            // number the SDK carries here is optional or sentinel-valued —
            // CoreLocation reports −1 for a speed or a course it does not have
            // — so the sentinels are turned into absences on the way through
            // and `RideWatch` never has to know about them.
            guard let last = locations.last else { return }
            self?.model.rides.received(RideFix(
                coord: Coord(
                    lon: last.coordinate.longitude, lat: last.coordinate.latitude
                ),
                at: last.timestamp.timeIntervalSince1970,
                speed: last.speed.flatMap { $0 >= 0 ? $0 : nil },
                course: last.bearing.flatMap { $0 >= 0 ? $0 : nil },
                accuracy: last.horizontalAccuracy ?? -1
            ))
        }.store(in: &cancellables)

        mapView.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            self?.installLayers()
        }.store(in: &cancellables)

        mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
            self?.reportViewport()
        }.store(in: &cancellables)

        // Where the map was left, for the next launch to open on.
        //
        // On idle rather than on every camera change, which is the difference
        // between one write when a pan stops and thirty a second while it is
        // happening. What it buys is not the camera — it is the *next* launch's
        // first draw: the timetable is expanded for whatever viewport this
        // restores, and after one session that is a canton rather than a
        // country. See `OpeningCamera`.
        mapView.mapboxMap.onMapIdle.observe { [weak self] _ in
            self?.rememberCamera()
        }.store(in: &cancellables)

        // What the renderer is actually doing, as opposed to what the model is
        // asking of it. Counted here because this is the only place that knows:
        // the map draws on its own schedule from data already uploaded, which
        // is why a finger can drag it at the display's rate while the vehicles
        // on it are being recomputed seventeen times a second.
        mapView.mapboxMap.onRenderFrameFinished.observe { [weak self] _ in
            self?.countRenderedFrame()
        }.store(in: &cancellables)

        // Whether OpenRailwayMap's tiles are actually arriving.
        //
        // This matters because the plates stand down wherever a footprint is
        // drawn: with no tiles, a station would have neither, which is the one
        // outcome worse than showing both. So the plates are only suppressed
        // once a tile has been seen, and a failure puts them back.
        mapView.mapboxMap.onSourceDataLoaded.observe { [weak self] event in
            guard event.type == .tile else { return }
            // The same question, asked of the line tiles: the app's own railway
            // overlay only stands down once ORM's has actually arrived.
            if RailwayLines.sourceIds.contains(event.sourceId) {
                self?.model.railwayLines(arrived: true)
                return
            }
            guard event.sourceId == RailwayShapes.sourceId else { return }
            self?.model.railwayShapes(arrived: true)
            // New tiles can carry a blob for a station already drawn from
            // another one, so the choice is made again over what is now loaded.
            Task { @MainActor in await self?.mergeStationBlobs() }
        }.store(in: &cancellables)

        mapView.mapboxMap.onMapLoadingError.observe { [weak self] error in
            if let source = error.sourceId, RailwayLines.sourceIds.contains(source) {
                self?.model.railwayLines(arrived: false)
                return
            }
            guard error.sourceId == RailwayShapes.sourceId else { return }
            self?.model.railwayShapes(arrived: false)
        }.store(in: &cancellables)

        // Also once the map has settled. The first camera event arrives before
        // the view has been laid out, and a map with no bounds yet describes no
        // viewport — see the guard in `reportViewport`. Without this the
        // viewport would then keep whatever it was last given, which on a map
        // nobody has panned is the initial guess rather than what is on screen.
        mapView.mapboxMap.onMapIdle.observe { [weak self] _ in
            self?.reportViewport()
            Task { @MainActor in await self?.mergeStationBlobs() }
        }.store(in: &cancellables)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        mapView.addGestureRecognizer(tap)
    }

    // MARK: - Following a vehicle

    /// Where the followed vehicle was at the last model tick, and how fast it
    /// was going when it got there.
    private var followAnchor: Coord?
    private var followVelocity: (lon: Double, lat: Double) = (0, 0)
    /// The instant `followAnchor` belongs to, **on the map's own clock** — the
    /// same clock the position was computed from, not the wall clock the frame
    /// happened to arrive on. See `follow(_:at:)`.
    private var followStamp: Double = 0
    /// The vehicle as the model last had it. Held rather than looked up: the
    /// bearing and the label are wanted every refresh and change once a tick.
    private var followWatched: VehicleSnapshot?
    private var followLink: CADisplayLink?
    /// The footprint as the model last built it, in its own coordinates. It is
    /// translated rather than rebuilt — see `followFrame`.
    private var followShape: VehicleFootprint?
    private var followId: String?
    /// The bearing the camera has been eased to, while it is turning with a
    /// vehicle. Nil whenever it is not.
    private var followBearing: CLLocationDirection?
    /// How fast that bearing is currently turning, in degrees per second, and
    /// when it was last moved. The turn is a damped spring rather than a
    /// fraction per frame, and a spring needs both. See `cameraBearing`.
    private var followBearingRate: Double = 0
    private var followBearingStamp: CFTimeInterval = 0
    /// How far the camera (and the followed body) still sit from the vehicle's
    /// true position, in metres east and north, after a jump too large to be
    /// travel. See `follow(_:at:)`.
    private var catchupEast = 0.0
    private var catchupNorth = 0.0
    private var catchupEastRate = 0.0
    private var catchupNorthRate = 0.0
    /// The same offset in degrees, so `followShift` can add it without
    /// converting on every call. Written whenever the metres are stepped.
    private var catchupLon = 0.0
    private var catchupLat = 0.0
    private var catchupStamp: CFTimeInterval = 0

    /// The vehicle drawn by the follow lane rather than with the others, if any.
    private var followedVehicleId: String? {
        guard model.isFollowingVehicle, case let .vehicle(id) = model.selection else { return nil }
        return id
    }

    /// The model has a new position for the vehicle being followed.
    ///
    /// Called once per model tick. All this does is set the anchor the display
    /// link predicts from; the camera itself is moved in `followFrame`, so that
    /// the camera and the drawn body are only ever moved together.
    ///
    /// **`at` is on the map's clock, and everything here is timed against it.**
    /// A position is a function of that clock and of nothing else, so the
    /// interval between two of them is the difference of their two stamps. What
    /// this used instead was the gap between the two *arrivals* — `follow` is
    /// called at the bottom of a tick that read its clock at the top, so that
    /// gap is the interval plus however much the tick's own work varied by.
    ///
    /// A tick that runs fifteen milliseconds slower than the one before it
    /// makes a 33 ms interval look like 48, and the speed derived from it comes
    /// out a third low; fifteen faster and it comes out nearly double. The
    /// display link then carried that speed forward for up to a frame or two
    /// and the next tick pulled the vehicle back to the truth — a wrong guess
    /// and a correction, thirty times a second, which is the jitter. And it
    /// only showed up when tick durations moved about, which is why it came and
    /// went rather than being simply always there.
    ///
    /// Timing against the map's clock also makes the follower right when that
    /// clock is not running at wall speed. At 10× the vehicle really does cover
    /// ten times the ground per second, and both the interval and the
    /// prediction below now scale with it; paused, the interval is zero, the
    /// speed is zero and nothing is predicted at all.
    private func follow(_ vehicle: VehicleSnapshot, at stamp: Double) {
        let coord = Coord(lon: vehicle.lon, lat: vehicle.lat)
        let elapsed = stamp - followStamp
        let same = followId == vehicle.id && followId != nil
        // Ignore a stale gap — a backgrounded app, a stalled tick, the clock
        // scrubbed — rather than extrapolating a vehicle across the canton from
        // it. And ignore a step so large it cannot be travel: a journey re-timed
        // by a fresh sighting moves its vehicle in one tick, and read as a speed
        // that is a lurch away and back again. That jump is still a jump, but
        // the camera eases across it rather than snapping: see `addCatchup`.
        if let previous = followAnchor, same, elapsed > 0.001, elapsed < 0.5,
           Geo.flatMetres(previous.lon, previous.lat, coord.lon, coord.lat) / elapsed
               <= Self.followFastest {
            followVelocity = (
                (coord.lon - previous.lon) / elapsed,
                (coord.lat - previous.lat) / elapsed
            )
        } else {
            followVelocity = (0, 0)
            if let previous = followAnchor, same, elapsed < 0.5 {
                let metres = Geo.flatMetres(previous.lon, previous.lat, coord.lon, coord.lat)
                if Self.shouldCatchup(metres, metresPerPoint: model.metresPerPoint) {
                    addCatchup(from: previous, to: coord)
                }
                // A tiny step — or a paused clock, whose elapsed is ~0 — is not
                // a reason to drop an ease that is already in flight.
            } else {
                clearCatchup()
            }
        }
        followAnchor = coord
        followStamp = stamp
        followWatched = vehicle
        followId = followedVehicleId
        followShape = followId.flatMap { model.shapesByID[$0] }
        startFollowLink()
        followFrame()
    }

    /// Faster than anything on these rails, in metres per second. A step that
    /// implies more than this is a correction rather than a speed.
    private static let followFastest = 140.0

    /// A re-timing smaller than this, in metres, is not worth easing across.
    /// Forty metres is a coach length; below that the train is still under
    /// the camera and snapping is invisible.
    private static let catchupMinMetres = 40.0

    /// And not worth it if it is also this small on screen, in points.
    ///
    /// At a country zoom forty metres is a couple of points, and easing for
    /// that is the map fidgeting. Both have to clear.
    private static let catchupMinPoints = 40.0

    /// Whether a jump is large enough that snapping the camera would read as
    /// a teleport.
    static func shouldCatchup(_ metres: Double, metresPerPoint: Double) -> Bool {
        metres >= catchupMinMetres && metres / max(metresPerPoint, 0.01) >= catchupMinPoints
    }

    /// Roughly how long the camera takes to settle onto a re-timed vehicle.
    ///
    /// The same window as the bearing spring: long enough to see the ease-in,
    /// short enough that a two-kilometre delay correction is not a tour.
    private static let catchupSettle: Double = 0.8

    /// A ceiling on how fast the camera may pan during a catch-up, in metres
    /// per second.
    ///
    /// Unbounded, a 2 km jump would peak around two kilometres a second — the
    /// whole world whipping past. Capped here, that jump is about a second,
    /// and an ordinary correction of a few hundred metres never reaches it.
    private static let catchupMaxRate: Double = 2_500

    /// How far past the last fix the display link may carry a vehicle.
    ///
    /// Long enough to cover a tick and the frame it is drawn on with room over
    /// — the gap this closes now includes the tick's own work, which the wall
    /// clock used to hide by measuring from the wrong end of it. Short enough
    /// that a model which has genuinely stopped leaves the vehicle standing a
    /// few metres on rather than inventing a journey for it.
    private static let followPredictAtMost = 0.12

    private func startFollowLink() {
        guard followLink == nil else { return }
        // Through a weak proxy: `CADisplayLink` retains its target, and a link
        // that is still running holds the coordinator — and through it the
        // model — alive after the map has gone.
        let link = CADisplayLink(
            target: DisplayLinkProxy { [weak self] in self?.followFrame() },
            selector: #selector(DisplayLinkProxy.fire)
        )
        link.add(to: .main, forMode: .common)
        followLink = link
    }

    /// Stop predicting, and put the followed vehicle back with the others.
    private func endFollowing() {
        followLink?.invalidate()
        followLink = nil
        followAnchor = nil
        followVelocity = (0, 0)
        followWatched = nil
        clearCatchup()
        guard let mapView, styleReady, followId != nil else { followId = nil; return }
        followId = nil
        followShape = nil
        followBearing = nil
        followBearingRate = 0
        mapView.mapboxMap.updateGeoJSONSource(
            withId: VehicleShapes.followSource,
            geoJSON: .featureCollection(FeatureCollection(features: []))
        )
        // Put the camera's own centre back where the view's centre is. The
        // offset belongs to following — see `followInset` — and Mapbox keeps
        // the last padding it was given, so leaving it set would hold the whole
        // map a fifth of a screen off centre for the rest of the session.
        mapView.mapboxMap.setCamera(to: CameraOptions(padding: .zero))
        draw()
    }

    /// How far past the last anchor the followed vehicle has travelled, right
    /// now, in degrees.
    ///
    /// Measured on the map's own clock — the same one the anchor was timed
    /// against — so it covers the tick's own work as well as the frames since.
    ///
    /// Shared, and that is the point of it being a function. Two places write
    /// the followed vehicle's dot and label: this lane, every display refresh,
    /// and `draw`, which rewrites the whole vehicle collection once a tick.
    /// Both land on one serial GeoJSON parsing queue inside the SDK, behind a
    /// full-collection parse that neither of them can time — so whichever
    /// arrives last is the one on screen, and if the two disagree about where
    /// the vehicle is, the label flicks between their two answers. It used to:
    /// `draw` wrote the raw anchor while this wrote the prediction, and the
    /// difference is a tick's travel — two metres at line speed, and two metres
    /// is a lot of points once the map is zoomed in far enough to want to
    /// follow anything.
    ///
    /// The catch-up offset is in here too, for the same reason: a re-timed
    /// vehicle has to be drawn where the camera is still looking, not where
    /// the timetable now says, or the body snaps while the camera eases.
    private func followShift() -> (lon: Double, lat: Double) {
        guard followAnchor != nil else { return (0, 0) }
        let ahead = min(max(0, model.clock.now() - followStamp), Self.followPredictAtMost)
        return (
            followVelocity.lon * ahead + catchupLon,
            followVelocity.lat * ahead + catchupLat
        )
    }

    /// Start easing the camera from `from` onto `to`.
    ///
    /// The vehicle is already at `to` — the timetable has been re-timed and
    /// there is no honest in-between along the rails that we can invent in
    /// a frame. What this does is keep the camera and the drawn body on the
    /// *old* side of that jump, then spring the offset to nothing so the
    /// world slides onto the new position rather than teleporting there.
    /// Added rather than replaced, so a second correction while one is still
    /// settling stacks instead of snapping to the latest.
    private func addCatchup(from: Coord, to: Coord) {
        let delta = Geo.eastNorth(from: to, to: from)
        catchupEast += delta.east
        catchupNorth += delta.north
        catchupEastRate = 0
        catchupNorthRate = 0
        catchupStamp = 0
        writeCatchupDegrees(at: to)
    }

    private func clearCatchup() {
        catchupEast = 0
        catchupNorth = 0
        catchupEastRate = 0
        catchupNorthRate = 0
        catchupLon = 0
        catchupLat = 0
        catchupStamp = 0
    }

    /// One display frame of the catch-up spring.
    ///
    /// Stepped here, and only here, because `followShift` is also read from
    /// `draw` on the model tick: putting the integration in the shift itself
    /// would advance it twice on the ticks that both fire.
    private func stepCatchup() {
        guard catchupEast != 0 || catchupNorth != 0
                || catchupEastRate != 0 || catchupNorthRate != 0
        else { return }
        let now = CACurrentMediaTime()
        let elapsed = catchupStamp == 0 ? 0 : now - catchupStamp
        catchupStamp = now
        let step = elapsed > 0 && elapsed < 0.25 ? elapsed : 1.0 / 60
        catchupEast = Self.linearSpring(
            catchupEast, towards: 0, rate: &catchupEastRate,
            over: step, settlingIn: Self.catchupSettle, atMost: Self.catchupMaxRate
        )
        catchupNorth = Self.linearSpring(
            catchupNorth, towards: 0, rate: &catchupNorthRate,
            over: step, settlingIn: Self.catchupSettle, atMost: Self.catchupMaxRate
        )
        if abs(catchupEast) < 0.5, abs(catchupNorth) < 0.5,
           abs(catchupEastRate) < 1, abs(catchupNorthRate) < 1 {
            clearCatchup()
            return
        }
        writeCatchupDegrees(at: followAnchor ?? Coord(lon: 0, lat: 0))
    }

    /// Convert the remaining metre offset into lon/lat at `at`'s latitude.
    private func writeCatchupDegrees(at origin: Coord) {
        let moved = Geo.moved(
            Geo.moved(origin, bearing: 0, metres: catchupNorth),
            bearing: 90, metres: catchupEast
        )
        catchupLon = moved.lon - origin.lon
        catchupLat = moved.lat - origin.lat
    }

    /// One display refresh of the followed vehicle.
    ///
    /// The model produces a position thirty times a second and the display asks
    /// sixty or a hundred and twenty times a second, so following at the model's
    /// rate held every step for two refreshes or more — the map, which is
    /// entirely in motion under a vehicle pinned to the middle of it, stepped
    /// rather than moved.
    ///
    /// What is drawn here is a prediction: the last position carried forward at
    /// the speed the last two ticks implied. That is exact for a train, which
    /// cannot change speed appreciably in thirty milliseconds, and the next tick
    /// corrects it before the error reaches a pixel.
    ///
    /// **The camera and the body are offset by the same vector, and that is the
    /// point.** The body is not recomputed from the timetable — it is the
    /// footprint the model last built, translated. So whatever the prediction
    /// does, the vehicle cannot drift against the camera holding it: both are
    /// wrong by the same amount or neither is. Recomputing them separately is
    /// what made the vehicle "constantly go a bit back and forth".
    @objc private func followFrame() {
        guard model.isFollowingVehicle, let anchor = followAnchor,
              let mapView, styleReady
        else {
            endFollowing()
            return
        }

        stepCatchup()
        let shift = followShift()
        let lon = anchor.lon + shift.lon
        let lat = anchor.lat + shift.lat

        // Handed over by the model with the position, rather than found here.
        // This runs at the display's rate, and searching the viewport's
        // vehicles for one of them a hundred and twenty times a second is work
        // on the main thread that buys a value which changes thirty.
        let watched = followWatched

        var camera = CameraOptions(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            padding: Self.followInset(in: mapView.bounds.height)
        )
        camera.bearing = cameraBearing(towards: watched?.bearing)
        mapView.mapboxMap.setCamera(to: camera)

        let style: MapboxMap = mapView.mapboxMap
        if let shape = followShape {
            // From one translated footprint, in one write. This lane runs at
            // the display's rate rather than the model's, so it is the one
            // place where three separate writes would have been most visible.
            let moved = shape.shifted(byLon: shift.lon, lat: shift.lat)
            style.updateGeoJSONSource(
                withId: VehicleShapes.followSource,
                geoJSON: .featureCollection(FeatureCollection(
                    features: vehicleDrawing(
                        [moved], excluding: nil, flatness: 1, follow: true
                    )
                ))
            )
        }
        // The dot and its line label hang off the point source, and they have to
        // travel with the body or the label swims beside the train it names.
        //
        // Rebuilt whole rather than moved. `updateGeoJSONSourceFeatures`
        // *replaces* the feature it matches, so anything left out of it is left
        // out of the source — see `vehicleFeature`.
        if let vehicle = watched {
            style.updateGeoJSONSourceFeatures(forSourceId: ID.vehicles, features: [
                Self.vehicleFeature(
                    vehicle,
                    at: Coord(lon: vehicle.lon + shift.lon, lat: vehicle.lat + shift.lat),
                    selected: true, emerged: followShape?.emergence ?? 0,
                    tunnel: tunnelIndex.fade(
                        at: Coord(lon: vehicle.lon + shift.lon, lat: vehicle.lat + shift.lat),
                        heading: vehicle.bearing
                    )
                )
            ])
        }
    }

    /// Which way is up while a vehicle is being followed, or nil to leave the
    /// map's own bearing alone.
    ///
    /// Eased rather than set, and that is the whole of it. A vehicle's bearing
    /// is recomputed from its position every tick, so it wanders a degree or
    /// two while a train is standing still and swings hard through a station
    /// throat — written straight onto the camera, the map twitches constantly
    /// and lurches at every point.
    ///
    /// **A spring, not a fraction per frame.** Moving a seventh of the way
    /// there each refresh was two separate problems. It was fastest at the very
    /// first frame and slowed from there, so every turn *started* with a jerk
    /// and finished with a long crawl — which is what reads as sharp. And it
    /// was a fraction of a *frame*, so the same turn happened twice as fast on
    /// a 120 Hz phone as on a 60 Hz one, and stalled with the frame rate.
    ///
    /// A critically damped spring fixes both. It is integrated against real
    /// elapsed time, so the turn takes the same wall-clock second whatever the
    /// display is doing; and it accelerates out of rest and decelerates into
    /// the new heading rather than braking the whole way, which is the shape a
    /// turn made by hand has. Critically damped exactly — no overshoot, so the
    /// map never swings past the vehicle's heading and comes back.
    ///
    /// Once the mode is left the map is not dragged back to north. Rotating it
    /// back would be a second unasked-for movement, and the compass in the
    /// corner is already both the notice that it is turned and the button that
    /// straightens it.
    private func cameraBearing(towards heading: Double?) -> CLLocationDirection? {
        guard model.vehicleFollow == .bearing, let heading else {
            followBearing = nil
            followBearingRate = 0
            return nil
        }

        let now = CACurrentMediaTime()
        // A first frame has no elapsed time to integrate over, and a frame after
        // a stall — a backgrounded app, a jammed main thread — has far too much.
        // Both are treated as one frame at the display's nominal rate.
        let elapsed = followBearing == nil ? 0 : now - followBearingStamp
        followBearingStamp = now
        let step = elapsed > 0 && elapsed < 0.25 ? elapsed : 1.0 / 60

        guard let from = followBearing else {
            // Taking the mode on picks up wherever the map already points, so
            // the first frame is not a jump either.
            followBearing = mapView?.mapboxMap.cameraState.bearing ?? 0
            followBearingRate = 0
            return followBearing
        }

        let turned = Self.spring(
            from, towards: heading, rate: &followBearingRate,
            over: step, settlingIn: Self.bearingSettle, atMost: Self.bearingMaxRate
        )
        followBearing = turned
        return turned
    }

    /// Where a followed vehicle sits on the screen, as bottom padding on the
    /// camera.
    ///
    /// Dead centre is the wrong place for it. The panel stands over the bottom
    /// third of the map, so a vehicle in the middle of the *view* is barely
    /// above the sheet — and what a reader is watching for is where it is
    /// going, which is the half of the screen the vehicle is pushed up against.
    /// A fifth of the height of padding puts it near the middle of what can
    /// actually be seen, and leaves the road ahead in front of it.
    ///
    /// Given to the camera rather than folded into the coordinate, so it is the
    /// same offset at every zoom and survives rotation: padding moves where the
    /// centre *lands*, and a latitude nudge would be a different distance on
    /// the ground at every zoom and point the wrong way the moment the map
    /// turned.
    static func followInset(in height: CGFloat) -> UIEdgeInsets {
        UIEdgeInsets(top: 0, left: 0, bottom: max(0, height * 0.2), right: 0)
    }

    /// Roughly how long the camera takes to settle onto a new heading, in
    /// seconds.
    ///
    /// Measured against what it replaced. A seventh of the way there per frame
    /// is an exponential with a tenth-of-a-second time constant, which starts a
    /// 90° turn at **756° a second** — two full revolutions in the first
    /// second, from a standing start, with no ramp at all. That number is the
    /// sharpness. Here the same turn peaks at 88°/s and gets there by
    /// accelerating into it and braking out of it, so nothing in the movement
    /// has a corner.
    ///
    /// Three quarters of a second is where the two things this trades off meet.
    /// Longer and the map visibly trails a train through a curve; shorter and
    /// the ease-in is too brief to see, which is the whole point of having one.
    private static let bearingSettle: Double = 0.75

    /// A ceiling on how fast the camera may rotate, in degrees per second.
    ///
    /// The spring alone is smooth but not gentle at the extreme: a vehicle that
    /// reverses at a terminus flips its heading by 180° between one tick and the
    /// next, and an unbounded spring answers that by spinning the map at 176° a
    /// second. Nothing about the position has changed and the whole world whips
    /// round. Capped, that reversal is an even two-second turn instead.
    ///
    /// Set above the spring's own peak for any ordinary turn, so it binds on the
    /// reversal and on nothing else: below about 90° of error the rotation is
    /// the spring's, curves and all, and the ceiling is never reached.
    private static let bearingMaxRate: Double = 90

    /// One step of a critically damped spring between two compass bearings.
    ///
    /// The error is taken the short way round, so 350° to 10° is a 20° turn
    /// rather than a 340° one, and `rate` is carried between steps because that
    /// is what makes the motion have momentum rather than restart every frame.
    ///
    /// The exponential is the standard rational approximation to `e^-x`: it is
    /// accurate to well under a degree over any step this is given and costs no
    /// transcendental per frame.
    static func spring(
        _ from: CLLocationDirection, towards to: CLLocationDirection,
        rate: inout Double, over step: Double,
        settlingIn settle: Double, atMost maxRate: Double
    ) -> CLLocationDirection {
        var error = (to - from).truncatingRemainder(dividingBy: 360)
        if error > 180 { error -= 360 }
        if error < -180 { error += 360 }
        let next = from + springDelta(
            error: error, rate: &rate, over: step, settlingIn: settle, atMost: maxRate
        )
        return (next.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The same spring on a straight line, for a pan rather than a turn.
    static func linearSpring(
        _ from: Double, towards to: Double,
        rate: inout Double, over step: Double,
        settlingIn settle: Double, atMost maxRate: Double
    ) -> Double {
        from + springDelta(
            error: to - from, rate: &rate, over: step, settlingIn: settle, atMost: maxRate
        )
    }

    /// How far a critically damped spring moves in one step.
    ///
    /// Shared by the bearing spring and the catch-up pan so the two motions
    /// have the same shape: accelerate out of rest, decelerate into the
    /// target, never overshoot.
    static func springDelta(
        error: Double, rate: inout Double, over step: Double,
        settlingIn settle: Double, atMost maxRate: Double
    ) -> Double {
        let omega = 2 / max(0.0001, settle)
        let x = omega * step
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let offset = -error
        let temp = (rate + omega * offset) * step
        rate = (rate - omega * temp) * decay
        var moved = error + (offset + temp) * decay

        // Whatever the spring asked for, no faster than this.
        let ceiling = maxRate * step
        if abs(moved) > ceiling {
            moved = moved < 0 ? -ceiling : ceiling
            rate = max(-maxRate, min(maxRate, rate))
        }
        return moved
    }

    /// One vehicle's dot, with everything the dot and its label are drawn from.
    ///
    /// In one place because it is written from two, and the second one used to
    /// leave it out. `followFrame` rewrites the followed vehicle's feature at
    /// the display's rate to keep it under the camera, and it built a bare
    /// point — no `color`, no `fade`, no `line`. A missing paint property is
    /// not "unchanged": the layer falls back to its own default, which for
    /// `circle-color` is black and for `circle-opacity` is fully opaque. So the
    /// vehicle you had just selected grew a solid black disc at its nose, and
    /// its line number — `text-field` reading a `line` that was no longer there
    /// — blinked out and back every time the model's own draw put the real
    /// feature back, fifteen times a second.
    private static func vehicleFeature(
        _ vehicle: VehicleSnapshot, at position: Coord, selected: Bool, emerged: Double,
        tunnel: Double = 0
    ) -> Feature {
        var feature = Feature(geometry: .point(Point(
            CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon)
        )))
        feature.identifier = .string(vehicle.id)
        // The body fades to nothing in a tunnel; the line number does not.
        let shown = (1 - emerged) * (1 - tunnel)
        feature.properties = [
            "line": .string(vehicle.line),
            "color": .string(vehicle.mode.hex),
            "bearing": .number(vehicle.bearing),
            "selected": .boolean(selected),
            "cancelled": .boolean(vehicle.cancelled),
            "fade": .number(shown),
            // Not all the way to nothing: the dot is invisible well before it
            // is gone, and a radius that reaches zero makes the last of the
            // fade happen in a disc too small to see it happen in.
            "shrink": .number(1 - 0.7 * emerged),
            "tunnel": .boolean(tunnel > 0.15),
        ]
        return feature
    }

    private var renderedFrames = 0
    private var renderWindowStart = Date()

    /// One rendered frame, reported onward about twice a second.
    ///
    /// Counting is a pair of integer operations; publishing is an `@Observable`
    /// write. Doing the second at the display's rate would make the readout
    /// cost more than the thing it reports on.
    private func countRenderedFrame() {
        renderedFrames += 1
        let elapsed = Date().timeIntervalSince(renderWindowStart)
        guard elapsed >= 0.5 else { return }
        model.recordRenderRate(Double(renderedFrames) / elapsed)
        renderedFrames = 0
        renderWindowStart = Date()
    }

    /// Apply a development start position, once the map can act on it.
    func applyDebugStartIfAny() {
        guard let mapView, let start = model.takeDebugStart() else { return }
        mapView.camera.ease(
            to: CameraOptions(
                center: CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon),
                zoom: start.zoom,
                bearing: start.bearing,
                pitch: start.pitch.map { CGFloat($0) }
            ),
            duration: 0.4
        )
        // Both together is the third case, and it is a sequence rather than a
        // position: open a vehicle, let the camera take hold of it, and then tap
        // the map out from under it. That is the one gesture that has the
        // display link, the tick at its follow rate and a selection change all
        // in flight at once, and it is not reachable from a launch argument that
        // can only describe where to start.
        guard start.selectVehicle || start.selectNearest else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if start.selectVehicle {
                model.selectNearestVehicle(lon: start.lon, lat: start.lat)
                guard start.selectNearest else { return }
                // Into the mode that turns the map as well as moving it, which
                // is the one with the display link driving the camera's bearing
                // as well as its centre.
                //
                // Twice where the start position is far enough out that the
                // first tap is spent closing on the vehicle instead; see
                // `tappedOpenVehicle`. The sequence is about the bearing lock,
                // so it has to arrive there whatever zoom it was started at.
                try? await Task.sleep(for: .seconds(1))
                if model.tappedOpenVehicle() {
                    try? await Task.sleep(for: .seconds(1))
                    model.tappedOpenVehicle()
                }
                // Long enough for the follow camera to have settled *and* for
                // everything the panel fetches after it opens to have landed —
                // a train's formation is a network round trip, and the wagons
                // arriving change the height the sheet is standing at. The tap
                // has to happen after all of that rather than during it.
                try? await Task.sleep(for: .seconds(8))
                // Away from the middle, because the middle is where the vehicle
                // being followed is. A tap on *that* is not a selection at all —
                // it advances how the camera is held; see `tappedOpenVehicle` —
                // so aiming there would exercise the one path this sequence is
                // not about.
                let point = CGPoint(x: mapView.bounds.midX + 110, y: mapView.bounds.midY + 110)
                await select(at: point, coordinate: mapView.mapboxMap.coordinate(for: point))
                return
            }
            // Straight through the tap handler, so this exercises the same path
            // a finger does rather than a shortcut around it — including the
            // drawn shapes, which are asked about by screen position and would
            // be skipped by a call that only carries a coordinate.
            let coordinate = CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon)
            await select(at: mapView.mapboxMap.point(for: coordinate), coordinate: coordinate)
        }
    }

    func apply(basemap: Basemap) {
        guard basemap != currentBasemap, let mapView else { return }
        currentBasemap = basemap
        // Cleared rather than carried: the style about to load has Standard's
        // own default preset, whatever this one had.
        currentPreset = nil
        styleReady = false
        mapView.mapboxMap.loadStyle(basemap.styleURI)
    }

    /// Put Standard's time of day where the setting says.
    ///
    /// Applied to the running style rather than reloaded into a new one, and
    /// the first attempt did it the other way round. Reloading was defensible
    /// on paper — the preset decides whether the ground is light or dark, and
    /// the halos over it were chosen from that — and it did not work at all:
    /// `loadStyle` with the URI already loaded is a no-op, so nothing happened
    /// until the basemap was actually changed to something else and back.
    ///
    /// Setting the config directly is both correct and better. It is one call,
    /// it lands on the next frame, and it does not throw away every source on
    /// the map to change the colour of the sun. What it does not do is restyle
    /// our own layers for the new ground — and since `placeOverlay` now has all
    /// of them emitting their own colour at full strength, there is nothing
    /// left there that depended on it.
    private func applyLightPreset(_ style: MapboxMap) {
        guard theme == .standard, model.lightPreset != currentPreset else { return }
        currentPreset = model.lightPreset
        Terrain3D.applyStandardConfig(style, preset: model.lightPreset)
        // Whether it is dark out is now a different question than it was a
        // moment ago, and the lamps are the one layer that asks it. Forced
        // through `applySolidity` rather than set here, because dark is only
        // half of what decides it.
        lampsLit = !isDarkTheme
        applySolidity()
    }

    // MARK: - The third dimension

    /// What the 3D scene was last built for, so a frame that changed nothing
    /// about it does nothing about it.
    ///
    /// `draw` runs fifteen times a second and every one of these is a style
    /// write that invalidates something: setting the terrain re-tiles the DEM,
    /// setting a layer's visibility re-validates the layer. Left ungated they
    /// would be the most expensive thing on the frame and they would be
    /// re-answering a question nobody had asked again.
    private var drawn3D: (terrain: Bool, exaggeration: Double, buildings: Bool)?

    /// Put the relief, the air and the buildings where the settings say.
    private func apply3D(_ style: MapboxMap) {
        let wanted = (
            terrain: model.terrain3D,
            exaggeration: model.terrainExaggeration,
            buildings: model.buildings3D
        )
        guard drawn3D == nil || drawn3D! != wanted else { return }
        drawn3D = wanted

        Terrain3D.apply(style, on: wanted.terrain, exaggeration: wanted.exaggeration)
        Terrain3D.applyAtmosphere(style, dark: isDarkTheme)
        if theme.hasOwnBuildings {
            // Standard draws its own, and asks for them by name. The preset it
            // is asked for is whatever the setting says right now; keeping it
            // there afterwards is `applyLightPreset`'s job.
            currentPreset = model.lightPreset
            Terrain3D.applyStandardConfig(style, preset: model.lightPreset)
        } else if theme.showsExtrudedBuildings {
            Terrain3D.setBuildings(style, visible: wanted.buildings)
        }
    }

    /// How solid the vehicles are drawn at the camera's current attitude.
    ///
    /// Kept off the model deliberately. This is a function of the *camera*,
    /// which moves at the display's rate; routing it through an `@Observable`
    /// would both step the fade at the model's tick rate — visibly, during the
    /// one gesture the whole feature answers — and re-render the entire
    /// interface for every degree of a two-finger tilt.
    private var appliedSolidity = -1.0
    private var appliedBaked: Bool?

    /// Whether the solids are the drawing on screen right now. See
    /// `applySolidity`, which switches rather than fades.
    private var showingSolids = false

    /// The baked wagon meshes, and what the style calls each of them.
    private let modelStore = VehicleModelStore()

    /// Which way the camera was looking when the lamps were last built.
    ///
    /// The lamps are the one part of the drawing whose *strength* depends on
    /// the camera and not only on the vehicle: a lamp shining away from the
    /// reader is faded out, and which of a vehicle's four that is changes as
    /// the map is turned. Everything else can sit still through a rotation;
    /// these cannot, so a camera that has turned far enough to matter asks for
    /// a rebuild even when nothing has moved.
    ///
    /// Tilt is no longer in it. The lamps used to be placed by spending their
    /// height as ground distance, which is a function of the pitch; they now
    /// carry the height itself — see `VehicleLamps` — and a tilt moves them no
    /// more than it moves the train under them.
    private var lampCamera = 0.0

    private func applySolidity() {
        guard styleReady, let mapView else { return }
        let camera = mapView.mapboxMap.cameraState
        let wanted = model.solidVehicles
            ? VehicleShape.solidity(pitch: camera.pitch, zoom: camera.zoom)
            : 0
        // A hundredth is well under what a frame can show, and the guard is
        // what keeps a slow tilt from writing a style property per refresh.
        // The lights come on with the third dimension rather than with the
        // fade, so they are a switch and not a dimmer: a headlight that is
        // itself half-transparent is a smear, and the thing it is standing in
        // front of is already fading in behind it.
        let lit = isDarkTheme && wanted > 0.25
        if lit != lampsLit {
            lampsLit = lit
            VehicleLamps.setVisible(mapView.mapboxMap, lit)
            // The source has no lamp features in it yet — or has four per
            // vehicle that are about to become dead weight — and nothing else
            // is going to ask for a rebuild. Through the model's own tick
            // rather than straight into `draw`, because this runs inside a
            // camera-change callback and `draw` calls back into here.
            model.requestTick()
        }
        if lit {
            // A degree and a half of turn moves a lamp by a few centimetres on
            // the ground and rather less on the screen, which is under what a
            // frame can show — and the tick it would otherwise ask for is the
            // whole viewport rebuilt.
            let turned = abs(
                (camera.bearing - lampCamera).truncatingRemainder(dividingBy: 360)
            )
            if min(turned, 360 - turned) > 1.5 {
                lampCamera = camera.bearing
                model.requestTick()
            }
        }
        // Which of the two renderings is in use is part of what has to be
        // applied, not merely part of what it is applied to. It changes once,
        // the first time a model is registered or refused, and that moment
        // rarely coincides with the camera moving — guarded on the fade alone,
        // the fleet would stay drawn by whichever renderer was in use when the
        // camera last moved, which is to say drawn by neither.
        // Drawn or not drawn, rather than drawn faintly. A tilt is the camera
        // changing its mind about which drawing is the right one, and neither
        // answer is "half of each": a solid at half strength is a train with
        // the rails visible through it. What carries the change instead is the
        // flat drawing on the ground, which is drawn at full strength either
        // way and is simply covered by the solid once it stands up — see
        // `drawVehicleShapes`. The two thresholds are one switch
        // with a hold either side, so a camera left sitting exactly on the
        // changeover cannot buzz between the two drawings.
        let solids = wanted >= (showingSolids ? 0.4 : 0.6)
        let baked = model.bakedModels
        guard solids != showingSolids || baked != appliedBaked else { return }
        showingSolids = solids
        appliedSolidity = wanted
        appliedBaked = baked
        // The flat drawing is about to be what the reader is reading again, so
        // it has to be drawn whole from the very next tick rather than from the
        // one after it. See `AppModel.standingVehicles`.
        if !(solids && baked) { model.standingVehicles = [] }
        VehicleModels.setSolidity(mapView.mapboxMap, baked || !solids ? 0 : 1)
        VehicleModels.setModelSolidity(mapView.mapboxMap, baked && solids)
        // And which of the two ways of showing a vehicle through a building is
        // in use. See `VehicleShapes.setXray`.
        VehicleShapes.setXray(mapView.mapboxMap, solids: baked && solids)
    }

    /// Tilt the camera, for the control that does it by hand.
    ///
    /// A two-finger vertical drag already tilts the map and always has. It is
    /// also the single least-known gesture on any phone map, and this feature
    /// is invisible until somebody performs it — so the setting that turns the
    /// solids on sits directly above a slider that does the one thing needed to
    /// see them. Eased rather than set: a pitch dragged in steps is a camera
    /// that jumps, and the ease is short enough to keep up with the slider.
    func tilt(to pitch: Double) {
        guard let mapView else { return }
        mapView.camera.ease(
            to: CameraOptions(pitch: max(0, min(75, pitch))), duration: 0.12
        )
    }

    /// How far the fingers travel for a degree of pitch, near enough.
    ///
    /// The SDK's own number is 2, which wants 150 points of travel to go from
    /// flat to the 75° limit — most of a phone screen, for a gesture people
    /// perform as a flick. 1.6 wants 120.
    private static let tiltTravel: CGFloat = 1.6

    /// The pitch the two-finger drag under way started from, and the flag
    /// saying one is under way at all.
    private var tiltStart: CGFloat?
    /// The app's own tilt recogniser, held so the delegate can tell it apart
    /// from the SDK's.
    private var tiltGesture: UIPanGestureRecognizer?

    /// Replace the SDK's tilt gesture with one that answers the first time.
    ///
    /// Out of the box, tilting takes several attempts and drags the map in
    /// between. Three things in `PitchGestureHandler` conspire:
    ///
    /// - Its recogniser is a `UIPanGestureRecognizer` left at UIKit's default
    ///   `minimumNumberOfTouches` of **one**, while its delegate refuses to
    ///   begin unless two fingers are already down. So the moment the first
    ///   finger has travelled the ten points UIKit calls a drag, the recogniser
    ///   asks to begin, finds one touch where it wanted two, and *fails* — for
    ///   the whole of that touch sequence, however many fingers arrive after.
    ///   Two fingers land a few tens of milliseconds apart; a flick covers ten
    ///   points in less than that.
    /// - The map's pan gesture is waiting on precisely that failure, so what
    ///   the map does instead is drag.
    /// - And when both fingers do land in time, the line between them has to
    ///   fall within 45° of horizontal — which is a hand held square to the
    ///   map, not a hand lying across a phone held in the other one.
    ///
    /// So the tilt becomes a recogniser of the app's own, asking for two
    /// touches up front — which makes it *wait* for the second finger instead
    /// of failing without it — and judging the fingers by a looser rule.
    private func installTilt(on mapView: MapView) {
        // Two fingers now mean tilt rather than drag. Mapbox lets the pan
        // gesture track any number of touches, so that a pinch slides the map
        // as well as scaling it; left on, that pan begins the instant two
        // fingers move, and a gesture that has begun cannot be talked out of
        // it. One finger still pans, which is the gesture anyone reaches for.
        mapView.gestures.options.pinchPanEnabled = false

        // The SDK's tilt stands down — but stays *enabled*. `pitchEnabled =
        // false` would be the obvious way and is the wrong one: the pan gesture
        // is wired to `require(toFail:)` that recogniser, there is no API to
        // undo a failure requirement, and a recogniser switched off never fails
        // anything. Left on with a delegate that always says no, it fails on
        // the first movement exactly as it already does — which is what
        // releases the pan — and tilts nothing ever again.
        mapView.gestures.pitchGestureRecognizer.delegate = self

        let tilt = UIPanGestureRecognizer(
            target: self, action: #selector(handleTilt(_:))
        )
        tilt.minimumNumberOfTouches = 2
        tilt.maximumNumberOfTouches = 2
        tilt.delegate = self
        mapView.addGestureRecognizer(tilt)
        tiltGesture = tilt
    }

    @objc private func handleTilt(_ recogniser: UIPanGestureRecognizer) {
        guard let mapView, let view = recogniser.view else { return }
        switch recogniser.state {
        case .began:
            // The second finger can still land on a drag already under way —
            // the one case a two-touch minimum cannot catch, because by then
            // the pan has begun. Switching the pan off cancels it where it
            // stands, and `PanGestureHandler` reads a cancellation as a plain
            // end with no deceleration, so the map stops rather than coasting.
            // Switched straight back on: UIKit will not hand it the touches it
            // has already missed, so it stays out until the fingers lift.
            let pan = mapView.gestures.panGestureRecognizer
            if pan.state == .began || pan.state == .changed {
                pan.isEnabled = false
                pan.isEnabled = true
            }
            tiltStart = mapView.mapboxMap.cameraState.pitch
            // What the renderer is told about a gesture in progress. Paired
            // with `endGesture` through `tiltStart`, which is set here and
            // nowhere else.
            mapView.mapboxMap.beginGesture()
        case .changed:
            guard let tiltStart else { return }
            let travelled = recogniser.translation(in: view).y
            mapView.mapboxMap.setCamera(to: CameraOptions(
                pitch: max(0, min(75, tiltStart - travelled / Self.tiltTravel))
            ))
        case .ended, .cancelled, .failed:
            guard tiltStart != nil else { return }
            tiltStart = nil
            mapView.mapboxMap.endGesture()
        default:
            break
        }
    }

    // MARK: - Viewport

    private func reportViewport() {
        // A view that has not been laid out yet has zero bounds, and a box built
        // from an empty rectangle is a point rather than a viewport. Reported,
        // that box contains almost nothing: the map drew a single vehicle at two
        // in the morning when fifty-six were running.
        guard let mapView, mapView.bounds.width > 1, mapView.bounds.height > 1 else { return }

        // Every edge of the screen, not two corners of it.
        //
        // `coordinateBounds(for:)` unprojects the top-right and bottom-left
        // screen points and calls them north-east and south-west. That is only
        // true of a map pointing north: rotate it and those two points are no
        // longer the extremes, so the box misses whatever is out past the other
        // two corners — the report was tracks and vehicles cut off along the
        // sides of a rotated map. Past 90° of bearing it is worse than
        // incomplete: the "north-east" corner is genuinely south-west of the
        // other, and the box collapses to nothing.
        //
        // The ground under a rotated, tilted screen is a convex quadrilateral,
        // so the box around its four corners covers all of it. The edge
        // midpoints are in as well, for the tilted case: near the horizon a
        // corner can unproject to nothing at all, and a box built from the
        // bottom of the screen alone would leave the far half of the view
        // unloaded.
        let rect = mapView.bounds
        let outline = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]

        var west = Double.infinity, south = Double.infinity
        var east = -Double.infinity, north = -Double.infinity
        for point in mapView.mapboxMap.coordinates(for: outline) {
            guard point.latitude.isFinite, point.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(point)
            else { continue }
            west = min(west, point.longitude)
            east = max(east, point.longitude)
            south = min(south, point.latitude)
            north = max(north, point.latitude)
        }
        guard west < east, south < north else { return }

        // Guarded, every one of them.
        //
        // This runs on `onCameraChanged`, which during a drag is a handful of
        // events and while *following a vehicle* is one per model tick, for as
        // long as the follow lasts. An `@Observable` write notifies whether or
        // not the value changed, so the unguarded version invalidated every
        // view reading the viewport thirty times a second — the whole header,
        // its chips and their materials — for a number that had usually moved
        // by less than a pixel. That is a re-render of the interface at the
        // model's tick rate, competing with the map for the same frame, and it
        // is why following was the one thing that made the map judder.
        //
        // The thresholds are below what anything downstream can act on: a
        // hundredth of a zoom level is imperceptible, and a viewport edge that
        // has moved a ten-thousandth of a degree — about ten metres — cannot
        // change which vehicles are in the box in any way a frame would show.
        let box = BBox(west: west, south: south, east: east, north: north)
        if model.viewport.moved(from: box, by: 1e-4) { model.viewport = box }
        let zoom = mapView.mapboxMap.cameraState.zoom
        if abs(model.zoom - zoom) > 0.01 { model.zoom = zoom }
        let scale = metresPerPoint
        if abs(model.metresPerPoint - scale) > scale * 0.01 { model.metresPerPoint = scale }
        // Guarded like the rest, and for the same reason — but half a degree
        // rather than something finer, because all the model does with the
        // pitch is decide whether the vehicles are worth slicing into solids,
        // and that answer moves in fiftieths across the whole useful range.
        let pitch = mapView.mapboxMap.cameraState.pitch
        if abs(model.pitch - pitch) > 0.5 { model.pitch = pitch }
        // Not guarded through the model at all: see `applySolidity`.
        applySolidity()
    }

    /// Store the camera, so the next launch opens where this one was left.
    ///
    /// Nothing is guarded or throttled beyond the idle event itself: this is a
    /// dictionary into `UserDefaults`, which coalesces its own writes, and an
    /// idle is a thing that happens when a gesture *stops*.
    private func rememberCamera() {
        guard let mapView else { return }
        let state = mapView.mapboxMap.cameraState
        guard CLLocationCoordinate2DIsValid(state.center) else { return }
        Settings.set(camera: OpeningCamera(
            lat: state.center.latitude,
            lon: state.center.longitude,
            zoom: state.zoom,
            bearing: state.bearing,
            pitch: state.pitch,
            clip: nil,
            where_: .remembered
        ))
    }

    /// Metres per screen point at the current camera — what turns a finger's
    /// width into a search radius on the ground.
    ///
    /// Two mistakes lived here and compounded. The 156,543 constant is metres
    /// per pixel for **256-pixel** tiles; Mapbox GL defines zoom against 512, so
    /// the figure is half that. And the result was then multiplied by the screen
    /// scale, which turns points into pixels — the opposite of what was wanted,
    /// since every other measurement in this file is already in points.
    ///
    /// Together they made the radius about six times too large: at zoom 13 a tap
    /// searched 858 metres, so tapping a stop routinely selected a bus several
    /// streets away.
    private var metresPerPoint: Double {
        guard let mapView else { return 10 }
        let centre = mapView.mapboxMap.cameraState.center
        let zoom = mapView.mapboxMap.cameraState.zoom
        return 78_271.517 * cos(centre.latitude * .pi / 180) / pow(2, zoom)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let mapView else { return }
        let point = recognizer.location(in: mapView)
        let coordinate = mapView.mapboxMap.coordinate(for: point)
        Task { @MainActor in await select(at: point, coordinate: coordinate) }
    }

    /// Answer a touch, wherever it came from.
    private func select(at point: CGPoint, coordinate: CLLocationCoordinate2D) async {
        // The drawn shapes are asked about first, because asking is a round trip
        // through the renderer and the model's own answer does not depend on it.
        // What the shapes are *worth* is decided in the model, after every
        // marker has had its chance: a plate under the finger still beats the
        // slab it is standing on.
        let shapes = await shapesUnder(point)
        await model.handleTap(
            lon: coordinate.longitude, lat: coordinate.latitude, metresPerPoint: metresPerPoint,
            platformShapes: shapes.platforms, stationShapes: shapes.stations,
            stopDots: shapes.dots, solidTaps: solidTaps(at: coordinate)
        )
    }

    /// Where the same touch would have landed had it been aimed at the ground,
    /// for a finger that was aimed at a vehicle standing up out of it.
    ///
    /// **The problem this exists for.** A tap is answered on the map surface:
    /// the touch is unprojected to a coordinate and the model compares it with
    /// the footprint each vehicle occupies there. Once the map is tilted, the
    /// vehicles are not on the map surface any more — they are solids standing
    /// several metres above it — and a point drawn at height *h* is drawn where
    /// the ground *past* it appears. So a finger placed squarely on the side of
    /// an intercity unprojected to a coordinate somewhere beyond the far rail,
    /// and the only part of the screen that selected the train was the ballast
    /// underneath it. Every solid on this map had a flat hitbox lying on the
    /// ground in its own shadow.
    ///
    /// **The correction.** For a camera whose axis makes an angle θ with the
    /// vertical, the top of something *h* tall is drawn where the ground point
    /// `h · tanθ` further from the camera is drawn. So the ground coordinate
    /// that a touch at height *h* really refers to is this one, moved `h · tanθ`
    /// metres back *towards* the camera — which is the bearing the map is
    /// turned to, reversed.
    ///
    /// Since the finger could have been anywhere between the rails and the
    /// roof, the whole side is sampled and the model takes whichever comes out
    /// nearest. That is what makes the box a box: it now has the height the
    /// drawing has, rather than only the plan.
    ///
    /// Empty on a map lying flat — `tan 0` is nothing and the ground answer was
    /// already right — and empty where nothing is standing up. See
    /// `AppModel.distance(to:lon:lat:lifted:)`.
    private func solidTaps(at coordinate: CLLocationCoordinate2D) -> [Coord] {
        guard let mapView, model.solidity > 0 else { return [] }
        let camera = mapView.mapboxMap.cameraState
        let pitch = Double(camera.pitch)
        guard pitch > 1 else { return [] }
        // Capped short of the horizon: `tan` runs away there, and a correction
        // measured in hundreds of metres is not a hitbox, it is a lottery.
        let lean = tan(Geo.toRad(min(pitch, 72)))
        // Away from the camera is the bearing the map is turned to, so back
        // towards it is that reversed.
        let towardsCamera = camera.bearing + 180
        return Self.tapHeights.map {
            let point = Geo.moved(
                Coord(lon: coordinate.longitude, lat: coordinate.latitude),
                bearing: towardsCamera, metres: $0 * lean
            )
            return point
        }
    }

    /// How far up the side of a vehicle the touch is sampled, in metres.
    ///
    /// Four rungs rather than two, because the correction is linear in the
    /// height and a finger that landed on the window band should not be
    /// answered by the roof. The top one is a little over a Swiss loading
    /// gauge once `VehicleShape.modelExaggeration` has been spent on it —
    /// the roof of the tallest thing this map stands up.
    private static let tapHeights: [Double] = [1.6, 3.2, 4.8, 6.2]

    // MARK: - One blob per station

    /// The blobs currently filtered out, so an unchanged answer costs nothing.
    private var mergedAway: [String] = []

    /// Keep one blob per station and drop the rest.
    ///
    /// A stop mapped as several OSM nodes gets several circles — Bern's tram
    /// stop is three of them, all named "Bern Bahnhof" — and overlapping fills
    /// stack into darker lenses, so one stop reads as three. Which blobs belong
    /// to the same station is not in the tile: it is the same identifier join
    /// that answers a tap, an OSM element id through `platforms.bin` to a UIC.
    ///
    /// Read from the *source* rather than from what is rendered. A rendered
    /// query only returns what is drawn, so the blobs hidden last time would be
    /// invisible to the query that decides whether to hide them — the set could
    /// only ever grow, and a station would end up with no blob at all.
    ///
    /// Run when the camera settles rather than per frame: it is a query over the
    /// loaded tiles and a hop to the fleet, and the answer cannot change while
    /// nothing moves.
    private func mergeStationBlobs() async {
        guard let mapView, styleReady else { return }
        let style: MapboxMap = mapView.mapboxMap
        guard model.showRailwayShapes,
              mapView.mapboxMap.cameraState.zoom >= RailwayShapes.blobMinZoom
        else { return }

        let boxes = await blobExtents(style)
        guard !boxes.isEmpty else { return }

        let stations = await model.stations(forShapes: Array(boxes.keys))

        // Grouped by station, and within a station by whether the blobs actually
        // lie on top of each other.
        //
        // Same station is not the same place. Bern's tram stop is three circles
        // over one crossing, and the K bays on Bubenbergplatz are a fourth two
        // hundred metres away that belongs to the same station and overlaps
        // nothing. Hiding that one leaves a stop with no blob at all, which is
        // the opposite of the complaint: the mush is the overlap, so the overlap
        // is what is merged.
        //
        // Largest first, so the blob that survives a cluster is the one giving
        // up the least ground; ties by the lower id, so the same view always
        // resolves the same way and nothing flickers as tiles come and go.
        var byStation: [String: [String]] = [:]
        for id in boxes.keys {
            guard let station = stations[id] else { continue }
            byStation[station, default: []].append(id)
        }

        var hidden: [String] = []
        for (_, ids) in byStation {
            let ordered = ids.sorted { left, right in
                let a = boxes[left]!, b = boxes[right]!
                return a.area == b.area ? left < right : a.area > b.area
            }
            var kept: [Box] = []
            for id in ordered {
                let box = boxes[id]!
                if kept.contains(where: { $0.overlaps(box) }) {
                    hidden.append(id)
                } else {
                    kept.append(box)
                }
            }
        }
        hidden.sort()

        guard hidden != mergedAway else { return }
        mergedAway = hidden
        RailwayShapes.merge(style, hiding: hidden)
    }

    /// A blob's extent on the ground.
    private struct Box {
        var west: Double, south: Double, east: Double, north: Double

        mutating func widen(to point: CLLocationCoordinate2D) {
            west = min(west, point.longitude)
            east = max(east, point.longitude)
            south = min(south, point.latitude)
            north = max(north, point.latitude)
        }

        func overlaps(_ other: Box) -> Bool {
            west < other.east && other.west < east && south < other.north && other.south < north
        }

        /// Longitudes are narrower than latitudes this far north. Blobs are only
        /// ever compared with their neighbours, so the cosine is taken once for
        /// the box rather than per point.
        var area: Double {
            (east - west) * cos(south * .pi / 180) * (north - south)
        }
    }

    /// Every station blob in the loaded tiles, and how much ground it covers.
    ///
    /// The area is of the bounding box rather than of the polygon: these are
    /// buffered circles, so the box ranks them the same way the shape would, and
    /// it is arithmetic over the coordinates rather than a geometry library. The
    /// boxes of a shape's several copies are merged first — a polygon crossing a
    /// tile boundary arrives once per tile, each time clipped, and the clipped
    /// piece is not what the blob covers.
    private func blobExtents(_ style: MapboxMap) async -> [String: Box] {
        let found: [QueriedSourceFeature] = await withCheckedContinuation { continuation in
            style.querySourceFeatures(
                for: RailwayShapes.sourceId,
                options: SourceQueryOptions(sourceLayerIds: [RailwayShapes.stationSourceLayer], filter: [])
            ) { result in
                continuation.resume(returning: (try? result.get()) ?? [])
            }
        }

        var boxes: [String: Box] = [:]
        for hit in found {
            let feature = hit.queriedFeature.feature
            guard let id = Self.identifier(of: feature), let geometry = feature.geometry else { continue }
            for point in Self.outline(of: geometry) {
                if var box = boxes[id] {
                    box.widen(to: point)
                    boxes[id] = box
                } else {
                    boxes[id] = Box(
                        west: point.longitude, south: point.latitude,
                        east: point.longitude, north: point.latitude
                    )
                }
            }
        }
        return boxes
    }

    private static func outline(of geometry: Geometry) -> [CLLocationCoordinate2D] {
        switch geometry {
        case let .polygon(polygon): return polygon.coordinates.flatMap { $0 }
        case let .multiPolygon(multi): return multi.coordinates.flatMap { $0.flatMap { $0 } }
        case let .lineString(line): return line.coordinates
        case let .multiLineString(lines): return lines.coordinates.flatMap { $0 }
        case let .point(point): return [point.coordinates]
        default: return []
        }
    }

    /// The OpenStreetMap ids of whatever OpenRailwayMap has drawn under a touch.
    ///
    /// Three lists rather than one: a platform footprint answers with a platform
    /// board, a stop dot and a station blob with a station board, and they are
    /// ranked against each other rather than merged — a platform is the smaller,
    /// more specific object and wins wherever both are under the finger, and the
    /// dot is smaller still.
    ///
    /// Topmost first, deduplicated, because a platform is drawn by a fill and an
    /// outline both and trying the same id twice repeats a lookup that already
    /// failed.
    private func shapesUnder(
        _ point: CGPoint
    ) async -> (platforms: [String], stations: [String], dots: [String]) {
        guard model.showRailwayShapes else { return ([], [], []) }
        // A finger is not a pixel — but the reach is what decides what a tap
        // means, so the small marks get the small radius. The dots on the track
        // are four points across and sit on top of everything; the blob under
        // them covers the whole station and is easy to hit anywhere.
        async let platforms = shapeIds(near: point, layers: RailwayShapes.platformLayers, radius: 4)
        async let stations = shapeIds(near: point, layers: RailwayShapes.stationLayers, radius: 8)
        async let dots = shapeIds(near: point, layers: RailwayShapes.stopDotLayers, radius: 5)
        return await (platforms, stations, dots)
    }

    private func shapeIds(near point: CGPoint, layers: [String], radius: CGFloat) async -> [String] {
        guard let mapView else { return [] }
        let present = layers.filter { mapView.mapboxMap.layerExists(withId: $0) }
        guard !present.isEmpty else { return [] }

        let box = CGRect(
            x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2
        )
        let found: [QueriedRenderedFeature] = await withCheckedContinuation { continuation in
            mapView.mapboxMap.queryRenderedFeatures(
                with: box, options: RenderedQueryOptions(layerIds: present, filter: nil)
            ) { result in
                continuation.resume(returning: (try? result.get()) ?? [])
            }
        }

        var seen = Set<String>()
        var out: [String] = []
        for hit in found {
            guard let id = Self.identifier(of: hit.queriedFeature.feature) else { continue }
            let key = "\(hit.queriedFeature.sourceLayer ?? ""):\(id)"
            if seen.insert(key).inserted { out.append(id) }
        }
        return out
    }

    /// The `id` property a tile carries, whichever type it is written as.
    ///
    /// The platform layers write `way-421636561` and the platform edges a bare
    /// integer — the same fact in two spellings, and both are accepted by the
    /// lookup on the other side.
    private static func identifier(of feature: Feature) -> String? {
        // Doubly optional: the feature may carry no properties, and a property
        // that is present may be JSON null.
        guard let value = feature.properties?["id"] ?? nil else { return nil }
        switch value {
        case let .string(text): return text
        case let .number(number): return String(Int(number))
        default: return nil
        }
    }

    /// The next locate mode along, and the camera to match.
    ///
    /// Unfocused → focused → bearing → focused. The cycle stops short of
    /// unfocused because there is no press that means "stop following": letting
    /// go of the map is what means that, and the map already reports it.
    ///
    /// The puck is already asking for the fix — it is switched on in
    /// `makeUIView` — so this reads the location the SDK has rather than
    /// starting a second one. With no fix yet there is nothing honest to move
    /// to, and the button says as much instead of easing the camera to a
    /// coordinate nobody has.
    private func advanceLocateMode() {
        guard let mapView, mapView.location.latestLocation != nil else { return }
        model.hasLocationFix = true
        switch model.locateMode {
        case .unfocused, .bearing:
            // Out of bearing lock the map is put back to north, which is the
            // other half of what that press means: stop turning, and undo the
            // turn.
            follow(.constant(0), as: .focused)
        case .focused:
            follow(.heading, as: .bearing)
        }
    }

    private func follow(_ bearing: FollowPuckViewportStateBearing, as mode: LocateMode) {
        guard let mapView else { return }
        // Close enough to see which street, and never further out than the map
        // already is: pressing it while looking at a platform should not throw
        // the view back to the canton.
        let zoom = max(mapView.mapboxMap.cameraState.zoom, 15)
        // Flat on the way in, unlike the SDK's default 45°. This is a map of
        // what is coming towards a stop, read from above; tipping it into a
        // driving view hides the half of the network that is furthest away.
        //
        // On the way in *only*, and that is the fix for a real bug. A follow
        // state does not set the camera once, it sets it on every puck update
        // — so a pitch named here is not a starting attitude, it is a pitch the
        // map is held at. Tilting a focused map did nothing at all: the slider
        // eased the camera over, the next fix from the phone put it back, and
        // the whole tilt-and-solids feature was unreachable without first
        // unfocusing. Named `nil`, pitch is simply not one of the things this
        // state has an opinion about, and the tilt is the reader's again.
        //
        // And only from cold. Coming back from the bearing lock the map is
        // already focused and may well be tilted on purpose; flattening it
        // there would be undoing something nobody asked to have undone.
        let flatten = model.locateMode == .unfocused
        let state = mapView.viewport.makeFollowPuckViewportState(
            options: FollowPuckViewportStateOptions(
                zoom: zoom, bearing: bearing, pitch: flatten ? 0 : nil
            )
        )
        model.locateMode = mode
        // No completion handler putting the button back on failure: the status
        // observer already hears the idle that a failed transition ends in, and
        // it hears it in order. A completion would not — press the button twice
        // quickly and the first transition's cancellation lands *after* the
        // second has started, unfocusing a map that is following perfectly well.
        //
        // Releasing the pitch is safe in that same completion for the opposite
        // reason: it says nothing about which state is current. Landed late, it
        // hands the tilt back on a state nobody is using any more, and the one
        // that *is* being used will hand its own back when it finishes.
        mapView.viewport.transition(
            to: state, transition: mapView.viewport.makeDefaultViewportTransition()
        ) { _ in
            state.options.pitch = nil
        }
    }

    func focus(on coordinate: CLLocationCoordinate2D, zoom: Double? = nil) {
        guard let mapView else { return }
        // Whatever the map was following, it is not following it any more: this
        // is the app moving the camera somewhere else, and a follow state left
        // running would drag it straight back.
        mapView.viewport.idle()
        mapView.camera.ease(
            to: CameraOptions(center: coordinate, zoom: zoom ?? mapView.mapboxMap.cameraState.zoom),
            duration: 0.6
        )
    }

    /// Close to a zoom, leaving the centre to whatever is holding it.
    ///
    /// Zoom alone, and that is the whole reason this is not `focus`. The
    /// vehicle follower writes the centre on every display frame, so an ease
    /// carrying a centre of its own would be two things moving the camera
    /// sideways at once for the length of the ease — the vehicle would swim
    /// against the map instead of the map moving under it. Nothing writes the
    /// zoom per frame, so the zoom is the one part that can be animated
    /// underneath the follower without a fight.
    ///
    /// The viewport is deliberately *not* idled, unlike `focus`: this is asked
    /// for while a vehicle is being followed, and that following is a camera
    /// set per frame rather than a viewport state, so there is nothing here to
    /// stand down.
    func zoom(to zoom: Double) {
        guard let mapView else { return }
        // Longer than a recentre. This is up to five zoom levels from a country
        // view, and taken at `focus`'s 0.6 s it is a lunge rather than an
        // approach — the ground scale goes past thirtyfold in the time it takes
        // to read the word.
        mapView.camera.ease(to: CameraOptions(zoom: zoom), duration: 0.8)
    }

    /// Pan by a lon/lat delta, keeping everything else the camera is doing.
    ///
    /// A selected train that has just been re-timed jumps under a camera that
    /// is not following it. Adding the same vector to the centre is what keeps
    /// the train at the screen position the reader tapped, instead of
    /// recentring — recentring would be a second, larger movement than the
    /// jump, and would put the train under the sheet.
    func nudge(dlon: Double, dlat: Double) {
        guard let mapView, dlon != 0 || dlat != 0 else { return }
        let centre = mapView.mapboxMap.cameraState.center
        mapView.camera.ease(
            to: CameraOptions(center: CLLocationCoordinate2D(
                latitude: centre.latitude + dlat,
                longitude: centre.longitude + dlon
            )),
            duration: 0.75
        )
    }

    /// Frame a whole run, so selecting a vehicle shows where it is going.
    func frame(_ path: [Coord]) {
        guard let mapView, path.count > 1 else { return }
        mapView.viewport.idle()
        let coordinates = path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let camera = try? mapView.mapboxMap.camera(
            for: coordinates,
            camera: CameraOptions(),
            coordinatesPadding: UIEdgeInsets(top: 80, left: 60, bottom: 320, right: 60),
            maxZoom: 14, offset: nil
        ) else { return }
        mapView.camera.ease(to: camera, duration: 0.8)
    }

    // MARK: - Layers

    private func installLayers() {
        guard let mapView else { return }
        let style: MapboxMap = mapView.mapboxMap
        // What the basemap brought. Everything in the style after this function
        // that is not in here is ours, which is how `placeOverlay` finds our
        // thirty-odd layers across four modules without any of them having to
        // declare themselves. See `Terrain3D.placeOverlay`.
        let basemapLayers = Set(style.allLayerIdentifiers.map(\.id))

        do {
            // The plates and kerb markers, before any layer asks for them.
            // Registering an image after the layer that names it leaves the
            // layer with nothing to draw and no error to say so.
            installChipImages(style)

            // The third dimension, under everything else.
            //
            // First in the file and first on the map, and both matter. The
            // elevation source has to exist before `apply3D` can switch relief
            // on; the buildings have to be added before any layer of this
            // app's, because a layer's depth is where it was added and the
            // whole point of the buildings is that the railway is drawn *on*
            // them rather than under them. Each is caught on its own: the
            // terrain needs a network, and a map with no relief is still a map.
            do {
                try Terrain3D.installSource(style)
                try Terrain3D.installSky(style, dark: isDarkTheme)
                // Installed whether or not they are wanted, and hidden if they
                // are not. A layer's depth is where it was *added*, and this is
                // the only moment at which "under everything this app draws" is
                // expressible — install it later, when somebody flips the
                // switch, and it lands on top of the trains instead of under
                // them. A hidden layer is not rasterised, so the only thing the
                // unwanted case costs is the entry in the layer list.
                if theme.showsExtrudedBuildings {
                    try Terrain3D.installBuildings(style, dark: isDarkTheme, below: nil)
                    Terrain3D.setBuildings(style, visible: model.buildings3D)
                }
            } catch {
                Diagnostics.note("3D scene unavailable: \(error)")
            }

            // Empty sources up front; `draw` fills them. Declaring them here
            // means a style reload cannot leave a layer pointing at nothing.
            //
            // Skipped if they are already here. `onStyleLoaded` fires more
            // than once for the same style — Standard finishing its import,
            // a config write, the SDK retrying — and adding a source that
            // exists throws. That throw used to take the whole overlay down
            // with `assertionFailure`, which is a blank map and a crash.
            for id in [ID.tracks, ID.vehicles, ID.stops, ID.route, ID.routeStops,
                       ID.platforms, ID.leaders] {
                guard !style.sourceExists(withId: id) else { continue }
                var source = GeoJSONSource(id: id)
                source.data = .featureCollection(FeatureCollection(features: []))
                try style.addSource(source)
            }

            // The station blobs and the platform footprints, under everything
            // else this map draws. That is OpenRailwayMap's own order and it is
            // the right one: the rails run over the platform, not under it, and
            // a station area is the ground the whole scene stands on.
            //
            // Failure here must not take the rest of the map with it, so it is
            // caught rather than thrown — the shapes are the one layer that
            // needs a network, and a map with no platforms is still a map.
            do {
                try RailwayShapes.installSource(style)
                try RailwayShapes.installShapes(style, dark: isDarkTheme)
            } catch {
                Diagnostics.note("railway shapes unavailable: \(error)")
            }

            // The railway network next, so everything else lies over it.
            //
            // The web app gets this from OpenRailwayMap's vector tiles. Here it
            // is drawn from the routing graph, which is the same OSM railway by
            // a shorter route: already on the device, and correct with no
            // network at all.
            var tracks = LineLayer(id: ID.tracks, source: ID.tracks)
            tracks.lineColor = .expression(
                Exp(.switchCase) {
                    Exp(.get) { "tram" }
                    "#7fd1a6"
                    "#8fb8de"
                }
            )
            tracks.lineWidth = .expression(
                Exp(.interpolate) { Exp(.linear); Exp(.zoom); 9; 0.6; 13; 2.0; 17; 4.5 }
            )
            tracks.lineOpacity = .constant(model.trackOpacity)
            tracks.lineCap = .constant(.round)
            // Everything that is actually out in the open. The tunnels are the
            // same source drawn again below, because a dash pattern is a layer
            // property and not something a feature can carry.
            tracks.filter = Exp(.not) { Exp(.get) { "tunnel" } }
            try addLayer(tracks, to: style)

            // And the track that is under something, dashed.
            //
            // A tunnel is drawn at all because it is where the train is: half
            // the Gotthard route and most of a city approach are underground,
            // and a map that stops at the portal loses the line exactly where
            // somebody following a train needs it. Drawn *differently* because
            // it is the one part of the network nobody could see by standing
            // there — the dash is the whole of that distinction, so it keeps
            // the colour and the weight of the line it continues and changes
            // nothing else.
            var tunnels = LineLayer(id: ID.tracksTunnel, source: ID.tracks)
            tunnels.filter = Exp(.get) { "tunnel" }
            tunnels.lineColor = tracks.lineColor
            tunnels.lineWidth = tracks.lineWidth
            tunnels.lineOpacity = .constant(model.trackOpacity)
            // Butt rather than round: a round cap on a two-point dash fills the
            // gap it is supposed to leave, and the line comes out solid at the
            // zooms the dash matters at.
            tunnels.lineCap = .constant(.butt)
            // In line widths, so the pattern holds its proportions as the line
            // thickens with the zoom.
            tunnels.lineDasharray = .constant([2.2, 1.6])
            try addLayer(tunnels, to: style)

            // And the same network in OpenRailwayMap's own colours, at the same
            // depth, for whichever of the two the map is set to draw. Installed
            // hidden and costing nothing until it is asked for — see
            // `RailwayLines`. Caught rather than thrown for the same reason the
            // shapes are: a map with one railway overlay instead of two is
            // still a map.
            do {
                try RailwayLines.installSources(style)
                try RailwayLines.installLines(style, dark: isDarkTheme)
                RailwayLines.setVisible(style, model.highContrastTracks)
                RailwayLines.setOpacity(style, model.trackOpacity)
            } catch {
                Diagnostics.note("railway lines unavailable: \(error)")
            }

            // The dots where a service actually stops sit *on* the rails, so
            // they go above them — the one part of the overlay ORM also draws
            // over its own network.
            try? RailwayShapes.installStopPositions(style, dark: isDarkTheme)
            RailwayShapes.setVisible(style, model.showRailwayShapes)

            // The route next, so it lies under the markers rather than over
            // them. Two layers over one source, split on `exact`: solid where
            // the line follows mapped track, dashed where it is a guess.
            //
            // The web app drew one style for a whole journey, chosen by where
            // *most* of its geometry came from — so a night train with real
            // rails through Switzerland drew its 300 km guess across Germany in
            // the same confident white. Per-run styling is why `legSources`
            // exists.
            var glow = LineLayer(id: "\(ID.route)-glow", source: ID.route)
            glow.lineColor = .constant(StyleColor(UIColor.white))
            glow.lineOpacity = .constant(0.22)
            glow.lineWidth = .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); 8; 6.0; 16; 22.0 })
            glow.lineCap = .constant(.round)
            glow.lineJoin = .constant(.round)
            try addLayer(glow, to: style)

            var solid = LineLayer(id: "\(ID.route)-solid", source: ID.route)
            solid.filter = Exp(.get) { "exact" }
            solid.lineColor = .constant(StyleColor(UIColor.white))
            solid.lineWidth = .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); 8; 1.6; 16; 5.0 })
            solid.lineCap = .constant(.round)
            solid.lineJoin = .constant(.round)
            try addLayer(solid, to: style)

            var dashed = LineLayer(id: "\(ID.route)-dashed", source: ID.route)
            dashed.filter = Exp(.not) { Exp(.get) { "exact" } }
            dashed.lineColor = .constant(StyleColor(UIColor.white))
            dashed.lineOpacity = .constant(0.75)
            dashed.lineWidth = .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); 8; 1.4; 16; 4.0 })
            dashed.lineDasharray = .constant([1.5, 1.5])
            try addLayer(dashed, to: style)

            var routeStops = CircleLayer(id: ID.routeStops, source: ID.routeStops)
            routeStops.circleRadius = .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); 10; 2.0; 16; 4.5 })
            routeStops.circleColor = .constant(StyleColor(UIColor.white))
            routeStops.circleStrokeWidth = .constant(1)
            routeStops.circleStrokeColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.5)))
            routeStops.minZoom = 10
            try addLayer(routeStops, to: style)

            // Stops, in three bands.
            //
            // The bands are each layer's own `minZoom`/`maxZoom` rather than one
            // filter, because "from 12, and up to 16 unless there are no kerbs"
            // written as a single zoom expression is exactly the shape a style
            // rejects — and a rejected layer draws nothing at all, silently.
            // Three plain layers say the same thing and cannot fail that way.
            for band in StationBand.allCases {
                var dot = CircleLayer(id: band.layerId, source: ID.stops)
                dot.circleRadius = .expression(
                    Exp(.interpolate) {
                        Exp(.linear); Exp(.zoom)
                        9; Exp(.switchCase) { Exp(.get) { "rail" }; 2.2; 1.8 }
                        12; Exp(.switchCase) { Exp(.get) { "rail" }; 3.2; 3.0 }
                        14; 3.8
                        16; 5.0
                        17; 5.6
                    }
                )
                dot.circleColor = .expression(
                    Exp(.switchCase) { Exp(.get) { "rail" }; "#ffffff"; "#b9bec7" }
                )
                dot.circleStrokeWidth = .constant(1.2)
                dot.circleStrokeColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.7)))
                dot.circleOpacity = .expression(
                    Exp(.interpolate) { Exp(.linear); Exp(.zoom); 9; 0.55; 12; 1.0 }
                )
                dot.filter = band.filter
                dot.minZoom = band.minZoom
                if let maxZoom = band.maxZoom { dot.maxZoom = maxZoom }
                try addLayer(dot, to: style)
            }

            // The ring on a selected station, under the same rules as the dot it
            // rings — without them it can outlive its own marker and hang over
            // the map with nothing inside it.
            var stationRing = CircleLayer(id: "\(ID.stops)-selected", source: ID.stops)
            stationRing.circleRadius = .constant(10)
            stationRing.circleColor = .constant(StyleColor(UIColor.clear))
            stationRing.circleStrokeWidth = .constant(2.5)
            stationRing.circleStrokeColor = .constant(StyleColor(UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)))
            stationRing.filter = Exp(.eq) { Exp(.get) { "id" }; "__none__" }
            stationRing.minZoom = 9
            try addLayer(stationRing, to: style)

            // The name. Railway stations are named as soon as they are drawn;
            // local stops are not named until the plates appear, because naming
            // 33,000 stops from zoom 13 buries the map under its own labels and
            // what a dot at that zoom says — *there is a stop here* — needs no
            // words.
            //
            // Two layers, not one filter with a zoom test. A `zoom` expression
            // inside a filter is exactly the shape a style rejects — see the
            // station bands above — and a rejected layer here used to take
            // every layer already added down with it.
            try addLayer(stopLabelLayer(
                id: "\(ID.stops)-label-rail",
                filter: Exp(.get) { "rail" },
                minZoom: 11
            ), to: style)
            try addLayer(stopLabelLayer(
                id: "\(ID.stops)-label-local",
                filter: Exp(.not) { Exp(.get) { "rail" } },
                minZoom: Self.plateMinZoom
            ), to: style)

            try installPlatformLayers(style)

            // Vehicles, on top. A coloured dot with a dark ring reads at every
            // zoom; the arrow only appears once there is room for it.
            // Vehicles, on top. A coloured dot with a dark ring reads at every
            // zoom; the arrow only appears once there is room for it.
            //
            // `fade` and `shrink` are how the dot hands over to the drawn
            // vehicle. Once a train is long enough on screen to be drawn as one
            // — which is a different zoom for a four-hundred-metre intercity
            // and for a minibus, so it cannot be a zoom expression — its dot
            // gives way. Cutting it out would blink; leaving it under the shape
            // puts a bright disc in the middle of the train. So it draws down
            // and away as the shape draws in, and what a reader sees is one
            // marker changing into another.
            var halo = CircleLayer(id: "\(ID.vehicles)-halo", source: ID.vehicles)
            // The shrink multiplies each *stop* rather than the curve as a
            // whole, which reads worse and is the only form a style accepts: a
            // `zoom` expression may only be the input to a top-level `step` or
            // `interpolate`, so wrapping the interpolate in a `*` puts zoom one
            // level down and the whole style is refused — every layer here,
            // including the ones already added. The stops say the same thing.
            halo.circleRadius = .expression(
                Exp(.interpolate) {
                    Exp(.linear); Exp(.zoom)
                    6; Exp(.product) { 3.0; Exp(.get) { "shrink" } }
                    11; Exp(.product) { 6.0; Exp(.get) { "shrink" } }
                    16; Exp(.product) { 11.0; Exp(.get) { "shrink" } }
                }
            )
            halo.circleColor = .expression(Exp(.get) { "color" })
            halo.circleStrokeWidth = .expression(
                Exp(.switchCase) { Exp(.get) { "selected" }; 3.0; 1.2 }
            )
            halo.circleStrokeColor = .expression(
                Exp(.switchCase) {
                    Exp(.get) { "selected" }
                    "#ffffff"
                    "rgba(0,0,0,0.6)"
                }
            )
            halo.circleOpacity = .expression(
                Exp(.product) {
                    Exp(.switchCase) { Exp(.get) { "cancelled" }; 0.35; 1.0 }
                    Exp(.get) { "fade" }
                }
            )
            // The ring carries its own opacity, and without this it outlives
            // the disc inside it: a fully drawn train with a hollow circle
            // sitting on its third coach.
            halo.circleStrokeOpacity = .expression(Exp(.get) { "fade" })
            try addLayer(halo, to: style)

            // The vehicles themselves, over the dots they replace and under the
            // line numbers, which stay legible whatever is drawn beneath them.
            do {
                try VehicleShapes.install(style)
                // And the same vehicles as solids, over the flat drawings they
                // rise out of. Installed at zero opacity and costing nothing
                // until the camera is tilted — see `applySolidity`.
                try VehicleModels.install(style)
                // And their lights, over everything — a lamp is the one thing
                // on a vehicle that is never behind any part of it.
                try VehicleLamps.install(style)
            } catch {
                // A map with dots and no shapes is the map this app had until
                // now, so a style that will not take these is not worth taking
                // the rest of the layers down over.
                Diagnostics.note("vehicle shapes unavailable: \(error)")
            }

            var labels = SymbolLayer(id: "\(ID.vehicles)-label", source: ID.vehicles)
            labels.textField = .expression(Exp(.get) { "line" })
            labels.textSize = .expression(
                Exp(.interpolate) {
                    Exp(.linear); Exp(.zoom)
                    11; 11.0; 15; 13.0; 18; 16.0
                }
            )
            labels.textOffset = .constant([0, -1.2])
            labels.textAnchor = .constant(.bottom)
            labels.textColor = .constant(StyleColor(UIColor.white))
            labels.textHaloColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.8)))
            labels.textHaloWidth = .constant(1.2)
            // Constants, not data-driven. `text-allow-overlap` and
            // `text-optional` do not take feature expressions — asking for
            // `["get", "tunnel"]` refused the whole layer, so the line
            // number never appeared. Always drawn: in a tunnel it *is* the
            // train, and in the open a number over a four-coach rake is
            // still the thing you follow.
            labels.textAllowOverlap = .constant(true)
            labels.textIgnorePlacement = .constant(true)
            // Default 0 hides a label that terrain occludes — which is every
            // number on a tunnel under a hill. The body has faded; the number
            // is what is left to follow, including through the mountain.
            labels.textOcclusionOpacity = .constant(1)
            labels.textEmissiveStrength = .constant(1)
            labels.symbolZElevate = .constant(true)
            labels.minZoom = 11
            try addLayer(labels, to: style)

            // Last, and above everything: where *you* are.
            installPuck(topmost: "\(ID.vehicles)-label")

            // And now that every layer of ours exists, put the whole overlay
            // where it belongs in somebody else's style: the ground markings
            // behind the buildings that stand on them, the markers in front,
            // and none of it lit by the basemap's own sun. Both of those are
            // invisible on Dark and Light — neither has slots or a scene light
            // — and both are the difference between a usable map and an
            // unusable one on Standard at night.
            Terrain3D.placeOverlay(
                style,
                ownLayers: Set(style.allLayerIdentifiers.map(\.id)).subtracting(basemapLayers)
            )

            forgetWhatWasDrawn()
            // The style that has just loaded knows nothing about the relief,
            // the air over it or what time of day Standard thinks it is. All
            // three are style-level state rather than layers, so a reload wipes
            // them and this is the only place that can put them back.
            //
            // *After* the memos are cleared, not before. `apply3D` does nothing
            // when what is wanted matches what was last applied — and what was
            // last applied was applied to a style that no longer exists, so
            // called first it would agree that there was nothing to do and the
            // relief would stay off until something else happened to change.
            apply3D(style)
            styleReady = true
            draw()
        } catch {
            // A style that refused a layer draws nothing at all, silently — the
            // one failure mode worth shouting about, because the map simply
            // looks empty. Logged always; crashed only when the sources
            // themselves did not land, because a partial overlay is still a
            // map and a duplicate `onStyleLoaded` is not worth dying over.
            Diagnostics.note("map layers rejected: \(error)")
            if style.sourceExists(withId: ID.vehicles) {
                styleReady = true
                draw()
            } else {
                assertionFailure("map layers rejected: \(error)")
            }
        }
    }

    /// Add `layer` unless this style already has it.
    private func addLayer(_ layer: some Layer, to style: MapboxMap) throws {
        guard !style.layerExists(withId: layer.id) else { return }
        try style.addLayer(layer)
    }

    /// Shared styling for a stop name. Split by filter rather than by zoom
    /// inside one filter — see the install above.
    private func stopLabelLayer(id: String, filter: Exp, minZoom: Double) -> SymbolLayer {
        var layer = SymbolLayer(id: id, source: ID.stops)
        layer.textField = .expression(Exp(.get) { "name" })
        layer.textSize = .expression(
            Exp(.interpolate) { Exp(.linear); Exp(.zoom); 11; 10.0; 16; 12.0 }
        )
        layer.textOffset = .constant([0, 0.9])
        layer.textAnchor = .constant(.top)
        layer.textOptional = .constant(true)
        layer.textColor = .constant(StyleColor(UIColor(white: 0.85, alpha: 1)))
        layer.textHaloColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.85)))
        layer.textHaloWidth = .constant(1.3)
        layer.filter = filter
        layer.minZoom = minZoom
        return layer
    }

    // MARK: - Where you are

    /// Install the location puck over everything the map draws.
    ///
    /// Two things, and both are about the same complaint.
    ///
    /// **Position.** A style load destroys every layer and the puck's with it,
    /// and the SDK puts it back wherever it happens to land — which, since this
    /// adds its own layers *after* the style finishes loading, was underneath
    /// all of them. Standing on a platform at Bern, the one marker on the
    /// screen that answers "where am I" was behind the rails, the platform
    /// slabs and any train that happened to be alongside. `layerPosition` fixes
    /// that, and it is re-applied here on every style load because that is
    /// exactly when it is lost.
    ///
    /// **Appearance.** The SDK's default is a blue disc with a small arrowhead
    /// stuck on one side of it, which on a dark basemap full of coloured
    /// vehicles reads as one more vehicle. Every other map on this phone draws
    /// the same thing the same way, so this draws it that way too: a blue dot
    /// in a white ring with a soft shadow, and a translucent cone fanning out
    /// the way you are facing. It is not decoration — the cone is the only part
    /// of a location marker that says which way you are looking, which on a
    /// platform is the difference between the train on your left and the one
    /// behind you.
    private func installPuck(topmost: String) {
        guard let mapView else { return }
        // Cleared first, and that is not tidiness.
        //
        // The SDK re-reads `layerPosition` only where it *adds* the puck's
        // layer, and moves an existing one only when the position has actually
        // changed — see `Puck2DRenderer.updateLayer`. Handing it the same
        // `.above(…)` it already holds is therefore a no-op, and a puck that is
        // already on the map stays exactly where it is: underneath every layer
        // installed since, which is all of them. That is what left the bold
        // overlay drawn across the blue dot until a basemap change — which
        // destroys the layer, so the position is read again — put it back on
        // top. Clearing the type first makes every install look like the first
        // one, so the position is applied every time rather than once.
        mapView.location.options.puckType = nil
        mapView.location.options.puckType = .puck2D(Puck2DConfiguration(
            topImage: Puck.dot,
            bearingImage: Puck.cone,
            shadowImage: Puck.shadow,
            showsAccuracyRing: false,
            opacity: 1,
            layerPosition: .above(topmost)
        ))
    }

    /// Forget what is on the map, because none of it is any more.
    ///
    /// Several layers are only rebuilt when the thing they draw has changed —
    /// the rails are thousands of features that do not move, the plates are a
    /// decluttering pass nobody wants run fifteen times a second. Those memos
    /// are about the *sources*, and loading a style destroys every source and
    /// builds them again empty. Left standing, they say the map already holds
    /// what it now holds nothing of, and the next frame changes nothing: the
    /// report was that switching the basemap left the railway overlay blank
    /// until something happened to move.
    ///
    /// So the memos are cleared exactly where the sources are recreated, which
    /// is the only place that can be wrong about them.
    private func forgetWhatWasDrawn() {
        drawn3D = nil
        appliedSolidity = -1
        appliedBaked = nil
        lampsLit = false
        // The meshes belong to the style, and this one has never heard of them.
        modelStore.styleChanged()
        model.bakedModels = false
        drawnTrackCount = -1
        drawnTrackOpacity = -1
        drawnHighContrast = nil
        drawnRouteRevision = -1
        drawnPlateRevision = -1
        drawnShapesVisible = nil
        drewVehicleShapes = false
        drawnFrameVersion = -1
        drawnStopsVersion = -1
        drawnHitboxes = nil
        drawnTunnelFades = nil
        // A new style has the layers' own filters back, so nothing is hidden.
        mergedAway = []
        highlightedPlatform = nil
        highlightedStation = nil
        highlightedShape = nil
    }

    // MARK: - Stops and platforms

    /// The three bands a stop dot is drawn in.
    ///
    /// A railway station is worth a dot from the moment the map is readable at
    /// all. A local stop is not, until the map is close enough that it is
    /// information rather than noise — and once the kerbs themselves are drawn,
    /// a stop that *has* kerbs should hand over to them rather than sit on top
    /// of them. The third band exists because a third of the country's stops
    /// have no kerbs in the register: there is nothing to hand over to, so their
    /// dot stays, and without it they would vanish at exactly the zoom you went
    /// in to look at one.
    private enum StationBand: CaseIterable {
        case rail, localWithKerbs, localOnly

        var layerId: String {
            switch self {
            case .rail: return "transit-stops-rail"
            case .localWithKerbs: return "transit-stops-local"
            case .localOnly: return "transit-stops-local-only"
            }
        }

        var filter: Exp {
            switch self {
            case .rail:
                return Exp(.get) { "rail" }
            case .localWithKerbs:
                return Exp(.all) {
                    Exp(.not) { Exp(.get) { "rail" } }
                    Exp(.get) { "kerbs" }
                }
            case .localOnly:
                return Exp(.all) {
                    Exp(.not) { Exp(.get) { "rail" } }
                    Exp(.not) { Exp(.get) { "kerbs" } }
                }
            }
        }

        /// The same numbers `StopPlace.dotDrawn(at:)` answers from, so what can
        /// be tapped is exactly what can be seen.
        var minZoom: Double {
            switch self {
            case .rail: return StopPlace.Dot.railMinZoom
            case .localWithKerbs, .localOnly: return StopPlace.Dot.localMinZoom
            }
        }

        var maxZoom: Double? {
            self == .localWithKerbs ? MapCoordinator.plateMinZoom : nil
        }
    }

    private enum Chip {
        static let plate = "platform-plate"
        static let plateActive = "platform-plate-active"
        static let pole = "platform-pole"
        static let poleActive = "platform-pole-active"
    }

    /// A stretchable rounded rectangle, used as the plate behind a code.
    ///
    /// Infrastructure has to look nothing like a vehicle. Every moving thing on
    /// this map is a circle, so a stop drawn as a circle reads as traffic. A
    /// boxed label is unmistakably a sign — it is the shape a platform indicator
    /// has in the real world — and it carries the code that answers the question
    /// being asked.
    ///
    /// The stretch bands let one small bitmap size itself to whatever text sits
    /// inside, so "E" and "13A-C" both get a tight plate with square corners.
    private func chipImage(fill: UIColor, stroke: UIColor) -> UIImage {
        let side = 24.0
        let radius = 7.0
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { context in
                let rect = CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
                fill.setFill()
                path.fill()
                stroke.setStroke()
                path.lineWidth = 1.6
                path.stroke()
                _ = context
            }
    }

    private func installChipImages(_ style: MapboxMap) {
        // In image pixels, and the image is drawn at scale 2 — so these are the
        // 24-point geometry above, doubled. Only the middle band stretches, so
        // the corners keep their radius however wide the code is.
        let stretch = [ImageStretches(first: 20, second: 28)]
        let content = ImageContent(left: 12, top: 10, right: 36, bottom: 38)

        let chips: [(String, UIColor, UIColor)] = [
            (Chip.plate,
             UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 0.92),
             UIColor(red: 0.75, green: 0.78, blue: 0.84, alpha: 0.85)),
            (Chip.plateActive,
             UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 0.22),
             UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0)),
            // A stop with no code gets its own marker rather than a shrunk
            // plate. The plate is near-black by design — it is a background for
            // pale text — and shrunk to a few points on a dark basemap it is
            // invisible. Pale fill, dark outline: legible on its own terms.
            (Chip.pole,
             UIColor(red: 0.81, green: 0.84, blue: 0.89, alpha: 0.92),
             UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 0.9)),
            (Chip.poleActive,
             UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0),
             UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 0.9)),
        ]

        for (id, fill, stroke) in chips {
            try? style.addImage(
                chipImage(fill: fill, stroke: stroke), id: id,
                stretchX: stretch, stretchY: stretch, content: content
            )
        }
    }

    private func installPlatformLayers(_ style: MapboxMap) throws {
        // The tether from a plate that had to be nudged aside back to the kerb
        // it belongs to. Drawn first, so it passes under every plate including
        // its own. Without it a moved plate is a quiet lie about position, and
        // being exact about position is the whole reason for drawing platforms
        // rather than stations.
        var leaders = LineLayer(id: ID.leaders, source: ID.leaders)
        leaders.lineColor = .constant(StyleColor(UIColor(red: 0.75, green: 0.78, blue: 0.84, alpha: 0.55)))
        leaders.lineWidth = .constant(1)
        leaders.lineCap = .constant(.round)
        leaders.minZoom = Self.plateMinZoom
        try addLayer(leaders, to: style)

        try addLayer(poleLayer(id: "\(ID.platforms)-pole", image: Chip.pole, selectedOnly: false), to: style)
        try addLayer(plateLayer(id: "\(ID.platforms)-plate", image: Chip.plate, highlighted: false), to: style)

        // Selection is the same marker in the highlight colour, drawn over the
        // top and filtered to one feature. A ring would be wrong twice over: it
        // is the shape of a vehicle, which is exactly what a platform must not
        // look like, and being separate geometry it would still draw when the
        // plate under it had been decluttered elsewhere — a hoop hanging over a
        // building with nothing in it.
        try addLayer(poleLayer(id: "\(ID.platforms)-pole-selected", image: Chip.poleActive, selectedOnly: true), to: style)
        try addLayer(plateLayer(id: "\(ID.platforms)-plate-selected", image: Chip.plateActive, highlighted: true), to: style)
    }

    /// A kerb with nothing to label: a small marker that says only *here*.
    private func poleLayer(id: String, image: String, selectedOnly: Bool) -> SymbolLayer {
        var layer = SymbolLayer(id: id, source: ID.platforms)
        layer.iconImage = .constant(.name(image))
        layer.iconSize = .constant(0.34)
        layer.iconAllowOverlap = .constant(true)
        layer.iconIgnorePlacement = .constant(true)
        layer.iconPadding = .constant(1)
        layer.minZoom = Self.plateMinZoom
        let codeless = Exp(.not) { Exp(.has) { "code" } }
        layer.filter = selectedOnly
            ? Exp(.all) { codeless; Exp(.eq) { Exp(.get) { "id" }; "__none__" } }
            : codeless
        return layer
    }

    /// The plate, sized to the code written on it.
    private func plateLayer(id: String, image: String, highlighted: Bool) -> SymbolLayer {
        var layer = SymbolLayer(id: id, source: ID.platforms)
        layer.iconImage = .constant(.name(image))
        layer.iconTextFit = .constant(.both)
        layer.iconTextFitPadding = .constant([2, 5, 2, 5])
        // Every plate is drawn, always. Left to the renderer's collision
        // detection, an overlap is resolved by *deleting* one of the two
        // labels — which at a forecourt with a dozen bays silently removes most
        // of them. A hidden platform is not a tidier map, it is a wrong one: the
        // bay is there and the map says it is not. The overlap is resolved by
        // moving instead, in `PlatformLayout`, and the plates are then placed
        // unconditionally.
        layer.iconAllowOverlap = .constant(true)
        layer.iconIgnorePlacement = .constant(highlighted)
        // The code alone: at this zoom the stop's name is already on the map and
        // what is missing is which of its platforms this one is.
        layer.textField = .expression(Exp(.get) { "code" })
        layer.textSize = .expression(
            Exp(.interpolate) { Exp(.linear); Exp(.zoom); 15; 9.5; 18; 12.0 }
        )
        layer.textAllowOverlap = .constant(true)
        layer.textIgnorePlacement = .constant(highlighted)
        // A letter this map assigned is drawn dimmer than a code somebody has
        // signposted. Both are useful; only one of them is a fact about the
        // world, and the map should not present the two as the same thing. The
        // panel says so in words when you tap.
        layer.textColor = .expression(
            Exp(.switchCase) {
                Exp(.get) { "assigned" }
                highlighted ? "rgba(255,214,10,0.72)" : "rgba(230,235,242,0.62)"
                highlighted ? "#ffd60a" : "#e6ebf2"
            }
        )
        layer.iconOpacity = .expression(
            Exp(.switchCase) { Exp(.get) { "assigned" }; 0.78; 1.0 }
        )
        layer.minZoom = Self.plateMinZoom
        let coded = Exp(.has) { "code" }
        layer.filter = highlighted
            ? Exp(.all) { coded; Exp(.eq) { Exp(.get) { "id" }; "__none__" } }
            : coded
        return layer
    }

    /// Point the highlight layers at whatever is selected.
    ///
    /// Filters rather than a separate marker: a highlight that is its own
    /// geometry can outlive the thing it highlights — the plate decluttered
    /// somewhere else, the dot handed over to the kerbs at zoom 16 — and hang
    /// over the map with nothing inside it. Filtering the *same* layer cannot
    /// produce one: if there is a highlight, there is a marker under it.
    private var highlightedPlatform: String?
    private var highlightedStation: String?
    private var highlightedShape: String?

    private func applyHighlights() {
        guard let mapView, styleReady else { return }
        let style: MapboxMap = mapView.mapboxMap

        let platform = selectedPlatformId ?? "__none__"
        let station = selectedStationId ?? "__none__"
        let shape = selectedShapeId
        if shape != highlightedShape {
            highlightedShape = shape
            RailwayShapes.highlight(style, shape: shape)
        }
        guard platform != highlightedPlatform || station != highlightedStation else { return }
        highlightedPlatform = platform
        highlightedStation = station

        try? style.updateLayer(withId: "\(ID.platforms)-plate-selected", type: SymbolLayer.self) {
            $0.filter = Exp(.all) { Exp(.has) { "code" }; Exp(.eq) { Exp(.get) { "id" }; platform } }
        }
        try? style.updateLayer(withId: "\(ID.platforms)-pole-selected", type: SymbolLayer.self) {
            $0.filter = Exp(.all) {
                Exp(.not) { Exp(.has) { "code" } }
                Exp(.eq) { Exp(.get) { "id" }; platform }
            }
        }
        try? style.updateLayer(withId: "\(ID.stops)-selected", type: CircleLayer.self) {
            $0.filter = Exp(.eq) { Exp(.get) { "id" }; station }
        }
    }

    private var selectedPlatformId: String? {
        if case let .platform(board) = model.selection { return board.id }
        return nil
    }

    private var selectedStationId: String? {
        if case let .station(board) = model.selection { return board.id }
        return nil
    }

    /// The drawn footprint a platform board was opened from, if it was opened
    /// from one. A board reached by tapping a plate has none, and outlining a
    /// shape then would light up something the user did not point at.
    private var selectedShapeId: String? {
        if case let .platform(board) = model.selection { return board.shape }
        return nil
    }

    // MARK: - Drawing

    func draw() {
        guard styleReady, let mapView else { return }
        // Here rather than at style load: the model reads its launch arguments
        // in a task that may not have run when the style finished, so asking
        // once at load lost the race about half the time.
        applyDebugStartIfAny()
        let style: MapboxMap = mapView.mapboxMap

        drawVehicles(style)
        drawStops(style)
        drawPlatforms(style)
        drawTracks(style)
        drawRoute(style)
        drawRailwayShapes(style)
        apply3D(style)
        applyLightPreset(style)
        // Solidity is normally driven off camera movement, which is where it
        // belongs. This catches the case where nothing moved and it changed
        // anyway: somebody turned the solid vehicles off while the map sat
        // still. Guarded inside, so a frame that changes nothing writes nothing.
        applySolidity()
        applyHighlights()
    }

    /// Which tick's fleet is currently in the sources, and which set of stops.
    ///
    /// `draw()` has two callers and they do not know about each other. One is
    /// the model's tick, which is the frame; the other is `updateUIView`, which
    /// SwiftUI runs whenever it thinks this view needs updating — and since
    /// `draw()` reads the model, SwiftUI *made itself* run it again on every
    /// write the tick performed. Every tick therefore rebuilt and re-uploaded
    /// every vehicle feature, every footprint polygon and every extrusion slab
    /// twice, at thirty ticks a second, which is where the choppiness came
    /// from: the tick loop kept its rate and the renderer never got a clear
    /// run at the data it was being handed.
    ///
    /// The versions are the fix and they are also cheap in the way that
    /// matters: `AppModel` keeps them out of observation, so asking "is this
    /// new?" from inside `updateUIView` does not register a dependency on the
    /// answer and cannot schedule the next update.
    private var drawnFrameVersion = -1
    private var drawnStopsVersion = -1
    /// Whether anything in each lane is part-way into a tunnel, and what the
    /// style was last told about it. See `VehicleModels.setTunnelFades`.
    private var fadingMainLane = false
    private var fadingFollowLane = false
    private var drawnTunnelFades: Bool?

    /// Whether the wagon hitbox layers are currently shown. Nil for a style
    /// that has just been built and has never been told.
    private var drawnHitboxes: Bool?

    /// The fleet: the dots, and the drawn bodies behind them.
    private func drawVehicles(_ style: MapboxMap) {
        guard model.frameVersion != drawnFrameVersion else { return }
        drawnFrameVersion = model.frameVersion

        let selectedId: String? = {
            if case let .vehicle(id) = model.selection { return id }
            return nil
        }()

        // How far each vehicle has turned into a drawn vehicle, so its dot can
        // get out of the way by exactly that much. Absent means still a dot.
        var emergence: [String: Double] = [:]
        emergence.reserveCapacity(model.vehicleShapes.count)
        for shape in model.vehicleShapes { emergence[shape.id] = shape.emergence }

        // The followed vehicle is written where the follow lane has it, not
        // where the last tick left it. See `followShift`.
        let shift = followId != nil ? followShift() : (lon: 0.0, lat: 0.0)
        let vehicleFeatures = model.vehicles.map { vehicle -> Feature in
            let moved = vehicle.id == followId
            let at = Coord(
                lon: vehicle.lon + (moved ? shift.lon : 0),
                lat: vehicle.lat + (moved ? shift.lat : 0)
            )
            return Self.vehicleFeature(
                vehicle, at: at,
                selected: vehicle.id == selectedId, emerged: emergence[vehicle.id] ?? 0,
                tunnel: tunnelIndex.fade(at: at, heading: vehicle.bearing)
            )
        }
        style.updateGeoJSONSource(
            withId: ID.vehicles, geoJSON: .featureCollection(FeatureCollection(features: vehicleFeatures))
        )
        drawVehicleShapes(style)
        #if DEBUG
        Diagnostics.pushed(vehicles: vehicleFeatures.count, tracks: model.tracks.count, styleReady: styleReady)
        #endif
    }

    /// The stop dots, rebuilt only when the set of them has changed.
    ///
    /// Up to fifteen hundred features, and the model already goes to the
    /// trouble of not writing them unless they differ — see the guard on
    /// `stops` in `AppModel.tick`. Without the same guard here that care bought
    /// nothing: the whole collection was rebuilt from scratch and handed to the
    /// renderer on every draw, for a set of points that changes when the camera
    /// crosses a zoom band or pans onto new ground and at no other time.
    private func drawStops(_ style: MapboxMap) {
        guard model.stopsVersion != drawnStopsVersion else { return }
        drawnStopsVersion = model.stopsVersion

        let stopFeatures = model.stops.map { stop -> Feature in
            var feature = Feature(geometry: .point(Point(
                CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
            )))
            feature.properties = [
                "id": .string(stop.id),
                "rail": .boolean(stop.rail),
                "name": .string(stop.name),
                // Whether this stop has kerbs of its own to hand over to at
                // zoom 16. A third of the country's stops have none, and their
                // dot has to stay or they vanish at exactly the zoom you went in
                // to look at one.
                "kerbs": .boolean(stop.kerbs > 0),
            ]
            return feature
        }
        style.updateGeoJSONSource(
            withId: ID.stops, geoJSON: .featureCollection(FeatureCollection(features: stopFeatures))
        )
    }

    /// Whether the vehicle shape source currently holds anything, so a map that
    /// has zoomed back out is emptied once rather than re-emptied every frame.
    private var drewVehicleShapes = false

    private func drawVehicleShapes(_ style: MapboxMap) {
        let shapes = model.vehicleShapes
        guard !shapes.isEmpty else {
            if !model.standingVehicles.isEmpty { model.standingVehicles = [] }
            guard drewVehicleShapes else { return }
            drewVehicleShapes = false
            style.updateGeoJSONSource(
                withId: VehicleShapes.source,
                geoJSON: .featureCollection(FeatureCollection(features: []))
            )
            return
        }
        drewVehicleShapes = true
        // How much of the flat drawing is left, which is the other half of the
        // solid's opacity. The two are the same picture at two attitudes, so
        // they hand over rather than stack: a fully solid train with its own
        // footprint still painted underneath it is a train with a shadow that
        // does not move, and one lying half in the ground.
        //
        // Read off the model rather than off `appliedSolidity`, because this
        // runs on the model's tick and the alpha is baked into the features it
        // builds. A step of a fiftieth per half-degree of pitch is finer than
        // the fade the eye is following on the layer above it.
        // Full strength until the solids actually arrive, then the shadow.
        // A switch rather than a ramp, for the same reason the solids are one:
        // while the flat drawing is what the reader is reading it should be the
        // whole drawing, and the moment it stops being that it becomes the
        // thing that says where a vehicle is when the solid cannot. Nothing in
        // between is a state worth rendering.
        // Not faded by the tilt at all, and that is the point of it.
        //
        // The flat drawing used to dim as the solids rose, on the reasoning
        // that the two are one picture at two attitudes. They are not: the
        // solid is a thing standing in the scene and a building in front of it
        // hides it, while the flat drawing is painted on the ground with a copy
        // of itself left up at `top` at half strength — see
        // `VehicleShapes.ghostOpacity` and `Terrain3D.placeOverlay`. That copy
        // is the only thing on a tilted map that says where a train behind a
        // block of flats is, and dimming it to a quarter of its colour over a
        // night basemap is dimming it to nothing. In the open it costs nothing
        // to leave at full strength: the solid stands on its own footprint and
        // covers it exactly.
        let flatness = 1.0
        style.updateGeoJSONSource(
            withId: VehicleShapes.source,
            geoJSON: .featureCollection(FeatureCollection(
                features: vehicleDrawing(
                    shapes, excluding: followedVehicleId, flatness: flatness,
                    follow: false
                )
            ))
        )
    }

    /// The whole of every drawn vehicle: footprint, solid and lamps.
    ///
    /// One collection into one source, and it has to be. Written to three
    /// sources in a row, the three drawings of a single vehicle went through
    /// the SDK's serial GeoJSON queue independently and landed on up to three
    /// different frames — which at line speed is most of a metre apiece, and
    /// which looked like head lamps trailing along behind the nose that was
    /// supposed to be carrying them. There is nothing to synchronise now
    /// because there is nothing separate left to synchronise.
    ///
    /// Order is the flat drawing, then the solid, then the lamps, and only the
    /// first of those depends on it: a fill layer paints its features in source
    /// order, so a roof has to follow the body it sits on. The extrusions and
    /// the lamps are both depth-tested rather than painted, and neither cares
    /// where in the list it appears.
    private func vehicleDrawing(
        _ shapes: [VehicleFootprint], excluding excluded: String?, flatness: Double,
        follow: Bool
    ) -> [Feature] {
        // Only when it has changed. This is a debug switch that moves about
        // once a session, and `setHitboxes` is six `layerExists` and six
        // `setLayerProperty` calls — twelve hops into the renderer, each one
        // marking a layer dirty and asking for it to be validated again.
        // Unguarded it ran on every model tick *and* on every display refresh
        // of the follow lane, which on a 120 Hz screen is fourteen hundred
        // style writes a second to say nothing has changed.
        if model.showWagonHitboxes != drawnHitboxes, let style = mapView?.mapboxMap {
            drawnHitboxes = model.showWagonHitboxes
            VehicleModels.setHitboxes(style, model.showWagonHitboxes)
        }
        // The solids first, though they are added second. Which vehicles are
        // standing up is not knowable until they have been built — a wagon
        // whose mesh is still being baked is not one of them — and it is what
        // the flat drawing has to be told, so that a train standing on the
        // ground is not also painted flat on it. See `VehicleShapes.Key.stood`.
        var solids: [Feature] = []
        var stood: Set<String> = []
        var buried: [String: Double] = [:]
        var resting: [String: VehicleModels.Rest] = [:]
        var wagonLifts: [String: [Double]] = [:]
        var wagonOpacities: [String: [Double]] = [:]
        if let style = mapView?.mapboxMap, model.solidVehicles {
            // One point per wagon, naming a mesh the style already holds. The
            // meshes for anything new on screen are registered here, a few per
            // tick — see `VehicleModelStore.names`.
            let names = modelStore.names(
                for: shapes.flatMap(\.placements), in: style
            )
            refreshTunnels()
            // How each wagon lies on the ground under it, kept from frame to
            // frame so a lookup that comes back empty leaves a wagon at the
            // angle it was at rather than flattening it. See `rest`.
            resting = rest(shapes, relief: model.terrain3D, measure: !follow, style)
            if !follow { probeRest(shapes, resting, style) }
            // A clock per lane. The two run at different rates — the model's
            // tick and the display's refresh — and sharing one meant whichever
            // called last reset it for the other, so while a vehicle was being
            // followed the main lane read a `dt` of a refresh instead of a tick
            // and every tunnel fade on the map eased at a quarter speed.
            let now = Date()
            let dt = min(0.1, now.timeIntervalSince(follow ? followFadeClock : fadeClock))
            if follow { followFadeClock = now } else { fadeClock = now }
            let placed = VehicleModels.placements(
                shapes, excluding: excluded, names: names, resting: resting,
                tunnels: tunnelIndex, ghostTunnels: model.ghostTunnels,
                yaws: &yaws, fades: &fades, dt: dt
            )
            solids = placed.features
            wagonLifts = placed.lifts
            wagonOpacities = placed.opacities
            for print in shapes {
                if wagonOpacities[print.id] == nil {
                    wagonOpacities[print.id] = model.ghostTunnels
                        ? Self.tunnelOpacities(print, index: tunnelIndex)
                        : [Double](repeating: 1, count: max(1, print.placements.count))
                }
                let hidden = (wagonOpacities[print.id] ?? []).contains { $0 < 0.5 }
                if hidden { buried[print.id] = 1 }
            }
            // The part-way tunnel bands, only while something is part-way.
            //
            // Per lane, and both lanes counted, because each writes its own
            // source and each sees only its own vehicles: the follow lane is
            // handed one train and the main lane everything but that train, so
            // either one alone would turn the bands off for the other. See
            // `VehicleModels.setTunnelFades`, which explains what they cost.
            let fading = wagonOpacities.values.contains { wagon in
                wagon.contains { $0 < 0.8 }
            }
            if follow { fadingFollowLane = fading } else { fadingMainLane = fading }
            let anyFading = fadingMainLane || fadingFollowLane
            if anyFading != drawnTunnelFades {
                drawnTunnelFades = anyFading
                VehicleModels.setTunnelFades(style, anyFading)
            }
            // Only where the solid is actually being painted. The models are
            // built a little before the camera has tilted far enough to show
            // them — see `applySolidity`, which switches rather than fades —
            // and a vehicle whose flat drawing stepped aside for a solid that
            // is not being drawn yet is a vehicle that has gone missing.
            if showingSolids, model.bakedModels { stood = placed.stood }
            if let working = modelStore.working, model.bakedModels != working {
                model.bakedModels = working
                applySolidity()
            }
        }
        // Told back to the model, so the next tick does not build the trim of a
        // vehicle standing up as a mesh — every polygon of it is dropped just
        // below. Outside the block above rather than inside it, so switching
        // the solids off restates an empty set instead of leaving the last one
        // standing and every vehicle drawn as a bare body from then on. The
        // follow lane is handed one vehicle and sees only that one, so it must
        // not restate the whole set. See `AppModel.standingVehicles`.
        if !follow, model.standingVehicles != stood { model.standingVehicles = stood }

        var features = VehicleShapes.features(
            shapes, excluding: excluded, flatness: flatness, stood: stood,
            lifts: wagonLifts, opacities: wagonOpacities
        )
        features += solids
        // The prisms, which are still built and still drawn on any renderer
        // that would not take the models. Empty otherwise: `AppModel` stops
        // building the geometry at all once the models are known to work.
        features += VehicleModels.features(shapes, excluding: excluded)
        // Only where there is a third dimension for them to sit in. The lamps
        // are hidden on a flat map, so building them there is work for nothing
        // — and it is four features a vehicle on a source that is rewritten
        // fifteen times a second.
        if lampsLit {
            // Against the camera as well as against the vehicle: which of a
            // vehicle's four lamps are pointing at the reader is a function of
            // where the camera is standing. See `VehicleLamps.features`.
            let camera = mapView?.mapboxMap.cameraState
            features += VehicleLamps.features(
                shapes, excluding: excluded,
                viewBearing: camera?.bearing ?? 0,
                buried: buried
            )
        }
        if model.showWagonHitboxes {
            features += VehicleModels.hitboxes(
                shapes, excluding: excluded, resting: resting
            )
        }
        return features
    }

    /// TEMPORARY — a line per frame about how the first vehicle on screen is
    /// lying, for `-debugRest 1`. Remove before finishing.
    private func probeRest(
        _ shapes: [VehicleFootprint], _ resting: [String: VehicleModels.Rest],
        _ style: MapboxMap
    ) {
        guard UserDefaults.standard.bool(forKey: "debugRest") else { return }
        var pick: (VehicleFootprint, VehicleModels.Rest)?
        var best = -1.0
        for shape in shapes {
            guard let seen = resting[shape.id] else { continue }
            let peak = seen.grades.map { abs($0) }.max() ?? 0
            if peak > best { best = peak; pick = (shape, seen) }
        }
        guard let (first, seen) = pick else { return }
        let camera = style.cameraState
        let grades = seen.grades.map { String(format: "%.1f", $0) }.joined(separator: ",")
        let lifts = seen.lifts.map { String(format: "%.1f", $0) }.joined(separator: ",")
        var ground: [String] = []
        for p in first.placements {
            let h = style.elevation(at: CLLocationCoordinate2D(
                latitude: p.at.lat, longitude: p.at.lon
            ))
            ground.append(h.map { String(format: "%.0f", $0) } ?? "-")
        }
        print("[rest] \(first.id) n=\(first.placements.count)"
            + " zoom=\(String(format: "%.2f", camera.zoom))"
            + " pitch=\(String(format: "%.0f", camera.pitch))"
            + " grades=[\(grades)] lifts=[\(lifts)]"
            + " ground=[\(ground.joined(separator: ","))]")
    }

    /// The bores near the camera.
    ///
    /// Rebuilt only when the model has fetched a different set — which happens
    /// when the viewport moves far enough, not when the map moves — because
    /// building the index walks every vertex of every tunnel in view and the
    /// tunnels are the one thing on this map that never move.
    private var tunnelIndex = TunnelIndex([])
    private var tunnelMark = -1

    private func refreshTunnels() {
        if model.tunnelRevision != tunnelMark {
            tunnelMark = model.tunnelRevision
            tunnelIndex = TunnelIndex(model.tunnels)
        }
    }

    /// How much of each wagon is still drawn, 1 in the open, 0 in a tunnel.
    private static func tunnelOpacities(
        _ print: VehicleFootprint, index: TunnelIndex
    ) -> [Double] {
        if print.placements.isEmpty {
            let head = print.centreline.first ?? Coord(lon: 0, lat: 0)
            return [index.onTrack(head) == nil ? 1 : 0]
        }
        return print.placements.map {
            index.onTrack(
                print.rails(at: $0.alongTrain), heading: $0.heading
            ) == nil ? 1 : 0
        }
    }

    /// The ground under each vehicle, as last measured.
    ///
    /// `elevation(at:)` answers only for ground the renderer is currently
    /// holding, and a fifth of the asks come back empty on a map that is still
    /// filling in — tiles in flight, a vehicle at the edge of the screen. An
    /// empty answer taken as zero is one coach laid flat at sea level while the
    /// fifteen around it stay on the hill, which is worse than a tilt being a
    /// frame out of date. Keeping the last good sample means a missing one
    /// leaves that coach lying the way it was lying, and the ground under a
    /// coach at line speed does not change between frames by anything anyone
    /// can see.
    private struct Seat {
        var rest: VehicleModels.Rest
        /// Every height measured along this vehicle, in the order `rest` walks
        /// them: nose, middle and tail of each wagon in turn, with a coupling
        /// counted once. `.nan` where nobody has ever known.
        var ground: [Double]
    }

    private var seats: [String: Seat] = [:]
    /// Last unwrapped heading of each wagon, keyed by vehicle id. See
    /// `VehicleModels.placements`.
    private var yaws: [String: [Double]] = [:]
    /// Displayed tunnel opacity of each wagon, easing toward 0 or 1 over
    /// half a second. See `VehicleModels.placements`.
    private var fades: [String: [Double]] = [:]
    private var fadeClock = Date()
    /// The same, for the follow lane, which steps on its own rate. See
    /// `vehicleDrawing`.
    private var followFadeClock = Date()

    /// How each wagon lies on the ground under it.
    ///
    /// **Each wagon takes the angle of the ground it is standing on.** The
    /// ground is measured under a wagon's nose, its middle and its tail; the
    /// slope through those is the angle it is turned by; and the renderer has
    /// already stood it at the height of the ground under its own middle. So a
    /// train on a ramp climbs, a train over a summit bends across it, and
    /// nothing is ever lifted into the air to meet a line fitted somewhere
    /// else.
    ///
    /// **What this replaced.** The train used to be fitted as one beam: a
    /// single least-squares gradient down the whole rake, clamped at twelve
    /// degrees, with every wagon lifted off the ground to meet it. Where the
    /// drawn hillside was steeper than the clamp — a rack railway, or any
    /// alpine ledge with the relief dial past one — the beam could not follow
    /// the ground, and everything it could not express came out as lift
    /// instead, because it was seated on its *highest* sample: the leading
    /// coach on the rails and the rest of the train hanging level in the air
    /// behind it, up to a thirty-metre clamp, over a track climbing away
    /// underneath.
    ///
    /// **The slope is this wagon's own, not a window a wagon either side.** A
    /// fit that reached the coaches in front and behind averaged a small hill
    /// into nothing: the DEM under a gentle mound is a metre or two, the
    /// neighbours are on the flat, and the line through all of them is level
    /// — so the rake stood as a staircase of boxes stepping up a hill it
    /// refused to tilt into. A wagon is a rigid box on two bogies; the ground
    /// that turns it is the ground under *its* nose and tail. Bad cells still
    /// happen (a cutting beside the line, a station roof) and those are
    /// thrown away as outliers, but only when there are enough samples left
    /// to fit without them.
    ///
    /// **The lift is what keeps a nose out of the ground.** A wagon is turned
    /// about its middle, and the renderer has stood that middle on the ground;
    /// where the fitted line runs below the measured ground at either end — a
    /// dip a wagon spans, a crest it is climbing over — the wagon is raised
    /// until nothing of it is under the surface. It is nearly always nothing
    /// and never more than a few metres.
    ///
    /// **Against the drawn ground, not the real one.** `elevation(at:)` returns
    /// metres already multiplied by the terrain exaggeration, which is what is
    /// wanted: the train has to lie on the slope the reader can see, and at an
    /// exaggeration of two that is twice the slope the railway has.
    /// **`measure: false` reuses the last measurement rather than taking a
    /// new one.** `elevation(at:)` is a hop into the renderer for a number it
    /// has to look up in the terrain it is currently holding, and this asks for
    /// two per wagon plus one — thirty-odd for an intercity. That is the right
    /// price to pay once per model tick and quite the wrong one to pay per
    /// display refresh, which is what the follow lane was doing: sixty or a
    /// hundred and twenty times a second, on the main thread, in front of the
    /// renderer that is trying to draw the frame.
    ///
    /// And it buys nothing. Between two refreshes a train at line speed moves
    /// about a centimetre; between two model ticks, a metre. The ground under a
    /// twenty-five-metre wagon does not change slope over a metre by anything
    /// that can be drawn, which is the same reasoning `Seat` is already built
    /// on — it exists so that a lookup which comes back empty leaves a wagon
    /// where it was rather than flattening it. This says the measurement is
    /// good for a tick as well as for a missing sample.
    private func rest(
        _ shapes: [VehicleFootprint], relief: Bool, measure: Bool, _ style: MapboxMap
    ) -> [String: VehicleModels.Rest] {
        var out: [String: VehicleModels.Rest] = [:]
        var kept: [String: Seat] = [:]
        out.reserveCapacity(shapes.count)
        kept.reserveCapacity(shapes.count)

        /// The drawn ground under a point, or nil where the tile for it has not
        /// arrived.
        func height(_ at: Coord) -> Double? {
            known(style.elevation(at: CLLocationCoordinate2D(
                latitude: at.lat, longitude: at.lon
            )))
        }

        /// A height that is actually a height. Both sources of one — the
        /// renderer and the sample held from the last frame — say "no answer"
        /// by handing back something that is not a number, and a `??` chain
        /// takes `.nan` for an answer and puts it in a rotation.
        func known(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return value
        }

        for print in shapes where !print.placements.isEmpty {
            guard relief else {
                // No relief: the ground is flat everywhere, every wagon lies
                // level on it, and no lookup is needed to find that out.
                out[print.id] = VehicleModels.Rest(grades: [], lifts: [])
                continue
            }
            let held = seats[print.id]
            // Good enough, and already in hand. A rake that has been re-formed
            // since — a coach added, a portion detached — has a different
            // number of wagons and is measured again rather than fitted to
            // somebody else's angles.
            if !measure, let held, held.rest.grades.count == print.placements.count {
                out[print.id] = held.rest
                continue
            }

            // Every place the ground is asked about, down the length of the
            // train: three per wagon, less the couplings, where one wagon's
            // tail and the next one's nose are the same point and one lookup.
            var along: [Double] = []
            var ground: [Double] = []
            along.reserveCapacity(print.placements.count * 3)
            ground.reserveCapacity(print.placements.count * 3)
            /// Where each wagon's three samples ended up.
            var spans: [(nose: Int, middle: Int, tail: Int)] = []
            spans.reserveCapacity(print.placements.count)

            func sample(_ at: Coord, _ offset: Double) -> Int {
                let index = along.count
                along.append(offset)
                ground.append(
                    height(at)
                        ?? known(index < (held?.ground.count ?? 0)
                            ? held?.ground[index] : nil)
                        ?? .nan
                )
                return index
            }

            var coupled: (at: Coord, index: Int)?
            for placement in print.placements {
                let half = max(1, placement.length / 2)
                // On the rails, not on the wagon's chord. The chord of a
                // coach on a curve sits several metres inside the track —
                // at Bödelibad, inside the pool the embankment is holding
                // the railway above — and the DEM there is a 13° drop that
                // no coupler could follow. See `VehicleFootprint.rails`.
                let nose = print.rails(at: placement.alongTrain - half)
                let mid = print.rails(at: placement.alongTrain)
                let tail = print.rails(at: placement.alongTrain + half)
                // Head first, so the wagon in front of this one was measured
                // last and its tail is where this one's nose is.
                let front = coupled.flatMap {
                    Geo.metres($0.at, nose) < 1.5 ? $0.index : nil
                } ?? sample(nose, placement.alongTrain - half)
                let middle = sample(mid, placement.alongTrain)
                let back = sample(tail, placement.alongTrain + half)
                coupled = (tail, back)
                spans.append((front, middle, back))
            }

            var grades = [Double](repeating: 0, count: print.placements.count)
            var lifts = [Double](repeating: 0, count: print.placements.count)
            var surfaces = [Double](repeating: .nan, count: print.placements.count)
            /// Which of them the ground actually answered for. A wagon it did
            /// not is not a level wagon; it is a wagon nobody has measured, and
            /// what it does is what its neighbours are doing.
            var measured = [Bool](repeating: false, count: print.placements.count)

            for (index, _) in print.placements.enumerated() {
                let span = spans[index]
                let centre = along[span.middle]
                // This wagon's nose, middle and tail, and nothing of the
                // coaches either side. A window that reached them fitted a
                // hill shorter than the train as flat, and a sample borrowed
                // from the wagon in front is how the front's pitch walked
                // down the rake.
                var used: [Int] = []
                for k in [span.nose, span.middle, span.tail] where ground[k].isFinite {
                    if !used.contains(k) { used.append(k) }
                }
                guard used.count >= 2 else {
                    // Nothing to measure with. Left exactly as it was rather
                    // than flattened — see `Seat` — and filled in from its
                    // neighbours below if it has never been measured at all.
                    if index < (held?.rest.grades.count ?? 0) {
                        grades[index] = held?.rest.grades[index] ?? 0
                        measured[index] = true
                    }
                    if index < (held?.rest.lifts.count ?? 0) {
                        lifts[index] = held?.rest.lifts[index] ?? 0
                    }
                    continue
                }

                var fit = Self.line(through: used, along: along, ground: ground)
                // And again without the sample that agrees least, if there are
                // enough left to fit and it disagrees by more than a wagon
                // could ride over. Three samples (nose, middle, tail) are the
                // hill itself — dropping the middle of a mound flattened it.
                if used.count >= 4 {
                    var worst = used[0]
                    var by = 0.0
                    for k in used {
                        let off = abs(ground[k] - (fit.at + fit.slope * (along[k] - centre)))
                        if off > by { by = off; worst = k }
                    }
                    if by > 3 {
                        used.removeAll { $0 == worst }
                        fit = Self.line(through: used, along: along, ground: ground)
                    }
                }

                let angle = -atan(fit.slope) * 180 / Double.pi
                grades[index] = max(-Self.steepest, min(Self.steepest, angle))
                measured[index] = true
            }

            // An unmeasured wagon takes the angle of the nearest wagon that
            // was measured — a coach at the edge of the screen with no terrain
            // under it yet, or one whose samples all landed in one cell.
            // Neighbours are not averaged together: that was the other half of
            // the lower limit, a real hill under one coach mixed with the
            // flat under the two beside it until nothing remained to tilt into.
            if let anchor = measured.firstIndex(of: true) {
                for index in grades.indices where !measured[index] {
                    var nearest = anchor
                    var by = abs(index - anchor)
                    for other in grades.indices where measured[other] {
                        if abs(index - other) < by { by = abs(index - other); nearest = other }
                    }
                    grades[index] = grades[nearest]
                }
            }

            // Each wagon keeps the angle of the ground under it. A median
            // across neighbours and a 4° step clamp used to copy the head's
            // pitch down the rake a frame at a time — the front tilted, then
            // the next coach, then the rest, which read as one rigid chain
            // and as a staircase. A coupler cannot follow an 18° DEM spike,
            // but that spike is already thrown out per wagon (the sample that
            // disagrees by more than three metres). Coupling the coaches to
            // each other was the larger lie.

            // And where each wagon ends up standing, once its angle is settled.
            // A wagon is turned about its own middle, which the renderer has
            // stood on the ground under that middle; anything of it that comes
            // out under the ground its own ends were measured on is raised out
            // of it. Nearly always nothing — a dip a wagon spans.
            for index in print.placements.indices {
                let span = spans[index]
                guard let seat = known(ground[span.middle]) else { continue }
                surfaces[index] = seat
                let centre = along[span.middle]
                let slope = -tan(grades[index] * Double.pi / 180)
                var sunk = 0.0
                for k in [span.nose, span.tail] where ground[k].isFinite {
                    sunk = max(sunk, ground[k] - (seat + slope * (along[k] - centre)))
                }
                lifts[index] = min(4, max(0, sunk))
            }

            let rest = VehicleModels.Rest(grades: grades, lifts: lifts, surfaces: surfaces)
            out[print.id] = rest
            kept[print.id] = Seat(rest: rest, ground: ground)
        }
        // Merged rather than replaced. The follow lane asks about one vehicle
        // at the display's rate; replacing the table with that one left every
        // other train without a held grade until the next model tick, so a
        // missing elevation sample flattened it for a frame.
        for (id, seat) in kept { seats[id] = seat }
        let live = Set(shapes.map(\.id))
        if live.count > 1 || followedVehicleId == nil || live.first != followedVehicleId {
            seats = seats.filter { live.contains($0.key) }
            yaws = yaws.filter { live.contains($0.key) }
            fades = fades.filter { live.contains($0.key) }
        }
        return out
    }

    /// The least-squares line through some of the samples along a train, as a
    /// height at the middle of the wagon being fitted and a slope about it.
    ///
    /// Centred on that wagon rather than on the head of the train, because the
    /// numbers stay small: `alongTrain` on the last coach of an intercity is
    /// four hundred, and its square is what a fit through half a metre of
    /// relief would otherwise be looking for a difference inside.
    private static func line(
        through used: [Int], along: [Double], ground: [Double]
    ) -> (at: Double, slope: Double) {
        let n = Double(used.count)
        guard n > 1 else {
            return (used.first.map { ground[$0] } ?? 0, 0)
        }
        let centre = used.reduce(0.0) { $0 + along[$1] } / n
        var sxx = 0.0
        var sxy = 0.0
        var sy = 0.0
        for k in used {
            let x = along[k] - centre
            sxx += x * x
            sxy += x * ground[k]
            sy += ground[k]
        }
        // Every sample in one place — a wagon standing still, all three of its
        // asks in one cell — has no slope to give.
        let slope = sxx > 0.25 ? sxy / sxx : 0
        return (sy / n, slope)
    }

    /// Steeper than the drawn ground gets, in degrees.
    ///
    /// Measured against the terrain the reader can see, which is already
    /// multiplied by the exaggeration dial — a 25 ‰ rack at a dial of two is
    /// twenty-eight degrees, and the old clamp of twenty left the train
    /// flatter than the hill. Fifty is past anything the dial can put under
    /// a railway and still a coach rather than a wall.
    private static let steepest = 50.0

    /// Whether the head and tail lamps are on right now.
    ///
    /// Dark *and* tilted. See `VehicleLamps.setVisible`, which explains both;
    /// this is the same answer kept where the feature builder can reach it, so
    /// a frame that is not going to draw them does not build them either.
    private var lampsLit = false

    /// Show or hide OpenRailwayMap's shapes, when the setting has changed.
    private var drawnShapesVisible: Bool?

    private func drawRailwayShapes(_ style: MapboxMap) {
        guard model.showRailwayShapes != drawnShapesVisible else { return }
        drawnShapesVisible = model.showRailwayShapes
        RailwayShapes.setVisible(style, model.showRailwayShapes)
    }

    /// The plates, and the tethers back to the kerbs that moved.
    ///
    /// Rebuilt only when the layout has actually changed. The decluttering is a
    /// few hundred boxes against a grid, which is cheap but not free, and the
    /// answer does not change between frames on a map nobody is touching.
    private var drawnPlateRevision = -1

    private func drawPlatforms(_ style: MapboxMap) {
        guard model.plateRevision != drawnPlateRevision else { return }
        drawnPlateRevision = model.plateRevision

        let features = model.plates.map { plate -> Feature in
            var feature = Feature(geometry: .point(Point(
                CLLocationCoordinate2D(latitude: plate.lat, longitude: plate.lon)
            )))
            var properties: JSONObject = [
                "id": .string(plate.stop.id),
                "name": .string(plate.stop.name),
            ]
            // No `code` key at all rather than an empty one: the layers split on
            // whether the property *exists*, and an empty string would draw a
            // plate with nothing written in it — the phantom box you could tap
            // but never read.
            if let code = plate.code, !code.isEmpty {
                properties["code"] = .string(code)
                properties["assigned"] = .boolean(plate.isAssigned)
            }
            feature.properties = properties
            return feature
        }
        style.updateGeoJSONSource(
            withId: ID.platforms, geoJSON: .featureCollection(FeatureCollection(features: features))
        )

        let leaders = model.plates.compactMap { plate -> Feature? in
            guard plate.moved else { return nil }
            return Feature(geometry: .lineString(LineString([
                CLLocationCoordinate2D(latitude: plate.stop.lat, longitude: plate.stop.lon),
                CLLocationCoordinate2D(latitude: plate.lat, longitude: plate.lon),
            ])))
        }
        style.updateGeoJSONSource(
            withId: ID.leaders, geoJSON: .featureCollection(FeatureCollection(features: leaders))
        )
    }

    /// The railway overlay, rebuilt only when the model has new segments.
    ///
    /// Thousands of features, and they do not change between frames — rebuilding
    /// them at the tick rate would spend the whole frame budget redrawing the
    /// same rails.
    private var drawnTrackCount = -1
    private var drawnTrackOpacity = -1.0
    /// Whether ORM's own lines are the ones currently visible.
    private var drawnHighContrast: Bool?
    /// The selected route does not change as its marker moves. Re-uploading it
    /// every live tick makes Mapbox retessellate the white line visibly.
    private var drawnRouteRevision = -1

    private func drawTracks(_ style: MapboxMap) {
        if model.trackOpacity != drawnTrackOpacity {
            drawnTrackOpacity = model.trackOpacity
            for layer in [ID.tracks, ID.tracksTunnel] {
                try? style.setLayerProperty(
                    for: layer, property: "line-opacity", value: model.trackOpacity
                )
            }
            // One dial for both overlays, so switching between them keeps
            // whatever weight the map was set to.
            RailwayLines.setOpacity(style, model.trackOpacity)
        }
        if model.highContrastTracks != drawnHighContrast {
            drawnHighContrast = model.highContrastTracks
            RailwayLines.setVisible(style, model.highContrastTracks)
        }
        guard model.tracks.count != drawnTrackCount else { return }
        drawnTrackCount = model.tracks.count

        let tram = model.trackTramBit
        let tunnel = model.trackTunnelBit
        let features = model.tracks.map { line -> Feature in
            var feature = Feature(geometry: .lineString(LineString(
                line.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            )))
            feature.properties = [
                "tram": .boolean(tram != 0 && (line.kind & tram) != 0),
                "tunnel": .boolean(tunnel != 0 && (line.kind & tunnel) != 0),
            ]
            return feature
        }
        style.updateGeoJSONSource(
            withId: ID.tracks, geoJSON: .featureCollection(FeatureCollection(features: features))
        )
    }

    /// The drawn line, cut into runs of equal confidence.
    ///
    /// Runs are emitted with their shared vertex in both, so there is no gap at
    /// the seam where the style changes.
    private func drawRoute(_ style: MapboxMap) {
        guard drawnRouteRevision != model.selectedGeometryRevision else { return }
        drawnRouteRevision = model.selectedGeometryRevision

        guard let geometry = model.selectedGeometry, geometry.path.count > 1 else {
            style.updateGeoJSONSource(
                withId: ID.route, geoJSON: .featureCollection(FeatureCollection(features: []))
            )
            style.updateGeoJSONSource(
                withId: ID.routeStops, geoJSON: .featureCollection(FeatureCollection(features: []))
            )
            return
        }

        var features: [Feature] = []
        let legs = geometry.legs
        let sources = geometry.legSources

        // `!sources.isEmpty` as well as the length check, because the two agree
        // on a one-stop geometry — no legs, no sources — and the loop below
        // then has nothing to iterate and draws nothing at all. A line whose
        // confidence is not recorded per leg is drawn whole, which is what the
        // else branch is for.
        if !sources.isEmpty, sources.count == legs.count - 1 {
            var start = 0
            for leg in sources.indices {
                let exact = sources[leg] != .chord
                let isLast = leg == sources.count - 1
                if !isLast, (sources[leg + 1] != .chord) == exact { continue }

                let lo = legs[start], hi = legs[leg + 1]
                if hi > lo, hi < geometry.path.count {
                    features.append(runFeature(Array(geometry.path[lo...hi]), exact: exact))
                }
                start = leg + 1
            }
        } else {
            features.append(runFeature(geometry.path, exact: geometry.source == .osmRoute))
        }

        // The other half of a splitting train, from where the two part company.
        // Only the branch: both workings list the trunk, and laying one over the
        // other made the shared part read as a heavier line than the parts that
        // actually differ — the opposite of what the drawing is for.
        for branch in model.selectedBranches where branch.path.count > 1 {
            features.append(runFeature(branch.path, exact: branch.exact))
        }

        style.updateGeoJSONSource(
            withId: ID.route, geoJSON: .featureCollection(FeatureCollection(features: features))
        )

        // The stop markers sit where each call projects *onto the mapped way*,
        // not at the station's published coordinate — the same point the line
        // passes through and the vehicle stands at.
        var stopFeatures: [Feature] = legs.compactMap { at in
            guard at >= 0, at < geometry.path.count else { return nil }
            let point = geometry.path[at]
            return Feature(geometry: .point(Point(
                CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
            )))
        }
        for branch in model.selectedBranches {
            stopFeatures += branch.stops.map { point in
                Feature(geometry: .point(Point(
                    CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
                )))
            }
        }
        style.updateGeoJSONSource(
            withId: ID.routeStops,
            geoJSON: .featureCollection(FeatureCollection(features: stopFeatures))
        )
    }

    private func runFeature(_ points: [Coord], exact: Bool) -> Feature {
        var feature = Feature(geometry: .lineString(LineString(
            points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        )))
        feature.properties = ["exact": .boolean(exact)]
        return feature
    }
}

/// Where the unfocused state comes from.
///
/// A display-link target that does not keep its owner alive.
private final class DisplayLinkProxy {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Never from the button — no press means "stop following". Letting go of the
/// map means it, and so does the app moving the camera somewhere of its own
/// choosing, and both of those reach the button through here.
extension MapCoordinator: GestureManagerDelegate {
    func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
        // Letting go of a vehicle means going *somewhere else*, and only a pan
        // says that. Everything else is a change of view onto the same place.
        //
        // Zoom especially. Pinching out while following a bus through the
        // Kandertal is asking "where is this going", not "stop following it" —
        // and it was the one way to ask, so the answer was: lose the vehicle,
        // find it again, tap it again. A pinch does drag the centre about as
        // well as scaling, but `followFrame` writes the centre every refresh
        // and only the centre, so the zoom the fingers asked for survives and
        // the pan they did not is overwritten before it is ever drawn.
        //
        // Pitch and rotation are the same argument: tilting to see down a
        // valley, or turning the map to read it, are both still about the
        // vehicle. Rotating while the camera is *also* turning with the vehicle
        // is the one case where the two disagree, and there the map wins the
        // frame and the spring takes it back — which reads as the map holding
        // on, because it is.
        guard gestureType == .pan else { return }
        model.mapWasDragged()
    }

    func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {}
    func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {}
}

/// The two questions the app's own tilt gesture is judged by — and the single
/// answer the SDK's is given, which is no.
extension MapCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ recogniser: UIGestureRecognizer) -> Bool {
        // Anything else asking is the SDK's tilt, kept alive only to fail.
        guard let tilt = recogniser as? UIPanGestureRecognizer,
              tilt === tiltGesture, let view = tilt.view,
              tilt.numberOfTouches == 2 else { return false }

        // Are the fingers side by side, or stacked one above the other? Stacked
        // they are a pinch waiting to happen, and the drag between them means
        // either thing. The SDK draws this line at 45° off horizontal; 70°
        // leaves the pinch its own ground while admitting the hand that lies
        // diagonally across a phone, which is most of them.
        let first = tilt.location(ofTouch: 0, in: view)
        let second = tilt.location(ofTouch: 1, in: view)
        let lean = abs(atan2(second.y - first.y, second.x - first.x) * 180 / .pi)
        guard min(lean, 180 - lean) < 70 else { return false }

        // And is the drag going up the screen rather than across it? The SDK
        // never asks. Two fingers no longer pan, so a sideways drag does
        // nothing either way — but without this it would do nothing while
        // quietly bleeding the wobble in it into the pitch.
        let drag = tilt.translation(in: view)
        return abs(drag.y) > abs(drag.x)
    }

    func gestureRecognizer(
        _ recogniser: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Only with the pan, and only so that the tilt can take a drag over
        // from it mid-gesture — see `handleTilt`. Sharing with the pinch or the
        // rotate would put a stray zoom into the end of every tilt.
        recogniser === tiltGesture && other === mapView?.gestures.panGestureRecognizer
    }
}

extension MapCoordinator: ViewportStatusObserver {
    nonisolated func viewportStatusDidChange(
        from fromStatus: ViewportStatus,
        to toStatus: ViewportStatus,
        reason: ViewportStatusChangeReason
    ) {
        guard toStatus == .idle else { return }
        Task { @MainActor [weak self] in
            if self?.model.locateMode != .unfocused { self?.model.locateMode = .unfocused }
        }
    }
}
