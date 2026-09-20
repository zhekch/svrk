import Foundation
import os

/// A dominant scheduled headway for one advertised service at one station.
/// It is derived from packed integers without expanding the day's journeys.
public struct TimetableCadence: Sendable, Equatable {
    public static func intervalDescription(_ minutes: Int, prefix: String = "every") -> String {
        guard minutes >= 60 else { return "\(prefix) \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return hours == 1 ? "\(prefix) hour" : "\(prefix) \(hours) hours"
        }
        return "\(prefix) \(hours) hr \(remainder) min"
    }

    public var mode: Mode
    public var line: String
    /// The first different station after the board stop. This stays stable when
    /// a late service short-turns at Spiez instead of continuing to Bern.
    public var direction: String
    public var minutes: Int

    public init(mode: Mode, line: String, direction: String, minutes: Int) {
        self.mode = mode
        self.line = line
        self.direction = direction
        self.minutes = minutes
    }
}

/// The national timetable, read in place.
///
/// The app used to learn what was running by downloading the country: SIRI-ET
/// has no regional filter, so every refresh was 7 MB on the wire and ~150 MB of
/// XML, and almost all of it was the *timetable* — which does not change from
/// one minute to the next. This store is that timetable, packed once by
/// `scripts/pack-timetable.mjs` and mapped rather than parsed, so the map can
/// draw the whole country with the network switched off.
///
/// What makes a year fit at all is the Takt. A pattern here is a stop sequence
/// *together with its relative times*, and keyed that way the feed's 2,071,007
/// trips fold to 179,287 patterns — the same shape of journey, run every hour,
/// stored once. A trip is then a pattern, a service, and the minute it starts.
///
/// Two invariants the rest of the app depends on:
///
/// - **A day is never expanded.** A weekday holds 215,943 trips and 3.07 million
///   calls; building those as `Journey` objects would cost something like 150 MB
///   of heap for data the map cannot draw. Only the asked-for window is built,
///   and because trips are stored sorted by start minute that window is a binary
///   search and a range scan rather than a sweep.
/// - **Calls name a SLOID and nothing else.** No coordinates are stored here,
///   because `stop_times.stop_id` in this feed *is* the SLOID with platform —
///   the same key `StopRegister` is built on — so placement goes through the
///   register exactly as it does for a SIRI call.
public final class TimetableStore: @unchecked Sendable {
    static let magic = "SVTIMTB1"
    /// Format 4 carries the through-service graph. Earlier formats are not
    /// read: the graph is not an optional extra any more, it is how chaining
    /// works, and an archive without it would quietly fall back to guessing.
    static let version: UInt32 = 4

    /// One trip: pattern, service, start minute, class, id prefix, number, id
    /// suffix. Deliberately not a multiple of four — at two million trips the
    /// padding would cost more than the unaligned loads do.
    static let tripStride = 22

    /// One call in a pattern: stop slot, and minutes from the trip's first
    /// arrival to this call's arrival and departure.
    static let callStride = 8

    private let file: MappedFile
    private let bytes: UnsafeRawBufferPointer

    /// The packed string blob, decoded on first use rather than at open.
    ///
    /// The table holds 353,733 entries. Materialising every one as a `String`
    /// was most of "Reading the transit network" on a phone — a launch that
    /// then drew one canton had paid for the names of every stop in the
    /// country. The blob stays mapped; a viewport interned a few thousand.
    private let stringCount: Int
    private let stringOffsetsAt: Int
    private let stringBlobAt: Int
    private var interned: [String?] = []

    /// Days since 1970 of the feed's first service day; the calendar bitmaps
    /// are indexed from here.
    private let feedStart: Int
    private let dayCount: Int
    private let serviceStride: Int

    private let servicesAt: Int
    private let stopsAt: Int
    private let prefixesAt: Int
    private let classesAt: Int
    private let patternIndexAt: Int
    private let patternCallsAt: Int
    private let tripsAt: Int
    private let suffixesAt: Int
    /// Format 2: the GTFS `trip_id`, which is what GTFS-Realtime names runs by.
    private let keyPairsAt: Int
    private let tripKeysAt: Int
    private let literalsAt: Int
    private let keyPairCount: Int
    private let routesAt: Int
    private let routeCount: Int
    /// The through-service graph: which numbered workings are one vehicle.
    private let linksAt: Int
    private let linkCount: Int

    /// `route_id` to the line it is published as, and the mode it runs in.
    ///
    /// Kept because GTFS-Realtime names an *added* run — one in no timetable —
    /// by its route and nothing else. Small enough (5,121 routes) to hold as a
    /// dictionary rather than searched in place, and filled on first ask
    /// because a launch that never sees an extra run never asks.
    private var routeLines: [String: (line: String?, mode: Mode)] = [:]

    public private(set) var patternCount = 0
    public private(set) var tripCount = 0
    private let stopCount: Int
    private let classCount: Int
    private let prefixCount: Int

    /// Each pattern's last departure offset, so a window query can reject a trip
    /// that finished before the window opened without reading its calls.
    ///
    /// Filled per pattern on first use. Opening used to walk every pattern's
    /// last call — 179,287 jumps into the mapped file — before anything had
    /// been asked for. A viewport only needs the patterns in its window.
    private var patternDuration: [Int32] = []

    /// Bound used to open a window query. Larger than any real run in this
    /// feed (a night service filed at 25:40 is still well under a day), so a
    /// query that has not yet seen every pattern still includes trips that
    /// started before the window and have not finished.
    ///
    /// Forty-eight hours used to be the floor, which for a day-relative start
    /// minute is "scan from midnight". After durations are known this tightens
    /// to the longest pattern plus a little slack.
    private var lookbackMinutes = 16 * 60

    /// Sentinel: this pattern's duration has not been read yet.
    private static let unknownDuration: Int32 = -1

    public var isReady: Bool { tripCount > 0 }

    /// Slot coordinates, pattern boxes and durations are filled, either from
    /// a cache written by an earlier launch or from one sequential pass.
    public private(set) var geographyReady = false

    /// Where the derived geography is kept between launches, if anywhere.
    private var geographyURL: URL?

    private static let log = Logger(subsystem: "com.kexts.swisstransit", category: "timetable")

    public init(url: URL) throws {
        file = try MappedFile(url: url)
        bytes = file.buffer

        var reader = BinaryReader(file)
        try reader.expect(magic: Self.magic, version: Self.version)
        // Mapped, not decoded. See `interned`.
        stringCount = Int(try reader.readUInt32())
        stringOffsetsAt = try reader.skip((stringCount + 1) * 4)
        let blobLength = Int(
            bytes.loadUnaligned(fromByteOffset: stringOffsetsAt + stringCount * 4, as: UInt32.self)
        )
        stringBlobAt = try reader.skip(blobLength)
        try reader.align(to: 4)

        feedStart = Int(try reader.readUInt32())
        dayCount = Int(try reader.readUInt32())
        let serviceCount = Int(try reader.readUInt32())
        patternCount = Int(try reader.readUInt32())
        tripCount = Int(try reader.readUInt32())
        stopCount = Int(try reader.readUInt32())
        classCount = Int(try reader.readUInt32())
        prefixCount = Int(try reader.readUInt32())

        serviceStride = (dayCount + 7) / 8
        servicesAt = try reader.skip(serviceCount * serviceStride)
        try reader.align(to: 4)

        stopsAt = try reader.skip(stopCount * 4)
        prefixesAt = try reader.skip(prefixCount * 4)
        classesAt = try reader.skip(classCount * 16)

        patternIndexAt = try reader.skip(patternCount * 8 + 4)
        try reader.align(to: 4)
        let callBytes = Int(
            bytes.loadUnaligned(fromByteOffset: patternIndexAt + patternCount * 8, as: UInt32.self)
        )
        patternCallsAt = try reader.skip(callBytes)
        try reader.align(to: 4)

        tripsAt = try reader.skip(tripCount * Self.tripStride)
        try reader.align(to: 4)
        let suffixBytes = Int(try reader.readUInt32())
        suffixesAt = try reader.skip(suffixBytes)
        try reader.align(to: 4)

        // Trip ids. Every one of the 2,071,007 in this feed is unique and every
        // one is `<prefix>.<number>.<season>` over 5,120 distinct prefix/season
        // pairs with the number below 65,536 — so an id is two `UInt16`s, four
        // bytes, and it comes back byte for byte. Whole they would be 55.6 MB.
        routeCount = Int(try reader.readUInt32())
        routesAt = try reader.skip(routeCount * 12)
        try reader.align(to: 4)

        keyPairCount = Int(try reader.readUInt32())
        keyPairsAt = try reader.skip(keyPairCount * 8)
        tripKeysAt = try reader.skip(tripCount * 4)
        try reader.align(to: 4)
        let literalBytes = Int(try reader.readUInt32())
        literalsAt = try reader.skip(literalBytes)

        // Through-services: twelve bytes a link, being the two trip rows and
        // the calendar the link runs on.
        try reader.align(to: 4)
        linkCount = Int(try reader.readUInt32())
        linksAt = try reader.skip(linkCount * 12)
    }

    // MARK: - Derived geography

    private static let geoMagic = "SVTGEO01"
    private static let geoVersion: UInt32 = 1

    /// Remember where a later launch should look for slot coordinates and
    /// pattern boxes, and load them if they still match this file.
    public func openGeographyCache(at url: URL) {
        geographyURL = url
        _ = loadGeographyCache()
    }

    /// Make a clipped window query cheap: every pattern box is an integer
    /// compare instead of a stop-register walk through cold mapped pages.
    ///
    /// A launch used to derive boxes in trip order while scanning the window.
    /// That is random access through 119 MB, and on a phone whose page cache
    /// had been emptied overnight it was the minute the curtain sat still.
    /// One sequential pass — or the cache that pass writes — is the same
    /// answer, in order, once.
    public func prepareQuery(place: (String) -> Place?) {
        if geographyReady { return }
        if loadGeographyCache() {
            Self.log.notice("geography: cache hit")
            return
        }
        // A cache miss must not walk every pattern before the first viewport
        // is drawn. On an iPhone Debug build that sequential fill was 28 s
        // of the curtain; the window query only needs the boxes it rejects
        // against. The rest is filled after the map is up.
        prepareGeography()
    }

    /// Walk every pattern once and persist the boxes, so the next launch is
    /// a cache hit rather than a stop-register walk.
    public func completeGeography(place: (String) -> Place?) {
        if geographyReady { return }
        if loadGeographyCache() { return }
        let started = Date()
        fillGeography(place: place)
        geographyReady = true
        updateLookback()
        saveGeographyCache()
        Self.log.notice("geography: sequential fill \(Date().timeIntervalSince(started) * 1000, format: .fixed(precision: 0))ms")
    }

    private func fillGeography(place: (String) -> Place?) {
        file.adviseSequential()
        prepareGeography()
        if patternDuration.count != patternCount {
            patternDuration = [Int32](repeating: Self.unknownDuration, count: patternCount)
        }
        for slot in 0..<stopCount {
            _ = slotCoord(slot, place: place)
        }
        for pattern in 0..<patternCount {
            let indexAt = patternIndexAt + pattern * 8
            let offset = Int(bytes.loadUnaligned(fromByteOffset: indexAt, as: UInt32.self))
            let count = Int(bytes.loadUnaligned(fromByteOffset: indexAt + 4, as: UInt32.self))
            if count > 0 {
                let last = patternCallsAt + offset + (count - 1) * Self.callStride
                patternDuration[pattern] = Int32(
                    bytes.loadUnaligned(fromByteOffset: last + 6, as: UInt16.self)
                )
            } else {
                patternDuration[pattern] = 0
            }
            _ = patternBox(pattern, place: place)
        }
        file.adviseNormal()
    }

    private func updateLookback() {
        var longest = 0
        for duration in patternDuration where duration >= 0 {
            longest = max(longest, Int(duration))
        }
        if longest > 0 {
            lookbackMinutes = min(16 * 60, longest + 15)
        }
    }

    private func loadGeographyCache() -> Bool {
        guard let url = geographyURL else { return false }
        guard let mapped = try? MappedFile(url: url) else { return false }
        var reader = BinaryReader(mapped)
        guard (try? reader.expect(magic: Self.geoMagic, version: Self.geoVersion)) != nil,
              let trips = try? reader.readUInt32(), trips == UInt32(tripCount),
              let patterns = try? reader.readUInt32(), patterns == UInt32(patternCount),
              let stops = try? reader.readUInt32(), stops == UInt32(stopCount),
              let length = try? reader.readInt64(), length == Int64(bytes.count),
              let start = try? reader.readUInt32(), start == UInt32(feedStart)
        else { return false }
        guard
            let durations = try? reader.readArray(Int32.self, count: patternCount),
            let lons = try? reader.readArray(Int32.self, count: stopCount),
            let lats = try? reader.readArray(Int32.self, count: stopCount),
            let boxes = try? reader.readArray(Int32.self, count: patternCount * 4)
        else { return false }
        patternDuration = durations
        slotLon = lons
        slotLat = lats
        patternBoxes = boxes
        geographyReady = true
        updateLookback()
        return true
    }

    private func saveGeographyCache() {
        guard geographyReady, let url = geographyURL else { return }
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var data = Data()
        data.append(contentsOf: Self.geoMagic.utf8)
        func putU32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func putI64(_ value: Int64) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        putU32(Self.geoVersion)
        putU32(UInt32(tripCount))
        putU32(UInt32(patternCount))
        putU32(UInt32(stopCount))
        putI64(Int64(bytes.count))
        putU32(UInt32(feedStart))
        patternDuration.withUnsafeBytes { data.append(contentsOf: $0) }
        slotLon.withUnsafeBytes { data.append(contentsOf: $0) }
        slotLat.withUnsafeBytes { data.append(contentsOf: $0) }
        patternBoxes.withUnsafeBytes { data.append(contentsOf: $0) }
        try? data.write(to: url, options: .atomic)
    }

    /// What a route is published as, where the static feed knows it.
    public func route(_ id: String) -> (line: String?, mode: Mode)? {
        ensureRouteLines()
        return routeLines[id]
    }

    private func ensureRouteLines() {
        guard routeLines.isEmpty, routeCount > 0 else { return }
        let modes: [Mode] = [.train, .tram, .bus, .metro, .boat, .cable, .other]
        routeLines.reserveCapacity(routeCount)
        for i in 0..<routeCount {
            let at = routesAt + i * 12
            let id = string(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            let line = string(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            let raw = Int(bytes.loadUnaligned(fromByteOffset: at + 8, as: UInt32.self))
            guard let id, !id.isEmpty else { continue }
            routeLines[id] = (line, raw < modes.count ? modes[raw] : .other)
        }
    }

    /// Last-call offset of one pattern, read on first use.
    private func duration(of pattern: Int) -> Int {
        guard pattern >= 0, pattern < patternCount else { return 0 }
        if patternDuration.count != patternCount {
            patternDuration = [Int32](repeating: Self.unknownDuration, count: patternCount)
        }
        var held = patternDuration[pattern]
        if held == Self.unknownDuration {
            let at = patternIndexAt + pattern * 8
            let offset = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            let calls = Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            if calls > 0 {
                let last = patternCallsAt + offset + (calls - 1) * Self.callStride
                held = Int32(
                    bytes.loadUnaligned(fromByteOffset: last + 6, as: UInt16.self)
                )
            } else {
                held = 0
            }
            patternDuration[pattern] = held
        }
        return Int(held)
    }

    /// Start minute of trip `i`, read through the mapping.
    ///
    /// Used to be copied into an array of two million `UInt16`s at open, which
    /// is 2,071,007 strided unaligned loads through 44 MB of trip records.
    /// A window query binary-searches this (~21 loads) and then scans the
    /// window; copying the country to make that scan a handful of nanoseconds
    /// faster was the wrong trade for a launch.
    private func tripStartMinute(_ i: Int) -> Int {
        Int(bytes.loadUnaligned(fromByteOffset: tripsAt + i * Self.tripStride + 8, as: UInt16.self))
    }

    // MARK: - Record access

    private struct Trip {
        var pattern: Int
        var service: Int
        var start: Int
        var klass: Int
        var prefix: Int
        var number: UInt32
        var suffix: Int
    }

    private func trip(_ i: Int) -> Trip {
        let at = tripsAt + i * Self.tripStride
        return Trip(
            pattern: Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)),
            service: Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)),
            start: Int(bytes.loadUnaligned(fromByteOffset: at + 8, as: UInt16.self)),
            klass: Int(bytes.loadUnaligned(fromByteOffset: at + 10, as: UInt16.self)),
            prefix: Int(bytes.loadUnaligned(fromByteOffset: at + 12, as: UInt16.self)),
            number: bytes.loadUnaligned(fromByteOffset: at + 14, as: UInt32.self),
            suffix: Int(bytes.loadUnaligned(fromByteOffset: at + 18, as: UInt32.self))
        )
    }

    /// The GTFS `trip_id` for a row, rebuilt from its pair and its number.
    ///
    /// This is the journey's identity everywhere in the app, because it is the
    /// one identifier all three sources agree on: it is unique in the static
    /// feed, it is what GTFS-Realtime names a run by, and it is therefore the
    /// join that needs no matching step at all.
    public func tripID(row: Int) -> String {
        guard row >= 0, row < tripCount else { return "" }
        let at = tripKeysAt + row * 4
        let pair = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self))
        let value = Int(bytes.loadUnaligned(fromByteOffset: at + 2, as: UInt16.self))

        // 0xffff marks an id that did not fit the shape and was kept whole.
        guard pair != 0xffff else {
            let base = literalsAt + value
            let length = Int(bytes.loadUnaligned(fromByteOffset: base, as: UInt16.self))
            let lo = base + 2
            return String(
                decoding: UnsafeRawBufferPointer(rebasing: bytes[lo..<(lo + length)]), as: UTF8.self
            )
        }
        guard pair < keyPairCount else { return "" }
        let entry = keyPairsAt + pair * 8
        let prefix = string(bytes.loadUnaligned(fromByteOffset: entry, as: UInt32.self)) ?? ""
        let season = string(bytes.loadUnaligned(fromByteOffset: entry + 4, as: UInt32.self)) ?? ""
        return prefix + String(value) + season
    }

    private func string(_ index: UInt32) -> String? {
        let i = Int(index)
        guard index != BinaryFormat.noString, i >= 0, i < stringCount else { return nil }
        if interned.count != stringCount {
            interned = [String?](repeating: nil, count: stringCount)
        }
        if let held = interned[i] { return held }
        let lo = stringBlobAt + Int(
            bytes.loadUnaligned(fromByteOffset: stringOffsetsAt + i * 4, as: UInt32.self)
        )
        let hi = stringBlobAt + Int(
            bytes.loadUnaligned(fromByteOffset: stringOffsetsAt + (i + 1) * 4, as: UInt32.self)
        )
        guard lo >= stringBlobAt, hi >= lo, hi <= bytes.count else { return nil }
        let decoded = String(
            decoding: UnsafeRawBufferPointer(rebasing: bytes[lo..<hi]), as: UTF8.self
        )
        interned[i] = decoded
        return decoded
    }

    private func stopRef(_ slot: Int) -> String {
        guard slot < stopCount else { return "" }
        let index = bytes.loadUnaligned(fromByteOffset: stopsAt + slot * 4, as: UInt32.self)
        return string(index) ?? ""
    }

    // MARK: - Geography

    /// Where each pattern runs, so a window query can reject a trip without
    /// building it.
    ///
    /// This is what makes a launch cost the viewport rather than the country.
    /// Expanding a 90-minute window nationally builds 25,518 `Journey` objects
    /// — half a million `Call`s, a string interpolation each — and a phone
    /// opened on one canton draws about a thousand of them. The other 96% were
    /// built, placed, and never looked at.
    ///
    /// Rejecting them needs a pattern's geographic extent, and the packed file
    /// does not carry one. It does not have to: a pattern's calls name stop
    /// slots, and a slot resolves through the same register the calls are
    /// placed by. So the extent is derived here once and kept, in two layers
    /// that are both filled lazily because a national query never asks:
    ///
    /// - **Slot coordinates.** A slot is resolved to a coordinate on first use
    ///   and remembered, so the 81,756 register lookups a full resolution would
    ///   cost are only paid for the slots patterns in the window actually name.
    /// - **Pattern boxes.** The min/max over a pattern's slots, computed once
    ///   and reused by every one of its trips — the Takt means a pattern runs
    ///   every hour, so this is amortised across a dozen trips per window and
    ///   across every later window in the session.
    ///
    /// Both are plain integer arrays in the packed coordinate encoding rather
    /// than dictionaries: the whole point is to be cheaper than building the
    /// journey, and a hash lookup per call is not.
    private var slotLon: [Int32] = []
    private var slotLat: [Int32] = []
    private var patternBoxes: [Int32] = []

    /// Not yet worked out. Outside any real coordinate: longitude is bounded by
    /// 180°, which encodes to 180,000,000.
    private static let unknown = Int32.min
    /// Worked out, and there is nothing to place — a slot the register does not
    /// know, or a pattern made entirely of them.
    private static let nowhere = Int32.max

    private func prepareGeography() {
        if slotLon.count != stopCount {
            slotLon = [Int32](repeating: Self.unknown, count: stopCount)
            slotLat = [Int32](repeating: 0, count: stopCount)
        }
        if patternBoxes.count != patternCount * 4 {
            patternBoxes = [Int32](repeating: Self.unknown, count: patternCount * 4)
        }
    }

    /// Where a stop slot is, in the packed encoding, or `nil` if the register
    /// cannot place it.
    private func slotCoord(_ slot: Int, place: (String) -> Place?) -> (lon: Int32, lat: Int32)? {
        guard slot >= 0, slot < stopCount else { return nil }
        var lon = slotLon[slot]
        if lon == Self.unknown {
            let found = place(stopRef(slot))
            // `(0, 0)` is how an unplaced call is written throughout — see
            // `build` — and it is in the Gulf of Guinea rather than in
            // Switzerland, so treating it as absent here loses nothing real.
            if let found, found.lat != 0 || found.lon != 0 {
                lon = BinaryFormat.encode(found.lon)
                slotLon[slot] = lon
                slotLat[slot] = BinaryFormat.encode(found.lat)
            } else {
                lon = Self.nowhere
                slotLon[slot] = lon
            }
        }
        guard lon != Self.nowhere else { return nil }
        return (lon, slotLat[slot])
    }

    /// The box a pattern's calls span, or `nil` if none of them can be placed.
    ///
    /// A journey is drawn between its calls, so the calls' own extent bounds
    /// every position it can be at — with one exception the caller pads for:
    /// a train bent onto its mapped rails can bow a little outside the chord.
    private func patternBox(
        _ pattern: Int, place: (String) -> Place?
    ) -> (w: Int32, s: Int32, e: Int32, n: Int32)? {
        let at = pattern * 4
        var west = patternBoxes[at]
        if west == Self.unknown {
            let index = patternIndexAt + pattern * 8
            let offset = Int(bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self))
            let count = Int(bytes.loadUnaligned(fromByteOffset: index + 4, as: UInt32.self))
            var minLon = Int32.max, maxLon = Int32.min
            var minLat = Int32.max, maxLat = Int32.min
            var placed = 0
            for c in 0..<count {
                let base = patternCallsAt + offset + c * Self.callStride
                let slot = Int(bytes.loadUnaligned(fromByteOffset: base, as: UInt32.self))
                guard let found = slotCoord(slot, place: place) else { continue }
                placed += 1
                minLon = min(minLon, found.lon); maxLon = max(maxLon, found.lon)
                minLat = min(minLat, found.lat); maxLat = max(maxLat, found.lat)
            }
            // One placed call is enough to keep, and that is not a rounding of
            // the rule but the same rule `build` applies: it wants two calls
            // and *one* of them placed. Rejecting on fewer than two placed
            // would drop journeys the national pass keeps, and a filter that
            // loses vehicles is worse than one that saves nothing.
            guard placed > 0 else {
                patternBoxes[at] = Self.nowhere
                return nil
            }
            patternBoxes[at] = minLon
            patternBoxes[at + 1] = minLat
            patternBoxes[at + 2] = maxLon
            patternBoxes[at + 3] = maxLat
            west = minLon
        }
        guard west != Self.nowhere else { return nil }
        return (west, patternBoxes[at + 1], patternBoxes[at + 2], patternBoxes[at + 3])
    }

    /// A region in the packed encoding, which is what the boxes are compared in.
    private struct Clip {
        var west: Int32, south: Int32, east: Int32, north: Int32

        init(_ box: BBox) {
            west = BinaryFormat.encode(box.west)
            south = BinaryFormat.encode(box.south)
            east = BinaryFormat.encode(box.east)
            north = BinaryFormat.encode(box.north)
        }
    }

    private func pattern(
        _ pattern: Int, intersects clip: Clip, place: (String) -> Place?
    ) -> Bool {
        guard let box = patternBox(pattern, place: place) else { return false }
        return box.w <= clip.east && box.e >= clip.west
            && box.s <= clip.north && box.n >= clip.south
    }

    // MARK: - Stations

    /// Which station each stop slot belongs to, as an id into `stationSlots`.
    ///
    /// A departure board asks the opposite question to the map's: not "what is
    /// running in this hour" but "what calls at this stop, whenever it next
    /// does", and the packed file is laid out for the first one — trips sorted
    /// by start minute, calls reachable only through their pattern. Answering
    /// the second without reading three million calls on every tap needs the
    /// inverse, and it is built here in two steps, both lazily because a map
    /// that is only being drawn never asks:
    ///
    /// - **Slot to station.** One pass over the 81,756 stop slots, interning the
    ///   station each belongs to. `ch:1:sloid:7000:1:21` and `ch:1:sloid:7000`
    ///   are the same station, which is exactly the join a board is made of.
    /// - **Station to patterns.** One pass over every pattern's calls, then an
    ///   array per station. Asking per tap used to rescan all 179,287 patterns
    ///   (~250 ms) for every destination a Bern board chained through — ten
    ///   seconds of the same walk. Paid once, read back for every later stop.
    private var stationOfSlot: [Int32] = []
    private var stationSlots: [String: Int32] = [:]
    private var patternsAtStation: [[Int32]] = []
    private var patternsByKey: [String: [Int32]] = [:]
    private var cadencesByKey: [String: [TimetableCadence]] = [:]

    private func prepareStations() {
        guard stationOfSlot.count != stopCount else { return }
        var ids: [String: Int32] = [:]
        var out = [Int32](repeating: -1, count: stopCount)
        for slot in 0..<stopCount {
            let station = Self.station(ofSlotRef: stopRef(slot))
            guard !station.isEmpty else { continue }
            if let id = ids[station] {
                out[slot] = id
            } else {
                let id = Int32(ids.count)
                ids[station] = id
                out[slot] = id
            }
        }
        stationOfSlot = out
        stationSlots = ids
    }

    /// Walk every pattern once and remember which stations it calls at.
    ///
    /// `patterns(callingAt:)` used to do this scan for *each* station key. A
    /// through-working looks up the destination of every train, so a Bern
    /// board paid it fifty times over. The lists are a few megabytes; the
    /// alternative was a spinner.
    private func preparePatternIndex() {
        prepareStations()
        let stationCount = stationSlots.count
        guard stationCount > 0, patternsAtStation.count != stationCount else { return }
        var lists = [[Int32]](repeating: [], count: stationCount)
        var stamp = [UInt32](repeating: 0, count: stationCount)
        var generation: UInt32 = 1
        for index in 0..<patternCount {
            if generation == 0 {
                stamp = [UInt32](repeating: 0, count: stationCount)
                generation = 1
            }
            let gen = generation
            generation &+= 1
            let at = patternIndexAt + index * 8
            let offset = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            let count = Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            let pattern = Int32(index)
            for call in 0..<count {
                let slot = Int(bytes.loadUnaligned(
                    fromByteOffset: patternCallsAt + offset + call * Self.callStride,
                    as: UInt32.self
                ))
                guard slot >= 0, slot < stationOfSlot.count else { continue }
                let station = Int(stationOfSlot[slot])
                guard station >= 0, station < stationCount, stamp[station] != gen else { continue }
                stamp[station] = gen
                lists[station].append(pattern)
            }
        }
        patternsAtStation = lists
    }

    /// Build the board indexes off the tap path. A map that is only being
    /// drawn still never pays; the first station tap then does not either.
    public func prepareBoardIndexes() {
        guard isReady else { return }
        prepareStations()
        preparePatternIndex()
        prepareTripsByPattern()
    }

    private var railwayStationCache: [String: Bool] = [:]

    /// Railway evidence independent of today's running services. Some small
    /// stations are missing the stop register's crawl-derived railway flag.
    public func isRailwayStation(_ id: String) -> Bool {
        let ref = StopRegister.sloid(forDidok: id) ?? id
        let station = Self.station(ofSlotRef: ref)
        if let cached = railwayStationCache[station] { return cached }
        let candidates = patterns(callingAt: [station], key: "city-rail:\(station)")
        prepareTripsByPattern()
        let railway = candidates.contains { pattern in
            let index = Int(pattern)
            for slot in Int(patternTripsAt[index])..<Int(patternTripsAt[index + 1]) {
                let row = trip(Int(patternTrips[slot]))
                if klass(row.klass).mode == .train { return true }
            }
            return false
        }
        railwayStationCache[station] = railway
        return railway
    }

    /// `StopRegister.stationOf`, over the whole stop table without the litter.
    ///
    /// The register's own version splits on every colon and joins the first
    /// four back together, which is three allocations for a string that is a
    /// prefix of the one it was given. Run 68,445 times — once per slot — that
    /// is most of the cost of the pass, and the answer is the same: everything
    /// up to the fourth colon, with a `_gen` suffix cut off first.
    static func station(ofSlotRef ref: String) -> String {
        // Generated sector references can contain a complete platform SLOID
        // after `_gen`, e.g. `8005_gen:ch:1:sloid:8005:3:4_pf:4AB`.
        // Trim that suffix before counting colons or the station becomes
        // `ch:1:sloid:8005_gen` and departures vanish from Burgdorf's index.
        if let cut = ref.range(of: "_gen") {
            return station(ofSlotRef: String(ref[..<cut.lowerBound]))
        }
        // Foreign stops are filed as `ch:1:ScheduledStopPoint:8301003`. The
        // board asks for the UIC, so the index has to be the UIC too.
        if let code = StopRegister.scheduledStopPointCode(ref) { return code }
        var colons = 0
        var end = ref.utf8.count
        var index = 0
        for byte in ref.utf8 {
            if byte == 0x3a { // ':'
                colons += 1
                if colons == 4 { end = index; break }
            }
            index += 1
        }
        if colons < 4 {
            return ref
        }
        return String(decoding: Array(ref.utf8.prefix(end)), as: UTF8.self)
    }

    /// Which trips run each pattern, so a board can walk the dozen trips of the
    /// patterns that call there rather than the two million in the file.
    ///
    /// The trip table is sorted by start minute across the whole year, which is
    /// exactly the order a map wants and the wrong one for a stop: asking for
    /// the next day at one place touches most of the file. Grouped by pattern
    /// it is 2,071,007 rows over 179,287 patterns — eleven trips a pattern — and
    /// a board reads only the groups its own station names. Measured on the
    /// packed feed, that took the first board for a station from 149 ms to
    /// 33 ms and every later one to under a millisecond.
    ///
    /// It costs nine megabytes of `Int32` for the session and is built on the
    /// first board rather than at load, so a map that is only being looked at
    /// never pays for it.
    private var patternTripsAt: [Int32] = []
    private var patternTrips: [Int32] = []

    private func prepareTripsByPattern() {
        guard patternTrips.count != tripCount else { return }
        var offsets = [Int32](repeating: 0, count: patternCount + 1)
        for i in 0..<tripCount {
            let pattern = tripPattern(i)
            guard pattern < patternCount else { continue }
            offsets[pattern + 1] += 1
        }
        for i in 1...patternCount { offsets[i] += offsets[i - 1] }
        var fill = offsets
        var rows = [Int32](repeating: 0, count: tripCount)
        for i in 0..<tripCount {
            let pattern = tripPattern(i)
            guard pattern < patternCount else { continue }
            rows[Int(fill[pattern])] = Int32(i)
            fill[pattern] += 1
        }
        patternTripsAt = offsets
        patternTrips = rows
    }

    /// The patterns that call at any slot this board accepts.
    ///
    /// Remembered under `key`, because the question is asked again on every tap
    /// of the same place and the answer is a property of the timetable rather
    /// than of the hour.
    ///
    /// `accepting` is what makes a *platform* board a platform board. Asked for
    /// the station instead, the patterns are every pattern calling anywhere at
    /// Bern, Bahnhof — hundreds of them — and the schedule then fills the
    /// board's whole budget with trips leaving from kerbs A to Z, of which
    /// almost none call at stop M. That is exactly what the screenshot showed:
    /// three departures on a kerb with a Moonliner booked through it at 01:45.
    /// The station test is an array read; the caller's test is only ever run on
    /// the slots that belong to the station, a few dozen out of 68,445.
    private func patterns(
        callingAt stations: Set<String>, key: String, accepting: ((String) -> Bool)? = nil
    ) -> [Int32] {
        preparePatternIndex()
        if let known = patternsByKey[key] { return known }

        var ids = Set<Int32>()
        for station in stations {
            if let id = stationSlots[station] { ids.insert(id) }
        }
        guard !ids.isEmpty else {
            patternsByKey[key] = []
            return []
        }

        var found: [Int32] = []
        if ids.count == 1, accepting == nil, let id = ids.first {
            found = patternsAtStation[Int(id)]
            patternsByKey[key] = found
            return found
        }

        var seen = Set<Int32>()
        found.reserveCapacity(ids.reduce(0) { $0 + patternsAtStation[Int($1)].count })
        for id in ids {
            for pattern in patternsAtStation[Int(id)] {
                guard seen.insert(pattern).inserted else { continue }
                if let accepting, !patternCalls(
                    Int(pattern), at: ids, accepting: accepting
                ) { continue }
                found.append(pattern)
            }
        }
        patternsByKey[key] = found
        return found
    }

    /// Whether any call of this pattern is at one of these stations *and*
    /// accepted as this platform. Used to turn the station index into a
    /// platform index without walking the other 179,000 patterns.
    private func patternCalls(
        _ pattern: Int, at stationIDs: Set<Int32>, accepting: (String) -> Bool
    ) -> Bool {
        guard pattern >= 0, pattern < patternCount else { return false }
        let indexAt = patternIndexAt + pattern * 8
        let offset = Int(bytes.loadUnaligned(fromByteOffset: indexAt, as: UInt32.self))
        let count = Int(bytes.loadUnaligned(fromByteOffset: indexAt + 4, as: UInt32.self))
        for call in 0..<count {
            let at = patternCallsAt + offset + call * Self.callStride
            let slot = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            guard slot >= 0, slot < stationOfSlot.count,
                  stationIDs.contains(stationOfSlot[slot]),
                  accepting(stopRef(slot))
            else { continue }
            return true
        }
        return false
    }

    /// The pattern a trip row runs, read on its own.
    ///
    /// Four bytes rather than the twenty-two `trip` reads, because for a board
    /// this is the rejection that throws away 99% of the day: at Bern, 2,300 of
    /// a weekday's 215,943 trips call there.
    private func tripPattern(_ i: Int) -> Int {
        Int(bytes.loadUnaligned(fromByteOffset: tripsAt + i * Self.tripStride, as: UInt32.self))
    }

    /// What the printed timetable has calling at these stations, over a span
    /// the drawn window has no reason to cover.
    ///
    /// This is what a departure board is actually asking. The map's expansion is
    /// an hour wide and is about what can be *drawn*; a board is about what
    /// leaves, and at a lakeside landing with four boats a day, or a city stop
    /// at one in the morning waiting on a night bus, the next departure is
    /// hours outside that hour. Asked over the same file with the same builder,
    /// so a row from here is the same journey the map would have drawn had the
    /// clock been moved to it.
    ///
    /// `limit` is a ceiling on journeys *built*, and the scan is in start-minute
    /// order, so a busy station stops early and a quiet one walks a cheap
    /// integer rejection over the day.
    public func journeys(
        callingAt stations: Set<String>,
        key: String? = nil,
        accepting: ((String) -> Bool)? = nil,
        from: Timestamp,
        to: Timestamp,
        zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current,
        limit: Int = 120,
        keepHiddenPatterns: Bool = true,
        place: (String) -> Place?,
        operatorName: (String) -> String? = { _ in nil }
    ) -> [Journey] {
        guard isReady, to >= from, !stations.isEmpty else { return [] }
        let wanted = patterns(
            callingAt: stations,
            key: key ?? stations.sorted().joined(separator: "|"),
            accepting: accepting
        )
        guard !wanted.isEmpty else { return [] }
        prepareTripsByPattern()

        // The service days in reach. Yesterday too, for the same reason the
        // window query considers it: a night service filed under yesterday
        // leaves at 25:40.
        var days: [(index: Int, zero: Timestamp, opened: Int, closes: Int)] = []
        var cursor = Date(timeIntervalSince1970: TimeInterval(from) - 86400)
        let lastDay = Date(timeIntervalSince1970: TimeInterval(to))
        while cursor <= lastDay {
            defer { cursor = cursor.addingTimeInterval(86400) }
            guard let zero = Self.dayStart(cursor, zone: zone) else { continue }
            let index = Self.daysSince1970(cursor, zone: zone) - feedStart
            guard index >= 0, index < dayCount else { continue }
            let closes = Int((to - zero) / 60)
            guard closes >= 0 else { continue }
            days.append((index, zero, Int((from - zero) / 60), closes))
        }
        guard !days.isEmpty else { return [] }

        // Every trip of every pattern that calls here, against every day it
        // could be running on. Ordered by when it leaves its own origin, which
        // is the order it is built in — a board sorts by the call at *this*
        // stop afterwards, and cannot sort what was never built.
        var candidates: [(at: Timestamp, row: Int, day: Int, zero: Timestamp)] = []
        for pattern in wanted {
            let index = Int(pattern)
            guard index < patternCount else { continue }
            let run = duration(of: index)
            for slot in Int(patternTripsAt[index])..<Int(patternTripsAt[index + 1]) {
                let row = Int(patternTrips[slot])
                let start = tripStartMinute(row)
                var service = -1
                for day in days {
                    if start > day.closes || start + run < day.opened { continue }
                    if service < 0 { service = trip(row).service }
                    guard runs(service: service, onDay: day.index) else { continue }
                    candidates.append((day.zero + Timestamp(start) * 60, row, day.index, day.zero))
                }
            }
        }
        candidates.sort { $0.at < $1.at }

        // A busy station's next N trips are the seven-minute tram, over and
        // over. Stopping at `limit` never reached the hourly S-Bahn. Walk the
        // rest of the day for patterns that still have no upcoming call here,
        // and only skip *extra* trips of a pattern already on the board.
        prepareStations()
        let stationIDs = Set(stations.compactMap { stationSlots[$0] })
        var offsetByPattern: [Int: Int] = [:]
        func stationOffset(of pattern: Int) -> Int? {
            if let cached = offsetByPattern[pattern] { return cached }
            guard let found = departureOffset(
                of: pattern, at: stationIDs, accepting: accepting
            ) else { return nil }
            offsetByPattern[pattern] = found
            return found
        }

        var seenPatterns: Set<Int> = []
        var out: [Journey] = []
        out.reserveCapacity(min(limit, candidates.count))
        let patternTotal = wanted.count
        for candidate in candidates {
            let record = trip(candidate.row)
            guard let offset = stationOffset(of: record.pattern) else { continue }
            let callAt = candidate.at + Timestamp(offset) * 60
            if callAt < from - 60 { continue }
            let isNew = seenPatterns.insert(record.pattern).inserted
            if !isNew {
                if out.count >= limit { continue }
            } else if out.count >= limit {
                // Past the row budget, only modes that a frequent tram can
                // hide still get a seat: trains, metros, boats, cableways.
                // A first-paint board skips this extra walk so the packed
                // rows can appear before the rare overnight services.
                guard keepHiddenPatterns else { continue }
                switch klass(record.klass).mode {
                case .train, .metro, .boat, .cable: break
                default: continue
                }
            }
            if let journey = build(
                record, row: candidate.row, dayZero: candidate.zero,
                place: place, operatorName: operatorName
            ) {
                out.append(journey)
            }
            if seenPatterns.count >= patternTotal, out.count >= limit { break }
        }
        return out
    }

    /// Minutes from a trip's origin to its first departure at one of these
    /// stations, or nil if the pattern does not call there.
    private func departureOffset(
        of pattern: Int, at stationIDs: Set<Int32>, accepting: ((String) -> Bool)?
    ) -> Int? {
        guard pattern >= 0, pattern < patternCount, !stationIDs.isEmpty else { return nil }
        let indexAt = patternIndexAt + pattern * 8
        let callsOffset = Int(bytes.loadUnaligned(fromByteOffset: indexAt, as: UInt32.self))
        let callCount = Int(bytes.loadUnaligned(fromByteOffset: indexAt + 4, as: UInt32.self))
        for call in 0..<callCount {
            let at = patternCallsAt + callsOffset + call * Self.callStride
            let slot = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            guard slot >= 0, slot < stationOfSlot.count,
                  stationIDs.contains(stationOfSlot[slot]),
                  accepting?(stopRef(slot)) ?? true
            else { continue }
            return Int(bytes.loadUnaligned(fromByteOffset: at + 6, as: UInt16.self))
        }
        return nil
    }

    private struct Class {
        var line: String?
        var headsign: String?
        var agency: String?
        var mode: Mode
    }

    private func klass(_ i: Int) -> Class {
        let at = classesAt + i * 16
        func field(_ n: Int) -> UInt32 {
            bytes.loadUnaligned(fromByteOffset: at + n * 4, as: UInt32.self)
        }
        let raw = Int(field(3))
        let modes: [Mode] = [.train, .tram, .bus, .metro, .boat, .cable, .other]
        return Class(
            line: string(field(0)), headsign: string(field(1)), agency: string(field(2)),
            mode: raw < modes.count ? modes[raw] : .other
        )
    }

    /// The usual daytime interval for each service calling at a station.
    ///
    /// A future-only board cannot infer this at the evening transition: an
    /// hourly route with calls at 21:30 and 23:01 appears to run every 91
    /// minutes. This query instead considers the current day's 06:00–22:00
    /// service. It walks only packed trip/class integers for the station's
    /// already-indexed patterns, creates no `Journey` or `Call` objects, and is
    /// cached per station and service day.
    public func departureCadences(
        callingAt stations: Set<String>,
        key: String? = nil,
        accepting: ((String) -> Bool)? = nil,
        on date: Date,
        zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
    ) -> [TimetableCadence] {
        guard isReady, !stations.isEmpty,
              let dayZero = Self.dayStart(date, zone: zone)
        else { return [] }
        let dayIndex = Self.daysSince1970(date, zone: zone) - feedStart
        guard dayIndex >= 0, dayIndex < dayCount else { return [] }
        let stationKey = key ?? stations.sorted().joined(separator: "|")
        let cacheKey = "\(stationKey)|\(dayIndex)|\(zone.identifier)"
        if let cached = cadencesByKey[cacheKey] { return cached }

        let wanted = patterns(
            callingAt: stations,
            key: stationKey,
            accepting: accepting
        )
        guard !wanted.isEmpty else {
            cadencesByKey[cacheKey] = []
            return []
        }
        prepareTripsByPattern()
        prepareStations()

        let stationIDs = Set(stations.compactMap { stationSlots[$0] })
        guard !stationIDs.isEmpty else {
            cadencesByKey[cacheKey] = []
            return []
        }

        struct ServiceKey: Hashable {
            var mode: Mode
            var line: String
            var direction: String
        }
        let previousProbe = Date(
            timeIntervalSince1970: TimeInterval(dayZero - 60 * 60)
        )
        let previousZero = Self.dayStart(previousProbe, zone: zone)
        let previousIndex = Self.daysSince1970(previousProbe, zone: zone) - feedStart
        let serviceDays = [(zero: dayZero, index: dayIndex)] + (previousZero.map {
            [(zero: $0, index: previousIndex)]
        } ?? [])
        let opens = dayZero + 6 * 60 * 60
        let closes = dayZero + 22 * 60 * 60
        var departures: [ServiceKey: Set<Timestamp>] = [:]

        for rawPattern in wanted {
            let pattern = Int(rawPattern)
            guard pattern >= 0, pattern < patternCount else { continue }
            let indexAt = patternIndexAt + pattern * 8
            let callsOffset = Int(bytes.loadUnaligned(
                fromByteOffset: indexAt,
                as: UInt32.self
            ))
            let callCount = Int(bytes.loadUnaligned(
                fromByteOffset: indexAt + 4,
                as: UInt32.self
            ))
            var departureOffset: Int?
            var acceptedCall: Int?
            for call in 0 ..< callCount {
                let at = patternCallsAt + callsOffset + call * Self.callStride
                let slot = Int(bytes.loadUnaligned(
                    fromByteOffset: at,
                    as: UInt32.self
                ))
                guard slot >= 0, slot < stationOfSlot.count,
                      stationIDs.contains(stationOfSlot[slot]),
                      accepting?(stopRef(slot)) ?? true
                else { continue }
                departureOffset = Int(bytes.loadUnaligned(
                    fromByteOffset: at + 6,
                    as: UInt16.self
                ))
                acceptedCall = call
                break
            }
            guard let departureOffset, let acceptedCall else { continue }
            var direction: String?
            for call in (acceptedCall + 1) ..< callCount {
                let at = patternCallsAt + callsOffset + call * Self.callStride
                let slot = Int(bytes.loadUnaligned(
                    fromByteOffset: at,
                    as: UInt32.self
                ))
                guard slot >= 0, slot < stationOfSlot.count,
                      !stationIDs.contains(stationOfSlot[slot])
                else { continue }
                let station = Self.station(ofSlotRef: stopRef(slot))
                if !station.isEmpty { direction = station }
                break
            }
            guard let direction else { continue }

            for tripSlot in Int(patternTripsAt[pattern])
                ..< Int(patternTripsAt[pattern + 1]) {
                let row = Int(patternTrips[tripSlot])
                let record = trip(row)
                guard record.klass >= 0, record.klass < classCount else { continue }
                let info = klass(record.klass)
                let trimmedLine = info.line?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                let service = ServiceKey(
                    mode: info.mode,
                    line: trimmedLine.isEmpty
                        ? (string(record.number) ?? info.mode.rawValue.capitalized)
                        : trimmedLine,
                    direction: direction
                )
                for serviceDay in serviceDays {
                    guard serviceDay.index >= 0, serviceDay.index < dayCount,
                          runs(service: record.service, onDay: serviceDay.index)
                    else { continue }
                    let departure = serviceDay.zero
                        + Timestamp(record.start + departureOffset) * 60
                    guard departure >= opens, departure <= closes else { continue }
                    departures[service, default: []].insert(departure)
                }
            }
        }

        var result: [TimetableCadence] = []
        result.reserveCapacity(departures.count)
        for (service, times) in departures {
            let ordered = times.sorted()
            guard ordered.count >= 3 else { continue }
            let gaps = zip(ordered, ordered.dropFirst()).compactMap { earlier, later -> Int? in
                let minutes = (later - earlier) / 60
                return (3 ... 180).contains(minutes) ? minutes : nil
            }
            guard gaps.count >= 2 else { continue }
            var buckets: [Int: Int] = [:]
            for gap in gaps {
                let rounded = max(5, Int((Double(gap) / 5).rounded()) * 5)
                buckets[rounded, default: 0] += 1
            }
            guard let winner = buckets.max(by: { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }), winner.value >= 2, winner.value * 2 >= gaps.count
            else { continue }
            result.append(TimetableCadence(
                mode: service.mode,
                line: service.line,
                direction: service.direction,
                minutes: winner.key
            ))
        }
        cadencesByKey[cacheKey] = result
        return result
    }

    /// Rebuild the OJP journey reference from its interned prefix and packed
    /// tail, or nil where the feed gives this run none.
    ///
    /// The tail is stored as what it is rather than as the text it is written
    /// in — 47% of these are a UUID and most of the rest an integer — so this is
    /// where those become characters again. It has to be exact: a reference that
    /// does not come back byte for byte is one OJP will not answer to.
    private func journeyRef(prefix: Int, suffix at: Int) -> String? {
        guard bytes.load(fromByteOffset: suffixesAt + at, as: UInt8.self) != 3 else { return nil }

        let head: String
        if prefix < prefixCount {
            let index = bytes.loadUnaligned(fromByteOffset: prefixesAt + prefix * 4, as: UInt32.self)
            head = string(index) ?? ""
        } else {
            head = ""
        }

        let base = suffixesAt + at
        switch bytes.load(fromByteOffset: base, as: UInt8.self) {
        case 1:
            var hex = ""
            hex.reserveCapacity(36)
            for i in 0..<16 {
                if i == 4 || i == 6 || i == 8 || i == 10 { hex.append("-") }
                let byte = bytes.load(fromByteOffset: base + 1 + i, as: UInt8.self)
                hex.append(String(format: "%02x", byte))
            }
            return head + hex
        case 2:
            let value = bytes.loadUnaligned(fromByteOffset: base + 1, as: UInt32.self)
            return head + String(value)
        default:
            let length = Int(bytes.loadUnaligned(fromByteOffset: base + 1, as: UInt16.self))
            let lo = base + 3
            let text = String(
                decoding: UnsafeRawBufferPointer(rebasing: bytes[lo..<(lo + length)]), as: UTF8.self
            )
            return head + text
        }
    }

    /// The operator reference a Swiss Journey ID names, or nil.
    ///
    /// `ch:1:sjyid:100058:2806-001` carries its operator in the third field,
    /// and that field is an SBOID — the same key `OperatorRegister` is built
    /// on. The timetable's own `agency_id` is not the same key space: GTFS
    /// files it as `801`, `11`, `sbg034`, and the federal register has never
    /// heard of any of them. Resolving the operator through the agency id
    /// therefore named nobody on every single timetabled run, and a vehicle
    /// with no operator is drawn in no livery.
    ///
    /// 432 of the 441 prefixes in the packed year resolve this way. The nine
    /// that do not are foreign — `ch:1:sjyid:AT817000:`, `DE807000` — and nil
    /// is the right answer for those: the register is Swiss.
    static func operatorRef(ofJourneyRef ref: String?) -> String? {
        guard let ref else { return nil }
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[2].lowercased() == "sjyid",
              !parts[3].isEmpty, parts[3].allSatisfy(\.isNumber)
        else { return nil }
        return "ch:1:sboid:\(parts[3])"
    }

    /// The operator an `agency_id` names, for the runs that carry no journey
    /// reference to read one out of.
    ///
    /// A hand-written table, which this codebase avoids and which is the right
    /// answer here for one reason: the alternative is not a better table, it is
    /// **no operator at all**. 164,000 of the two million trips in the packed
    /// year carry no journey reference — the marker is "none", not an empty
    /// string — and 29 agencies have not got one on a single run. For those
    /// there is nothing to parse, so `operatorRef(ofJourneyRef:)` returns nil,
    /// the register is never asked, and the vehicle comes out with no company:
    /// no name in the panel, no livery, and no class of stock, because
    /// `LayoutLibrary` keys the paint *and* the shape on the operator code. A
    /// Matterhorn Gotthard train to Zermatt was drawn as a standard-gauge FLIRT
    /// in plain mode-red.
    ///
    /// **Kept honest by being small and by being checked against the data
    /// rather than remembered.** Every row below was read out of the packed
    /// timetable itself — the agency's own lines, headsigns and mode — and
    /// nothing is entered on a hunch. Most of the ref-less agencies are French,
    /// German and Austrian, and those stay out: the register is the Swiss one
    /// and has never heard of them, so nil is the true answer and a guess would
    /// be worse than the blank. Known Swiss agencies also cover journeys
    /// whose references are absent on only some routes, such as PostAuto 220.
    ///
    /// The proper fix is upstream — the packer should write the SBOID into the
    /// class record, and then this goes away. Until it does, this is the only
    /// place the two key spaces can be joined, because the `agency_id` is
    /// already read and then dropped.
    static func operatorRef(ofAgency agency: String?) -> String? {
        guard let agency else { return nil }
        return sboidByAgency[agency]
    }

    /// `agency_id` → SBOID, for the ref-less Swiss agencies that can be
    /// identified from what they run.
    ///
    /// **48 and 93 are both the Matterhorn Gotthard Bahn**, which is what the
    /// merger of the BVZ and the Furka Oberalp is still filed as two halves of.
    /// 48 runs R43–R46 and the Glacier Express over Andermatt, Disentis,
    /// Oberwald and Realp; 93 runs R40–R42 down the Mattertal to Täsch, Zermatt
    /// and Visp. Both are trains, both are metre gauge, and neither carries a
    /// journey reference on a single one of its 688 runs. The Gornergrat is not
    /// either of them — it is a separate company with its own rack railway, and
    /// none of its stops appears under either id.
    private static let sboidByAgency: [String: String] = [
        "48": "ch:1:sboid:100029",
        "93": "ch:1:sboid:100029",
        // PostAuto. Kiental's 220 has no journey references; other workings
        // under this agency identify PostAuto as 100602. An explicit journey
        // reference still takes precedence for services run by another company.
        "801": "ch:1:sboid:100602",
    ]

    /// The moments the packed feed can answer for.
    ///
    /// The whole point of having an archive rather than a snapshot: `feedStart`
    /// is the first service day and `dayCount` how many follow, so this is a
    /// year wide and every minute inside it draws from the file with no network
    /// at all. It is also the only *real* bound on the clock — before this
    /// existed, the app had to measure how far the SIRI snapshot in hand could
    /// be stretched, which is a couple of hours and a falloff to apologise for.
    ///
    /// The upper edge is the start of the day after the last service day, so
    /// the last day is offered whole rather than up to its own midnight.
    public func span(zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current) -> ClosedRange<Timestamp>? {
        guard isReady, dayCount > 0 else { return nil }
        // Midday UTC on the day in question, which lands on the same calendar
        // date in Zurich either side of the clocks changing — `dayStart` then
        // reads that date and steps back to the service day's own zero.
        func midday(_ index: Int) -> Date {
            Date(timeIntervalSince1970: TimeInterval((feedStart + index) * 86400 + 43_200))
        }
        guard let first = Self.dayStart(midday(0), zone: zone),
              let last = Self.dayStart(midday(dayCount - 1), zone: zone),
              first < last + 86_400
        else { return nil }
        return first...(last + 86_400)
    }

    private func runs(service: Int, onDay day: Int) -> Bool {
        guard day >= 0, day < dayCount, service >= 0 else { return false }
        let byte = bytes.load(fromByteOffset: servicesAt + service * serviceStride + day / 8, as: UInt8.self)
        return byte >> UInt8(day % 8) & 1 == 1
    }

    // MARK: - The window query

    /// The service day a GTFS time is measured from.
    ///
    /// Not local midnight, deliberately. GTFS counts from "noon minus twelve
    /// hours" so that the two days a year when midnight is 23 or 25 hours away
    /// do not shift every departure on them by an hour. Taking noon and
    /// stepping back is the rule as written, and it is the only handling of it
    /// that survives the clocks changing.
    static func dayStart(_ day: Date, zone: TimeZone) -> Timestamp? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = 12
        parts.minute = 0
        parts.second = 0
        guard let noon = calendar.date(from: parts) else { return nil }
        return Timestamp(noon.timeIntervalSince1970) - 12 * 3600
    }

    private static func daysSince1970(_ day: Date, zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        var utc = DateComponents()
        utc.year = parts.year
        utc.month = parts.month
        utc.day = parts.day
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = gregorian.date(from: utc) else { return 0 }
        return Int(date.timeIntervalSince1970) / 86400
    }

    /// The first trip whose start minute is at or after `minute`.
    private func lowerBound(_ minute: Int) -> Int {
        var lo = 0
        var hi = tripCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if tripStartMinute(mid) < minute { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// What the timetable says is running between two moments.
    ///
    /// - Parameters:
    ///   - place: resolves a SLOID to a coordinate, as `StopRegister.lookup`
    ///     does for a SIRI call.
    ///   - operatorName: the printed name for an operator reference. Given an
    ///     SBOID read out of the run's journey reference — see `operatorRef` —
    ///     because that is the key the register is built on.
    ///   - limit: a ceiling on how many journeys to build. The busiest hour of a
    ///     weekday has 20,988 vehicles moving at once, which is the same order
    ///     as the SIRI fleet this replaces, but a caller asking for a whole day
    ///     would otherwise get three million calls.
    ///   - uniquePatterns: build only the first running trip for each stop
    ///     pattern. Fixed infrastructure needs the route once, not once per
    ///     departure.
    public func journeys(
        from: Timestamp,
        to: Timestamp,
        zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current,
        limit: Int = 30_000,
        modes: Set<Mode>? = nil,
        uniquePatterns: Bool = false,
        in region: BBox? = nil,
        place: (String) -> Place?,
        operatorName: (String) -> String? = { _ in nil }
    ) -> [Journey] {
        guard isReady, to >= from else { return [] }

        // Clipped, this builds what a viewport can draw instead of what the
        // country is running. See `patternBox`; `nil` is the national pass and
        // costs nothing extra.
        var clip: Clip?
        if let region {
            prepareGeography()
            // A quarter of the viewport on each side, and the filter is far
            // more forgiving than that sounds. A pattern box is the extent of
            // the *whole route*, not of the vehicle: a Geneva–Zurich run is
            // kept for a reader looking at either end, and at every station
            // between. So this errs towards building journeys that will not be
            // drawn, which costs a little, rather than dropping one that would
            // have been, which is a vehicle missing from the map. The margin
            // covers the rest — a train bent onto its rails standing slightly
            // off the chord its calls describe.
            clip = Clip(region.padded(by: 0.25))
        }

        var out: [Journey] = []
        out.reserveCapacity(min(limit, region == nil ? 24_000 : 4_000))
        var seenPatterns: Set<Int> = []

        // A run filed under yesterday can still be moving — a night service
        // leaves at 25:40 — so the day before the window is always considered.
        let firstDay = Date(timeIntervalSince1970: TimeInterval(from) - 86400)
        let lastDay = Date(timeIntervalSince1970: TimeInterval(to))
        var cursor = firstDay
        while cursor <= lastDay {
            defer { cursor = cursor.addingTimeInterval(86400) }
            guard let dayZero = Self.dayStart(cursor, zone: zone) else { continue }
            let index = Self.daysSince1970(cursor, zone: zone) - feedStart
            guard index >= 0, index < dayCount else { continue }

            let lo = Int((from - dayZero) / 60) - lookbackMinutes
            let hi = Int((to - dayZero) / 60)
            guard hi >= 0 else { continue }

            var i = lowerBound(max(lo, 0))
            while i < tripCount, out.count < limit {
                let start = tripStartMinute(i)
                if start > hi { break }
                defer { i += 1 }

                let record = trip(i)
                guard record.pattern < patternCount else { continue }
                if let modes, !modes.contains(classMode(record.klass)) { continue }
                // The cheap rejections first: a trip that had already finished,
                // then one that does not run today. Both are far cheaper than
                // reading the pattern's calls.
                if start + duration(of: record.pattern) < Int((from - dayZero) / 60) { continue }
                guard runs(service: record.service, onDay: index) else { continue }
                // Last of the cheap rejections, because it is the only one that
                // can have work to do the first time it is asked: a pattern
                // whose box has never been worked out resolves its slots here.
                // Every later trip of the same pattern — and there are a dozen
                // an hour — reads the answer.
                if let clip, !pattern(record.pattern, intersects: clip, place: place) { continue }
                if uniquePatterns, !seenPatterns.insert(record.pattern).inserted { continue }

                if let journey = build(record, row: i, dayZero: dayZero, place: place, operatorName: operatorName) {
                    out.append(journey)
                }
            }
        }
        return out
    }

    /// Resolve pattern boxes for the window without building any journeys.
    ///
    /// A clipped expand only works out the boxes it needs to reject against.
    /// Zooming out then pays that cost on the new patterns, on the fleet actor,
    /// in front of the frame. Walking the rest of the window in the background
    /// — the same cheap rejections, no `Journey` objects — means a later
    /// expand is a box compare and a build of what is newly in view.
    ///
    /// `budget` is how many *unknown* boxes this call will resolve, so a caller
    /// can interleave it with the draw loop rather than owning the actor for
    /// the whole remainder. Returns whether any unknown boxes were still
    /// waiting when the budget ran out.
    public func prefetchGeography(
        from: Timestamp,
        to: Timestamp,
        zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current,
        budget: Int = 512,
        place: (String) -> Place?
    ) -> Bool {
        guard isReady, to >= from, budget > 0 else { return false }
        if geographyReady { return false }
        prepareGeography()

        var remaining = budget
        let firstDay = Date(timeIntervalSince1970: TimeInterval(from) - 86400)
        let lastDay = Date(timeIntervalSince1970: TimeInterval(to))
        var cursor = firstDay
        while cursor <= lastDay {
            defer { cursor = cursor.addingTimeInterval(86400) }
            guard let dayZero = Self.dayStart(cursor, zone: zone) else { continue }
            let index = Self.daysSince1970(cursor, zone: zone) - feedStart
            guard index >= 0, index < dayCount else { continue }

            let lo = Int((from - dayZero) / 60) - lookbackMinutes
            let hi = Int((to - dayZero) / 60)
            guard hi >= 0 else { continue }

            var i = lowerBound(max(lo, 0))
            while i < tripCount {
                let start = tripStartMinute(i)
                if start > hi { break }
                defer { i += 1 }

                let record = trip(i)
                guard record.pattern < patternCount else { continue }
                if start + duration(of: record.pattern) < Int((from - dayZero) / 60) {
                    continue
                }
                guard runs(service: record.service, onDay: index) else { continue }
                let at = record.pattern * 4
                guard at < patternBoxes.count, patternBoxes[at] == Self.unknown else { continue }
                _ = patternBox(record.pattern, place: place)
                remaining -= 1
                if remaining == 0 { return true }
            }
        }
        return false
    }

    private func build(
        _ record: Trip,
        row: Int,
        dayZero: Timestamp,
        place: (String) -> Place?,
        operatorName: (String) -> String?
    ) -> Journey? {
        let at = patternIndexAt + record.pattern * 8
        let offset = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
        let count = Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
        guard count > 0 else { return nil }

        let info = klass(record.klass)
        let origin = dayZero + Timestamp(record.start) * 60
        // Read once: it is both what OJP is asked under and where the operator
        // is named.
        let ref = journeyRef(prefix: record.prefix, suffix: record.suffix)

        var calls: [Call] = []
        calls.reserveCapacity(count)
        // A looping route calls at the same stop twice, and the two are
        // different calls — so the visit number is part of a call's identity
        // here exactly as it is in the SIRI parser.
        var visits: [String: Int] = [:]

        for c in 0..<count {
            let base = patternCallsAt + offset + c * Self.callStride
            let slot = Int(bytes.loadUnaligned(fromByteOffset: base, as: UInt32.self))
            let arriveAt = Int(bytes.loadUnaligned(fromByteOffset: base + 4, as: UInt16.self))
            let departAt = Int(bytes.loadUnaligned(fromByteOffset: base + 6, as: UInt16.self))

            let ref = stopRef(slot)
            guard !ref.isEmpty else { continue }
            let visit = (visits[ref] ?? 0) + 1
            visits[ref] = visit

            let found = place(ref)
            let name = found?.name ?? ref
            if StopNaming.isTechnical(name) { continue }
            // An unplaced call is written as `(0, 0)` everywhere else, and
            // that is a vertex in the Gulf of Guinea. Skip it here so the
            // printed timetable cannot mint the Africa chord either.
            guard let found, found.lat != 0 || found.lon != 0 else { continue }
            let arrive = origin + Timestamp(arriveAt) * 60
            let depart = origin + Timestamp(departAt) * 60

            calls.append(Call(
                key: "\(ref)|\(visit)",
                ref: ref,
                name: name,
                lat: found.lat,
                lon: found.lon,
                platform: found.platform,
                precise: found.precise,
                arr: arrive,
                dep: depart,
                delay: nil,
                // Nothing here has been observed. It is the printed timetable,
                // and saying so is what keeps a forecast from being drawn as a
                // measurement once OJP has been asked and has not answered.
                observed: false,
                sched: depart,
                assigned: found.assigned
            ))
        }

        // A call the register cannot place has no coordinate, and a journey of
        // those is a line through the sea. Two placed calls is the minimum that
        // can be drawn at all.
        guard calls.count >= 2, calls.contains(where: { $0.lat != 0 || $0.lon != 0 }) else { return nil }

        // Identity is the GTFS `trip_id`. It is unique across the whole feed,
        // it is what GTFS-Realtime names a run by, and using it here is what
        // makes applying the live feed a dictionary lookup rather than a match.
        // The journey *reference* is a different thing and stays separate: it
        // is absent on 20.7% of a weekday's trips and duplicated across others.
        return Journey(
            id: tripID(row: row),
            mode: info.mode,
            category: nil,
            line: Journey.publishedLine(info.line, mode: info.mode),
            number: string(record.number),
            // The journey reference first, because it is this run's own word
            // for who is running it; the agency id only where there is no
            // reference to read. See `operatorRef(ofAgency:)`.
            operatorName: (Self.operatorRef(ofJourneyRef: ref)
                ?? Self.operatorRef(ofAgency: info.agency)).flatMap(operatorName),
            operatorFull: nil,
            to: info.headsign,
            from: calls[0].name,
            delay: nil,
            start: calls[0].dep,
            end: calls[calls.count - 1].arr,
            complete: true,
            monitored: false,
            cancelled: false,
            source: Journey.timetableSource,
            stops: calls,
            journeyRef: ref
        )
    }

    // MARK: - Through-services

    /// Rebuild a row's journey reference, or nil where the feed gives it none.
    private func journeyReference(row: Int) -> String? {
        guard row >= 0, row < tripCount else { return nil }
        let record = trip(row)
        return journeyRef(prefix: record.prefix, suffix: record.suffix)
    }

    /// Every name this working answers to, for matching it against a fleet.
    ///
    /// Two, because the two sources spell a run differently and both reach
    /// here: the packed timetable files a journey under its GTFS `trip_id`,
    /// while SIRI files the same run under its Swiss Journey ID. A link that
    /// offered only one of them would join packed legs and never live ones.
    ///
    /// Lower-cased here, once, rather than at every comparison. The feeds
    /// disagree on the case of the namespace — `CH:1:sjyid:` against
    /// `ch:1:sjyid:` — so the comparison has to be case-insensitive, and doing
    /// it lazily meant re-folding 75,000 names on every chain rebuild.
    private func workingNames(row: Int) -> [String] {
        var names = [tripID(row: row).lowercased()]
        if let ref = journeyReference(row: row)?.lowercased(), ref != names[0] {
            names.append(ref)
        }
        return names.filter { !$0.isEmpty }
    }

    /// The published through-services running on `date`.
    ///
    /// This is the feed saying outright what the app used to infer: these two
    /// numbered workings are one vehicle and the passenger does not get off.
    /// A day is around 18,800 links nationally, so the whole day is resolved at
    /// once and the caller indexes it; there is no per-train query because at
    /// this size there does not need to be one.
    ///
    /// The calendar is not a detail. A link is only true on the days both its
    /// workings run, and the same trip row carries different successors on
    /// different days — unfiltered, one appears to part as many as 56 ways.
    public func throughServices(
        on date: Date, zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
    ) -> [ThroughLink] {
        guard isReady, linkCount > 0 else { return [] }
        let day = Self.daysSince1970(date, zone: zone) - feedStart
        guard day >= 0, day < dayCount else { return [] }

        var out: [ThroughLink] = []
        out.reserveCapacity(4096)
        for i in 0..<linkCount {
            let at = linksAt + i * 12
            let service = Int(bytes.loadUnaligned(fromByteOffset: at + 8, as: UInt32.self))
            guard runs(service: service, onDay: day) else { continue }
            let from = Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            let to = Int(bytes.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            guard from >= 0, from < tripCount, to >= 0, to < tripCount else { continue }
            let leaving = workingNames(row: from)
            let arriving = workingNames(row: to)
            guard !leaving.isEmpty, !arriving.isEmpty else { continue }
            out.append(ThroughLink(from: leaving, to: arriving))
        }
        return out
    }

    /// The mode field alone, for queries that can reject a trip without
    /// allocating the three strings beside it in the class record.
    private func classMode(_ i: Int) -> Mode {
        guard i >= 0, i < classCount else { return .other }
        let raw = Int(bytes.loadUnaligned(
            fromByteOffset: classesAt + i * 16 + 12, as: UInt32.self
        ))
        let modes: [Mode] = [.train, .tram, .bus, .metro, .boat, .cable, .other]
        return raw < modes.count ? modes[raw] : .other
    }
}

public extension Journey {
    /// Marks a journey the timetable produced rather than a feed.
    ///
    /// Worth a name of its own because the distinction is user-visible: a
    /// timetabled journey is what is *meant* to happen and carries no delay, and
    /// the panel says so rather than implying a silence means punctuality.
    static let timetableSource = "timetable"

    var isTimetabled: Bool { source == Journey.timetableSource }
}
