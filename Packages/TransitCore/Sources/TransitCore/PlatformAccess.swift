import Foundation

/// The platform as a strip of ground, and the ways on and off it.
///
/// The formation panel could already say which coach and which sector, which is
/// half of what somebody standing at a barrier wants. The other half is how far
/// to walk, and that needs the platform itself to be a thing with a length and
/// two ends rather than a letter in a caption.
///
/// **Where this does not come from.** ATLAS was the obvious source and does not
/// have it, which is worth writing down so nobody checks twice. Its
/// *Verkehrspunktelemente* half (`TrafficPointElementVersion`) is geometry —
/// sloid, length, compass direction, a point — and lists no access furniture at
/// all. Its *PRM* half knows about lifts and ramps, through `boardingDevice`
/// (RAMPS | LIFTS | NO) and `stepFreeAccess` (YES_WITH_LIFT | YES_WITH_RAMP |
/// …), but `PlatformVersion` carries no coordinates whatever: it says a
/// platform *has* a lift and never where. So the positions are OpenStreetMap's,
/// resolved at build time by `scripts/build-platform-access.mjs`.
///
/// **What arrives here** is therefore already projected: each access point is a
/// fraction of the way along the platform's own line, not a coordinate. The
/// phone never re-projects anything, and a strip is drawn from four numbers.
public struct AccessPoint: Sendable, Equatable {
    /// Which of the four ways up this is.
    ///
    /// An escalator is not a staircase with a note attached — for somebody
    /// deciding whether to walk two hundred metres with a suitcase it is the
    /// whole answer — so it is its own case rather than a flag on `stairs`.
    public enum Kind: UInt8, Sendable, Equatable {
        case stairs = 0
        case escalator = 1
        case lift = 2
        case ramp = 3
    }

    /// How far along the platform, from the end its line starts at. 0…1.
    public var fraction: Double
    public var kind: Kind

    public init(fraction: Double, kind: Kind) {
        self.fraction = fraction
        self.kind = kind
    }
}

/// One platform, as a line on the ground with things standing along it.
public struct PlatformStrip: Sendable, Equatable {
    /// The platform's centreline, simplified to a couple of metres. Two points
    /// for the great majority of platforms and a handful for a curved one.
    public var line: [Coord]
    /// Its length in metres, measured along `line` before simplification.
    public var length: Double
    /// Sorted by `fraction`, so a drawing walks them in platform order.
    public var access: [AccessPoint]

    public init(line: [Coord], length: Double, access: [AccessPoint]) {
        self.line = line
        self.length = length
        self.access = access
    }

    /// Where a point on the ground falls along this platform, 0…1.
    ///
    /// Clamped, deliberately. A train's nose overhanging the end of a platform
    /// is a real thing that happens and the honest drawing of it is a train
    /// flush with the end, not one hanging off it.
    public func fraction(of point: Coord) -> Double {
        guard line.count >= 2, length > 0 else { return 0 }
        var travelled = 0.0
        var best = (along: 0.0, off: Double.infinity)
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let foot = Geo.footOnSegment(lon: point.lon, lat: point.lat, a: a, b: b)
            let off = Geo.metres(point, foot)
            let segment = Geo.metres(a, b)
            if off < best.off { best = (travelled + Geo.metres(a, foot), off) }
            travelled += segment
        }
        return min(1, max(0, best.along / length))
    }

    /// Which way the line runs, as a compass bearing from its first point to
    /// its last. The one number that says whether fractions increase with or
    /// against a train's direction of travel.
    public var bearing: Double {
        guard let first = line.first, let last = line.last, line.count >= 2 else { return 0 }
        return Geo.bearing(first, last)
    }
}

/// `station|track` → the strip drawn for it.
///
/// Keyed by track rather than by SLOID, and for the same reason
/// `OSMPlatformIndex.coveredTracks()` is: the register lists Bern's platform 7
/// three times over as `7`, `7A-D` and `7E-H`, and they are one platform with
/// one strip. Keyed by SLOID they would be three strips, two of them unreachable
/// from a departure board that says `7A-D`.
public final class PlatformAccessIndex: @unchecked Sendable {
    private var table: [String: PlatformStrip] = [:]

    public init() {}

    public var isReady: Bool { !table.isEmpty }
    public var platformCount: Int { table.count }

    public func load(_ url: URL) throws {
        var reader = BinaryReader(try MappedFile(url: url))
        try reader.expect(magic: "SVACCESS", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let count = Int(try reader.readUInt32())
        var built = [String: PlatformStrip](minimumCapacity: count)
        for _ in 0..<count {
            let key = strings[Int(try reader.readUInt32())]
            // Decimetres, so the whole file is integers and nothing has to be
            // aligned for a float read. A platform measured to the centimetre
            // would be measured more precisely than OSM draws it.
            let length = Double(try reader.readUInt32()) / 10

            let pointCount = Int(try reader.readUInt32())
            var line: [Coord] = []
            line.reserveCapacity(pointCount)
            for _ in 0..<pointCount {
                let lon = BinaryFormat.decode(try reader.readInt32())
                let lat = BinaryFormat.decode(try reader.readInt32())
                line.append(Coord(lon: lon, lat: lat))
            }

            let accessCount = Int(try reader.readUInt32())
            var access: [AccessPoint] = []
            access.reserveCapacity(accessCount)
            for _ in 0..<accessCount {
                let fraction = Double(try reader.readUInt32()) / 1000
                let raw = UInt8(truncatingIfNeeded: try reader.readUInt32())
                guard let kind = AccessPoint.Kind(rawValue: raw) else { continue }
                access.append(AccessPoint(fraction: fraction, kind: kind))
            }

            built[key] = PlatformStrip(line: line, length: length, access: access)
        }
        table = built
    }

    /// The strip for a departure board's platform code.
    ///
    /// The code is normalised and its sector suffix dropped before the lookup,
    /// because the feed reports the section a train stops in rather than the
    /// platform — an IC on Bern's platform 1 arrives as `1A-D`, and there is no
    /// strip filed under that.
    public func strip(station: String, track: String) -> PlatformStrip? {
        guard isReady else { return nil }
        // Normalised as well as cut. The build writes `7`; a board that says
        // `07A-D` has to arrive at the same key or the strip is simply missing
        // for whichever operator writes its platforms with a leading zero.
        let code = StopRegister.normaliseCode(StopRegister.trackOf(track) ?? "")
        guard !code.isEmpty, !station.isEmpty else { return nil }
        return table["\(station)|\(code)"]
    }

    /// The strip for a SLOID, which knows its own station.
    public func strip(sloid: String, track: String) -> PlatformStrip? {
        strip(station: StopRegister.stationOf(sloid), track: track)
    }
}

// MARK: - Putting a train on the strip

/// Where a train stands on a platform, in the platform's own coordinates.
///
/// `head` and `tail` are both fractions of the platform and either may be the
/// larger: which end the train's nose is at depends on which way it came in,
/// and forcing them into order would erase exactly that.
public struct StripSpan: Sendable, Equatable {
    public var head: Double
    public var tail: Double

    public init(head: Double, tail: Double) {
        self.head = head
        self.tail = tail
    }

    public var lower: Double { min(head, tail) }
    public var upper: Double { max(head, tail) }

    /// Whether fractions grow from the nose backwards — which is to say whether
    /// the train arrived pointing at the far end of the line or the near one.
    public var reversed: Bool { tail < head }

    /// A fraction of the way from the nose to the rear, as a platform fraction.
    public func alongTrain(_ f: Double) -> Double { head + (tail - head) * f }
}

public enum PlatformPlacement {
    /// Where a train standing at stop `index` sits on `strip`.
    ///
    /// Takes the stop list and the drawn geometry rather than a `Journey`,
    /// because the panel that wants this holds a `VehicleSnapshot` and those are
    /// the two fields of it that matter. It also means the answer is the same
    /// for any stop of the run, not only the one the train is at now: the
    /// geometry is the line the train physically runs on, and stop 9's point on
    /// it is as knowable as stop 2's.
    ///
    /// The direction is the half that cannot be guessed. A train extends
    /// *backwards* from its nose, so which way it lies along the platform is
    /// the bearing it faces compared with the bearing of the platform's own
    /// line: agreeing means the train runs back towards fraction 0, disagreeing
    /// means it runs on towards 1. Without this a westbound train at Bern comes
    /// out occupying the sectors of the eastbound one.
    public static func place(
        stops: [Call], geometry: JourneyGeometry?, at index: Int,
        length: Double, on strip: PlatformStrip
    ) -> StripSpan? {
        guard index >= 0, index < stops.count, stops.count >= 2 else { return nil }
        guard length > 0, strip.length > 0, strip.line.count >= 2 else { return nil }
        guard let facing = heading(stops: stops, geometry: geometry, at: index) else { return nil }

        let head = strip.fraction(of: facing.point)
        let span = min(1, length / strip.length)

        // Within a quarter turn is "the same way". A platform line and the
        // track beside it are never more than a degree or two apart, so the
        // test is nowhere near its own boundary and does not need to be gentle.
        let delta = (facing.bearing - strip.bearing).truncatingRemainder(dividingBy: 360)
        let turned = abs(delta < 0 ? delta + 360 : delta)
        let sameWay = turned < 90 || turned > 270

        // The nose is at `head` and the train lies behind it. Where the whole
        // train will not fit behind the nose, the platform is shorter than the
        // train — routine at a request halt — and the drawing then shows the
        // train filling the platform, which is what it looks like from the end
        // of one.
        let tail = sameWay ? head - span : head + span
        if tail < 0 { return StripSpan(head: min(1, span), tail: 0) }
        if tail > 1 { return StripSpan(head: max(0, 1 - span), tail: 1) }
        return StripSpan(head: head, tail: tail)
    }

    /// Where the train's nose is at stop `index`, and which way it points.
    ///
    /// The mapped track wins over the station coordinate for the same reason it
    /// does everywhere else in `Positioning`: standing at a platform is exactly
    /// where a station's registered point is furthest from the truth. Bern's is
    /// ninety metres from platform 12 and on top of platform 4, which as a
    /// fraction of a platform is most of the way along it.
    private static func heading(
        stops: [Call], geometry: JourneyGeometry?, at index: Int
    ) -> (point: Coord, bearing: Double)? {
        let ahead = index + 1 < stops.count ? stops[index + 1].coord : nil
        let behind = index > 0 ? stops[index - 1].coord : nil
        let fallback = ahead.map { Geo.bearing(stops[index].coord, $0) }
            ?? behind.map { Geo.bearing($0, stops[index].coord) }
        guard let fallback else { return nil }

        // A geometry built for a different version of the stop list answers for
        // the wrong stop — see `Positioning.usableGeometry`, where the same
        // check is what stopped a train booked for Thun being drawn at Bern.
        guard let geometry, geometry.legs.count == stops.count, !geometry.path.isEmpty,
              index < geometry.legs.count
        else { return (stops[index].coord, fallback) }

        let at = geometry.legs[index]
        guard at >= 0, at < geometry.path.count else { return (stops[index].coord, fallback) }
        let point = geometry.path[at]

        // Along the line, taken from the neighbouring vertex on whichever side
        // exists. At a terminus that is the one it arrived over, which is the
        // way it is still pointing.
        if at + 1 < geometry.path.count {
            return (point, Geo.bearing(point, geometry.path[at + 1]))
        }
        if at > 0 {
            return (point, Geo.bearing(geometry.path[at - 1], point))
        }
        return (point, fallback)
    }
}
