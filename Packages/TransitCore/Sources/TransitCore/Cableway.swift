import Foundation

/// The fixed half of an aerial cableway: the stations, the rope strung between
/// them, and the towers that carry it.
///
/// **Why there is anything here at all.** A cabin hangs. `Silhouette.hover` has
/// said so for as long as the map has drawn one, and it put the pod where a pod
/// belongs — a dozen metres over the hillside instead of standing on it. What it
/// could not do is say *what from*. A rounded box floating over a meadow with
/// nothing above it is not a gondola; it is a box that has come loose. The rope
/// is the whole of the difference, and the rope is not part of the vehicle: it
/// belongs to the line, it is there when no cabin is, and every cabin on the
/// line hangs from the same one.
///
/// **Where the alignment comes from.** Nowhere new. A cableway is not in the
/// railway graph and OpenStreetMap's aerialway ways are not in the packed
/// relations, so an aerial leg falls all the way through `GeometryBuilder` to
/// the chord between its two stops — which, for once, is not a fallback but the
/// truth: a rope really does run straight from one station to the next. So the
/// rope is drawn along the journey's own geometry, whatever that geometry turned
/// out to be. Where a relation does describe the line the rope follows it; where
/// nothing does, it follows the chord the cabins are already flying along. The
/// rope and the cabins cannot disagree about where the line is, because they are
/// reading the same answer.
///
/// **Heights are shared with the mesh and that is the point.** Everything
/// vertical in a cableway is one number — `ropeHeight` — measured in the
/// vehicle's own metres. The cabin's `hover` is derived from it by subtracting
/// the cabin, its arm and its grip, so the top of a grip is at rope height by
/// construction rather than by two constants being kept in step by hand. Move
/// the rope and every cabin in the Alps moves with it.
public enum Cableway {
    // MARK: - The one vertical dimension

    /// How high the rope runs above the ground, in the vehicle's own metres.
    ///
    /// The vehicle's metres, not the map's: everything in `VehicleMesh` is
    /// written in true metres and multiplied by `VehicleShape.modelExaggeration`
    /// where it is placed, so a height that has to line up with a mesh has to be
    /// stated in the same units the mesh is. `drawnRopeHeight` is the same
    /// number in the metres the ground is measured in.
    ///
    /// Twelve and a half rather than forty. A rope over a mid-span meadow really
    /// is thirty or forty metres up, and drawn there the cabin is a speck in the
    /// sky above a map nobody can relate it to — which is the same argument
    /// `Silhouette.hover` already made and won. What this height has to be is
    /// *legibly off the ground*: high enough that the reader sees the cabin is
    /// flying, low enough that the station it flies into is still a building on
    /// the same map.
    public static let ropeHeight = 12.7

    /// The arm from the cabin's roof to the underside of the grip.
    public static let armHeight = 1.55

    /// The grip and the carriage it is part of, top to bottom.
    public static let gripDepth = 0.45

    /// The same, in the metres the map draws in.
    public static var drawnRopeHeight: Double {
        ropeHeight * VehicleShape.modelExaggeration
    }

    // MARK: - The station

    /// How long a station building is along the line, in drawn metres.
    ///
    /// A real valley station is a shed thirty or forty metres long with the
    /// bullwheel at one end of it. Drawn at that length it swamps the two-metre
    /// cabins it is there to explain, so it is cut to about half — long enough
    /// to read as a building the rope runs into, short enough that the cabin
    /// arriving is still the thing being looked at.
    public static let stationLength = 19.0
    /// And across it.
    public static let stationWidth = 11.0
    /// The roof over the running line, top to bottom. A station roof is above
    /// the rope, not level with it.
    public static let stationRoof = 2.2

    /// How much of the building's length each end pier takes.
    ///
    /// Two piers rather than four walls, and it is the difference between a
    /// station and a shed with a gondola sealed inside it. What a cableway
    /// station actually is, is a concrete deck with a roof over it on columns
    /// and the whole middle open: the cabins run in at deck height, round the
    /// bullwheel and out again, in plain sight the whole way. Drawn as a solid
    /// box to rope height it was exactly the wrong shape, and wrong in the way
    /// that costs the most — a cabin standing at its station is a cabin the
    /// reader has just followed there, and it vanished inside the building at
    /// the moment of arriving.
    public static let stationPier = 0.17

    /// The deck a cabin's floor is level with, in the metres the map draws in.
    ///
    /// Read off the cabin rather than chosen, for the same reason the rope's
    /// height is: the platform a gondola stops at is the height a gondola flies
    /// at, and one number that both are derived from cannot be got out of step
    /// with itself.
    public static var drawnDeckHeight: Double {
        Silhouette.aerialCabin.hover * VehicleShape.modelExaggeration
    }

    // MARK: - The towers

    /// How far apart the towers stand, in metres.
    ///
    /// Not a fact about any particular line — tower spacing is a function of the
    /// ground, and the ground is not in the data. What it has to be is *often
    /// enough that the rope is plainly being held up*: a line at 18 m with
    /// nothing under it for two kilometres reads as a line drawn on the sky.
    static let towerSpacing = 320.0
    /// How close to a station a tower may stand. Inside this the station
    /// building is the structure holding the rope, and a tower there is a mast
    /// through the roof.
    static let towerClearance = 90.0
    public static let towerWidth = 2.0
    /// The crosshead the sheaves hang from, across the line.
    public static let towerHead = 5.2
    public static let towerHeadDepth = 1.1

    // MARK: - Which vehicles hang

    /// Whether this run is a cabin on a rope rather than a car on rails.
    ///
    /// Asked of `LayoutLibrary`, and it must be. The vehicle drawn for a run and
    /// the infrastructure drawn under it are two answers to one question — is
    /// this thing hanging — and a second copy of that decision here would
    /// eventually disagree with the first. What disagreement looks like is the
    /// only kind of bug this feature can really have: a pod in the air beside a
    /// rope that is not under it, or a funicular climbing a hillside with a
    /// cableway strung over the top of it. See `LayoutLibrary.CableKind`.
    ///
    /// A run with no category is not a gondola here for exactly the reason it is
    /// not drawn as one there: nothing on the device says it is. That covers
    /// every run read out of the packed archive rather than the live feed — the
    /// pack collapses GTFS's route types to one mode per route — so the ropes
    /// appear where the cabins do and nowhere else, which is the property worth
    /// keeping.
    public static func hangs(mode: Mode, category: String?) -> Bool {
        guard mode == .cable else { return false }
        return LayoutLibrary.cableKind(of: category)?.hangs ?? false
    }

    /// The same question of a vehicle the fleet has already resolved.
    ///
    /// This is the one the map asks. `hangs(mode:category:)` above can only read
    /// what the feed *said*, and on nearly every cable service in the country
    /// the feed says nothing — see `Fleet.cableKind(of:)`. The snapshot carries
    /// the worked-out answer, and it is the same answer `LayoutLibrary` drew the
    /// body from, so a cabin and its rope cannot disagree.
    public static func hangs(_ vehicle: VehicleSnapshot) -> Bool {
        guard vehicle.mode == .cable else { return false }
        let kind = LayoutLibrary.cableKind(of: vehicle.category) ?? vehicle.cable
        return kind?.hangs ?? false
    }

    // MARK: - The plan

    /// One station: where it stands, and which way the line runs through it.
    public struct Station: Sendable, Equatable {
        public var at: Coord
        /// The compass bearing the building is aligned along — the rope's own
        /// direction through it. A station is a shed built round the line, so
        /// this is not decoration: a box lying across the rope reads as a
        /// warehouse somebody has parked next to the cableway.
        public var bearing: Double
    }

    /// One rope between two stations, as the polyline it is strung along.
    public struct Span: Sendable, Equatable {
        public var points: [Coord]
    }

    /// Every cableway currently worth drawing, deduplicated.
    public struct Plan: Sendable, Equatable {
        public var stations: [Station] = []
        public var spans: [Span] = []
        public var isEmpty: Bool { stations.isEmpty && spans.isEmpty }
        public init(stations: [Station] = [], spans: [Span] = []) {
            self.stations = stations
            self.spans = spans
        }
    }

    /// Longer than any aerial span in the country, in metres.
    ///
    /// The Vanoise Express is 1,850 m between towers and the longest single
    /// Swiss span is shorter than that; anything past this is not a cableway, it
    /// is a chord drawn between two stops that were never joined by one — a
    /// mis-matched journey, a feed that has filed a bus under `PB`. Drawing it
    /// would run a rope across a canton.
    static let longestSpan = 9_000.0

    /// And shorter than any of them, in metres.
    ///
    /// A ropeway with a mid-station has a short leg into it, but not a fifty
    /// metre one: below this the two "stops" are two names for one station —
    /// a valley terminal and the road stop outside it — and a rope drawn
    /// between them is a stub sticking out of the shed.
    static let shortestSpan = 120.0

    /// The stations and ropes implied by whatever aerial runs are on screen.
    ///
    /// **Deduplicated by place, not by line.** A gondola line is a great many
    /// cabins and the feed reports each as its own journey, in both directions,
    /// all of them on the same rope — so grouping by line number would draw the
    /// same span forty times and grouping by journey would draw it once per
    /// cabin. What identifies a span is its two ends, unordered, to about a
    /// metre; what identifies a station is where it is. Both fall out of the
    /// coordinates and neither needs the feed to be consistent about names.
    ///
    /// **Built from the journeys rather than from a table** because there is no
    /// table: the packed data has no aerialway network in it. The cost of that
    /// is honest and worth stating — a line with nothing running on it has no
    /// rope, because nothing on the device knows it exists. In practice a
    /// gondola runs a cabin every twenty seconds all day, and the run that has
    /// just left carries the whole line's stop list with it.
    public static func plan(for vehicles: [VehicleSnapshot]) -> Plan {
        /// A coordinate rounded to about a metre, for matching two journeys'
        /// idea of the same station.
        func cell(_ at: Coord) -> Int64 {
            let lon = Int64((at.lon * 100_000).rounded())
            let lat = Int64((at.lat * 100_000).rounded())
            return lon &* 4_000_000 &+ lat
        }

        var spans: [Int64: Span] = [:]
        /// Every direction the line leaves a station in, so a mid station can be
        /// aligned with the line through it rather than with one of its halves.
        var legs: [Int64: (at: Coord, bearings: [Double])] = [:]

        for vehicle in vehicles where hangs(vehicle) {
            let stops = vehicle.stops
            guard stops.count >= 2 else { continue }
            for i in 1..<stops.count {
                let from = stops[i - 1].coord
                let to = stops[i].coord
                let length = Geo.metres(from, to)
                guard length >= shortestSpan, length < longestSpan else { continue }

                let key = cell(from) < cell(to)
                    ? cell(from) &* 8_000_000_000 &+ cell(to)
                    : cell(to) &* 8_000_000_000 &+ cell(from)

                // The mapped alignment where the journey has one, and the chord
                // where it has not — which for an aerial leg is the same line.
                // Kept only if it is a better description than what some other
                // cabin on the same rope already contributed: a run whose
                // geometry has not been attached yet must not overwrite one
                // whose has.
                let along = path(of: vehicle, leg: i - 1) ?? [from, to]
                if (spans[key]?.points.count ?? 0) < along.count {
                    spans[key] = Span(points: along)
                }

                note(&legs, at: from, towards: along.count > 1 ? along[1] : to)
                note(
                    &legs, at: to,
                    towards: along.count > 1 ? along[along.count - 2] : from
                )
            }
        }

        var plan = Plan()
        plan.spans = spans.values.sorted { $0.points[0].lon < $1.points[0].lon }
        plan.stations = legs.values
            .map { Station(at: $0.at, bearing: alignment(of: $0.bearings)) }
            .sorted { $0.at.lon < $1.at.lon }
        return plan
    }

    /// Record which way the line leaves this station.
    private static func note(
        _ legs: inout [Int64: (at: Coord, bearings: [Double])],
        at station: Coord, towards next: Coord
    ) {
        func cell(_ at: Coord) -> Int64 {
            Int64((at.lon * 100_000).rounded()) &* 4_000_000
                &+ Int64((at.lat * 100_000).rounded())
        }
        guard Geo.metres(station, next) > 0.5 else { return }
        let bearing = Geo.bearing(station, next)
        legs[cell(station), default: (station, [])].bearings.append(bearing)
    }

    /// One heading for a building the line runs *through*.
    ///
    /// Averaged as axes rather than as directions, which is the whole of it: a
    /// mid station is left in two opposite directions, and the mean of 20° and
    /// 200° is 110° — a shed at right angles to its own rope. Doubling the
    /// angles folds the two into one, and halving the answer brings it back.
    static func alignment(of bearings: [Double]) -> Double {
        guard !bearings.isEmpty else { return 0 }
        var x = 0.0
        var y = 0.0
        for bearing in bearings {
            let doubled = Geo.toRad(bearing * 2)
            x += cos(doubled)
            y += sin(doubled)
        }
        guard x != 0 || y != 0 else { return bearings[0] }
        let mean = Geo.toDeg(atan2(y, x)) / 2
        return mean < 0 ? mean + 180 : mean
    }

    /// The polyline one leg of a journey is drawn along, where the journey has
    /// geometry attached and it names this leg.
    static func path(of vehicle: VehicleSnapshot, leg: Int) -> [Coord]? {
        guard let geometry = vehicle.geometry,
              leg >= 0, leg + 1 < geometry.legs.count
        else { return nil }
        let from = geometry.legs[leg]
        let to = geometry.legs[leg + 1]
        guard from >= 0, to > from, to < geometry.path.count else { return nil }
        return Array(geometry.path[from...to])
    }

    // MARK: - The towers

    /// Where the towers stand along one span.
    ///
    /// Walked in real metres rather than dropped every *n* vertices, because a
    /// span is usually two points and sometimes two hundred, and a tower every
    /// vertex would be either none at all or a fence.
    public static func towers(along points: [Coord]) -> [(at: Coord, bearing: Double)] {
        guard points.count >= 2 else { return [] }
        let total = Geo.length(of: points)
        guard total > towerClearance * 2 + towerSpacing * 0.5 else { return [] }

        var out: [(at: Coord, bearing: Double)] = []
        var walked = 0.0
        var next = towerClearance + towerSpacing
        for i in 1..<points.count {
            let step = Geo.metres(points[i - 1], points[i])
            guard step > 0 else { continue }
            while next <= walked + step, next <= total - towerClearance {
                let share = (next - walked) / step
                out.append((
                    at: Geo.interpolate(points[i - 1], points[i], share),
                    bearing: Geo.bearing(points[i - 1], points[i])
                ))
                next += towerSpacing
            }
            walked += step
        }
        return out
    }
}
