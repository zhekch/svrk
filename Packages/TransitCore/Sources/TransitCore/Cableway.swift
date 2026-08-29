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

    /// How much daylight a taut rope keeps over the ground it passes, in drawn
    /// metres.
    ///
    /// This is what the towers are for and it is the whole shape of the answer
    /// below: a rope is straight until the mountain gets in its way, and where
    /// the mountain gets in its way somebody has built a tower. Eight metres is
    /// enough that the rope reads as clearing the ridge rather than grazing it,
    /// and low enough that a tower on a shoulder is a tower rather than a mast.
    public static let clearance = 8.0

    /// How far inside that clearance a rope is allowed to cut a corner, in
    /// drawn metres.
    ///
    /// This is the number that decides how many towers a line gets, and it is
    /// the one thing here that is a drawing decision rather than a fact. At
    /// nothing, every sample of a smooth hillside is a tower; at ten metres, a
    /// line over a ridge is a straight rope through the top of it. Two is a
    /// hand's breadth against the eight above, so a rope still visibly clears
    /// what it passes, and a mountainside comes out with three or four towers
    /// on it rather than fifty.
    public static let slack = 2.0

    /// Longest a rope may run without a tower under it, in metres.
    ///
    /// The taut profile puts a tower wherever the rope actually bends, which is
    /// the honest place for one, and on an even hillside that is nowhere at
    /// all. A two-kilometre span with nothing under it reads as a line drawn on
    /// the sky, so the straight stretches are filled in.
    public static let towerFill = 340.0

    /// One rope, as the heights it actually hangs at.
    ///
    /// Held by the coordinator after it is built, because two things need it
    /// and they must agree exactly: the line that draws the rope, and the lift
    /// that hangs the cabins on it. See `MapCoordinator.rest`.
    public struct Rope {
        /// The plan, resampled.
        public var points: [Coord]
        /// How far along the span each of those is, in metres.
        public var along: [Double]
        /// The ground under each, in the metres the map draws in.
        public var ground: [Double]
        /// And where the rope is, above sea level, at each.
        public var altitude: [Double]
        /// The distances at which the rope changes angle — the towers.
        public var bends: [Double]

        public var total: Double { along.last ?? 0 }

        /// The rope's height above sea level at a point near it, and the ground
        /// under that point, or nil if the point is not on this span.
        ///
        /// Nearest vertex rather than a true perpendicular projection: the
        /// points are twenty-five metres apart and a cabin is never more than a
        /// few metres off the line it is running on, so the two answers differ
        /// by less than the thickness of the rope.
        public func at(_ coord: Coord, within metres: Double) -> (rope: Double, ground: Double)? {
            var best = metres
            var found: Int?
            for (i, point) in points.enumerated() {
                let d = Geo.metres(point, coord)
                if d < best { best = d; found = i }
            }
            guard let found else { return nil }
            return (altitude[found], ground[found])
        }
    }

    // MARK: - Pulling the rope tight

    /// The rope a taut cable would take over this ground.
    ///
    /// **It is the upper convex hull of the clearance profile, and that is not
    /// an approximation of a rope — it is what a rope is.** Pull a string tight
    /// between two points over a lumpy surface and it touches the surface at
    /// exactly the points of the upper hull and runs dead straight between
    /// them. Every one of those touch points is where a real cableway has a
    /// tower, which is why the towers below are placed at them rather than at
    /// an interval somebody chose.
    ///
    /// The two ends are pinned at rope height over their own stations, because
    /// that is where the rope leaves the building; everything between is pinned
    /// no lower than `clearance` over the ground. So a span across a valley
    /// comes out as one straight line with a hundred metres of air under it,
    /// and a span up an even hillside comes out parallel to the hill, which is
    /// what each of them looks like.
    ///
    /// Nil if the terrain has not been measured at every point — a span half
    /// measured would be pulled tight against ground that is not there yet.
    public static func taut(along points: [Coord], ground: (Coord) -> Double?) -> Rope? {
        var along: [Double] = [0]
        var floor: [Double] = []
        var heights: [Double] = []
        for (i, point) in points.enumerated() {
            guard let g = ground(point), g.isFinite else { return nil }
            heights.append(g)
            if i > 0 { along.append(along[i - 1] + Geo.metres(points[i - 1], point)) }
        }
        guard along.count == points.count, let last = along.last, last > 0 else { return nil }

        // What the rope may not go below: its own station height at the two
        // ends, and a clearance over the ground everywhere between.
        for (i, g) in heights.enumerated() {
            let isEnd = i == 0 || i == heights.count - 1
            floor.append(g + (isEnd ? Cableway.drawnRopeHeight : clearance))
        }

        // The upper hull, by monotone chain. A point is kept while the turn it
        // makes with the two before it is a right one; a left turn means the
        // middle point is under the line joining its neighbours, which is a
        // point the rope flies over.
        var hull: [Int] = []
        for i in 0..<floor.count {
            while hull.count >= 2 {
                let a = hull[hull.count - 2], b = hull[hull.count - 1]
                let cross = (along[b] - along[a]) * (floor[i] - floor[a])
                    - (floor[b] - floor[a]) * (along[i] - along[a])
                if cross >= 0 { hull.removeLast() } else { break }
            }
            hull.append(i)
        }
        guard hull.count >= 2 else { return nil }

        // **And then most of the hull is thrown away, which is the difference
        // between a rope and a contour line.**
        //
        // The hull is exactly right and it is too detailed to be a cableway. A
        // taut string over a *smooth* dome touches the dome all the way across
        // it — that is a true fact about strings, and it came out as fifty-seven
        // towers up one hillside. What a real rope does is bear on a handful of
        // towers and cut the corner between them, hanging a metre or two closer
        // to the ground in the middle of each stretch than a string pulled
        // infinitely tight would.
        //
        // So the vertices are walked greedily and skipped for as long as the
        // straight chord over them stays within `slack` of the ground it is
        // supposed to clear. Where the hillside is smooth, consecutive hull
        // points are nearly in line and the chord skips the lot; where there is
        // an actual ridge, the chord would cut into it and the vertex is kept.
        // What is left is the set of points the rope genuinely needs bearing
        // on, which is the set of points somebody built a tower on.
        var supports: [Int] = [hull[0]]
        var k = 0
        while k < hull.count - 1 {
            var reach = k + 1
            var next = k + 1
            while next < hull.count {
                let a = supports[supports.count - 1], b = hull[next]
                let run = along[b] - along[a]
                var clears = true
                if run > 0 {
                    for j in (k + 1)..<next {
                        let i = hull[j]
                        let share = (along[i] - along[a]) / run
                        let chord = floor[a] + (floor[b] - floor[a]) * share
                        if chord < floor[i] - slack { clears = false; break }
                    }
                }
                if !clears { break }
                reach = next
                next += 1
            }
            supports.append(hull[reach])
            k = reach
        }

        // And the height at every point of the span, read off what is left.
        var altitude = [Double](repeating: 0, count: floor.count)
        for k in 1..<supports.count {
            let a = supports[k - 1], b = supports[k]
            let run = along[b] - along[a]
            for i in a...b {
                let share = run > 0 ? (along[i] - along[a]) / run : 0
                altitude[i] = floor[a] + (floor[b] - floor[a]) * share
            }
        }
        return Rope(
            points: points, along: along, ground: heights, altitude: altitude,
            bends: supports.dropFirst().dropLast().map { along[$0] }
        )
    }

    /// The rope's height above sea level at a distance along it.
    public static func height(of rope: Rope, at distance: Double) -> Double {
        position(rope, at: distance)?.height ?? (rope.altitude.first ?? 0)
    }

    /// Where a distance along the rope falls: the point, the ground under it,
    /// the rope over it, and which way the line is running there.
    public static func position(
        _ rope: Rope, at distance: Double
    ) -> (coord: Coord, ground: Double, height: Double, bearing: Double)? {
        guard rope.points.count >= 2 else { return nil }
        let want = min(max(0, distance), rope.total)
        var i = 1
        while i < rope.along.count - 1 && rope.along[i] < want { i += 1 }
        let a = i - 1, b = i
        let run = rope.along[b] - rope.along[a]
        let share = run > 0 ? (want - rope.along[a]) / run : 0
        return (
            coord: Geo.interpolate(rope.points[a], rope.points[b], share),
            ground: rope.ground[a] + (rope.ground[b] - rope.ground[a]) * share,
            height: rope.altitude[a] + (rope.altitude[b] - rope.altitude[a]) * share,
            bearing: Geo.bearing(rope.points[a], rope.points[b])
        )
    }

    /// The stretch of the plan between two distances along it.
    public static func slice(_ rope: Rope, from: Double, to: Double) -> [Coord] {
        var out: [Coord] = []
        if let head = position(rope, at: from) { out.append(head.coord) }
        for (i, point) in rope.points.enumerated()
        where rope.along[i] > from + 0.5 && rope.along[i] < to - 0.5 {
            out.append(point)
        }
        if let tail = position(rope, at: to) { out.append(tail.coord) }
        return out
    }

    /// Where the towers stand: at every bend, and down the straight stretches
    /// between them so a long clear span is still held up by something.
    public static func towerPoints(of rope: Rope) -> [Double] {
        var stops = [0.0] + rope.bends + [rope.total]
        stops.sort()
        var out: [Double] = rope.bends
        for i in 1..<max(2, stops.count) where i < stops.count {
            let run = stops[i] - stops[i - 1]
            guard run > towerFill * 1.5 else { continue }
            let count = Int((run / towerFill).rounded())
            guard count > 1 else { continue }
            for k in 1..<count {
                out.append(stops[i - 1] + run * Double(k) / Double(count))
            }
        }
        // Never inside a station.
        return out.filter {
            $0 > Cableway.towerClearance && $0 < rope.total - Cableway.towerClearance
        }
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
    public static let towerClearance = 90.0
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
