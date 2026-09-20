import SwiftUI
import UIKit
import Combine
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
    /// Standard owns its buildings and supports configurable lighting.
    case standard = "Standard"
    case satellite = "Satellite"

    var id: String { rawValue }

    var styleURI: StyleURI {
        switch self {
        case .satellite: return .satelliteStreets
        // No constant for it in the SDK, which still ships the v11 list.
        // The URI is stable and documented; force-unwrapped because a literal
        // that cannot parse is a typo rather than a runtime condition.
        case .standard: return StyleURI(rawValue: "mapbox://styles/mapbox/standard")!
        }
    }

    /// Whether this basemap draws buildings of its own.
    var hasOwnBuildings: Bool { self == .standard }
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
    @Environment(\.scenePhase) private var scenePhase
    let basemap: Basemap
    var showsUserLocation = true
    var showsVehicles = true
    /// Mapbox's north arrow. Hidden with the rest of the chrome while the
    /// camera is watching a service full screen.
    var showsCompass = true

    func makeCoordinator() -> MapCoordinator { MapCoordinator(model: model) }

    func makeUIView(context: Context) -> MapView {
        // Where the phone already knows it is, or where the map was left, or
        // the country. Read from the model rather than resolved here, because
        // the fleet was drawn for this exact camera and the two disagreeing
        // would mean opening on a viewport the timetable was not expanded for.
        // See `OpeningCamera`.
        let opening = model.opening
        let options = MapInitOptions(
            // Do not leave the framebuffer scale implicit. Mapbox currently
            // defaults this to `nativeScale`, but spelling it out guarantees
            // that the Metal drawable is allocated at the panel's physical
            // pixel resolution rather than at one pixel per UIKit point.
            mapOptions: MapOptions(pixelRatio: UIScreen.main.nativeScale),
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
        mapView.ornaments.options.compass.visibility = showsCompass ? .adaptive : .hidden
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
        //
        // Which bearing source the puck turns to, if it turns at all. *Whether*
        // it turns — and whether the magnetometer is running to tell it — is
        // decided per moment rather than once, because a compass spinning a
        // wedge nobody can see is pure loss. See `Coordinator.applyLocationPolicy`.
        mapView.location.options.puckBearing = .heading
        context.coordinator.setVehiclesVisible(showsVehicles)
        context.coordinator.setPuckVisible(showsUserLocation)
        context.coordinator.attach(to: mapView, locationActive: scenePhase == .active)
        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.setVehiclesVisible(showsVehicles)
        context.coordinator.setPuckVisible(showsUserLocation)
        context.coordinator.setLocationActive(scenePhase == .active)
        context.coordinator.apply(basemap: basemap)
        let compass: OrnamentVisibility = showsCompass ? .adaptive : .hidden
        if mapView.ornaments.options.compass.visibility != compass {
            mapView.ornaments.options.compass.visibility = compass
        }
        // Do not draw here. SwiftUI calls this on every chrome animation
        // frame — opening search, the clock, a status-pill rewrite — and the
        // model's `onFrame` already redraws the map from the tick. Drawing
        // again from here is what froze the search morph.
    }

    static func dismantleUIView(_ mapView: MapView, coordinator: MapCoordinator) {
        coordinator.detach(from: mapView)
    }
}

/// Cable profiles, kept across pans, style reloads and app launches.
///
/// The expensive part is sampling terrain and reducing its clearance hull.
/// Styling that answer for the current theme is cheap, so the cache stores the
/// `Rope` rather than Mapbox features. Its key includes the complete alignment
/// and terrain settings; a changed route or relief setting naturally misses.
private final class CablewayRopeCache {
    private struct Entry: Codable, Sendable {
        var rope: Cableway.Rope
        var complete: Bool
    }

    private struct Archive: Codable, Sendable {
        var version: Int
        var ropes: [String: Entry]
    }

    private static let version = 2
    private static let limit = 512
    private var ropes: [String: Entry] = [:]
    private let file: URL?
    private let writer = DispatchQueue(label: "ch.swisstransit.cableway-rope-cache")

    init() {
        file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("cableway-rope-profiles-v2.json")
        guard let file, let data = try? Data(contentsOf: file),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == Self.version
        else { return }
        ropes = archive.ropes
    }

    func profile(
        _ key: String, includingProvisional: Bool
    ) -> (rope: Cableway.Rope, complete: Bool)? {
        guard let entry = ropes[key], entry.complete || includingProvisional else {
            return nil
        }
        return (entry.rope, entry.complete)
    }

    func store(
        solved: [String: Cableway.Rope], provisional: [String: Cableway.Rope]
    ) {
        guard !solved.isEmpty || !provisional.isEmpty else { return }
        var changed = false
        for (key, rope) in provisional
        where ropes[key]?.complete != true && ropes[key]?.rope != rope {
            ropes[key] = Entry(rope: rope, complete: false)
            changed = true
        }
        for (key, rope) in solved where ropes[key]?.complete != true {
            ropes[key] = Entry(rope: rope, complete: true)
            changed = true
        }
        guard changed else { return }
        while ropes.count > Self.limit, let key = ropes.keys.first {
            ropes.removeValue(forKey: key)
        }
        guard let file else { return }
        let archive = Archive(version: Self.version, ropes: ropes)
        writer.async {
            guard let data = try? JSONEncoder().encode(archive) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// Owns the map's sources and layers, and keeps them in step with the model.
@MainActor
final class MapCoordinator: NSObject {
    private let model: AppModel
    private weak var mapView: MapView?
    /// Centre animations yield to the vehicle follower; independent zoom and
    /// tilt animations can continue while it owns the centre.
    private var centreAnimation: Cancelable?
    private var cancellables: Set<AnyCancelable> = []
    private var styleReady = false
    private var currentBasemap: Basemap?
    private let cablewayRopeCache = CablewayRopeCache()

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
    /// name a default rather than unwrap. Standard is the app's default, and a
    /// change re-runs the whole install anyway.
    private var theme: Basemap { currentBasemap ?? .standard }

    /// Which light preset the Standard basemap was last built for.
    ///
    /// Cache the resolved day/night value so Auto never reaches the style API
    /// and clock changes update the config once, without reloading it.
    private var currentPreset: Terrain3D.LightPreset?
    private var automaticLightMinute: Int?
    private var automaticLightCell: Int?
    private var automaticLightPreset: Terrain3D.LightPreset = .night
    private var lightPreset: Terrain3D.LightPreset {
        guard model.lightPreset == .auto else { return model.lightPreset }
        // Draw already runs while the map is visible. Recalculate when the
        // minute rolls or the camera has moved far enough that the sun's
        // height at this place is a different question.
        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        let lat = (model.viewport.south + model.viewport.north) / 2
        let lon = (model.viewport.west + model.viewport.east) / 2
        let cell = Int((lat * 2).rounded()) &* 4_000 &+ Int((lon * 2).rounded())
        if minute != automaticLightMinute || cell != automaticLightCell {
            automaticLightMinute = minute
            automaticLightCell = cell
            automaticLightPreset = Terrain3D.LightPreset.auto.resolved(
                at: now, latitude: lat, longitude: lon
            )
        }
        return automaticLightPreset
    }

    /// Whether what is under our layers is dark.
    ///
    /// Satellite uses light overlay labels; Standard follows its lighting.
    private var isDarkTheme: Bool {
        theme == .standard ? lightPreset.isDark : true
    }

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - How fast the renderer is allowed to run

    /// The interval the model last said it was feeding the map at.
    private var pacedInterval: Duration?

    /// Whether the camera is mid-movement — a finger, or an ease the app
    /// started — and so owns the frame rate until the map settles again.
    ///
    /// Mapbox camera-changed is not a user gesture; treating it as one holds
    /// ProMotion at 60 Hz for the lifetime of 3D.
    private var cameraSettled = true {
        didSet {
            guard cameraSettled != oldValue else { return }
            if model.cameraIsSettled != cameraSettled {
                model.cameraIsSettled = cameraSettled
            }
        }
    }

    /// Programmatic camera eases (focus, frame, debug start, locate).
    /// A generation rather than a count: cancelling an ease must not leave
    /// the display link uncapped if its completion never arrives.
    private var easeGeneration: UInt64 = 0
    private var easeCameraActive = false
    private var compassCameraActive = false
    private var userCameraBusy: Bool {
        gestureCameraActive || easeCameraActive || compassCameraActive
    }
    private var settleWatchdog: Task<Void, Never>?
    private static let settleWatchdogDelay: Duration = .milliseconds(200)

    /// What the map and the follow link are currently being held to.
    private var renderRange = CAFrameRateRange.default

    /// Hold the renderer's display link to the rate the model is actually
    /// feeding it.
    ///
    /// **A display link is a request as well as a callback.** Left at its
    /// default the SDK's link asks for the panel's maximum — 120 Hz on a
    /// ProMotion phone — and iOS grants it by holding the *display itself* at
    /// that rate for as long as the link is alive. So the default costs twice
    /// over: `MapView.updateFromDisplayLink` runs a hundred and twenty times a
    /// second to discover, four times out of five, that nothing is dirty; and
    /// the screen never drops to the low refresh rate it would otherwise idle
    /// at. Those are the GPU and Display bars on an energy trace, and neither
    /// of them buys a frame — the data underneath changes fifteen to thirty
    /// times a second and no faster, because `AppModel.frameInterval` went to
    /// some trouble to work out that it need not.
    ///
    /// **Except while somebody is moving the map.** A pan, a pinch and every
    /// camera ease are drawn from data already uploaded, at whatever rate the
    /// display can manage — that is why a finger can drag the map smoothly
    /// while the vehicles on it are being recomputed seventeen times a second.
    /// Capping the link through a gesture would make the gesture stutter, which
    /// is the one thing here actually worth the energy. So the cap comes off
    /// while the camera is busy and goes back on when the map settles.
    private func setRenderRate(_ interval: Duration? = nil) {
        if let interval { pacedInterval = interval }
        guard let mapView, let paced = pacedInterval else { return }

        let wanted: CAFrameRateRange
        if !locationActive {
            // The scene is covered or backgrounded. UIKit will normally stop
            // presenting it entirely; this one-hertz ceiling also closes the
            // inactive interval before suspension takes effect.
            wanted = CAFrameRateRange(minimum: 1, maximum: 1, preferred: 1)
        } else if model.panelMotionActive {
            // A sheet drag is outside the map's gesture recognizers. Keep the
            // display responsive through the drag and its settling animation.
            wanted = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        } else if model.prefersHighFrameRate {
            // The follow pill is rolling a stop name. 60 Hz made that ease
            // look stepped; ProMotion can give 120 and other panels 60.
            wanted = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        } else if model.isFollowingVehicle, !model.mapObscured {
            wanted = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        } else if !cameraSettled {
            wanted = .default
        } else {
            wanted = Self.pacedRange(for: paced)
        }

        guard wanted != renderRange else { return }
        renderRange = wanted
        mapView.preferredFrameRateRange = wanted
        followLink?.preferredFrameRateRange = wanted
    }

    /// The renderer's ordinary range at the rate the model can provide data.
    /// A range rather than one mandatory number gives iOS a lower panel divisor
    /// when the exact preferred rate is unavailable.
    private static func pacedRange(for interval: Duration) -> CAFrameRateRange {
        let hz = Float(min(120, max(1, (1 / max(1.0 / 120, interval.seconds)).rounded())))
        return CAFrameRateRange(
            minimum: max(1, hz / 2), maximum: hz, preferred: hz
        )
    }

    /// The camera moved. What that means depends entirely on who moved it.
    ///
    /// A finger or an ease owns the frame rate until the map settles. The
    /// *follower* does not: it sets the camera every display refresh, so its
    /// own writes must never be read back as somebody moving the map, or the
    /// cap would come off for as long as following lasted and never go back on
    /// — a followed map never goes idle.
    ///
    /// Terrain tile arrival and GeoJSON-driven invalidation also fire
    /// camera-changed. Those must not clear `cameraSettled`, or 3D never
    /// returns to the paced display-link cap.
    private func cameraMoved() {
        // A finger keeps the immediate feedback path. The follower, on the
        // other hand, changes only centre and bearing on every display refresh;
        // unprojecting the eight-point viewport at that rate feeds no decision
        // the model can make between its own ticks. Keep its feedback frequent
        // enough to load ahead while avoiding a renderer round-trip per frame.
        if gestureCameraActive || !model.isFollowingVehicle {
            reportViewport()
        } else {
            let now = CACurrentMediaTime()
            if now - followViewportAt >= Self.followViewportInterval {
                followViewportAt = now
                reportViewport()
            } else {
                // Pitch/solidity and lamp attitude are camera-owned and cheaper
                // than rebuilding the geographic viewport. Preserve their frame
                // path even when the bounding-box report is being coalesced.
                applySolidity()
            }
        }
        if userCameraBusy {
            markCameraBusy()
        }
    }

    private func markCameraBusy() {
        settleWatchdog?.cancel()
        settleWatchdog = nil
        if cameraSettled {
            cameraSettled = false
        }
        setRenderRate()
    }

    /// Idle is a nice extra, not the only path back to the cap. 3D terrain
    /// keeps Mapbox from staying idle, so a short watchdog breaks the
    /// chicken-and-egg.
    private func settleCamera() {
        settleWatchdog?.cancel()
        settleWatchdog = nil
        guard !userCameraBusy else { return }
        if !cameraSettled {
            cameraSettled = true
        }
        setRenderRate()
    }

    private func armSettleWatchdog() {
        settleWatchdog?.cancel()
        settleWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleWatchdogDelay)
            guard !Task.isCancelled, let self else { return }
            self.settleCamera()
        }
    }

    @discardableResult
    private func beginEaseCamera() -> UInt64 {
        easeGeneration &+= 1
        easeCameraActive = true
        markCameraBusy()
        return easeGeneration
    }

    private func endEaseCamera(_ generation: UInt64) {
        guard generation == easeGeneration else { return }
        easeCameraActive = false
        if !userCameraBusy { settleCamera() }
    }

    private func endCompassCamera() {
        compassCameraActive = false
        if !userCameraBusy { settleCamera() }
    }

    private static let followViewportInterval: CFTimeInterval = 0.1
    private var followViewportAt: CFTimeInterval = 0
    private var gestureCameraCount = 0
    private var customTiltActive = false
    private var gestureCameraActive: Bool { gestureCameraCount > 0 || customTiltActive }

    // MARK: - What the phone is asked to work out about itself

    /// The location source, owned here rather than left to the SDK's default.
    ///
    /// **The default is the most expensive setting CoreLocation has.** Mapbox
    /// builds its provider with `kCLLocationAccuracyBest` and no distance
    /// filter — a GNSS receiver at full duty cycle and a continuous Wi-Fi scan,
    /// from launch, for the whole session — and this app never asked for that.
    /// A hundred metres is enough to draw a dot on a map of a country; ten is
    /// enough once a trail is actually being matched against the fleet, which
    /// discards anything worse than seventy metres before it looks at it. See
    /// `RideWatch.accurateEnough`.
    private let locationProvider = AppleLocationProvider()

    /// Whether the map is attached to an active scene. Replacing the map's
    /// publisher with an empty one is what actually removes the provider's last
    /// observer; changing accuracy alone would leave CoreLocation running while
    /// the app is covered or in the background.
    private var locationActive = false
    /// Nil is Mapbox's initial/default model, true is our provider, and false
    /// is the empty inactive model. The third state matters when a view is
    /// created while its scene is already inactive: the SDK default must still
    /// be replaced before anything can subscribe to it.
    private var locationConnected: Bool?

    /// A coarse fix can still say, independently of its horizontal accuracy,
    /// that the phone is moving at transit speed. Promote on that raw signal
    /// before `RideWatch` rejects the point for being wider than its matching
    /// threshold, otherwise coarse acquisition can never reach the accurate
    /// mode needed to build a ride trail.
    private var rawMotionUntil: CFTimeInterval = 0
    /// A short evidence-quality acquisition around a known stop. Coarse
    /// location is enough to decide whether a stop is nearby, but not enough
    /// to distinguish its platforms or establish a stationary cluster.
    private var nearTransitUntil: CFTimeInterval = 0
    /// Re-applies the policy when a temporary precision reason expires. Core
    /// Location may produce no callback while a stationary phone is searching,
    /// so waiting for the next fix can otherwise leave GNSS at full duty
    /// indefinitely.
    private var precisionPolicyTask: Task<Void, Never>?
    /// The cheap stop-grid probe is asynchronous because Fleet is an actor.
    /// Only one may be outstanding, and repeated coarse fixes are throttled.
    private var stationProbeTask: Task<Void, Never>?
    /// Identifies the probe whose result is still allowed to clear the task
    /// handle or promote location accuracy. Cancellation alone is not enough:
    /// Fleet may already be inside synchronous actor work when the scene leaves,
    /// and that old task can return after a new active-scene probe has begun.
    private var stationProbeGeneration: UInt64 = 0
    private var stationProbeAfter: CFTimeInterval = 0
    private static let rawMotionSampleAge: TimeInterval = 10
    private static let rawMotionGrace: CFTimeInterval = 20
    private static let nearTransitGrace: CFTimeInterval = 30
    private static let stationProbeInterval: CFTimeInterval = 2
    private static let precisionPolicyPoll: CFTimeInterval = 5

    /// Whether the data model currently in place carries a heading publisher,
    /// or nil before one has ever been installed.
    private var appliedHeading: Bool?

    /// Ask the phone for exactly as much as is about to be used, and no more.
    ///
    /// Re-evaluated when the map settles, when a fix arrives and when the
    /// locate button changes state — which between them cover every way either
    /// answer below can change, at about a second's granularity.
    ///
    /// The distance filter stays off once a ride is active, and that is not an
    /// oversight. `RideWatch` reads a *stationary* phone as evidence — a train
    /// standing at a terminus is still your train, and four minutes of not
    /// moving is how the claim is finally given up — and a distance filter
    /// makes a stationary phone produce no fixes at all, which is a different
    /// state entirely and the one the tunnel hold is for.
    private func applyLocationPolicy() {
        guard let mapView else { return }

        guard locationActive else {
            disconnectLocation(from: mapView)
            return
        }

        // Precise where a fix is being read for its own sake: a camera locked
        // to the puck, a trail already moving or fitted to a journey, or the
        // short acquisition grace opened by a raw speed sample. Merely enabling
        // ride detection does not hold GNSS at full duty for the whole session.
        let rides = model.rides
        let now = CACurrentMediaTime()
        let recentlyMoving = rides.enabled && now < rawMotionUntil
        let acquiringNearby = rides.enabled && now < nearTransitUntil
        // A still phone with a 25 m filter produces no new fixes, so the
        // station offer can never start. Ten-metre GNSS while standing is
        // the whole of "you are in Spiez".
        let standingForPlace = rides.enabled
            && rides.ride == nil && !rides.moving && !rides.holding
            && (model.clock.isLive || rides.ignoresClock)
        let precise = model.locateMode != .unfocused
            || rides.ride != nil || rides.holding || rides.moving
            || recentlyMoving || acquiringNearby || nearbyOfferVisible
            || standingForPlace
        let options = AppleLocationProvider.Options(
            distanceFilter: precise ? kCLDistanceFilterNone : 25,
            desiredAccuracy: precise
                ? kCLLocationAccuracyNearestTenMeters
                : kCLLocationAccuracyHundredMeters,
            activityType: .otherNavigation
        )
        if locationProvider.options != options { locationProvider.options = options }

        let heading = headingIsVisible
        guard locationConnected != true || heading != appliedHeading else { return }
        locationConnected = true
        appliedHeading = heading
        mapView.location.options.puckBearingEnabled = heading
        // **`puckBearingEnabled` alone does not stop the compass.** That flag
        // reaches the puck's *renderer* and nothing else; the SDK subscribes to
        // whatever heading publisher the data model carries either way, and the
        // subscription is what calls `startUpdatingHeading`. So the only way to
        // put the magnetometer down is to hand over a data model that has no
        // heading in it. See `LocationManager.updateDataModel`.
        mapView.location.dataModel = LocationDataModel(
            location: locationProvider.onLocationUpdate.eraseToAnyPublisher(),
            heading: heading ? locationProvider.onHeadingUpdate.eraseToAnyPublisher() : nil
        )
    }

    /// Stop both CoreLocation streams without replacing our provider (and its
    /// cached last fix). `AppleLocationProvider` starts on its first observer
    /// and stops on its last; the empty model releases those observations.
    private func disconnectLocation(from mapView: MapView) {
        guard locationConnected != false else { return }
        locationConnected = false
        appliedHeading = nil
        mapView.location.options.puckBearingEnabled = false
        mapView.location.dataModel = LocationDataModel(
            location: Empty<[Location], Never>(completeImmediately: false)
                .eraseToAnyPublisher()
        )
    }

    /// Read before `RideWatch.received`, which deliberately discards a coarse
    /// point. A stale cached point must not restart high-accuracy tracking when
    /// a scene reconnects, hence the separate sample-age bound.
    private func noticeRawMotion(_ location: Location) {
        guard model.rides.enabled,
              let speed = location.speed, speed >= RideMatching.movingAt
        else { return }
        let age = Date().timeIntervalSince(location.timestamp)
        guard age >= -1, age <= Self.rawMotionSampleAge else { return }
        rawMotionUntil = max(rawMotionUntil, CACurrentMediaTime() + Self.rawMotionGrace)
        schedulePrecisionPolicyCheck()
    }

    /// Whether a stationary-place answer is still visible. Keep its evidence
    /// stream precise while it is being shown, then notice a dismissal within
    /// one short policy poll and step back down.
    private var nearbyOfferVisible: Bool {
        guard case .some(.nearby(_)) = model.rides.offering else { return false }
        return true
    }

    /// Wake at the end of a temporary high-accuracy reason even if Core
    /// Location is silent. While a nearby offer is visible the same lightweight
    /// timer also notices its dismissal, which otherwise has no map callback.
    private func schedulePrecisionPolicyCheck() {
        precisionPolicyTask?.cancel()
        precisionPolicyTask = nil
        guard locationActive else { return }

        let now = CACurrentMediaTime()
        let deadline = max(rawMotionUntil, nearTransitUntil)
        let delay: CFTimeInterval
        if deadline > now {
            delay = max(0.1, deadline - now)
        } else if nearbyOfferVisible {
            delay = Self.precisionPolicyPoll
        } else {
            return
        }

        precisionPolicyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.locationActive else { return }
            self.applyLocationPolicy()
            self.schedulePrecisionPolicyCheck()
        }
    }

    /// A coarse fix near the transit network earns one bounded precise burst.
    /// This restores stationary platform/station offers without returning to
    /// the old policy of running full-accuracy GNSS for every open-map minute.
    private func probeForNearbyTransit(_ location: Location) {
        let now = CACurrentMediaTime()
        let rides = model.rides
        guard locationActive, rides.enabled,
              model.clock.isLive || rides.ignoresClock,
              rides.ride == nil, !rides.moving, !rides.holding,
              !nearbyOfferVisible,
              now >= stationProbeAfter,
              now >= max(rawMotionUntil, nearTransitUntil),
              stationProbeTask == nil
        else { return }

        let age = Date().timeIntervalSince(location.timestamp)
        guard age >= -1, age <= Self.rawMotionSampleAge else { return }
        let accuracy = max(0, location.horizontalAccuracy ?? 150)
        guard accuracy <= 1_000 else { return }

        stationProbeAfter = now + Self.stationProbeInterval
        let lon = location.coordinate.longitude
        let lat = location.coordinate.latitude
        let radius = min(500, max(250, accuracy + 200))
        let fleet = model.fleet
        stationProbeGeneration &+= 1
        let generation = stationProbeGeneration
        stationProbeTask = Task { @MainActor [weak self] in
            let nearby = await fleet.hasStopPlace(near: lon, lat: lat, within: radius)
            guard let self, self.stationProbeGeneration == generation else { return }
            self.stationProbeTask = nil
            guard !Task.isCancelled, self.locationActive, self.model.rides.enabled,
                  nearby else { return }
            self.nearTransitUntil = max(
                self.nearTransitUntil,
                CACurrentMediaTime() + Self.nearTransitGrace
            )
            self.applyLocationPolicy()
            self.schedulePrecisionPolicyCheck()
        }
    }

    /// Invalidate both the task and its identity. A cancelled actor call may
    /// still return, but it can no longer clear a replacement probe's handle.
    private func cancelStationProbe(resetThrottle: Bool) {
        stationProbeGeneration &+= 1
        stationProbeTask?.cancel()
        stationProbeTask = nil
        if resetThrottle { stationProbeAfter = 0 }
    }

    /// Whether the cone is somewhere it could be seen.
    ///
    /// The cone is the only thing in this app that uses a heading. Two ways it
    /// is on screen: the map is following the puck, so it is there by
    /// construction; or the last known fix falls inside the viewport, so it is
    /// there by arithmetic. Anywhere else the puck is off the edge of the map
    /// and the compass would be turning a wedge in an empty room.
    private var headingIsVisible: Bool {
        guard let mapView else { return false }
        if model.locateMode != .unfocused { return true }
        guard let fix = mapView.location.latestLocation else { return false }
        // A tenth of the box in every direction. Swapping the data model stops
        // and restarts the location manager, so a puck sitting exactly on the
        // edge of the screen should not be able to do it twice a pan — and a
        // margin is cheaper than the flapping it prevents.
        let box = model.viewport
        let margin = 0.1
        let lonRoom = (box.east - box.west) * margin
        let latRoom = (box.north - box.south) * margin
        let point = fix.coordinate
        return point.longitude >= box.west - lonRoom && point.longitude <= box.east + lonRoom
            && point.latitude >= box.south - latRoom && point.latitude <= box.north + latRoom
    }

    func attach(to mapView: MapView, locationActive: Bool) {
        model.onMapChoices = { [weak self] options in self?.presentChoices(options) }
        self.mapView = mapView
        self.locationActive = locationActive
        // Before anything subscribes to a location, so the provider that starts
        // is ours rather than the SDK's default one at full accuracy.
        applyLocationPolicy()
        model.rides.onNeedPlaceAccuracy = { [weak self] in self?.applyLocationPolicy() }
        model.onFrame = { [weak self] in self?.draw() }
        model.onMapOverlays = { [weak self] in self?.drawMapOverlays() }
        model.onPace = { [weak self] interval in self?.setRenderRate(interval) }
        // The loop only announces a change, and it may already be running at
        // the rate it wants — so the first one is taken by hand.
        setRenderRate(model.frameInterval)
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
        model.onSetVehiclesVisible = { [weak self] visible in self?.setVehiclesVisible(visible) }
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
            // This must precede RideWatch's accuracy filter. A hundred-metre
            // acquisition fix is not fit evidence, but its speed is enough to
            // ask the provider for the evidence-quality stream.
            self?.noticeRawMotion(last)
            self?.probeForNearbyTransit(last)
            self?.model.rides.received(RideFix(
                coord: Coord(
                    lon: last.coordinate.longitude, lat: last.coordinate.latitude
                ),
                at: last.timestamp.timeIntervalSince1970,
                speed: last.speed.flatMap { $0 >= 0 ? $0 : nil },
                course: last.bearing.flatMap { $0 >= 0 ? $0 : nil },
                accuracy: last.horizontalAccuracy ?? -1
            ))

            // Cheap and guarded: the options are only written when they differ
            // and the data model only swapped when the compass changes hands.
            self?.applyLocationPolicy()
        }.store(in: &cancellables)

        mapView.mapboxMap.onStyleLoaded.observe { [weak self] _ in
            self?.installLayers()
        }.store(in: &cancellables)

        mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
            self?.cameraMoved()
        }.store(in: &cancellables)

        // The built-in compass owns its ease inside Mapbox. It never begins a
        // map gesture or calls beginEaseCamera, so track its actual lifecycle
        // to lift the idle FPS cap before the first animation frame.
        mapView.camera.onCameraAnimatorStarted.observe { [weak self] animator in
            guard animator.owner == .compass, let self else { return }
            compassCameraActive = true
            markCameraBusy()
            // The compass asked for north. Heading lock would spring the map
            // back onto the train the moment the ease finished.
            dropFollowBearing()
        }.store(in: &cancellables)
        mapView.camera.onCameraAnimatorFinished.observe { [weak self] animator in
            guard animator.owner == .compass else { return }
            self?.endCompassCamera()
        }.store(in: &cancellables)
        mapView.camera.onCameraAnimatorCancelled.observe { [weak self] animator in
            guard animator.owner == .compass else { return }
            self?.endCompassCamera()
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
            GeoJSONQueueProbe.shared.ingest(dataId: event.dataId)
            if event.sourceId == VehicleShapes.followSource {
                self?.commitFollowBake(dataId: event.dataId)
            }
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
            guard let self else { return }
            reportViewport()
            settleCamera()
            // The viewport is what decides whether the puck is on screen, so
            // the moment it stops moving is the moment to ask again.
            applyLocationPolicy()
            Task { @MainActor in await self.mergeStationBlobs() }
        }.store(in: &cancellables)

        mapView.gestures.onMapTap.observe { [weak self] context in
            self?.handleTap(at: context.point, coordinate: context.coordinate)
        }.store(in: &cancellables)
    }

    /// Scene activity is supplied by SwiftUI so there is exactly one lifecycle
    /// authority. Going inactive disconnects the provider immediately; coming
    /// back reconnects it with whichever accuracy policy is current.
    func setLocationActive(_ active: Bool) {
        guard active != locationActive else { return }
        locationActive = active
        if !active {
            selectionTapTask?.cancel()
            selectionTapTask = nil
            _ = model.beginSelectionInteraction()
        }
        if active {
            // A probe interrupted by scene suspension did not answer the
            // question its 45-second throttle represents. Let the cached recent
            // fix ask it again immediately; a stale fix is rejected by the age
            // gate in `probeForNearbyTransit` and the provider's next fix retries.
            stationProbeAfter = 0
            schedulePrecisionPolicyCheck()
            if model.isFollowingVehicle { wakeFollowLink() }
        } else {
            precisionPolicyTask?.cancel()
            precisionPolicyTask = nil
            cancelStationProbe(resetThrottle: true)
            pauseFollowLink()
        }
        applyLocationPolicy()
        if active, let location = mapView?.location.latestLocation {
            probeForNearbyTransit(location)
        }
        setRenderRate()
    }

    /// `UIViewRepresentable` can dismantle without waiting for ARC to collect
    /// Mapbox. Drop signal subscriptions and the display link explicitly so no
    /// sensor or refresh producer survives an off-screen map.
    func detach(from view: MapView) {
        guard mapView === view else { return }
        selectionTapTask?.cancel()
        selectionTapTask = nil
        _ = model.beginSelectionInteraction()
        locationActive = false
        precisionPolicyTask?.cancel()
        precisionPolicyTask = nil
        cancelStationProbe(resetThrottle: true)
        disconnectLocation(from: view)
        model.rides.onNeedPlaceAccuracy = nil
        model.onMapChoices = nil
        choicePopover?.dismiss(animated: false)
        choicePopover = nil
        choiceMenuAnchor?.contextMenuInteraction?.dismissMenu()
        choiceMenuAnchor?.removeFromSuperview()
        choiceMenuAnchor = nil
        cancellables.removeAll()
        followLink?.invalidate()
        followLink = nil
        settleWatchdog?.cancel()
        settleWatchdog = nil
        easeCameraActive = false
        compassCameraActive = false
        easeGeneration &+= 1
        mapView = nil
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
    /// The inputs that can alter either feature written by the follow lane.
    /// Kept separately from its output so a stationary model tick can leave a
    /// paused display link asleep instead of waking the screen to rediscover
    /// that the camera and both sources are already exact.
    private struct FollowRenderContext: Equatable {
        var id: String?
        var vehicle: VehicleSnapshot
        var shape: VehicleFootprint?
        var velocityLon: Double
        var velocityLat: Double
        var emergence: Double?
        var labelOpenId: String?
        var cablewayLabel: Bool
        var bakedModels: Bool
        var showingSolids: Bool
        var lampsLit: Bool
        var solidVehicles: Bool
        var terrain: Bool
        var ghostTunnels: Bool
        var hitboxes: Bool
        var tunnelRevision: Int
        var clockPlaying: Bool
        var clockSpeed: Double
        /// The followed vehicle is in a bore, so the body is about to yield to
        /// the tunnel marker. Kept on the context so a train that disappears
        /// under a hill wakes the display link instead of leaving an invisible
        /// rake on screen until something else moves.
        var underground: Bool
    }
    private var followRenderContext: FollowRenderContext?

    /// The parts of a follow-lane drawing that force a GeoJSON rewrite.
    /// Position is not in here: between rebuilds the body slides with
    /// `model-translation` / `fill-translate` from `followUploadedAt`.
    ///
    /// Putting the model tick's `followStamp` in this key rebaked the source
    /// thirty times a second and zeroed those translates before Mapbox had
    /// applied the new geometry — wagons jumping back onto stale points, then
    /// forward again, which reads as a shake that grows as the queue lags.
    private struct FollowDrawingKey: Equatable {
        var showingSolids: Bool
        var bakedModels: Bool
        var lampsLit: Bool
        var ghostTunnels: Bool
        var hitboxes: Bool
        var underground: Bool
        var tunnelRevision: Int
        var emergence: Double?
        var wagons: Int
    }
    /// What was last handed to each source. Feature equality includes geometry
    /// and properties, so this catches a true no-op without guessing which of
    /// the renderer's several fades or model-placement properties mattered.
    private var drawnFollowShapeFeatures: [Feature]?
    private var drawnFollowPointFeature: Feature?
    /// Geographic position of the geometry currently in the follow source —
    /// or still in flight, until `commitFollowBake`. Absolute, not relative
    /// to `followAnchor`, which jumps every model tick.
    private var followUploadedAt: Coord?
    /// A source rewrite that moved that origin, not yet visible. Translation
    /// keeps using `followUploadedAt` until this lands, otherwise the wagons
    /// sit on the old points with a zeroed offset.
    private var followPendingOrigin: Coord?
    private var followPendingDataId: String?
    private var followPendingStamp: CFTimeInterval = 0
    /// Heading last written into the follow source, for the rebake threshold.
    private var followUploadedHeading: Double?
    /// Map clock of the footprint last written, so a model tick rebakes
    /// 3D points instead of sliding them with `model-translation`.
    private var followUploadedStamp: Double = -1
    /// Heading of the geometry currently on the GPU. Used to rotate
    /// `model-translation` into the model's frame; the in-flight write's
    /// heading must not be used until that write lands.
    private var followBakedHeading: Double?
    private var followPendingHeading: Double?
    /// Snapped tunnel-fade signature last written, so an in-progress ease
    /// can keep stepping without a GeoJSON rewrite every refresh.
    private var followUploadedFadeSig: Int?
    /// Last screen-space translate written to the follow fill/line layers.
    private var followLayerTranslate = CGSize.zero
    /// Translate-anchor has been pinned to viewport on the follow layers.
    private var followTranslateAnchorSet = false
    /// Common lift of the followed rake, for the model-translation fast path.
    private var followModelLift = 0.0
    /// Layer constant is currently overriding the data-driven lift expression.
    private var followModelTranslated = false
    /// Solids/lamps/hitboxes as they were when the follow source was last
    /// rebuilt, so a tilt can force a new tessellation without waiting for
    /// the next model tick.
    private var followUploadedDrawing: FollowDrawingKey?
    /// The footprint as the model last built it, in its own coordinates. It is
    /// translated rather than rebuilt — see `followFrame`.
    private var followShape: VehicleFootprint?
    private var followId: String?
    /// Whether the follow lane currently has a footprint in its source, so it
    /// is emptied exactly once when there stops being one. See `followFrame`.
    private var drewFollowShape = false
    /// The bearing the camera has been eased to, while it is turning with a
    /// vehicle. Nil whenever it is not.
    private var followBearing: CLLocationDirection?
    /// How fast that bearing is currently turning, in degrees per second, and
    /// when it was last moved. The turn is a damped spring rather than a
    /// fraction per frame, and a spring needs both. See `cameraBearing`.
    private var followBearingRate: Double = 0
    private var followBearingStamp: CFTimeInterval = 0
    private var acquiringFollowBearing = false
    /// A rotate recogniser is down, so the follow spring must not write heading
    /// until the fingers lift — Mapbox only reports the rotate after a few
    /// degrees, and writing through that window is what snaps the map back.
    private var freezeFollowHeading = false
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
        let previousId = followId
        if !same {
            followBearing = nil
            acquiringFollowBearing = false
            freezeFollowHeading = false
            // A map tap does not idle Mapbox's GPS-follow viewport. Unless it
            // is explicitly released, the next phone fix pulls the camera back
            // from the selected train. This is especially visible on your own
            // ride, where GPS and the timetable give nearby but different points.
            mapView?.viewport.idle()
            centreAnimation?.cancel()
            centreAnimation = nil
            model.locateMode = .unfocused
            applyLocationPolicy()
        }
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
        refreshTunnels()
        let underground = model.ghostTunnels
            && tunnelMarker(for: vehicle, at: coord).fade > 0.85
        let context = FollowRenderContext(
            id: followId,
            vehicle: vehicle,
            shape: followShape,
            velocityLon: followVelocity.lon,
            velocityLat: followVelocity.lat,
            emergence: displayedVehicleEmergence[vehicle.id] ?? followShape?.emergence,
            labelOpenId: labelOpenId,
            cablewayLabel: cablewayLabelIDs.contains(vehicle.id),
            bakedModels: model.bakedModels,
            showingSolids: showingSolids,
            lampsLit: lampsLit,
            solidVehicles: model.detailedVehicles && model.solidVehicles,
            terrain: model.terrain3D,
            ghostTunnels: model.ghostTunnels,
            hitboxes: model.showWagonHitboxes,
            tunnelRevision: model.tunnelRevision,
            clockPlaying: model.clock.isPlaying,
            clockSpeed: model.clock.speed,
            underground: underground
        )
        let changed = context != followRenderContext
        followRenderContext = context

        let created = startFollowLink()
        if created || previousId != followId {
            // The first selected frame should not wait for the next vsync. After
            // this hand-off the display link is the sole frame producer.
            drawnFollowShapeFeatures = nil
            drawnFollowPointFeature = nil
            resetFollowShapeTranslate()
            followFrame(at: CACurrentMediaTime())
        } else if changed {
            wakeFollowLink()
        }
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

    /// Rebake follow GeoJSON after this much travel, in metres.
    ///
    /// Models stand on the terrain under their GeoJSON point, then a rigid
    /// translate is applied. A long gap freezes the rake's curve and grade.
    /// Five metres is a fraction of a coach: about a fifth of a second at
    /// line speed, still cheap as a GeoJSON write.
    private static let followRebuildMetres = 5.0

    /// Rebake when the front heading has moved this many degrees. Two degrees
    /// waited out a gentle curve for tens of metres; a quarter degree is a
    /// couple of ticks on a 500 m radius.
    private static let followHeadingStep = 0.25

    /// Give up waiting for `onSourceDataLoaded` after this, in seconds, and
    /// commit the pending origin anyway. Better a rare hitch than a stuck
    /// pending that blocks every later write.
    private static let followBakeTimeout = 0.3

    @discardableResult
    private func startFollowLink() -> Bool {
        guard followLink == nil else { return false }
        // Through a weak proxy: `CADisplayLink` retains its target, and a link
        // that is still running holds the coordinator — and through it the
        // model — alive after the map has gone.
        let link = CADisplayLink(
            target: DisplayLinkProxy { [weak self] link in
                self?.followFrame(at: link.targetTimestamp)
            },
            selector: #selector(DisplayLinkProxy.fire(_:))
        )
        // At the rate the map itself is being held to, rather than at the
        // panel's maximum. See `setRenderRate`.
        link.preferredFrameRateRange = renderRange
        link.add(to: .main, forMode: .common)
        followLink = link
        // A newly-created link starts while the renderer is still carrying the
        // ordinary model range. Promote both immediately; relying on the first
        // camera-change callback misses the case where that first camera write
        // is correctly elided as a no-op.
        setRenderRate()
        return true
    }

    private func wakeFollowLink() {
        guard locationActive, let followLink, followLink.isPaused else { return }
        followLink.isPaused = false
        // Restore the follow rate after scene suspension or a style reload.
        setRenderRate()
    }

    private func pauseFollowLink() {
        guard let followLink, !followLink.isPaused else { return }
        followLink.isPaused = true
        // Pause interpolation during scene suspension or a style reload.
        setRenderRate()
    }

    /// Stop predicting, and put the followed vehicle back with the others.
    private func endFollowing() {
        followLink?.invalidate()
        followLink = nil
        // `CADisplayLink.invalidate()` stops our callback, not Mapbox's. Put
        // the renderer back on the ordinary model budget even if clearing the
        // follow padding below turns out to be a camera no-op.
        setRenderRate()
        followAnchor = nil
        followVelocity = (0, 0)
        followWatched = nil
        followRenderContext = nil
        drawnFollowShapeFeatures = nil
        drawnFollowPointFeature = nil
        resetFollowShapeTranslate()
        clearCatchup()
        // Whether *this* call is the one that ended a follow, as against one of
        // the several that tidy up after it. It decides the camera reset below
        // and nothing else.
        let wasFollowing = followId != nil
        followId = nil
        followShape = nil
        followedStandingVehicle = nil
        clearFollowFadeState()
        followBearing = nil
        followBearingRate = 0
        acquiringFollowBearing = false
        freezeFollowHeading = false
        followZoomTo = nil
        followZoomFrom = nil
        guard let mapView, styleReady else { drewFollowShape = false; return }

        // **The footprint goes because there is one, not because this call
        // happens to be the one that ended the follow.** That distinction is
        // the whole of a bug: `followId` is reassigned on the model's tick and
        // cleared the moment the follow stops, so by the time the display link
        // next runs and calls this, `followId` is already nil — and the guard
        // that used to stand here read that as "nothing to clean up" and
        // returned before emptying the source. What was left was the last frame
        // of the drawn train, painted on the map at the position and the zoom
        // it had when the follow ended, while the vehicle's own dot carried on
        // up the valley without it.
        if drewFollowShape {
            drewFollowShape = false
            resetFollowShapeTranslate(in: mapView.mapboxMap)
            mapView.mapboxMap.updateGeoJSONSource(
                withId: VehicleShapes.followSource,
                geoJSON: .featureCollection(FeatureCollection(features: []))
            )
        }
        guard wasFollowing else { return }
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
    private func followMapTime(at displayTime: CFTimeInterval? = nil) -> Double {
        let now = model.clock.now()
        guard let displayTime, model.clock.isPlaying else { return now }
        let realLead = max(0, displayTime - CACurrentMediaTime())
        return now + realLead * model.clock.speed
    }

    private func followShift(at displayTime: CFTimeInterval? = nil) -> (lon: Double, lat: Double) {
        guard followAnchor != nil else { return (0, 0) }
        // A display link names the frame it is preparing, not merely the instant
        // its callback happened. Carry the map clock through that last fraction
        // of a frame at the selected playback speed. Non-display callers keep
        // using the clock's current instant.
        let target = followMapTime(at: displayTime)
        let ahead = min(max(0, target - followStamp), Self.followPredictAtMost)
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
    private func stepCatchup(at displayTime: CFTimeInterval) {
        guard catchupEast != 0 || catchupNorth != 0
                || catchupEastRate != 0 || catchupNorthRate != 0
        else { return }
        let elapsed = catchupStamp == 0 ? 0 : displayTime - catchupStamp
        catchupStamp = displayTime
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
    private func followFrame(at displayTime: CFTimeInterval) {
        guard model.isFollowingVehicle, let anchor = followAnchor, let mapView else {
            endFollowing()
            return
        }
        // A basemap reload temporarily has no sources to update. Keep the
        // follow state, but put its link to sleep until `installLayers` has
        // recreated them; ending here caused a visible body/camera hitch on
        // every style switch.
        guard styleReady else {
            pauseFollowLink()
            return
        }

        stepCatchup(at: displayTime)
        let shift = followShift(at: displayTime)
        let lon = anchor.lon + shift.lon
        let lat = anchor.lat + shift.lat

        // Handed over by the model with the position, rather than found here.
        // This runs at the display's rate, and searching the viewport's
        // vehicles for one of them a hundred and twenty times a second is work
        // on the main thread that buys a value which changes thirty.
        let watched = followWatched

        // Once the rake has vanished into the bore, the thing on screen is the
        // tunnel marker — a point. The follow padding is for watching the road
        // ahead of a train, and applied to a dot it leaves the camera looking
        // at empty hillside in front of an invisible body.
        let followTheDot = (followRenderContext?.underground ?? false)
            && !followFadeInProgress
        let inset = followTheDot
            ? UIEdgeInsets.zero
            : Self.followInset(in: mapView.bounds.height, low: model.followLockLow)
        let bearing = cameraBearing(towards: watched?.bearing, at: displayTime)
        let zoom = followZoom(at: displayTime, from: mapView.mapboxMap.cameraState.zoom)
        let current = mapView.mapboxMap.cameraState
        let centreChanged = abs(current.center.longitude - lon) > Self.followCoordinateEpsilon
            || abs(current.center.latitude - lat) > Self.followCoordinateEpsilon
        let bearingChanged = bearing.map {
            Self.bearingDistance(current.bearing, $0) > Self.followBearingEpsilon
        } ?? false
        let zoomChanged = zoom.map { abs(current.zoom - $0) > 0.002 } ?? false
        if centreChanged || current.padding != inset || bearingChanged || zoomChanged {
            var camera = CameraOptions(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                padding: inset
            )
            camera.bearing = bearing.map { CGFloat($0) }
            camera.zoom = zoom.map { CGFloat($0) }
            mapView.mapboxMap.setCamera(to: camera)
        }

        let style: MapboxMap = mapView.mapboxMap
        if let shape = followShape, !followTheDot {
            // From one translated footprint, in one write. This lane runs at
            // the display's rate rather than the model's, so it is the one
            // place where three separate writes would have been most visible.
            drewFollowShape = true
            drawFollowShape(
                shape, shift: shift, style: style, mapView: mapView, at: displayTime
            )
        } else if drewFollowShape {
            // **The vehicle has stopped being drawn as a vehicle, and what was
            // left behind was the last frame of it.**
            //
            // A footprint is only built while the vehicle is long enough on
            // screen to be worth one — see `AppModel.rebuildShapes` — so zooming
            // out far enough takes `followShape` away while the follow is still
            // running. This branch did not exist: the write above was simply
            // skipped, and a source nobody writes keeps what it has. So the
            // train stayed painted on the map at the position and the zoom it
            // had when it was last built, while its own dot went on up the
            // valley without it. At zoom 12 that is a train sitting in a field
            // half a kilometre behind the marker naming it.
            //
            // Cleared once rather than every frame: this lane runs at the
            // display's rate and re-emptying an empty source sixty times a
            // second is sixty parses of nothing.
            followedStandingVehicle = nil
            clearFollowFadeState(in: style)
            drewFollowShape = false
            drawnFollowShapeFeatures = []
            resetFollowShapeTranslate(in: style)
            style.updateGeoJSONSource(
                withId: VehicleShapes.followSource,
                geoJSON: .featureCollection(FeatureCollection(features: []))
            )
        } else {
            followedStandingVehicle = nil
            clearFollowFadeState(in: style)
            drawnFollowShapeFeatures = []
        }
        // The dot and its line label hang off the point source, and they have to
        // travel with the body or the label swims beside the train it names.
        //
        // Rebuilt whole rather than moved. `updateGeoJSONSourceFeatures`
        // *replaces* the feature it matches, so anything left out of it is left
        // out of the source — see `vehicleFeature`.
        if let vehicle = watched {
            let position = Coord(
                lon: vehicle.lon + shift.lon, lat: vehicle.lat + shift.lat
            )
            updateRouteProgress(vehicle: vehicle, position: position)
            let marker = tunnelMarker(for: vehicle, at: position)
            let feature = Self.vehicleFeature(
                vehicle,
                at: position,
                selected: true,
                emerged: Cableway.hangs(vehicle)
                        && followedStandingVehicle == vehicle.id
                    ? followShape?.emergence ?? 1
                    : displayedVehicleEmergence[vehicle.id]
                        ?? followShape?.emergence ?? 0,
                tunnel: marker.fade, tunnelAltitude: marker.altitude,
                // **The open flag, and leaving it to default was the whole
                // of why the line number would not go away.**
                //
                // This lane rewrites the followed vehicle's own feature at
                // the display's rate — sixty times a second against the
                // model's thirty — so whatever it puts here is what the
                // label layers actually see. Built without this the feature
                // came back every frame saying it was not the open vehicle,
                // which put its number straight back into the layer that
                // never fades. The main lane was setting the flag correctly
                // and being overwritten before it could be drawn.
                // Read off `labelOpenId` rather than asserted: this lane
                // rewrites the feature sixty times a second, so it decides
                // what the label layers see, and it must say the same thing
                // the other lane is saying or the two fight. During the tick
                // a selection is handed over they differ, which is exactly
                // when getting it wrong would fade the wrong vehicle.
                open: vehicle.id == labelOpenId,
                label: Cableway.hangs(vehicle) && !cablewayLabelIDs.contains(vehicle.id)
                    ? "" : vehicle.displayLine
            )
            if feature != drawnFollowPointFeature {
                drawnFollowPointFeature = feature
                style.updateGeoJSONSourceFeatures(
                    forSourceId: ID.vehicles, features: [feature],
                    dataId: GeoJSONQueueProbe.shared.stamp(.followPoint, at: displayTime)
                )
            }
        } else {
            drawnFollowPointFeature = nil
        }

        // Keep the visible follow lane on its 60 Hz clock. Feature equality
        // above avoids redundant uploads when the train is standing still.
    }

    /// Draw the followed body. Tessellate when the drawing, heading bucket,
    /// wagon count, tunnel fade or ~40 m of travel requires it; between those,
    /// slide the already-tiled mesh.
    ///
    /// The camera and the 2D footprint move synchronously (`setCamera`,
    /// `fill-translate`). Wagons are point features, so they ride a layer
    /// `model-translation` in metres from the last baked origin. Rebuilding
    /// the source every model tick zeroed that translation on the next frame
    /// while Mapbox's GeoJSON queue still held the previous points — the rake
    /// shaking in every direction, worse as the queue lagged.
    private func drawFollowShape(
        _ shape: VehicleFootprint,
        shift: (lon: Double, lat: Double),
        style: MapboxMap,
        mapView: MapView,
        at displayTime: CFTimeInterval
    ) {
        let anchor = followAnchor ?? Coord(lon: 0, lat: 0)
        let displayed = Coord(lon: anchor.lon + shift.lon, lat: anchor.lat + shift.lat)
        if followPendingOrigin != nil,
           followPendingStamp > 0,
           displayTime - followPendingStamp > Self.followBakeTimeout {
            commitFollowBake(dataId: followPendingDataId, force: true)
        }
        if let origin = followUploadedAt {
            applyFollowShapeMotion(from: origin, to: displayed, style: style, mapView: mapView)
        }

        let heading = shape.placements.first?.heading ?? followWatched?.bearing ?? 0
        let drawing = FollowDrawingKey(
            showingSolids: showingSolids,
            bakedModels: model.bakedModels,
            lampsLit: lampsLit,
            ghostTunnels: model.ghostTunnels,
            hitboxes: model.showWagonHitboxes,
            underground: followRenderContext?.underground ?? false,
            tunnelRevision: model.tunnelRevision,
            emergence: shape.emergence,
            wagons: shape.placements.count
        )
        let travelled = followUploadedAt.map {
            Geo.flatMetres($0.lon, $0.lat, displayed.lon, displayed.lat)
        } ?? .infinity
        let headingMoved = followUploadedHeading.map {
            abs(Geo.unwrapHeading(heading, previous: $0) - $0) >= Self.followHeadingStep
        } ?? false
        let drawingChanged = followUploadedDrawing != drawing
        let modelMoved = followUploadedStamp != followStamp
        let rebuild = followPendingOrigin == nil && (
            followFadeInProgress
            || drawnFollowShapeFeatures == nil
            || drawingChanged
            || headingMoved
            || modelMoved
            || travelled >= Self.followRebuildMetres
        )
        if !rebuild {
            GeoJSONQueueProbe.shared.noteFollowWagons(
                solids: showingSolids,
                points: Self.modelFeatureCount(in: drawnFollowShapeFeatures ?? []),
                rebuilt: false,
                patched: 0
            )
            return
        }

        let moved = shape.shifted(byLon: shift.lon, lat: shift.lat)
        let features = Self.snappedFollowFade(vehicleDrawing(
            [moved], excluding: nil, flatness: 1, follow: true
        ))
        let wagons = Self.modelFeatureCount(in: features)
        let fadeSig = Self.followFadeSignature(features)
        followUploadedDrawing = drawing
        let fadeOnly = !drawingChanged && !headingMoved && !modelMoved
            && travelled < Self.followRebuildMetres
            && drawnFollowShapeFeatures != nil
        if fadeOnly, fadeSig == followUploadedFadeSig {
            GeoJSONQueueProbe.shared.noteFollowWagons(
                solids: showingSolids, points: wagons, rebuilt: false, patched: 0
            )
            return
        }
        if features == drawnFollowShapeFeatures {
            followUploadedHeading = heading
            followUploadedFadeSig = fadeSig
            followUploadedStamp = followStamp
            GeoJSONQueueProbe.shared.noteFollowWagons(
                solids: showingSolids, points: wagons, rebuilt: true, patched: 0
            )
            return
        }
        drawnFollowShapeFeatures = features
        let kind: GeoJSONQueueProbe.Kind = wagons > 0 ? .followWagons : .followShape
        let dataId = GeoJSONQueueProbe.shared.stamp(kind, at: displayTime)
            ?? "\(kind.rawValue):\(String(format: "%.6f", displayTime))"
        style.updateGeoJSONSource(
            withId: VehicleShapes.followSource,
            geoJSON: .featureCollection(FeatureCollection(features: features)),
            dataId: dataId
        )
        followUploadedHeading = heading
        followUploadedFadeSig = fadeSig
        followUploadedStamp = followStamp
        if followUploadedAt == nil {
            followUploadedAt = displayed
            followBakedHeading = heading
        } else {
            followPendingOrigin = displayed
            followPendingHeading = heading
            followPendingDataId = dataId
            followPendingStamp = displayTime
        }
        GeoJSONQueueProbe.shared.noteFollowWagons(
            solids: showingSolids, points: wagons, rebuilt: true, patched: 0
        )
    }

    /// Slide the already-baked follow drawing from `origin` onto `displayed`.
    ///
    /// Fill/line layers take a viewport pixel offset. Wagon models stay on
    /// their GeoJSON points — XY `model-translation` walks them off the rails.
    private func applyFollowShapeMotion(
        from origin: Coord, to displayed: Coord,
        style: MapboxMap, mapView: MapView
    ) {
        let from = CLLocationCoordinate2D(latitude: origin.lat, longitude: origin.lon)
        let dest = CLLocationCoordinate2D(latitude: displayed.lat, longitude: displayed.lon)
        let pixel0 = mapView.mapboxMap.point(for: from)
        let pixel1 = mapView.mapboxMap.point(for: dest)
        setFollowShapeTranslate(
            CGSize(width: pixel1.x - pixel0.x, height: pixel1.y - pixel0.y),
            on: style
        )
        if showingSolids {
            let moved = Geo.eastNorth(from: origin, to: displayed)
            VehicleModels.setFollowModelTranslation(
                style, east: moved.east, north: moved.north, lift: followModelLift
            )
            followModelTranslated = true
        } else {
            restoreFollowModelTranslation(style)
        }
    }

    /// The in-flight origin rebake is now the geometry on screen. Translation
    /// switches to this point on the same callback so the next frame does not
    /// add the old extra on top of the new points.
    private func commitFollowBake(dataId: String?, force: Bool = false) {
        guard let pending = followPendingOrigin else { return }
        if !force, let expected = followPendingDataId, dataId != expected { return }
        followUploadedAt = pending
        if let heading = followPendingHeading {
            followBakedHeading = heading
        }
        followPendingOrigin = nil
        followPendingHeading = nil
        followPendingDataId = nil
        followPendingStamp = 0
        guard let mapView, let anchor = followAnchor, styleReady else { return }
        let shift = followShift(at: CACurrentMediaTime())
        let displayed = Coord(lon: anchor.lon + shift.lon, lat: anchor.lat + shift.lat)
        applyFollowShapeMotion(
            from: pending, to: displayed, style: mapView.mapboxMap, mapView: mapView
        )
    }

    /// Quantise follow-lane wagon opacity onto the fade bands the layers
    /// actually filter on, so a tunnel ease does not rewrite GeoJSON 60 times
    /// a second for values the picture cannot show.
    private static func snappedFollowFade(_ features: [Feature]) -> [Feature] {
        features.map { feature in
            guard feature.properties?[VehicleShapes.Kind.key]
                    == .string(VehicleShapes.Kind.model),
                  var properties = feature.properties,
                  case let .number(opacity) = properties[VehicleModels.Placed.opacity]
            else { return feature }
            var next = feature
            properties[VehicleModels.Placed.opacity] = .number(
                VehicleModels.snappedOpacity(opacity)
            )
            next.properties = properties
            return next
        }
    }

    private static func followFadeSignature(_ features: [Feature]) -> Int {
        var hasher = Hasher()
        for feature in features {
            guard feature.properties?[VehicleShapes.Kind.key]
                    == .string(VehicleShapes.Kind.model),
                  case let .number(opacity) = feature.properties?[VehicleModels.Placed.opacity]
            else { continue }
            hasher.combine(opacity)
        }
        return hasher.finalize()
    }

    private static func modelFeatureCount(in features: [Feature]) -> Int {
        features.reduce(0) { n, feature in
            feature.properties?[VehicleShapes.Kind.key] == .string(VehicleShapes.Kind.model)
                ? n + 1 : n
        }
    }

    private func setFollowShapeTranslate(_ offset: CGSize, on style: MapboxMap) {
        if followTranslateAnchorSet,
           abs(offset.width - followLayerTranslate.width) < 0.25,
           abs(offset.height - followLayerTranslate.height) < 0.25 {
            return
        }
        followLayerTranslate = offset
        let value = [Double(offset.width), Double(offset.height)]
        var wrote = false
        for layer in Self.followTranslateLayers {
            guard style.layerExists(withId: layer.id) else { continue }
            if !followTranslateAnchorSet {
                try? style.setLayerProperty(
                    for: layer.id, property: layer.anchor, value: "viewport"
                )
            }
            try? style.setLayerProperty(
                for: layer.id, property: layer.offset, value: value
            )
            wrote = true
        }
        if wrote { followTranslateAnchorSet = true }
    }

    private func resetFollowShapeTranslate(in style: MapboxMap? = nil) {
        followUploadedAt = nil
        followPendingOrigin = nil
        followPendingHeading = nil
        followPendingDataId = nil
        followPendingStamp = 0
        followUploadedHeading = nil
        followBakedHeading = nil
        followUploadedStamp = -1
        followUploadedFadeSig = nil
        followUploadedDrawing = nil
        let style = style ?? mapView?.mapboxMap
        if let style {
            setFollowShapeTranslate(.zero, on: style)
            restoreFollowModelTranslation(style)
        } else {
            followLayerTranslate = .zero
            followModelTranslated = false
        }
    }

    private func restoreFollowModelTranslation(_ style: MapboxMap) {
        guard followModelTranslated else { return }
        VehicleModels.restoreFollowModelTranslation(style)
        followModelTranslated = false
    }

    private struct FollowTranslateLayer {
        var id: String
        var offset: String
        var anchor: String
    }

    private static let followTranslateLayers: [FollowTranslateLayer] = [
        FollowTranslateLayer(
            id: VehicleShapes.followCasing,
            offset: "line-translate", anchor: "line-translate-anchor"
        ),
        FollowTranslateLayer(
            id: VehicleShapes.followFill,
            offset: "fill-translate", anchor: "fill-translate-anchor"
        ),
        FollowTranslateLayer(
            id: VehicleShapes.followGhost,
            offset: "fill-translate", anchor: "fill-translate-anchor"
        ),
        FollowTranslateLayer(
            id: VehicleShapes.followOutline,
            offset: "line-translate", anchor: "line-translate-anchor"
        ),
        FollowTranslateLayer(
            id: VehicleShapes.followXray,
            offset: "line-translate", anchor: "line-translate-anchor"
        ),
        FollowTranslateLayer(
            id: VehicleModels.followFill,
            offset: "fill-extrusion-translate",
            anchor: "fill-extrusion-translate-anchor"
        ),
        FollowTranslateLayer(
            id: VehicleLamps.followGlow,
            offset: "line-translate", anchor: "line-translate-anchor"
        ),
        FollowTranslateLayer(
            id: VehicleLamps.followCore,
            offset: "line-translate", anchor: "line-translate-anchor"
        ),
    ]

    private static let followCoordinateEpsilon = 1e-10
    private static let followBearingEpsilon = 0.001

    private static func bearingDistance(_ a: Double, _ b: Double) -> Double {
        let distance = abs((a - b).truncatingRemainder(dividingBy: 360))
        return min(distance, 360 - distance)
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
    ///
    /// A two-finger rotate (or the compass) owns the heading from then on.
    /// The spring would otherwise write the train's bearing back every
    /// refresh — Mapbox only reports the rotate after a few degrees, so
    /// without this the map twitches toward the fingers and then snaps onto
    /// the rake again the moment they lift.
    private func cameraBearing(
        towards heading: Double?, at displayTime: CFTimeInterval
    ) -> CLLocationDirection? {
        if compassCameraActive {
            dropFollowBearing()
            return nil
        }
        // Fingers are in a rotate gesture. Leave the heading where it is so
        // the spring cannot undo the turn; Mapbox may not have counted it as
        // a rotate yet.
        if rotationGestureActive {
            freezeFollowHeading = true
            return nil
        }
        // Gesture just ended. If the camera moved, keep it; if it did not
        // (a pinch that twisted a couple of degrees and was discarded),
        // resume the spring from where it froze.
        if freezeFollowHeading {
            freezeFollowHeading = false
            if let locked = followBearing,
               let now = mapView?.mapboxMap.cameraState.bearing,
               Self.bearingDistance(now, locked) > Self.followUserTurn {
                dropFollowBearing()
                return nil
            }
        }
        guard model.vehicleFollow == .bearing, let heading else {
            followBearing = nil
            followBearingRate = 0
            acquiringFollowBearing = false
            return nil
        }

        // A first frame has no elapsed time to integrate over, and a frame after
        // a stall — a backgrounded app, a jammed main thread — has far too much.
        // Both are treated as one frame at the display's nominal rate.
        let elapsed = followBearing == nil ? 0 : displayTime - followBearingStamp
        followBearingStamp = displayTime
        let step = elapsed > 0 && elapsed < 0.25 ? elapsed : 1.0 / 60

        guard let from = followBearing else {
            // Taking the mode on picks up wherever the map already points, so
            // the first frame is not a jump either.
            followBearing = mapView?.mapboxMap.cameraState.bearing ?? 0
            followBearingRate = 0
            acquiringFollowBearing = true
            return followBearing
        }

        let turned = Self.spring(
            from, towards: heading, rate: &followBearingRate,
            over: step,
            settlingIn: acquiringFollowBearing ? 0.22 : Self.bearingSettle,
            atMost: acquiringFollowBearing ? 540 : Self.bearingMaxRate
        )
        if acquiringFollowBearing,
           Self.bearingDistance(turned, heading) < 0.5,
           abs(followBearingRate) < 5 {
            acquiringFollowBearing = false
        }
        followBearing = turned
        return turned
    }

    /// How far the camera has to have been turned off the follow spring
    /// before that turn is read as the reader's, not noise on a frame.
    private static let followUserTurn = 5.0

    private var rotationGestureActive: Bool {
        switch mapView?.gestures.rotateGestureRecognizer.state {
        case .began, .changed: return true
        default: return false
        }
    }

    private func dropFollowBearing() {
        model.releaseFollowBearing()
        followBearing = nil
        followBearingRate = 0
        acquiringFollowBearing = false
        freezeFollowHeading = false
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
    static func followInset(in height: CGFloat, low: Bool = false) -> UIEdgeInsets {
        // Full-screen follow only has a strip of card at the bottom, so the
        // vehicle sits lower than it does over the ordinary sheet.
        UIEdgeInsets(top: 0, left: 0, bottom: max(0, height * (low ? 0.08 : 0.2)), right: 0)
    }

    /// Zoom the follow camera itself. A Mapbox ease is cancelled by the
    /// per-frame `setCamera` that holds the vehicle, so the approach used to
    /// land a fraction of a level per tap.
    private var followZoomTo: Double?
    private var followZoomFrom: Double?
    private var followZoomStarted: CFTimeInterval = 0
    private static let followZoomDuration: CFTimeInterval = 0.8

    private func followZoom(at displayTime: CFTimeInterval, from current: Double) -> Double? {
        guard let to = followZoomTo else { return nil }
        let origin = followZoomFrom ?? current
        if followZoomFrom == nil {
            followZoomFrom = current
            followZoomStarted = displayTime
        }
        let t = min(1, max(0, (displayTime - followZoomStarted) / Self.followZoomDuration))
        let eased = 1 - (1 - t) * (1 - t) * (1 - t)
        if t >= 1 {
            followZoomTo = nil
            followZoomFrom = nil
            return to
        }
        return origin + (to - origin) * eased
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
        tunnel: Double = 0, tunnelAltitude: Double? = nil,
        open: Bool = false, label: String? = nil
    ) -> Feature {
        var feature = Feature(geometry: .point(Point(
            CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon)
        )))
        feature.identifier = .string(vehicle.id)
        // The ordinary dot yields to a small tunnel marker as the body vanishes.
        let shown = (1 - emerged) * (1 - tunnel)
        feature.properties = [
            "id": .string(vehicle.id),
            "line": .string(label ?? Journey.badgeLine(vehicle.displayLine, extra: vehicle.extra, mode: vehicle.mode)),
            "color": .string(vehicle.mode.hex),
            "bearing": .number(vehicle.bearing),
            "selected": .boolean(selected),
            "cancelled": .boolean(vehicle.cancelled),
            "cableDot": .boolean(vehicle.mode == .cable),
            "fade": .number(shown),
            // Not all the way to nothing: the dot is invisible well before it
            // is gone, and a radius that reaches zero makes the last of the
            // fade happen in a disc too small to see it happen in.
            "shrink": .number(1 - 0.7 * emerged),
            "tunnel": .boolean(tunnel > 0.15),
            "tunnelFade": .number(tunnel),
            "tunnelIcon": .string(VehicleDot.tunnelImageName(vehicle.mode, selected: selected)),
            "tunnelElevationKnown": .boolean(tunnelAltitude != nil),
            "tunnelAltitude": .number(tunnelAltitude ?? 0),
            // Whether this is the vehicle whose panel is open. It decides
            // which of the two label layers draws this vehicle's number, and
            // nothing else — the fade itself belongs to the layer. See
            // `VehicleDot.labelHideZoom`.
            "open": .boolean(open),
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
        #if DEBUG
        // A deterministic picker preview for checking phone layout and edge
        // placement without waiting for two live vehicles to overlap.
        if UserDefaults.standard.bool(forKey: "previewMapPicker") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let mapView = self.mapView else { return }
                self.lastTapPoint = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
                let examples = [("9", "Wabern"), ("3", "Bern, Bahnhof")]
                self.presentChoices(examples.map { line, destination in
                    .vehicle(VehicleSnapshot(
                        id: "picker-preview-\(line)", mode: .tram, category: "T", line: line,
                        operatorName: "Bernmobil", to: destination, from: "Bern",
                        lon: start.lon, lat: start.lat, stops: []
                    ), distance: 0)
                })
            }
            return
        }
        #endif
        let ease = beginEaseCamera()
        mapView.camera.ease(
            to: CameraOptions(
                center: CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon),
                zoom: start.zoom,
                bearing: start.bearing,
                pitch: start.pitch.map { CGFloat($0) }
            ),
            duration: 0.4
        ) { [weak self] _ in
            self?.endEaseCamera(ease)
        }
        #if DEBUG
        if let city = UserDefaults.standard.string(forKey: "selectCityLabel") {
            tapCityLabelForDebugStart(city)
            return
        }
        #endif
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
        pauseFollowLink()
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
        guard theme == .standard, lightPreset != currentPreset else { return }
        currentPreset = lightPreset
        let camera = mapView?.mapboxMap.cameraState
        let pitch = camera.map { Double($0.pitch) } ?? model.pitch
        let zoom = camera.map { Double($0.zoom) } ?? model.zoom
        Terrain3D.applyStandardConfig(
            style, preset: lightPreset, buildings: model.buildings3D,
            trees: model.buildings3D && pitch < Terrain3D.treePitchLimit,
            landmarks: model.buildings3D && zoom >= Terrain3D.landmarkMinZoom
        )
        applyHorizon(style)
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
    private var drawn3D: (
        terrain: Bool, exaggeration: Double, buildings: Bool,
        trees: Bool, landmarks: Bool
    )?
    private var drawnHorizon: (bucket: Int, dark: Bool, on: Bool)?

    /// Put the relief, the air and the buildings where the settings say.
    private func apply3D(_ style: MapboxMap) {
        let exaggeration = model.thermalCapsTerrain
            ? min(1, model.terrainExaggeration)
            : model.terrainExaggeration
        let camera = mapView?.mapboxMap.cameraState
        let pitch = camera.map { Double($0.pitch) } ?? model.pitch
        let zoom = camera.map { Double($0.zoom) } ?? model.zoom
        let wanted = (
            terrain: model.terrain3D,
            exaggeration: exaggeration,
            buildings: model.buildings3D,
            trees: model.buildings3D && pitch < Terrain3D.treePitchLimit,
            landmarks: model.buildings3D && zoom >= Terrain3D.landmarkMinZoom
        )
        guard drawn3D == nil || drawn3D! != wanted else {
            applyHorizon(style)
            return
        }
        drawn3D = wanted

        Terrain3D.apply(style, on: wanted.terrain, exaggeration: wanted.exaggeration)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "terrainRenderingAudit") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, let map = self.mapView?.mapboxMap else { return }
                let source: Any = map.terrainProperty("source")
                let exaggeration: Any = map.terrainProperty("exaggeration")
                let audit = "TERRAIN AUDIT toggle=\(self.model.terrain3D) source=\(source) exaggeration=\(exaggeration) elevation=\(String(describing: map.elevation(at: map.cameraState.center))) camera=\(map.cameraState)"
                try? audit.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("terrain-audit.txt"), atomically: true, encoding: .utf8)
            }
        }
        #endif
        applyHorizon(style)
        // Terrain on must not leave the display link at `.default`. DEM
        // streaming for a couple of seconds is fine; 40 s of 60 Hz is not.
        setRenderRate()
        if theme.hasOwnBuildings {
            // Standard draws its own, and asks for them by name. The preset it
            // is asked for is whatever the setting says right now; keeping it
            // there afterwards is `applyLightPreset`'s job.
            currentPreset = lightPreset
            Terrain3D.applyStandardConfig(
                style, preset: lightPreset, buildings: wanted.buildings,
                trees: wanted.trees, landmarks: wanted.landmarks
            )
        }
    }

    /// Fog and 3D-object far clip. Gated on a 2° pitch bucket so a tilt
    /// does not rewrite the style per refresh.
    private func applyHorizon(_ style: MapboxMap) {
        let camera = mapView?.mapboxMap.cameraState
        let pitch = camera.map { Double($0.pitch) } ?? 0
        let zoom = camera.map { Double($0.zoom) } ?? model.zoom
        let dark = isDarkTheme
        let on = pitch >= Geo.tiltLookAheadPitch && zoom >= 12
        let bucket = on ? Int((pitch / 2).rounded()) : 0
        let wanted = (bucket: bucket, dark: dark, on: on)
        if let drawn = drawnHorizon, drawn == wanted { return }
        drawnHorizon = wanted
        Terrain3D.applyHorizon(style, pitch: pitch, zoom: zoom, dark: dark)
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
    private var appliedOccluders: Bool?

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
    /// When the turn last bought a tick, so a spin cannot buy one per camera
    /// event. See `applySolidity`.
    private var lampTickAt: CFTimeInterval = 0

    private func applySolidity() {
        guard styleReady, let mapView else { return }
        defer {
            // Ghost, x-ray and lamp layers can be switched on here. If the
            // route overlay has asked the fleet off, put them straight back.
            if !vehiclesVisible { applyVehicleOverlayVisibility() }
        }
        let camera = mapView.mapboxMap.cameraState
        let wanted = model.detailedVehicles && model.solidVehicles
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
            //
            // **And no more than thirty of those a second, which is the whole
            // of "rotating at zoom 20 drops the map to five frames".** The
            // angle is the right threshold and it is not a rate: `requestTick`
            // coalesces to one running and one queued, so it does not pile up —
            // it runs ticks back to back as fast as they finish, and a spin at
            // two hundred degrees a second clears a degree and a half every
            // seven milliseconds. That asks the main actor for a hundred and
            // thirty full ticks a second — the fleet queried, every footprint
            // rebuilt, every source uploaded — on a loop that has never asked
            // itself for more than thirty, and it asks for them *from inside a
            // camera callback*, so the renderer is competing with them for the
            // same thread. What the reader sees is the map stopping while they
            // turn it.
            //
            // Capped, the lamps trail the turn by at most a thirtieth of a
            // second mid-spin and are exact the moment it stops, because the
            // camera event that ends the gesture finds the gate open.
            let turned = abs(
                (camera.bearing - lampCamera).truncatingRemainder(dividingBy: 360)
            )
            let now = CACurrentMediaTime()
            if min(turned, 360 - turned) > 1.5, now - lampTickAt > 1.0 / 30 {
                lampCamera = camera.bearing
                lampTickAt = now
                model.requestTick()
            }
        }
        // Models on or off with zoom, not a fade. A mesh at half opacity is
        // a train with the rails visible through it.
        let solids = wanted > 0
        let baked = model.bakedModels
        // The second translucent footprint only has a job when terrain or a 3D
        // building can actually stand between the camera and the vehicle.
        let occluders = model.terrain3D
            || (model.buildings3D && theme.hasOwnBuildings)
        guard solids != showingSolids || baked != appliedBaked
                || occluders != appliedOccluders else { return }
        showingSolids = solids
        appliedSolidity = wanted
        appliedBaked = baked
        appliedOccluders = occluders
        // The flat drawing is about to be what the reader is reading again, so
        // it has to be drawn whole from the very next tick rather than from the
        // one after it. See `AppModel.standingVehicles`.
        if !(solids && baked) { model.standingVehicles = [] }
        VehicleModels.setSolidity(mapView.mapboxMap, baked || !solids ? 0 : 1)
        VehicleModels.setModelSolidity(mapView.mapboxMap, baked && solids)
        // And which of the two ways of showing a vehicle through a building is
        // in use. See `VehicleShapes.setXray`.
        VehicleShapes.setXray(
            mapView.mapboxMap, solids: baked && solids, occluders: occluders
        )
        model.requestTick()
    }

    /// How far the camera may lean, in degrees. Mapbox will take 85; 75 was a
    /// self-imposed ceiling so a flick could not plant the horizon across the
    /// middle of the phone. Following a train into a valley wants more of the
    /// track ahead than that left on the screen.
    private static let maxPitch: CGFloat = 85

    /// How far the fingers travel for a degree of pitch, near enough.
    ///
    /// The SDK's own number is 2, which wanted 150 points of travel to go from
    /// flat to the old 75° limit — most of a phone screen, for a gesture people
    /// perform as a flick. 1.6 takes the new 85° ceiling in about 135.
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
            customTiltActive = true
            markCameraBusy()
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
                pitch: max(0, min(Self.maxPitch, tiltStart - travelled / Self.tiltTravel))
            ))
        case .ended, .cancelled, .failed:
            guard tiltStart != nil else { return }
            tiltStart = nil
            mapView.mapboxMap.endGesture()
            customTiltActive = false
            reportViewport()
            if !userCameraBusy { settleCamera() }
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
        var box = BBox(west: west, south: south, east: east, north: north)
        let pitch = mapView.mapboxMap.cameraState.pitch
        if Double(pitch) >= Geo.tiltLookAheadPitch {
            let center = Coord(
                lon: mapView.mapboxMap.cameraState.center.longitude,
                lat: mapView.mapboxMap.cameraState.center.latitude
            )
            let cap = Geo.tiltedLookAheadMetres(
                metresPerPoint: metresPerPoint,
                screenHeight: rect.height,
                pitch: Double(pitch)
            )
            box = box.clamped(around: center, maxMetres: cap)
        }
        if model.viewport.moved(from: box, by: 1e-4) { model.viewport = box }
        let zoom = mapView.mapboxMap.cameraState.zoom
        if abs(model.zoom - zoom) > 0.01 { model.zoom = zoom }
        let scale = metresPerPoint
        if abs(model.metresPerPoint - scale) > scale * 0.01 { model.metresPerPoint = scale }
        // Guarded like the rest, and for the same reason — but half a degree
        // rather than something finer, because all the model does with the
        // pitch is decide whether the vehicles are worth slicing into solids,
        // and that answer moves in fiftieths across the whole useful range.
        if abs(model.pitch - pitch) > 0.5 { model.pitch = pitch }
        // Not guarded through the model at all: see `applySolidity`.
        applySolidity()
        apply3D(mapView.mapboxMap)
        applyHorizon(mapView.mapboxMap)
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

    private func handleTap(at point: CGPoint, coordinate: CLLocationCoordinate2D) {
        guard mapView != nil, choiceMenuAnchor?.isMenuVisible != true else { return }
        selectionTapTask?.cancel()
        let interaction = model.beginSelectionInteraction()
        selectionTapTask = Task { @MainActor [weak self] in
            await self?.select(at: point, coordinate: coordinate, interaction: interaction)
        }
    }

    private var selectionTapTask: Task<Void, Never>?

    /// Answer a touch, wherever it came from.
    private func select(
        at point: CGPoint, coordinate: CLLocationCoordinate2D, interaction: UInt64? = nil
    ) async {
        guard !Task.isCancelled, mapView != nil else { return }
        let interaction = interaction ?? model.beginSelectionInteraction()
        guard model.selectionInteractionIsCurrent(interaction) else { return }
        lastTapPoint = point
        if CityStation.isEnabled(at: Double(mapView?.mapboxMap.cameraState.zoom ?? .infinity)),
           let city = await cityLabel(at: point) {
            guard model.selectionInteractionIsCurrent(interaction),
                  CityStation.isEnabled(at: Double(mapView?.mapboxMap.cameraState.zoom ?? .infinity)) else { return }
            await model.openCityStation(named: city.name, near: city.centre, interaction: interaction)
            return
        }
        guard model.selectionInteractionIsCurrent(interaction) else { return }
        // The renderer and the CPU footprint, together. A 3D wagon at a
        // station sits above its ground plan, and the unprojected coordinate
        // of a tap on its side often lands in the station hall behind it —
        // which is how a tap on every train at Bern opened the station first.
        var hits = vehicleHits(at: point, coordinate: coordinate)
        // A touch inside a visible body can open synchronously. Do not leave
        // it waiting for a renderer query while the fleet keeps moving.
        let direct = hits.filter { $0.distance <= 0.5 }
        if !direct.isEmpty, model.selectVehicle(at: direct) { return }
        var seen = Set(hits.map(\.id))
        let drawnIDs = await renderedVehicleIds(at: point)
        guard model.selectionInteractionIsCurrent(interaction) else { return }
        for id in drawnIDs where seen.insert(id).inserted {
            hits.append(.init(id: id, distance: 0))
        }
        if model.selectVehicle(at: hits) { return }
        // The drawn shapes are asked about first, because asking is a round trip
        // through the renderer and the model's own answer does not depend on it.
        // What the shapes are *worth* is decided in the model, after every
        // marker has had its chance: a plate under the finger still beats the
        // slab it is standing on.
        let shapes = await shapesUnder(point)
        guard model.selectionInteractionIsCurrent(interaction) else { return }
        await model.handleTap(
            lon: coordinate.longitude, lat: coordinate.latitude, metresPerPoint: metresPerPoint,
            platformShapes: shapes.platforms, stationShapes: shapes.stations,
            stopDots: shapes.dots, solidTaps: solidTaps(at: coordinate), vehiclesChecked: true,
            interaction: interaction
        )
    }

    private var lastTapPoint = CGPoint.zero

    /// Query the rendered text, whose screen position can differ from the town
    /// centre. Standard exposes imported labels through its public featureset.
    private func cityLabel(at point: CGPoint) async -> (name: String, centre: Coord)? {
        guard styleReady, let mapView else { return nil }
        if theme == .standard {
            let labels: [StandardPlaceLabelsFeature] = await withCheckedContinuation { continuation in
                mapView.mapboxMap.queryRenderedFeatures(with: point, featureset: .standardPlaceLabels) {
                    continuation.resume(returning: (try? $0.get()) ?? [])
                }
            }
            for label in labels where label.class == "settlement" {
                guard let name = label.name, case let .point(location) = label.geometry else { continue }
                return (name, Coord(lon: location.coordinates.longitude, lat: location.coordinates.latitude))
            }
        } else {
            let layers = mapView.mapboxMap.allLayerIdentifiers.filter {
                $0.type == .symbol
                    && ($0.id.hasPrefix("settlement-") || $0.id.hasPrefix("place-"))
            }.map(\.id)
            for hit in await queriedFeatures(near: point, layers: layers, radius: 0) {
                let feature = hit.queriedFeature.feature
                guard case .string("settlement") = feature.properties?["class"] ?? nil,
                      case let .string(name) = feature.properties?["name"] ?? nil,
                      case let .point(location) = feature.geometry else { continue }
                return (name, Coord(lon: location.coordinates.longitude, lat: location.coordinates.latitude))
            }
        }
        return nil
    }

    #if DEBUG
    /// Find the text actually painted by the basemap, then exercise the same
    /// handler as a touch. This keeps UI checks independent of label placement.
    private func tapCityLabelForDebugStart(_ name: String) {
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, let mapView = self.mapView else { return }
                let labels: [StandardPlaceLabelsFeature] = await withCheckedContinuation { continuation in
                    mapView.mapboxMap.queryRenderedFeatures(featureset: .standardPlaceLabels) {
                        continuation.resume(returning: (try? $0.get()) ?? [])
                    }
                }
                Diagnostics.note("city label probe zoom=\(mapView.mapboxMap.cameraState.zoom) labels=\(labels.map { "\($0.name ?? "?"):\($0.class ?? "?")" })")
                guard let label = labels.first(where: { $0.name == name && $0.class == "settlement" }),
                      case let .point(location) = label.geometry else { continue }
                let origin = mapView.mapboxMap.point(for: location.coordinates)
                for dy in [0.0, -12, 12, -24, 24] {
                    for dx in [0.0, -16, 16, -32, 32, -64, 64] {
                        let point = CGPoint(x: origin.x + dx, y: origin.y + dy)
                        guard mapView.bounds.contains(point), await self.cityLabel(at: point)?.name == name else { continue }
                        self.handleTap(at: point, coordinate: mapView.mapboxMap.coordinate(for: point))
                        return
                    }
                }
            }
        }
    }
    #endif
    private var choicePopover: MapChoicePopover?
    private var choiceMenuAnchor: MapChoiceButton?

    private func presentChoices(_ options: [TapChoice]) {
        guard let mapView, !options.isEmpty, var presenter = mapView.window?.rootViewController else { return }
        if #available(iOS 17.4, *) {
            let anchor = choiceMenuAnchor ?? MapChoiceButton(type: .system)
            if anchor.superview == nil { mapView.addSubview(anchor) }
            choiceMenuAnchor = anchor
            anchor.frame = CGRect(origin: lastTapPoint, size: CGSize(width: 2, height: 2))
            anchor.showsMenuAsPrimaryAction = true
            anchor.preferredMenuElementOrder = .fixed
            anchor.accessibilityElementsHidden = true
            anchor.menu = UIMenu(children: options.map { option in
                UIAction(title: option.menuTitle, image: option.menuImage) { [weak self, weak anchor] _ in
                    guard let self else { return }
                    let revision = self.model.beginSelectionInteraction()
                    anchor?.selectionAction = { [weak self] in
                        guard let self, self.model.selectionInteractionIsCurrent(revision) else { return }
                        self.model.choose(option, fromMap: true)
                    }
                }
            })
            anchor.performPrimaryAction()
            return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let picker = MapChoicePopover(options: options) { [weak self] option in
            guard let self else { return }
            self.choicePopover?.dismiss(animated: true) { [weak self] in
                self?.choicePopover = nil
                self?.model.choose(option, fromMap: true)
            }
        }
        picker.preferredContentSize = CGSize(
            width: min(340, mapView.bounds.width - 32),
            height: min(CGFloat(options.count) * 48, mapView.bounds.height * 0.6)
        )
        if let popover = picker.popoverPresentationController {
            popover.sourceView = mapView
            popover.sourceRect = CGRect(origin: lastTapPoint, size: CGSize(width: 1, height: 1))
            popover.permittedArrowDirections = []
            popover.backgroundColor = .clear
        }
        choicePopover = picker
        presenter.present(picker, animated: true)
    }

    /// Measure the visible coach polygons in screen points. A platform below
    /// them cannot shrink this target, and tilted maps keep the same tolerance.
    private func vehicleHits(at point: CGPoint, coordinate: CLLocationCoordinate2D) -> [VehicleTap.Hit] {
        guard vehiclesVisible, let mapView else { return [] }
        func project(_ at: Coord) -> VehicleTap.Point {
            let p = mapView.mapboxMap.point(for: CLLocationCoordinate2D(latitude: at.lat, longitude: at.lon))
            return .init(Double(p.x), Double(p.y))
        }
        let touch = VehicleTap.Point(Double(point.x), Double(point.y))
        let lifted = solidTaps(at: coordinate).map(project)
        let shift = followId == nil ? (lon: 0.0, lat: 0.0) : followShift()
        var hits: [VehicleTap.Hit] = []
        for vehicle in model.vehicles {
            let moved = vehicle.id == followId
            func shifted(_ at: Coord) -> Coord {
                Coord(lon: at.lon + (moved ? shift.lon : 0), lat: at.lat + (moved ? shift.lat : 0))
            }
            let position = shifted(Coord(lon: vehicle.lon, lat: vehicle.lat))
            // Underground symbols are queried at their rendered altitude above.
            if tunnelMarker(for: vehicle, at: position).fade >= 0.95 { continue }
            let shape = moved ? (followShape ?? model.shapesByID[vehicle.id]) : model.shapesByID[vehicle.id]
            let emergence = displayedVehicleEmergence[vehicle.id] ?? shape?.emergence ?? 0
            var distance = Double.infinity
            if let shape, !shape.hanging {
                // The 3D wagon is drawn *above* this plan. Offset the plan by
                // the same screen vector the renderer uses, so a tap on the
                // side of an IC at Bern hits the IC and not the hall behind it.
                let lift = screenLift(from: position, height: Self.tapBodyHeight(vehicle.mode))
                let half = max(shape.widthPoints / 2, 6)
                let line = shape.centreline.map { project(shifted($0)) }
                distance = min(
                    distance,
                    max(0, VehicleTap.distance(from: touch, toLine: line) - half),
                    max(0, VehicleTap.distance(from: touch, toLine: line.map { $0 + lift }) - half)
                )
                for part in shape.parts where part.role == .body {
                    let polygon = part.ring.map { project(shifted($0)) }
                    distance = min(distance, VehicleTap.distance(from: touch, to: polygon))
                    if lift != .zero {
                        distance = min(
                            distance,
                            VehicleTap.distance(from: touch, to: polygon.map { $0 + lift })
                        )
                    }
                    for p in lifted {
                        distance = min(distance, VehicleTap.distance(from: p, to: polygon))
                    }
                }
            }
            if emergence < 1 || shape == nil {
                let p = project(position)
                distance = min(distance, max(0, hypot(touch.x - p.x, touch.y - p.y) - VehicleDot.radius(atZoom: model.zoom)))
            }
            if distance <= VehicleTap.reach { hits.append(.init(id: vehicle.id, distance: distance)) }
        }
        return hits
    }

    /// How tall a vehicle is treated for hit-testing, in metres.
    ///
    /// The drawing is taller than the real thing — exaggeration is how a
    /// three-metre body reads as a body — and a tap is aimed at what is drawn.
    private static func tapBodyHeight(_ mode: Mode) -> Double {
        mode == .train ? 4.8 : 3.4
    }

    /// The screen vector from a ground point to the same point raised by
    /// `height` metres, which is where a solid wagon is actually painted.
    private func screenLift(from ground: Coord, height: Double) -> VehicleTap.Point {
        guard let mapView, height > 0 else { return .zero }
        let camera = mapView.mapboxMap.cameraState
        let pitch = Double(camera.pitch)
        guard pitch > 0.5 else { return .zero }
        let lean = tan(Geo.toRad(min(pitch, Double(Self.maxPitch) - 5)))
        let metres = height * lean
        guard metres > 0.2 else { return .zero }
        let raised = Geo.moved(ground, bearing: camera.bearing, metres: metres)
        let a = mapView.mapboxMap.point(
            for: CLLocationCoordinate2D(latitude: ground.lat, longitude: ground.lon)
        )
        let b = mapView.mapboxMap.point(
            for: CLLocationCoordinate2D(latitude: raised.lat, longitude: raised.lon)
        )
        return .init(Double(b.x - a.x), Double(b.y - a.y))
    }

    /// Vehicle ids the renderer is actually painting under the finger.
    private func renderedVehicleIds(at point: CGPoint) async -> [String] {
        guard vehiclesVisible else { return [] }
        let layers = VehicleDot.tunnelLayers(source: ID.vehicles)
            + ["\(ID.vehicles)-halo-selected", "\(ID.vehicles)-cable-dot-selected", "\(ID.vehicles)-halo", "\(ID.vehicles)-label", "\(ID.vehicles)-cable-dot", Self.openLabelLayer]
            + VehicleShapes.tapLayers
            + VehicleModels.tapLayers
        let found = await queriedFeatures(near: point, layers: layers, radius: 10)
        var seen = Set<String>()
        var ids: [String] = []
        let known = Set(model.vehicles.map(\.id))
        for hit in found {
            guard let id = Self.vehicleId(of: hit.queriedFeature.feature), known.contains(id),
                  seen.insert(id).inserted
            else { continue }
            ids.append(id)
        }
        return ids
    }

    private static func vehicleId(of feature: Feature) -> String? {
        if case let .string(text) = feature.properties?[VehicleShapes.vehicleIdKey] ?? nil {
            return text
        }
        if case let .string(text) = feature.properties?["id"] ?? nil { return text }
        if case let .string(text) = feature.identifier {
            if text.hasPrefix("m:") {
                let rest = text.dropFirst(2)
                if let last = rest.lastIndex(of: ":") { return String(rest[..<last]) }
            }
            return text
        }
        return nil
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
        guard vehiclesVisible, let mapView, model.solidity > 0 else { return [] }
        let camera = mapView.mapboxMap.cameraState
        let pitch = Double(camera.pitch)
        guard pitch > 0.5 else { return [] }
        // Capped short of the horizon: `tan` runs away there, and a correction
        // measured in hundreds of metres is not a hitbox, it is a lottery.
        let lean = tan(Geo.toRad(min(pitch, Double(Self.maxPitch) - 5)))
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
        var seen = Set<String>()
        var out: [String] = []
        for hit in await queriedFeatures(near: point, layers: layers, radius: radius) {
            guard let id = Self.identifier(of: hit.queriedFeature.feature) else { continue }
            let key = "\(hit.queriedFeature.sourceLayer ?? ""):\(id)"
            if seen.insert(key).inserted { out.append(id) }
        }
        return out
    }

    private func queriedFeatures(
        near point: CGPoint, layers: [String], radius: CGFloat
    ) async -> [QueriedRenderedFeature] {
        guard let mapView else { return [] }
        let present = layers.filter { mapView.mapboxMap.layerExists(withId: $0) }
        guard !present.isEmpty else { return [] }
        let box = CGRect(
            x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2
        )
        return await withCheckedContinuation { continuation in
            mapView.mapboxMap.queryRenderedFeatures(
                with: box, options: RenderedQueryOptions(layerIds: present, filter: nil)
            ) { result in
                continuation.resume(returning: (try? result.get()) ?? [])
            }
        }
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
        // The locate button hands the centre back to GPS immediately, even
        // while the selected train's detail panel remains open.
        model.mapWasDragged()
        if followId != nil { endFollowing() }
        centreAnimation?.cancel()
        centreAnimation = nil
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
        // Following the puck is a fix read for its own sake rather than for a
        // dot, and it puts the puck on screen by construction.
        applyLocationPolicy()
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
        let ease = beginEaseCamera()
        mapView.viewport.transition(
            to: state, transition: mapView.viewport.makeDefaultViewportTransition()
        ) { [weak self] _ in
            state.options.pitch = nil
            self?.endEaseCamera(ease)
        }
    }

    func focus(on coordinate: CLLocationCoordinate2D, zoom: Double? = nil) {
        guard let mapView else { return }
        // Whatever the map was following, it is not following it any more: this
        // is the app moving the camera somewhere else, and a follow state left
        // running would drag it straight back.
        model.mapWasDragged()
        if followId != nil { endFollowing() }
        mapView.viewport.idle()
        let ease = beginEaseCamera()
        centreAnimation = mapView.camera.ease(
            to: CameraOptions(center: coordinate, zoom: zoom ?? mapView.mapboxMap.cameraState.zoom),
            duration: 0.6
        ) { [weak self] _ in
            self?.endEaseCamera(ease)
        }
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
        if model.isFollowingVehicle {
            followZoomTo = zoom
            followZoomFrom = mapView.mapboxMap.cameraState.zoom
            followZoomStarted = CACurrentMediaTime()
            return
        }
        // Longer than a recentre. This is up to five zoom levels from a country
        // view, and taken at `focus`'s 0.6 s it is a lunge rather than an
        // approach — the ground scale goes past thirtyfold in the time it takes
        // to read the word.
        let ease = beginEaseCamera()
        mapView.camera.ease(to: CameraOptions(zoom: zoom), duration: 0.8) { [weak self] _ in
            self?.endEaseCamera(ease)
        }
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
        let ease = beginEaseCamera()
        centreAnimation = mapView.camera.ease(
            to: CameraOptions(center: CLLocationCoordinate2D(
                latitude: centre.latitude + dlat,
                longitude: centre.longitude + dlon
            )),
            duration: 0.75
        ) { [weak self] _ in
            self?.endEaseCamera(ease)
        }
    }

    /// Frame a whole run, so selecting a vehicle shows where it is going.
    func frame(_ path: [Coord]) {
        guard let mapView, path.count > 1 else { return }
        model.mapWasDragged()
        if followId != nil { endFollowing() }
        mapView.viewport.idle()
        let coordinates = path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let camera = try? mapView.mapboxMap.camera(
            for: coordinates,
            camera: CameraOptions(padding: .zero, bearing: 0, pitch: 0),
            coordinatesPadding: UIEdgeInsets(top: 140, left: 60,
                bottom: min(max(320, mapView.bounds.height * 0.42 + 48), mapView.bounds.height - 120), right: 60),
            maxZoom: 14, offset: nil
        ) else { return }
        let ease = beginEaseCamera()
        centreAnimation = mapView.camera.ease(to: camera, duration: 0.8) { [weak self] _ in
            self?.endEaseCamera(ease)
        }
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
            // Vehicle transforms and elevated route overlays use Mercator.
            // Do not inherit a globe transition from a replacement basemap:
            // elevated lines are unsupported there at low zoom.
            try style.setProjection(StyleProjection(name: .mercator))
            // The plates and kerb markers, before any layer asks for them.
            // Registering an image after the layer that names it leaves the
            // layer with nothing to draw and no error to say so.
            installChipImages(style)
            installStopDotImages(style)

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
                // Route progress and line trimming are measured over the
                // whole LineString. Without line metrics Mapbox trims each
                // tile's copy independently, making the travelled dots start
                // over at every tile boundary.
                if id == ID.route {
                    source.lineMetrics = true
                    source.tolerance = 0
                    source.maxzoom = 20
                    source.buffer = 128
                    source.prefetchZoomDelta = 0
                }
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
                    Mode.tram.hex
                    Mode.train.hex
                }
            )
            tracks.lineWidth = .expression(
                Exp(.interpolate) { Exp(.linear); Exp(.zoom); 8; 2.4; 12; 1.5; 16; 1.0 }
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
                RailwayLines.setVisible(style, model.usesORMTracks)
                RailwayLines.setOpacity(style, model.trackOpacity)
            } catch {
                Diagnostics.note("railway lines unavailable: \(error)")
            }

            // The dots where a service actually stops sit *on* the rails, so
            // they go above them — the one part of the overlay ORM also draws
            // over its own network.
            try? RailwayShapes.installStopPositions(style, dark: isDarkTheme)
            RailwayShapes.setVisible(style, model.showRailwayShapes)

            // Circle layers paint over the scene, including a vehicle standing
            // at this stop. Use the route's depth-tested dot icon instead.
            var routeStops = SymbolLayer(id: ID.routeStops, source: ID.routeStops)
            routeStops.iconImage = .constant(.name("transit-route-dot"))
            routeStops.iconSize = .expression(Exp(.interpolate) { Exp(.linear); Exp(.zoom); 10; 0.5; 16; 1.125 })
            routeStops.iconPitchAlignment = .constant(.map)
            routeStops.iconAllowOverlap = .constant(true)
            routeStops.iconIgnorePlacement = .constant(true)
            routeStops.iconOcclusionOpacity = .constant(0)
            routeStops.occlusionOpacityMode = .constant(.pixel)
            routeStops.iconEmissiveStrength = .constant(1)
            routeStops.slot = .middle
            routeStops.minZoom = 10
            try addLayer(routeStops, to: style)

            // Stops, in three bands.
            //
            // The bands are each layer's own `minZoom`/`maxZoom` rather than one
            // filter, because "from 12, and up to 16 unless there are no kerbs"
            // written as a single zoom expression is exactly the shape a style
            // rejects — and a rejected layer draws nothing at all, silently.
            // Three plain layers say the same thing and cannot fail that way.
            //
            // Symbols rather than circles: a circle paints over the scene, so
            // a bus stop on the far side of a block reads as a disc on the
            // roof. The route stop dots already made this swap; station dots
            // (rail and bus) use the same depth-tested icon.
            for band in StationBand.allCases {
                try addLayer(stationDotLayer(band), to: style)
            }

            // The ring on a selected station, under the same rules as the dot it
            // rings — without them it can outlive its own marker and hang over
            // the map with nothing inside it.
            try addLayer(stationRingLayer(), to: style)

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

            // Vehicles sit over the track overlay. Stop names and plates are
            // moved above them after all vehicle layers have been installed.
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
            // Out of `VehicleDot` rather than written here, because the model
            // reads the same curve to decide which of these dots are drawn
            // underneath another one and can be left out altogether. See
            // `AppModel.dotSpacing`.
            halo.circleRadius = .expression(VehicleDot.radiusExpression(shrunkBy: "shrink"))
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

            // What the gondolas hang from, under the vehicles that hang from
            // it. A cableway is scenery rather than a marker: the cabin flies
            // through the station and over the towers, so both have to be in
            // the style before it. Caught on its own — a map with gondolas and
            // no ropes is the map this app had until now.
            do {
                try Cableways.install(style)
            } catch {
                Diagnostics.note("cableways unavailable: \(error)")
            }

            // The vehicles themselves, over the dots they replace and under the
            // line numbers, which stay legible whatever is drawn beneath them.
            do {
                try VehicleShapes.install(style)
                // The route and its stop dots must precede the 3D model pass.
                // Installing them after the models paints them across roofs.
                try nativeRoute.install(style)
                try style.moveLayer(withId: ID.routeStops, to: .above(NativeRouteRenderer.layers.last!))
                try VehicleShapes.raiseSelectedFootprint(style, above: ID.routeStops)
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

            // Fallback dots are map markers, not ground-level cabin geometry.
            // Install after the scene's cables and buildings, with explicit
            // occlusion visibility. The normal emergence still removes them
            // once an actual cabin/funicular model is drawn.
            do {
                try VehicleDot.installCableOverlay(style, source: ID.vehicles)
                // Only retire their ground circles after the replacement is
                // installed, so a rejected icon cannot make a vehicle vanish.
                try style.setLayerProperty(
                    for: halo.id, property: "filter", value: ["!", ["get", "cableDot"]]
                )
            } catch {
                Diagnostics.note("cableway marker overlay unavailable: \(error)")
            }

            do {
                try VehicleDot.installTunnelOverlay(style, source: ID.vehicles)
            } catch {
                Diagnostics.note("tunnel marker overlay unavailable: \(error)")
            }

            // Two layers over one source, split on whether this is the vehicle
            // whose panel is open.
            //
            // **A filter and a plain number, rather than one layer with a
            // data-driven opacity.** The obvious way to write this is a single
            // layer whose `text-opacity` reads a value off each feature, and it
            // does not work — twice now the number stayed at full strength on
            // screen with no error anywhere, because a paint property the
            // renderer will not accept is not an error, it is a property that
            // silently keeps its default. There is nothing to debug and nothing
            // to see.
            //
            // Split in two there is no expression to refuse. Which layer draws
            // a vehicle is a filter, which is the most ordinary thing in the
            // style; what the open one's opacity is, is a single number on the
            // layer; and the fade between two numbers is
            // `text-opacity-transition`, which is what transitions are for and
            // which the renderer runs at its own frame rate rather than at the
            // model's tick. That last point is worth the extra layer on its
            // own: the hand-rolled ease this replaces stepped at fifteen a
            // second.
            var labels = SymbolLayer(id: "\(ID.vehicles)-label", source: ID.vehicles)
            // Asserted, like every other `get` in this file. A filter the
            // renderer will not read is a layer that draws nothing, and this
            // one carries every line number on the map.
            labels.filter = Exp(.not) { Exp(.toBoolean) { Exp(.get) { "open" } } }
            labels.textField = .expression(Exp(.get) { "line" })
            labels.textSize = .expression(
                Exp(.interpolate) {
                    Exp(.linear); Exp(.zoom)
                    11; 11.0; 15; 13.0; 18; 16.0
                }
            )
            // Gone over the vehicle the camera is holding, once the map is
            // close enough that the vehicle is the picture. `followed` is 0 on
            // everything else, so the whole product is 0 and their numbers are
            // untouched at every zoom.
            //
            // A ramp over a zoom band rather than a threshold, because a
            // threshold is what makes a label pop: a pinch through 16 would
            // take the number out between one frame and the next. Spread over a
            // zoom level, the number thins out as the vehicle grows into the
            // screen, which is the handover actually happening.
            // Gone over the vehicle the panel is open on, once the map is close
            // enough that the vehicle is the picture. Every other vehicle
            // carries 0 here and so is left at full strength at every zoom.
            //
            // **No zoom in the expression, and that is deliberate twice over.**
            // The fade is a function of time rather than of scale — see
            // `VehicleDot.labelFadeSeconds` — so the zoom is a decision the app
            // takes once and hands over as a number. It also keeps this legal
            // without having to think about it: a data-driven paint property
            // may only combine zoom and feature expressions with the zoom one
            // outermost, and nesting it inside the arithmetic gets the whole
            // property refused. What that costs is not this feature but every
            // line number on the map, which is a failure this layer has had
            // once already; see `text-allow-overlap` below.
            //
            // Asserted as a number, like every other `get` in this file: the
            // expression language is typed, and a property fetched without an
            // assertion has unknown type where arithmetic wants a number.
            labels.textOpacity = .expression(
                Exp(.subtract) { 1.0; Exp(.toNumber) { Exp(.get) { "followed" } } }
            )
            // Try the familiar position above the marker first, then use the
            // other three sides before giving up on the label. At a station
            // throat this keeps substantially more line numbers readable than
            // one fixed pile directly above the dots.
            labels.textVariableAnchor = .constant([.bottom, .top, .left, .right])
            labels.textJustify = .constant(.auto)
            labels.textRadialOffset = .constant(1.2)
            labels.textColor = .constant(StyleColor(UIColor.white))
            labels.textHaloColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.8)))
            labels.textHaloWidth = .constant(1.2)
            // Let the symbol collision index choose a readable subset in a
            // dense cluster. The dots remain visible, so this removes only a
            // name that could not have been read in the first place. Both
            // flags have to be false: `allow-overlap` keeps this label from
            // checking the index, while `ignore-placement` keeps it from
            // reserving its box for the labels considered after it.
            labels.textAllowOverlap = .constant(false)
            labels.textIgnorePlacement = .constant(false)
            // Default 0 hides a label that terrain occludes — which is every
            // number on a tunnel under a hill. The body has faded; the number
            // is what is left to follow, including through the mountain.
            labels.textOcclusionOpacity = .constant(1)
            labels.textEmissiveStrength = .constant(1)
            labels.symbolZElevate = .constant(true)
            labels.minZoom = VehicleDot.labelMinZoom

            // And the same layer again for the one vehicle that is open, whose
            // only difference is an opacity the app turns off close in.
            var openLabel = labels
            openLabel.id = Self.openLabelLayer
            openLabel.filter = Exp(.toBoolean) { Exp(.get) { "open" } }
            // The label a reader explicitly selected must not disappear just
            // because the station is busy. It claims its space before the
            // ordinary labels are considered, but never yields to a basemap
            // label underneath the transit overlay.
            openLabel.textAllowOverlap = .constant(true)
            openLabel.textOpacity = .constant(1)
            openLabel.textOpacityTransition = StyleTransition(
                duration: VehicleDot.labelFadeSeconds, delay: 0
            )
            try addLayer(openLabel, to: style)
            try addLayer(labels, to: style)

            // Names and plates are controls, so they win overlaps with
            // vehicles. Station dots sit on the ground in the middle slot
            // and must stay there — raising them into `top` paints a bus
            // stop across the roof of the building that stands on it.
            var topmost = try VehicleDot.raiseSelectedOverlays(
                style, source: ID.vehicles, above: labels.id
            )
            // Standard's top slot is below its place labels. Other basemaps
            // expose those labels directly, so move them above the route.
            for layer in style.allLayerIdentifiers where theme != .standard && basemapLayers.contains(layer.id) && layer.type == .symbol {
                let name = layer.id.lowercased()
                if name.contains("place") || name.contains("settlement") || name.contains("country") || name.contains("state-label") {
                    try style.moveLayer(withId: layer.id, to: .above(topmost))
                    topmost = layer.id
                }
            }
            let stopLayers = style.allLayerIdentifiers.filter {
                $0.id.hasPrefix("\(ID.stops)-label")
                    || $0.id.hasPrefix("\(ID.platforms)-plate")
            }
            for layer in stopLayers {
                try style.moveLayer(withId: layer.id, to: .above(topmost))
                topmost = layer.id
            }
            // The location puck stays above the complete transit overlay.
            installPuck(topmost: topmost)

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
            applyVehicleOverlayVisibility()
            wakeFollowLink()
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
                applyVehicleOverlayVisibility()
                wakeFollowLink()
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
        layer.textOcclusionOpacity = .constant(1)
        layer.textColor = .constant(StyleColor(UIColor(white: 0.85, alpha: 1)))
        layer.textHaloColor = .constant(StyleColor(UIColor.black.withAlphaComponent(0.85)))
        layer.textHaloWidth = .constant(1.3)
        layer.filter = filter
        layer.minZoom = minZoom
        return layer
    }

    // MARK: - Where you are

    private var puckVisible = true
    private var puckTopmost: String?

    /// Full-screen following hides the marker while location updates continue
    /// to serve ride detection. Restore it above the transit layers on exit.
    func setPuckVisible(_ visible: Bool) {
        guard puckVisible != visible else { return }
        puckVisible = visible
        if visible, let topmost = puckTopmost {
            installPuck(topmost: topmost)
        } else {
            mapView?.location.options.puckType = nil
        }
    }

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
        puckTopmost = topmost
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
        guard puckVisible else { return }
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
        // These values describe the previous style, not the user's settings.
        // Keeping them skips terrain/lighting on the replacement style until
        // the user toggles terrain, which also unexpectedly changes its light.
        drawn3D = nil
        drawnHorizon = nil
        currentPreset = nil
        appliedBaked = nil
        appliedOccluders = nil
        modelStore.styleChanged()
        drawnTrackRevision = -1
        drawnTrackOpacity = -1
        drawnHighContrast = nil
        drawnRouteRevision = -1
        drawnRouteUsesProgress = nil
        drawnRouteHidden = nil
        drawnPlateRevision = -1
        drawnShapesVisible = nil
        drewVehicleShapes = false
        drewFollowShape = false
        drawnFollowShapeFeatures = nil
        drawnFollowPointFeature = nil
        followUploadedAt = nil
        followPendingOrigin = nil
        followPendingHeading = nil
        followPendingDataId = nil
        followPendingStamp = 0
        followUploadedHeading = nil
        followBakedHeading = nil
        followUploadedStamp = -1
        followUploadedFadeSig = nil
        followUploadedDrawing = nil
        followLayerTranslate = .zero
        followTranslateAnchorSet = false
        followRenderContext = nil
        drawnCableways = nil
        cablewayPlanFrame = -1
        cablewayPlanInBand = false
        ropes = []
        cablewaysPending = false
        cablewayGround = []
        drawnFrameVersion = -1
        drawnStopsVersion = -1
        drawnHitboxes = nil
        labelOpenId = nil
        openLabelOpacity = 1
        openLabelSettleAt = 0
        fadingMainLane = false
        fadingFollowLane = false
        followFadeInProgress = false
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
    }

    /// Depth-tested station and kerb markers. Circles cannot occlude, so these
    /// are icons in the same slot as the rails; see `Terrain3D.placeOverlay`.
    private enum StopMark {
        static let rail = "transit-stop-dot-rail"
        static let local = "transit-stop-dot-local"
        static let selected = "transit-stop-dot-selected"
        static let ring = "transit-stop-ring"
        static let size = 16.0
        static let ringSize = 24.0

        static func iconSize(radius: Double) -> Double { (2 * radius) / size }
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
        ]

        for (id, fill, stroke) in chips {
            try? style.addImage(
                chipImage(fill: fill, stroke: stroke), id: id,
                stretchX: stretch, stretchY: stretch, content: content
            )
        }
    }

    private func installStopDotImages(_ style: MapboxMap) {
        let local = UIColor(red: 185 / 255, green: 190 / 255, blue: 199 / 255, alpha: 1)
        let selected = UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
        let images: [(String, UIImage)] = [
            (StopMark.rail, stopDotImage(fill: .white)),
            (StopMark.local, stopDotImage(fill: local)),
            (StopMark.selected, stopDotImage(fill: selected)),
            (StopMark.ring, stopRingImage(color: selected)),
        ]
        for (id, image) in images where !style.imageExists(withId: id) {
            try? style.addImage(image, id: id)
        }
    }

    private func stopDotImage(fill: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let size = StopMark.size
        let stroke = 1.9
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
            .image { canvas in
                let context = canvas.cgContext
                context.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor)
                context.fillEllipse(in: CGRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1))
                context.setFillColor(fill.cgColor)
                context.fillEllipse(in: CGRect(
                    x: 0.5 + stroke, y: 0.5 + stroke,
                    width: size - 1 - 2 * stroke, height: size - 1 - 2 * stroke
                ))
            }
    }

    private func stopRingImage(color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let size = StopMark.ringSize
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
            .image { canvas in
                let context = canvas.cgContext
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(3)
                context.strokeEllipse(in: CGRect(x: 2, y: 2, width: size - 4, height: size - 4))
            }
    }

    /// A station or bus-stop disc that can sit behind a building.
    private func stationDotLayer(_ band: StationBand) -> SymbolLayer {
        var layer = SymbolLayer(id: band.layerId, source: ID.stops)
        let rail = band == .rail
        layer.iconImage = .constant(.name(rail ? StopMark.rail : StopMark.local))
        layer.iconSize = .expression(
            Exp(.interpolate) {
                Exp(.linear); Exp(.zoom)
                9; StopMark.iconSize(radius: rail ? 2.2 : 1.8)
                12; StopMark.iconSize(radius: rail ? 3.2 : 3.0)
                14; StopMark.iconSize(radius: 3.8)
                16; StopMark.iconSize(radius: 5.0)
                17; StopMark.iconSize(radius: 5.6)
            }
        )
        layer.iconOpacity = .expression(
            Exp(.interpolate) { Exp(.linear); Exp(.zoom); 9; 0.55; 12; 1.0 }
        )
        layer.iconAllowOverlap = .constant(true)
        layer.iconIgnorePlacement = .constant(true)
        layer.iconPitchAlignment = .constant(.viewport)
        layer.iconRotationAlignment = .constant(.viewport)
        layer.iconOcclusionOpacity = .constant(0)
        layer.occlusionOpacityMode = .constant(.pixel)
        layer.iconEmissiveStrength = .constant(1)
        layer.slot = .middle
        layer.filter = band.filter
        layer.minZoom = band.minZoom
        if let maxZoom = band.maxZoom { layer.maxZoom = maxZoom }
        return layer
    }

    private func stationRingLayer() -> SymbolLayer {
        var layer = SymbolLayer(id: "\(ID.stops)-selected", source: ID.stops)
        layer.iconImage = .constant(.name(StopMark.ring))
        layer.iconSize = .constant(20 / StopMark.ringSize)
        layer.iconAllowOverlap = .constant(true)
        layer.iconIgnorePlacement = .constant(true)
        layer.iconPitchAlignment = .constant(.viewport)
        layer.iconRotationAlignment = .constant(.viewport)
        layer.iconOcclusionOpacity = .constant(0)
        layer.occlusionOpacityMode = .constant(.pixel)
        layer.iconEmissiveStrength = .constant(1)
        layer.slot = .middle
        layer.filter = Exp(.eq) { Exp(.get) { "id" }; "__none__" }
        layer.minZoom = 9
        return layer
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

        try addLayer(stopMarkerLayer(id: "\(ID.platforms)-pole", highlighted: false), to: style)
        try addLayer(plateLayer(id: "\(ID.platforms)-plate", image: Chip.plate, highlighted: false), to: style)

        // Selection is the same marker in the highlight colour, drawn over the
        // top and filtered to one feature. A ring would be wrong twice over: it
        // is the shape of a vehicle, which is exactly what a platform must not
        // look like, and being separate geometry it would still draw when the
        // plate under it had been decluttered elsewhere — a hoop hanging over a
        // building with nothing in it.
        try addLayer(stopMarkerLayer(id: "\(ID.platforms)-pole-selected", highlighted: true), to: style)
        try addLayer(plateLayer(id: "\(ID.platforms)-plate-selected", image: Chip.plateActive, highlighted: true), to: style)
    }

    /// A kerb with nothing to label: the same point language as every other
    /// stop on the map. Rectangles are reserved for codes printed inside them.
    private func stopMarkerLayer(id: String, highlighted: Bool) -> SymbolLayer {
        var layer = SymbolLayer(id: id, source: ID.platforms)
        layer.iconImage = .constant(.name(highlighted ? StopMark.selected : StopMark.local))
        layer.iconSize = .expression(
            Exp(.interpolate) {
                Exp(.linear); Exp(.zoom)
                16; StopMark.iconSize(radius: 5.0)
                18; StopMark.iconSize(radius: 6.2)
            }
        )
        layer.iconAllowOverlap = .constant(true)
        layer.iconIgnorePlacement = .constant(true)
        layer.iconPitchAlignment = .constant(.viewport)
        layer.iconRotationAlignment = .constant(.viewport)
        layer.iconOcclusionOpacity = .constant(0)
        layer.occlusionOpacityMode = .constant(.pixel)
        layer.iconEmissiveStrength = .constant(1)
        layer.slot = .middle
        layer.minZoom = Self.plateMinZoom
        let codeless = Exp(.not) { Exp(.has) { "code" } }
        layer.filter = highlighted
            ? Exp(.all) { codeless; Exp(.eq) { Exp(.get) { "id" }; "__none__" } }
            : codeless
        return layer
    }

    /// The plate, sized to the code written on it.
    private func plateLayer(id: String, image: String, highlighted: Bool) -> SymbolLayer {
        var layer = SymbolLayer(id: id, source: ID.platforms)
        layer.iconImage = .constant(.name(image))
        layer.iconTextFit = .constant(.both)
        layer.iconOcclusionOpacity = .constant(1)
        layer.textOcclusionOpacity = .constant(1)
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
        try? style.updateLayer(withId: "\(ID.stops)-selected", type: SymbolLayer.self) {
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
        // A stationary follow link may be asleep, so it cannot be relied on to
        // notice that selection or follow mode ended. The model frame is the
        // authoritative transition and cleans the private source immediately.
        if followId != nil, !model.isFollowingVehicle {
            endFollowing()
            return
        }
        // Here rather than at style load: the model reads its launch arguments
        // in a task that may not have run when the style finished, so asking
        // once at load lost the race about half the time.
        applyDebugStartIfAny()
        let style: MapboxMap = mapView.mapboxMap

        drawTracks(style)
        drawVehicles(style)
        drawCableways(style)
        drawStops(style)
        drawPlatforms(style)
        drawRoute(style)
        nativeRoute.updateDetail(style, viewport: model.viewport, metresPerPoint: metresPerPoint, settled: !userCameraBusy)
        drawRailwayShapes(style)
        applyOpenLabel(style)
        apply3D(style)
        applyLightPreset(style)
        // Solidity is normally driven off camera movement, which is where it
        // belongs. This catches the case where nothing moved and it changed
        // anyway: somebody turned the solid vehicles off while the map sat
        // still. Guarded inside, so a frame that changes nothing writes nothing.
        applySolidity()
        applyHighlights()
        updateRouteProgress()
        #if DEBUG
        startRenderingProbeIfRequested()
        #endif
    }

    private func drawMapOverlays() {
        guard styleReady, let mapView else { return }
        drawTracks(mapView.mapboxMap)
        drawRoute(mapView.mapboxMap)
    }

    private let nativeRoute = NativeRouteRenderer()

    #if DEBUG
    private var renderingProbeStarted = false

    /// Opt-in simulator regression capture. No observer, timer or disk writes
    /// exist in release builds or normal debug launches.
    private func startRenderingProbeIfRequested() {
        guard !renderingProbeStarted, UserDefaults.standard.bool(forKey: "mapRenderProbe"),
              case let .vehicle(id) = model.selection,
              let vehicle = model.selectedVehicle, vehicle.id == id,
              let geometry = model.selectedGeometry, geometry.path.count > 1,
              model.shapesByID[id] != nil, let mapView else { return }
        renderingProbeStarted = true
        model.clock.setPlaying(false)
        model.mapWasDragged()
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("map-render-probe", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let anchor = CLLocationCoordinate2D(latitude: vehicle.lat, longitude: vehicle.lon)
            var results: [[String: Any]] = []
            let poses: [(Double, Double, Double, Double)] = UserDefaults.standard.bool(forKey: "mapRenderProbeFocus")
                ? [(17, 65, 0, 0), (13, 75, 0, 0), (12, 85, 0, 0), (10, 65, 0, 0), (9, 65, 0, 0), (6, 0, 0, 0)] : [
                (17, 0, 0, 0), (17, 30, 0, 0), (17, 45, 0, 0),
                (17, 65, 0, 0), (17, 85, 0, 0), (17, 65, 90, 0),
                (17, 65, 180, 0), (17, 65, 270, 0), (17, 65, 360, 0),
                (17, 65, 0, 0.003), (17, 65, 0, 0),
                (17, 30, 0, 0), (17, 0, 0, 0), (15, 65, 135, 0),
                (12, 65, 135, 0), (10, 45, 135, 0), (8, 0, 0, 0),
                (6, 0, 0, 0), (12, 60, 90, 1), (17, 65, 0, 0),
                (19, 65, 90, 0), (20, 85, 180, 0)
            ]
            try? await Task.sleep(for: .seconds(3))
            for (index, pose) in poses.enumerated() {
                let path = self.model.selectedGeometry.flatMap { $0.path.count > 1 ? $0.path : nil } ?? geometry.path
                let far = path[path.count / 2]
                let centre = pose.3 == 1
                    ? CLLocationCoordinate2D(latitude: far.lat, longitude: far.lon)
                    : CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude + pose.3)
                mapView.camera.ease(to: CameraOptions(center: centre, zoom: pose.0,
                    bearing: pose.2, pitch: pose.1), duration: 0.8)
                for sample in 0..<24 {
                    try? await Task.sleep(for: .milliseconds(150))
                    let hits: [QueriedRenderedFeature] = await withCheckedContinuation { continuation in
                        mapView.mapboxMap.queryRenderedFeatures(with: mapView.bounds,
                            options: RenderedQueryOptions(layerIds: ["\(ID.route)-ahead", "\(ID.route)-solid", "\(ID.route)-travelled"], filter: nil)) {
                            continuation.resume(returning: (try? $0.get()) ?? [])
                        }
                    }
                    let shape = self.model.shapesByID[id]
                    let projected = mapView.mapboxMap.points(for: (self.model.selectedGeometry?.path ?? []).map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    })
                    results.append(["pose": index, "sample": sample,
                        "zoom": mapView.mapboxMap.cameraState.zoom,
                        "pitch": mapView.mapboxMap.cameraState.pitch,
                        "routeFeatures": hits.count, "routePoints": self.model.drawnRoutePoints,
                        "geometryPoints": self.model.selectedGeometry?.path.count ?? 0,
                        "hanging": self.hangingSelection,
                        "projection": mapView.mapboxMap.projection?.name.rawValue ?? "unknown",
                        "visibleRouteVertices": projected.filter { mapView.bounds.contains($0) }.count,
                        "shape": shape != nil, "placements": shape?.placements.count ?? 0,
                        "scales": shape?.placements.map { [$0.widthScale, $0.heightScale] } ?? [],
                        "solids": self.showingSolids])
                }
                if let data = try? mapView.snapshot(includeOverlays: true).pngData() {
                    try? data.write(to: directory.appendingPathComponent(String(format: "%02d.png", index)))
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("results.json"))
            }
        }
    }
    #endif

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
    /// Which vehicle the *features* currently say is the open one.
    ///
    /// Deliberately not the selection: it lags it, because moving a feature
    /// between the two label layers is instantaneous and the fade is not. See
    /// `applyOpenLabel`.
    private var labelOpenId: String?
    /// What the open label layer was last told its opacity is, so the fade is
    /// started once rather than restated thirty times a second.
    private var openLabelOpacity = 1.0
    /// When the fade that was last started will have finished.
    private var openLabelSettleAt: CFTimeInterval = 0

    private var drawnFrameVersion = -1
    private var drawnStopsVersion = -1
    /// Whether anything in each lane is part-way into a tunnel, and what the
    /// style was last told about it. See `VehicleModels.setTunnelFades`.
    private var fadingMainLane = false
    private var fadingFollowLane = false
    /// Extra model layers have to stay mounted for the whole 0→1 ease, not
    /// just while a wagon is below the full-strength band. Hiding them at 0.8
    /// left one frame matching no layer. This is also what may keep the
    /// high-rate follow display link awake.
    private var followFadeInProgress = false
    private var drawnTunnelFades: Bool?

    /// A followed vehicle that loses its footprint (or stops being followed)
    /// has no private source left whose tunnel fade can still be in flight.
    /// Clear both the animation reason and the lane's contribution to the shared
    /// fade-band visibility immediately rather than waiting for another shape.
    private func clearFollowFadeState(in style: MapboxMap? = nil) {
        followFadeInProgress = false
        guard fadingFollowLane else { return }
        fadingFollowLane = false
        let anyFading = fadingMainLane
        guard anyFading != drawnTunnelFades else { return }
        drawnTunnelFades = anyFading
        if let style = style ?? mapView?.mapboxMap {
            VehicleModels.setTunnelFades(style, anyFading)
        }
    }

    /// Whether the wagon hitbox layers are currently shown. Nil for a style
    /// that has just been built and has never been told.
    private var drawnHitboxes: Bool?

    /// The one cabin allowed to carry the shared line label for each cableway.
    ///
    /// A gondola service reports every cabin as a vehicle, and every one has
    /// the same line. Labelling the vehicles independently paints the same
    /// number down the whole rope. The label is useful while the cabins are
    /// still fallback dots, so one stable cabin per line keeps it; once a
    /// cabin has become a drawing the rope, station and model identify it and
    /// its ground-level symbol is both redundant and visibly displaced below
    /// the hanging body in a pitched view.
    private var cablewayLabelIDs: Set<String> = []
    /// Emergence as actually visible. Hanging footprints never render flat, so
    /// they stay dots until an elevated model or extrusion is on screen.
    private var displayedVehicleEmergence: [String: Double] = [:]
    /// The baked model in the high-rate follow source is deliberately excluded
    /// from the main source's `standingVehicles`; keep its actual handover here
    /// so selecting/following a gondola does not restore its fallback dot.
    private var followedStandingVehicle: String?

    private static func cablewayLabels(
        in vehicles: [VehicleSnapshot], emergence: [String: Double]
    ) -> Set<String> {
        var representative: [String: String] = [:]
        for vehicle in vehicles where Cableway.hangs(vehicle) {
            // Labels belong only to the dot fallback. A positive emergence is
            // already drawing the body and fading the dot away.
            guard (emergence[vehicle.id] ?? 0) <= 0 else { continue }
            let line = vehicle.line.trimmingCharacters(in: .whitespacesAndNewlines)
            let operatorName = vehicle.operatorName ?? ""
            let key: String
            if !line.isEmpty {
                key = "\(operatorName)|\(line)"
            } else {
                // A nameless line is uncommon, but its terminal pair still
                // identifies the rope without merging unrelated cableways.
                let terminals = [vehicle.stops.first?.name ?? vehicle.from,
                                 vehicle.stops.last?.name ?? vehicle.to ?? ""]
                    .sorted().joined(separator: "|")
                key = "\(operatorName)|\(terminals)"
            }
            if let current = representative[key] {
                representative[key] = min(current, vehicle.id)
            } else {
                representative[key] = vehicle.id
            }
        }
        return Set(representative.values)
    }

    private var vehiclesVisible = true
    /// Layers this overlay hid, so a show can restore them without turning on
    /// debug hitboxes, unlit lamps or the x-ray that the camera has put away.
    private var hiddenVehicleLayerIDs: [String] = []

    /// Hide every vehicle drawing without touching the GeoJSON.
    ///
    /// Emptying those sources is a parse of the whole fleet, and bringing them
    /// back is another — that is the second of delay this toggle had. Visibility
    /// is a style flag and lands on the next frame. The fleet keeps running so
    /// a show is the same drawing that was already on the GPU.
    func setVehiclesVisible(_ visible: Bool) {
        guard vehiclesVisible != visible else { return }
        vehiclesVisible = visible
        applyVehicleOverlayVisibility()
    }

    private func applyVehicleOverlayVisibility() {
        guard styleReady, let style = mapView?.mapboxMap else { return }
        if vehiclesVisible {
            let restore = hiddenVehicleLayerIDs
            hiddenVehicleLayerIDs = []
            guard !restore.isEmpty else { return }
            for id in restore where style.layerExists(withId: id) {
                try? style.setLayerProperty(for: id, property: "visibility", value: "visible")
            }
            VehicleLamps.setVisible(style, lampsLit)
            VehicleModels.setHitboxes(style, model.showWagonHitboxes)
            VehicleShapes.setXray(
                style,
                solids: showingSolids && (appliedBaked ?? false),
                occluders: appliedOccluders ?? false
            )
            return
        }
        var hidden = Set(hiddenVehicleLayerIDs)
        for layer in style.allLayerIdentifiers where layer.id.hasPrefix("transit-vehicle") {
            if hidden.contains(layer.id) {
                try? style.setLayerProperty(for: layer.id, property: "visibility", value: "none")
                continue
            }
            let current = style.layerProperty(for: layer.id, property: "visibility").value as? String
            if current != "none" {
                hidden.insert(layer.id)
                try? style.setLayerProperty(for: layer.id, property: "visibility", value: "none")
            }
        }
        hiddenVehicleLayerIDs = Array(hidden)
    }

    /// The fleet: the dots, and the drawn bodies behind them.
    private func drawVehicles(_ style: MapboxMap) {
        guard model.frameVersion != drawnFrameVersion else { return }
        drawnFrameVersion = model.frameVersion
        refreshTunnels()

        let selectedId: String? = {
            if case let .vehicle(id) = model.selection { return id }
            return nil
        }()

        // How far each vehicle has turned into a 3D drawing, so its dot can
        // get out of the way by exactly that much. Absent means still a dot.
        // The 2D footprint is not drawn; keep the point until a mesh (or the
        // extruded fallback) is actually on the map.
        var emergence: [String: Double] = [:]
        var shapesByID: [String: VehicleFootprint] = [:]
        emergence.reserveCapacity(model.vehicleShapes.count)
        shapesByID.reserveCapacity(model.vehicleShapes.count)
        for shape in model.vehicleShapes {
            shapesByID[shape.id] = shape
            let has3D: Bool
            if !showingSolids {
                has3D = false
            } else if model.bakedModels {
                has3D = model.standingVehicles.contains(shape.id)
                    || followedStandingVehicle == shape.id
            } else {
                has3D = !shape.slabs.isEmpty
            }
            if has3D { emergence[shape.id] = shape.emergence }
        }
        displayedVehicleEmergence = emergence
        cablewayLabelIDs = Self.cablewayLabels(
            in: model.vehicles, emergence: emergence
        )

        // The followed vehicle is written where the follow lane has it, not
        // where the last tick left it. See `followShift`.
        let shift = followId != nil ? followShift() : (lon: 0.0, lat: 0.0)
        let vehicleFeatures = model.vehicles.map { vehicle -> Feature in
            let moved = vehicle.id == followId
            let at = Coord(
                lon: vehicle.lon + (moved ? shift.lon : 0),
                lat: vehicle.lat + (moved ? shift.lat : 0)
            )
            let marker = tunnelMarker(for: vehicle, at: at)
            return Self.vehicleFeature(
                vehicle, at: at,
                selected: vehicle.id == selectedId, emerged: emergence[vehicle.id] ?? 0,
                tunnel: marker.fade, tunnelAltitude: marker.altitude,
                open: vehicle.id == labelOpenId,
                label: Cableway.hangs(vehicle) && !cablewayLabelIDs.contains(vehicle.id)
                    ? "" : vehicle.displayLine
            )
        }
        style.updateGeoJSONSource(
            withId: ID.vehicles,
            geoJSON: .featureCollection(FeatureCollection(features: vehicleFeatures)),
            dataId: GeoJSONQueueProbe.shared.stamp(.fleet, at: CACurrentMediaTime())
        )
        drawVehicleShapes(style)
        #if DEBUG
        Diagnostics.pushed(vehicles: vehicleFeatures.count, tracks: model.tracks.count, styleReady: styleReady)
        #endif
    }

    /// The cableway plan currently in the source, so a frame that would draw
    /// the same ropes again writes nothing.
    ///
    /// Compared by value rather than versioned, and it is the cheaper of the
    /// two here: a plan is a handful of stations and spans, and what it is being
    /// compared against is a rebuild of a source that runs to a few thousand
    /// vertices. What changes it is panning onto a new line or off one, which is
    /// a gesture rather than a tick — every other frame in between finds the
    /// same answer and stops.
    private var drawnCableways: Cableway.Plan?

    /// The ropes the drawn cableways hang from, kept because two things need
    /// them and they have to agree exactly: the line that draws a rope, and the
    /// lift that hangs a cabin on it. See `rest`.
    private var ropes: [Cableway.Rope] = []

    /// Whether some span is waiting for elevation tiles. While this is true the
    /// cableways are rebuilt so its provisional profile can be replaced when
    /// the missing ground measurements return.
    private var cablewaysPending = false
    private var cablewayRetryAfter: CFTimeInterval = 0

    /// A visible terrain height used only when a newly encountered span has no
    /// resident elevation samples at all. It keeps the provisional sea-level
    /// rope near the current ground until the real profile can be solved.
    private var cablewayReferenceGround: Double?

    /// The ground under a handful of points of the drawn cableways, as it was
    /// when they were last built.
    ///
    /// **The rope is the one thing this app draws at an absolute height**, and
    /// that is what makes it the one thing that can go stale. Everything else
    /// — a station or a wagon — is placed *on* the terrain by the
    /// renderer, so when a better elevation tile arrives it moves with it. The
    /// rope is at a height above sea level worked out by the app from the
    /// terrain it could see at the moment it was built, and if that was a
    /// coarse tile, or no tile, the rope stays where that put it while the
    /// stations and cabins under it rise into place without it.
    ///
    /// That is exactly the bug this exists for: a line drawn on arrival had a
    /// straight rope with cabins hanging clear of it, and switching the basemap
    /// fixed it — because a style reload
    /// throws the whole overlay away and rebuilds it, by which time the tiles
    /// had landed. Watching the ground is what makes the rebuild happen on its
    /// own. A dozen lookups a frame, against the several hundred `rest` already
    /// makes for the vehicles.
    private var cablewayGround: [Double] = []

    /// The stations and ropes under whatever is flying on them.
    ///
    /// Built from the all-day plan and improved by the live fleet rather than
    /// from the drawn shapes, and the difference matters at this zoom: a vehicle only
    /// becomes a drawing once it is long enough on screen to be worth one, and a
    /// gondola cabin is two metres long, so the cabins are still dots for a
    /// couple of zoom levels after their line is plainly visible. The rope is
    /// the line, not the cabin, and it should be there before them.
    ///
    /// Fleet frame the cableway plan was last built from, so a SwiftUI chrome
    /// pass (opening search, the clock) does not walk every vehicle again.
    private var cablewayPlanFrame = -1
    private var cablewayPlanInBand = false

    private func drawCableways(_ style: MapboxMap) {
        // Only where the cabins themselves could be drawn. Further out a span
        // is a line beside the route overlay's own line and a station is a
        // tenth of a pixel, and every one of them is still a polygon being
        // parsed. See `Cableways.minZoom`.
        let inBand = model.detailedVehicles && model.zoom >= Cableways.minZoom
        let clock = CACurrentMediaTime()
        let retryDue = cablewaysPending && clock >= cablewayRetryAfter
        if inBand == cablewayPlanInBand,
           model.frameVersion == cablewayPlanFrame,
           !retryDue {
            return
        }
        cablewayPlanInBand = inBand
        cablewayPlanFrame = model.frameVersion
        let wanted = inBand
            ? model.cableways.merging(Cableway.plan(for: model.vehicles))
            : Cableway.Plan()
        let planChanged = wanted != drawnCableways
        // A long span commonly reaches beyond the elevation tiles resident for
        // the current viewport. Its provisional profile is already visible;
        // retrying the full terrain walk every display frame only burns the
        // frame budget while waiting for the same missing tile.
        if !planChanged, cablewaysPending, clock < cablewayRetryAfter { return }
        func ground(_ at: Coord) -> Double? {
            guard model.terrain3D else { return 0 }
            let height = style.elevation(at: CLLocationCoordinate2D(
                latitude: at.lat, longitude: at.lon
            ))
            guard let height, height.isFinite else { return nil }
            return height
        }

        let camera = style.cameraState.center
        let cameraGround = ground(Coord(lon: camera.longitude, lat: camera.latitude))
        if let cameraGround { cablewayReferenceGround = cameraGround }
        let fallbackGround = cameraGround ?? cablewayReferenceGround ?? 0

        // Rebuilt when the set of lines changes, while a provisional span is
        // waiting for terrain, and whenever the ground it was built against
        // has since moved under it. See `cablewayGround`.
        let measured = Self.probes(of: wanted, ropes: ropes).map { ground($0) ?? .nan }
        let moved = measured.count != cablewayGround.count
            || zip(measured, cablewayGround).contains { now, then in
                now.isNaN != then.isNaN || (!now.isNaN && abs(now - then) > 0.5)
            }
        guard planChanged || cablewaysPending || moved else { return }
        let includeProvisionalCache = planChanged || !cablewaysPending
        let built = Cableways.features(
            wanted, dark: isDarkTheme, ground: ground,
            fallbackGround: fallbackGround,
            cacheKey: cablewayRopeCacheKey,
            cached: {
                cablewayRopeCache.profile(
                    $0, includingProvisional: includeProvisionalCache
                )
            }
        )
        cablewayRopeCache.store(
            solved: built.solved, provisional: built.provisional
        )
        // Always publish this per-span result. In particular, `drawnCableways`
        // is a non-nil empty plan after zooming below the layer floor; treating
        // that as a source worth preserving made zooming back in retain the
        // empty source whenever even one new span was waiting for terrain.
        drawnCableways = wanted
        ropes = built.ropes
        cablewayGround = Self.probes(of: wanted, ropes: built.ropes).map {
            ground($0) ?? .nan
        }
        cablewaysPending = built.pending
        cablewayRetryAfter = built.pending ? clock + 0.75 : 0
        style.updateGeoJSONSource(
            withId: Cableways.source,
            geoJSON: .featureCollection(FeatureCollection(features: built.features))
        )
    }

    /// A stable, direction-independent key for one solved terrain profile.
    /// Exact geometry is included so a later, better live alignment does not
    /// inherit the timetable chord's cached answer.
    private func cablewayRopeCacheKey(_ span: Cableway.Span) -> String {
        var points = span.points
        if let first = points.first, let last = points.last,
           last.lon < first.lon || (last.lon == first.lon && last.lat < first.lat) {
            points.reverse()
        }
        let relief = model.terrain3D
            ? "terrain-\(Int((model.terrainExaggeration * 1_000).rounded()))"
            : "flat"
        let geometry = points.map {
            "\(Int64(($0.lon * 1_000_000).rounded())),\(Int64(($0.lat * 1_000_000).rounded()))"
        }.joined(separator: ";")
        return "v2|\(relief)|\(span.identity ?? "-")|\(geometry)"
    }

    /// The few points whose ground is watched for a cableway to be rebuilt.
    ///
    /// Both ends and the middle of every span, and every station. Not every
    /// vertex: the question is only whether the terrain under this line has
    /// changed at all, and a tile arriving changes all of it at once.
    private static func probes(
        of plan: Cableway.Plan, ropes: [Cableway.Rope]
    ) -> [Coord] {
        var out: [Coord] = []
        out.reserveCapacity(plan.spans.count * 5 + plan.stations.count)
        for span in plan.spans where !span.points.isEmpty {
            out.append(span.points[0])
            out.append(span.points[span.points.count / 2])
            out.append(span.points[span.points.count - 1])
        }
        // A tower's base moves with its own terrain tile while the rope is held
        // at absolute altitude. Watching the exact tower positions is what
        // guarantees a newly refined tile restates the mast height and brings
        // its crosshead back to the cable.
        for rope in ropes {
            for distance in Cableway.towerPoints(of: rope) {
                if let point = Cableway.position(rope, at: distance) {
                    out.append(point.coord)
                }
            }
        }
        out.append(contentsOf: plan.stations.map(\.at))
        return out
    }

    /// The label layer for the vehicle whose panel is open.
    static let openLabelLayer = "transit-vehicles-label-open"

    /// How long to let a change of which vehicle is the open one reach the
    /// map before acting on it, in seconds.
    ///
    /// A GeoJSON write is queued rather than applied, so "the features now say
    /// X" is true a frame or two after saying it. Two frames at the model's
    /// slowest rate, which is short enough to be invisible and long enough to
    /// be sure.
    private static let labelSwapSettle = 0.12

    /// Take the line number off the open vehicle once the map is close enough
    /// that the vehicle is the picture, and put it back when it is not.
    ///
    /// **Two things can change and only one of them can be animated.** The
    /// layer's opacity fades, because that is what a paint transition does. Its
    /// *membership* cannot: a feature is in one label layer or the other, and
    /// the frame it changes over is the frame it changes over. So zooming faded
    /// and tapping did not — tapping a train moved its number into a layer
    /// already at nothing, and closing the panel moved it back into one already
    /// at full strength, both of them in one frame.
    ///
    /// The answer is to only ever change membership at the moment it cannot be
    /// seen, which is while both layers are at full strength. So a vehicle
    /// being let go of is faded back in *before* it is released, and one being
    /// taken up joins at full strength and is faded out afterwards. The
    /// sequencing costs a tick — the features are rewritten by `drawVehicles`
    /// on the model's clock, so this hands over and waits for the next one
    /// rather than setting an opacity the features have not caught up with.
    private func applyOpenLabel(_ style: MapboxMap) {
        guard style.layerExists(withId: Self.openLabelLayer) else { return }
        let selected: String? = {
            if case let .vehicle(id) = model.selection { return id }
            return nil
        }()

        if selected != labelOpenId {
            // Whoever is in the open layer has to be at full strength before
            // anyone can leave or join it.
            if openLabelOpacity != 1 {
                setOpenLabel(style, opacity: 1)
                return
            }
            // And the fade that brought them there has to have finished, or
            // they would be released halfway and snap the rest of the way.
            guard CACurrentMediaTime() >= openLabelSettleAt else { return }
            labelOpenId = selected
            // The features still say what they said, and a source update is
            // handed to the SDK's own parsing queue rather than applied where
            // it is written — so the swap lands a frame or two from now. Wait
            // for it before touching the opacity: faded in between, the number
            // would still be in the layer it is leaving and would jump to
            // wherever the fade had got to when it finally moved.
            openLabelSettleAt = CACurrentMediaTime() + Self.labelSwapSettle
            return
        }

        // Nothing is started while something is still running: a fade
        // interrupted halfway is a jump, and a swap released halfway is worse.
        guard CACurrentMediaTime() >= openLabelSettleAt else { return }
        let target = labelOpenId != nil && model.zoom > VehicleDot.labelHideZoom
            ? 0.0 : 1.0
        guard target != openLabelOpacity else { return }
        setOpenLabel(style, opacity: target)
    }

    private func setOpenLabel(_ style: MapboxMap, opacity: Double) {
        openLabelOpacity = opacity
        openLabelSettleAt = CACurrentMediaTime() + VehicleDot.labelFadeSeconds
        do {
            try style.setLayerProperty(
                for: Self.openLabelLayer, property: "text-opacity", value: opacity
            )
        } catch {
            // Said rather than swallowed. A refused paint property is the one
            // failure mode this feature has, it is silent, and it has already
            // cost two attempts that looked correct and changed nothing.
            Diagnostics.note("open label kept its opacity: \(error)")
        }
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
        style.updateGeoJSONSource(
            withId: VehicleShapes.source,
            geoJSON: .featureCollection(FeatureCollection(
                features: vehicleDrawing(
                    shapes, excluding: followedVehicleId, flatness: 1,
                    follow: false
                )
            )),
            dataId: GeoJSONQueueProbe.shared.stamp(.vehicleShapes, at: CACurrentMediaTime())
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
        _ shapes: [VehicleFootprint], excluding excluded: String?, flatness _: Double,
        follow: Bool
    ) -> [Feature] {
        // Re-stated by every lane rebuild. Without the reset, switching solids
        // off while a tunnel fade was in flight left the follow link believing
        // that animation was still pending forever.
        if follow {
            fadingFollowLane = false
            followFadeInProgress = false
        } else {
            fadingMainLane = false
        }
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
        // Model registration and terrain placement are only useful in 3D.
        if let style = mapView?.mapboxMap,
           model.detailedVehicles, model.solidVehicles,
           showingSolids {
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
            if follow {
                followModelLift = shapes.first.flatMap { wagonLifts[$0.id]?.first } ?? 0
            }
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
            //
            // Keep them mounted until every wagon has settled at 0 or 1.
            // Turning them off as soon as a wagon reached the full-strength
            // band (0.8) hid those layers a frame before the source had the
            // new opacity, so a coach finishing its climb back to solid
            // matched no layer for one frame and vanished. Zero is
            // underground, not an animation; `ease` snaps exactly to 0 or 1.
            let fading = wagonOpacities.values.contains { wagon in
                wagon.contains { $0 > 0 && $0 < 1 }
            }
            if follow {
                fadingFollowLane = fading
                followFadeInProgress = fading
            } else {
                fadingMainLane = fading
            }
            // Only where the solid is actually being painted. The models are
            // built a little before the camera has tilted far enough to show
            // them — see `applySolidity`, which switches rather than fades —
            // and a vehicle whose flat drawing stepped aside for a solid that
            // is not being drawn yet is a vehicle that has gone missing.
            if model.bakedModels {
                if showingSolids { stood = placed.stood }
            }
            if let working = modelStore.working, model.bakedModels != working {
                model.bakedModels = working
                applySolidity()
            }
        }
        let anyFading = fadingMainLane || fadingFollowLane
        if anyFading != drawnTunnelFades, let style = mapView?.mapboxMap {
            drawnTunnelFades = anyFading
            VehicleModels.setTunnelFades(style, anyFading)
        }
        // Told back to the model, so the next tick does not build the trim of a
        // vehicle standing up as a mesh — every polygon of it is dropped just
        // below. Outside the block above rather than inside it, so switching
        // the solids off restates an empty set instead of leaving the last one
        // standing and every vehicle drawn as a bare body from then on. The
        // follow lane is handed one vehicle and sees only that one, so it must
        // not restate the whole set. See `AppModel.standingVehicles`.
        if follow {
            followedStandingVehicle = stood.first
        } else if model.standingVehicles != stood {
            model.standingVehicles = stood
        }

        refreshTunnels()
        var features = solids
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
    /// Portal samples are held in real metres, independent of relief exaggeration.
    private var tunnelPortalElevations: [Coord: Double] = [:]
    private var tunnelElevationRetries: [Int: CFTimeInterval] = [:]

    private func tunnelMarker(
        for vehicle: VehicleSnapshot, at position: Coord
    ) -> (fade: Double, altitude: Double?) {
        guard model.detailedVehicles, model.solidVehicles, model.ghostTunnels,
              !(vehicle.mode == .train && !vehicle.moving && !vehicle.stops.isEmpty)
        else { return (0, nil) }
        refreshTunnels()
        guard let hit = tunnelIndex.hiding(at: position, heading: vehicle.bearing)
        else { return (0, nil) }
        let fade = TunnelIndex.fade(hit.fromPortal)
        guard model.terrain3D, let style = mapView?.mapboxMap else { return (fade, nil) }

        let bore = tunnelIndex.bores[hit.bore]
        let exaggeration = max(0.01, model.terrainExaggeration)
        let now = CACurrentMediaTime()
        if now >= (tunnelElevationRetries[hit.bore] ?? 0) {
            tunnelElevationRetries[hit.bore] = now + 1
            for portal in [bore.entrance, bore.exit] where tunnelPortalElevations[portal] == nil {
                if let height = style.elevation(at: CLLocationCoordinate2D(
                    latitude: portal.lat, longitude: portal.lon
                )), height.isFinite {
                    tunnelPortalElevations[portal] = height / exaggeration
                }
            }
        }
        // Both portals are needed for a bore-height estimate. While their DEM
        // tiles are unavailable, the ordinary surface marker remains visible.
        guard let entrance = tunnelPortalElevations[bore.entrance],
              let exit = tunnelPortalElevations[bore.exit]
        else { return (fade, nil) }
        return (fade, max(0, bore.altitude(
            along: hit.along, entrance: entrance, exit: exit
        ) * exaggeration))
    }

    private func refreshTunnels() {
        if model.tunnelRevision != tunnelMark {
            tunnelMark = model.tunnelRevision
            tunnelIndex = TunnelIndex(model.tunnels, stations: model.tunnelStations)
            tunnelPortalElevations.removeAll(keepingCapacity: true)
            tunnelElevationRetries.removeAll(keepingCapacity: true)
        }
    }

    /// How much of each wagon is still drawn, 1 in the open, 0 in a tunnel.
    private static func tunnelOpacities(
        _ print: VehicleFootprint, index: TunnelIndex
    ) -> [Double] {
        if print.stoppedAtStation {
            return [Double](repeating: 1, count: max(1, print.placements.count))
        }
        if print.placements.isEmpty {
            let head = print.centreline.first ?? Coord(lon: 0, lat: 0)
            return [index.hiding(at: head) == nil ? 1 : 0]
        }
        return print.placements.map {
            index.hiding(
                at: print.rails(at: $0.alongTrain), heading: $0.heading
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
            // What hangs takes no angle from the ground it is over.
            //
            // A wagon lies at the gradient of the hillside because it is
            // standing on it. A gondola is not: it hangs from a rope on a
            // pivot, and a cabin swinging into the slope of the mountain
            // underneath it is the one attitude a cabin never takes. Measured
            // like everything else it was reading a DEM twelve metres below its
            // own floor and tipping into it — worst exactly where a cableway
            // is, which is on the steepest ground the map ever draws.
            //
            // Asked of the mesh rather than of a flag on the footprint, so the
            // rule is the same one `VehicleMesh` already lifts the body by and
            // there is nothing to keep in step. See `Silhouette.hover`.
            if print.placements.allSatisfy({ $0.model.unit.silhouette.hover > 0 }) {
                let level = [Double](repeating: 0, count: print.placements.count)
                // And it hangs from the rope rather than at a fixed height over
                // the hill, which is the other half of pulling the rope tight.
                //
                // The mesh already carries the cabin at `Cableway.ropeHeight`
                // over whatever ground the renderer stands it on. Where the
                // rope is a taut line rather than a drape, that is the wrong
                // height by exactly the gap between the two — so the gap is
                // handed back as the wagon's lift, which is the same
                // translation a coach spanning a dip is raised by. Nothing is
                // measured twice: the height comes from the very profile the
                // rope was drawn along, so the grip meets the line it is
                // supposed to be clamped to whatever the ground below does.
                var lifts = level
                for (index, placement) in print.placements.enumerated() {
                    // The nearest rope, not merely the first that answers: at a
                    // mid station two spans meet and both of them are within
                    // reach of a cabin standing in it.
                    guard let seat = ropes.compactMap({
                        $0.at(placement.at, within: Cableways.snap)
                    }).min(by: { $0.away < $1.away }) else { continue }
                    // **Measured against the ground the *renderer* will use,
                    // not against the profile's own sample of it.** The lift is
                    // added to whatever height the renderer stands the model
                    // on, so the two have to be the same number or the
                    // difference is error — and the profile's ground is
                    // interpolated between samples twenty-five metres apart,
                    // which on a mountainside is metres out and differently out
                    // at every point along the span. That was the other half of
                    // the cabin bobbing over and under its own rope.
                    let floor = height(placement.at) ?? seat.ground
                    lifts[index] = seat.rope - floor - Cableway.drawnRopeHeight
                }
                out[print.id] = VehicleModels.Rest(grades: level, lifts: lifts)
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
    private var drawnTrackRevision = -1
    private var drawnTrackOpacity = -1.0
    /// Whether ORM's own lines are the ones currently visible.
    private var drawnHighContrast: Bool?
    /// Full-route geometry is uploaded once per selection, never per gesture.
    private var drawnRouteRevision = -1
    private var drawnRouteUsesProgress: Bool?
    private var drawnRouteHidden: Bool?
    private var routePattern = RoutePattern(path: [])
    private var routeProgressKey: [Double] = []

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
        if model.usesORMTracks != drawnHighContrast {
            drawnHighContrast = model.usesORMTracks
            RailwayLines.setVisible(style, model.usesORMTracks)
        }
        guard model.tracksRevision != drawnTrackRevision else { return }
        drawnTrackRevision = model.tracksRevision

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

    /// Whether the open vehicle hangs from a rope this map already draws.
    private var hangingSelection: Bool {
        guard case let .vehicle(id) = model.selection else { return false }
        if let vehicle = model.vehicles.first(where: { $0.id == id }) {
            return Cableway.hangs(vehicle)
        }
        if let vehicle = model.selectedVehicle, vehicle.id == id {
            return Cableway.hangs(vehicle)
        }
        return false
    }

    private func drawRoute(_ style: MapboxMap) {
        let usesProgress: Bool
        if case .vehicle = model.selection { usesProgress = true } else { usesProgress = false }
        let hidden = !model.showsSelectionOnMap || hangingSelection || (model.selectedGeometry?.path.count ?? 0) < 2
        guard drawnRouteRevision != model.selectedGeometryRevision || drawnRouteUsesProgress != usesProgress || drawnRouteHidden != hidden else { return }
        drawnRouteHidden = hidden
        drawnRouteRevision = model.selectedGeometryRevision
        drawnRouteUsesProgress = usesProgress
        routeProgressKey = []
        guard !hidden, let geometry = model.selectedGeometry else {
            routePattern = RoutePattern(path: [])
            nativeRoute.setGeometry(style, main: [], extras: [])
            model.routePathPoints = 0; model.drawnRoutePoints = 0
            style.updateGeoJSONSource(withId: ID.routeStops, geoJSON: .featureCollection(FeatureCollection(features: [])))
            return
        }
        let path = geometry.path
        routePattern = RoutePattern(path: path)
        var extras: [(path: [Coord], solid: Bool)] = []
        if !usesProgress {
            if !geometry.legSources.isEmpty, geometry.legSources.count == geometry.legs.count - 1 {
                var start = 0
                for leg in geometry.legSources.indices {
                    let exact = geometry.legSources[leg] != .chord
                    if leg + 1 < geometry.legSources.count, (geometry.legSources[leg + 1] != .chord) == exact { continue }
                    let lo = geometry.legs[start], hi = geometry.legs[leg + 1]
                    if lo >= 0, hi > lo, hi < path.count { extras.append((Array(path[lo...hi]), exact)) }
                    start = leg + 1
                }
            } else { extras.append((path, geometry.source == .osmRoute)) }
        }
        extras += model.selectedBranches.map { ($0.path, $0.exact) }
        nativeRoute.setGeometry(style, main: usesProgress ? path : [], extras: extras,
                                inferred: usesProgress ? RouteProgress(path: path).inferredRanges(in: geometry) : [])
        model.routePathPoints = path.count
        model.drawnRoutePoints = nativeRoute.pointCount
        #if DEBUG
        captureRouteVerificationIfNeeded(path: path)
        #endif
        let stops = geometry.legs.filter { path.indices.contains($0) }.map { path[$0] }
            + model.selectedBranches.flatMap(\.stops)
        style.updateGeoJSONSource(withId: ID.routeStops, geoJSON: .featureCollection(FeatureCollection(features: stops.map {
            Feature(geometry: .point(Point(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon))))
        })))
    }

    #if DEBUG
    private var routeShotTaken = false

    /// `-routeShot 1` writes local and world-zoom snapshots after a line is
    /// drawn, so a meridian-to-Africa regression is a file rather than a tap.
    private func captureRouteVerificationIfNeeded(path: [Coord]) {
        guard !routeShotTaken, UserDefaults.standard.bool(forKey: "routeShot"),
              path.count > 1, let mapView else { return }
        routeShotTaken = true
        let dir = URL(fileURLWithPath: "/tmp/svrk-route-shot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor [weak self] in
            guard let self, let mapView = self.mapView else { return }
            // Wait for OJP/formation extras to fold on. The Africa meridian
            // was a *rebuild* after that fold, not the first packed path.
            try? await Task.sleep(for: .seconds(12))
            let shot = self.model.selectedGeometry?.path ?? path
            let lats = shot.map(\.lat), lons = shot.map(\.lon)
            let info = [
                "n=\(shot.count)",
                "lat \(lats.min() ?? 0) \(lats.max() ?? 0)",
                "lon \(lons.min() ?? 0) \(lons.max() ?? 0)",
            ].joined(separator: "\n")
            try? info.write(to: dir.appendingPathComponent("bbox.txt"), atomically: true, encoding: .utf8)
            func snap(_ name: String) {
                if let data = try? mapView.snapshot(includeOverlays: true).pngData() {
                    try? data.write(to: dir.appendingPathComponent(name))
                }
            }
            snap("framed.png")
            let world = self.beginEaseCamera()
            mapView.camera.ease(
                to: CameraOptions(
                    center: CLLocationCoordinate2D(latitude: 20, longitude: 7.4),
                    zoom: 2.3, bearing: 0, pitch: 0
                ),
                duration: 0.15
            ) { [weak self] _ in self?.endEaseCamera(world) }
            try? await Task.sleep(for: .seconds(2.5))
            snap("world.png")
            let local = self.beginEaseCamera()
            mapView.camera.ease(
                to: CameraOptions(
                    center: CLLocationCoordinate2D(latitude: 46.88, longitude: 7.39),
                    zoom: 10, bearing: 0, pitch: 0
                ),
                duration: 0.15
            ) { [weak self] _ in self?.endEaseCamera(local) }
            try? await Task.sleep(for: .seconds(2.5))
            snap("local.png")
            try? "done".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }
    #endif

    /// Paint-only progress updates. The line, dots and arrows retain their
    /// geographic vertices while Mapbox performs every camera transform.
    private func updateRouteProgress(vehicle displayed: VehicleSnapshot? = nil, position displayedPosition: Coord? = nil) {
        guard styleReady, let mapView, drawnRouteUsesProgress == true,
              case let .vehicle(id) = model.selection, let geometry = model.selectedGeometry,
              !geometry.legs.isEmpty, !hangingSelection else { return }
        // At a turnback the selection/follower can still name the arriving
        // working, while the panel and geometry already describe its departure.
        // Only use progress and prediction belonging to the route being shown.
        let routeID = model.departingVehicle?.id ?? id
        let displayedOnRoute = displayed?.id == routeID ? displayed : nil
        let followedOnRoute = followId == routeID ? followWatched : nil
        guard let vehicle = displayedOnRoute ?? followedOnRoute ?? model.departingVehicle
            ?? model.vehicles.first(where: { $0.id == routeID })
            ?? (model.selectedVehicle?.id == routeID ? model.selectedVehicle : nil),
              vehicle.id == routeID else { return }
        let leg = min(max(0, vehicle.index), geometry.legs.count - 1)
        let start = geometry.legs[leg], end = geometry.legs[min(leg + 1, geometry.legs.count - 1)]
        let nose = Coord(lon: vehicle.lon, lat: vehicle.lat)
        let shift = followId == routeID ? followShift() : (lon: 0.0, lat: 0.0)
        let position = (displayedOnRoute != nil ? displayedPosition : nil)
            ?? Coord(lon: nose.lon + shift.lon, lat: nose.lat + shift.lat)
        let offset = Geo.eastNorth(from: nose, to: position)
        let bearing = vehicle.bearing * Double.pi / 180
        let advance = offset.east * sin(bearing) + offset.north * cos(bearing)
        // Use the displayed nose, including the same follow prediction. A
        // half-body subtraction delayed the handover, and unsigned distance
        // turned a backwards catch-up correction into forward route progress.
        let distance = max(0, routePattern.distance(from: start, to: end, progress: vehicle.progress) + advance)
        // Quantize below a visible pixel, avoiding redundant paint updates.
        let quantum = max(0.25, metresPerPoint * 0.5)
        let key = [(distance / quantum).rounded() * quantum]
        guard key != routeProgressKey else { return }
        routeProgressKey = key
        nativeRoute.updateProgress(mapView.mapboxMap, distance: key[0])
    }


}

/// Where the unfocused state comes from.
///
/// A display-link target that does not keep its owner alive.
private final class DisplayLinkProxy {
    private let handler: (CADisplayLink) -> Void
    init(_ handler: @escaping (CADisplayLink) -> Void) { self.handler = handler }
    @objc func fire(_ link: CADisplayLink) { handler(link) }
}

/// Never from the button — no press means "stop following". Letting go of the
/// map means it, and so does the app moving the camera somewhere of its own
/// choosing, and both of those reach the button through here.
extension MapCoordinator: GestureManagerDelegate {
    func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
        gestureCameraCount += 1
        markCameraBusy()
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
        // Pitch is the same argument: tilting to see down a valley is still
        // about the vehicle. Rotation is not. Turning the map is a heading
        // of its own; snapping back onto the train would undo it. Keep
        // following the position, leave the bearing where the fingers put it.
        if gestureType == GestureType.rotation {
            dropFollowBearing()
            return
        }
        guard gestureType == GestureType.pan else { return }
        model.mapWasDragged()
    }

    func gestureManager(
        _ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool
    ) {
        guard !willAnimate else { return }
        finishGestureCamera()
    }

    func gestureManager(
        _ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType
    ) {
        finishGestureCamera()
    }

    private func finishGestureCamera() {
        gestureCameraCount = max(0, gestureCameraCount - 1)
        if !gestureCameraActive {
            reportViewport()
            if !userCameraBusy { armSettleWatchdog() }
        }
    }
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
            guard let self, mapView?.viewport.status == .idle,
                  model.locateMode != .unfocused else { return }
            model.locateMode = .unfocused
            // And the phone can stop working so hard: nothing is locked to the
            // puck any more.
            applyLocationPolicy()
        }
    }
}

/// Finish the native picker's dismissal before presenting its vehicle sheet.
/// Opening from UIAction itself overlaps the two UIKit transitions.
@MainActor
private final class MapChoiceButton: UIButton {
    var selectionAction: (() -> Void)?
    private(set) var isMenuVisible = false

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        isMenuVisible = true
        selectionAction = nil
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        let finish = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isMenuVisible = false
                let action = self.selectionAction
                self.selectionAction = nil
                action?()
            }
        }
        if let animator { animator.addCompletion(finish) }
        else { finish() }
    }
}
