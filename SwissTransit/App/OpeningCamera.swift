import CoreLocation
import TransitCore
import UIKit

/// Where the map opens, and — the part that costs a second — which slice of the
/// country the first frame has to be drawn from.
///
/// The app used to open on the whole of Switzerland at zoom 7.4, every launch,
/// and that choice is what made the launch expensive rather than the data
/// being large. Expanding the timetable nationally builds 25,518 journeys and
/// half a million calls; a phone opened on one canton draws about a thousand of
/// them. So the opening camera is now decided *before* the fleet is drawn, and
/// the fleet is drawn for it.
///
/// Three sources, in order, and the order is the point:
///
/// - **Where the map was left.** Instant, needs no permission, and after the
///   first session it is a better guess at where somebody is than a fix is —
///   people open a transit app to look at the same few places.
/// - **The last location the system already has.** `CLLocationManager.location`
///   is a cached fix read synchronously; it is not a request, and it does not
///   wait. Waiting for a real fix would put a GPS lock on the critical path of
///   a launch, which is the opposite of the point.
/// - **The country.** No stored camera, no fix, or no permission: the map opens
///   the way it always did, and the timetable is expanded nationally because at
///   zoom 7.4 there is nothing to clip away.
struct OpeningCamera {
    var lat: Double
    var lon: Double
    var zoom: Double
    var bearing: Double
    var pitch: Double

    /// What the first frame will show, or `nil` for the whole country.
    ///
    /// Handed to `Fleet.drawTimetable(in:)`. `nil` is not "unknown" — it is the
    /// national pass, which is what a country-wide opening genuinely needs.
    var clip: BBox?

    var where_: Source

    enum Source: String {
        /// Restored from the last session.
        case remembered
        /// The fix the system already had, at `OpeningCamera.localZoom`.
        case located
        /// The whole network, as it was before any of this.
        case country
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// A city and the network around it: close enough to pick a vehicle out and
    /// tap it, wide enough to see where the lines go.
    ///
    /// Chosen on measurement rather than taste. Two costs fall away sharply
    /// between here and the canton-wide view a zoom or two out, and they
    /// compound: the timetable expanded for this viewport builds 2,469
    /// journeys against 11,134, and the background pass that puts vehicles on
    /// their true paths — see `Fleet.refineDrawn` — settles in 0.5 s against
    /// 16.5 s. The wider view opens more slowly *and* then spends half a minute
    /// of a core correcting itself.
    static let localZoom = 11.0

    /// Switzerland, whole, which is where the app opened before there was
    /// anything to remember.
    static let country = OpeningCamera(
        lat: 46.8182, lon: 8.2275, zoom: 7.4, bearing: 0, pitch: 0,
        clip: nil, where_: .country
    )

    static func resolve() -> OpeningCamera {
        if let remembered = Settings.camera() { return remembered }
        if let fix = lastKnownFix() {
            return OpeningCamera(
                lat: fix.latitude, lon: fix.longitude, zoom: localZoom,
                bearing: 0, pitch: 0,
                clip: viewport(centre: fix, zoom: localZoom),
                where_: .located
            )
        }
        return country
    }

    /// The fix the system is already holding, if it is holding one.
    ///
    /// Deliberately not a request. A `CLLocationManager` created here and asked
    /// for `location` answers from the cache or answers `nil`; it never blocks,
    /// and it never prompts — the permission dialog belongs to the map's puck,
    /// where it is asked for in the context of something visible happening.
    private static func lastKnownFix() -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default: return nil
        }
        guard let last = manager.location else { return nil }
        // A fix from last week is not where somebody is standing. An hour is
        // generous for "the phone has been here recently" and still rules out
        // opening on the city somebody flew home from.
        guard Date().timeIntervalSince(last.timestamp) < 3600 else { return nil }
        let here = last.coordinate
        guard CLLocationCoordinate2DIsValid(here) else { return nil }
        // Outside the country the network does not cover, the stored camera is
        // absent and the fix is useless: opening the Swiss transit map on Milan
        // shows an empty rectangle. The country is the better answer.
        guard Self.switzerland.contains(lon: here.longitude, lat: here.latitude) else { return nil }
        return here
    }

    /// Roughly the extent of the packed data, used only to decide whether a fix
    /// is worth opening on.
    private static let switzerland = BBox(west: 5.5, south: 45.6, east: 10.9, north: 48.0)

    /// The box a camera produces on this screen.
    ///
    /// Web-Mercator arithmetic: a zoom level is 256 points to a tile and 2^zoom
    /// tiles around the world, so a point is `360 / (256 · 2^zoom)` degrees of
    /// longitude — and that many degrees of latitude scaled by the cosine of
    /// where you are, because Mercator stretches north.
    ///
    /// An estimate, and it does not have to be better than one. It decides how
    /// much of the timetable to expand, and `TimetableStore` pads it and then
    /// matches against whole *routes* rather than positions, so being a little
    /// small costs a few journeys built that will not be drawn.
    static func viewport(
        centre: CLLocationCoordinate2D, zoom: Double, size: CGSize = screenSize
    ) -> BBox {
        let degreesPerPoint = 360 / (256 * pow(2, zoom))
        let lonSpan = Double(size.width) * degreesPerPoint
        let latSpan = Double(size.height) * degreesPerPoint * cos(centre.latitude * .pi / 180)
        return BBox(
            west: centre.longitude - lonSpan / 2,
            south: centre.latitude - latSpan / 2,
            east: centre.longitude + lonSpan / 2,
            north: centre.latitude + latSpan / 2
        )
    }

    /// The screen, or a plausible phone if the scene is not up yet.
    ///
    /// `start()` runs from a `.task` on the window's own content, so in practice
    /// the scene exists; the fallback is for the launch where it does not, and
    /// a wrong guess here costs a slightly wrong first viewport, not a wrong
    /// map.
    static var screenSize: CGSize {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        return scene?.screen.bounds.size ?? CGSize(width: 390, height: 844)
    }
}

// MARK: - Remembering it

extension Settings {
    private static let cameraKey = "camera"

    /// The camera the last session was left on.
    ///
    /// Stored as one dictionary rather than five keys so a half-written camera
    /// cannot be read back — a longitude from this session with a zoom from the
    /// last one is a map that opens somewhere nobody has ever been.
    static func camera() -> OpeningCamera? {
        guard let stored = UserDefaults.standard.dictionary(forKey: prefix + cameraKey),
              let lat = stored["lat"] as? Double,
              let lon = stored["lon"] as? Double,
              let zoom = stored["zoom"] as? Double,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        else { return nil }
        let centre = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        // The viewport is recomputed rather than restored. A stored one is only
        // right for the screen that wrote it, and the phone may have been
        // rotated — or be a different phone restoring a backup.
        return OpeningCamera(
            lat: lat, lon: lon, zoom: zoom,
            bearing: stored["bearing"] as? Double ?? 0,
            pitch: stored["pitch"] as? Double ?? 0,
            clip: OpeningCamera.viewport(centre: centre, zoom: zoom),
            where_: .remembered
        )
    }

    static func set(camera: OpeningCamera) {
        UserDefaults.standard.set([
            "lat": camera.lat, "lon": camera.lon, "zoom": camera.zoom,
            "bearing": camera.bearing, "pitch": camera.pitch,
        ], forKey: prefix + cameraKey)
    }
}
