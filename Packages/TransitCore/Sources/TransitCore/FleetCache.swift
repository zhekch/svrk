import Foundation

/// The last national snapshot, kept in the shape the app actually uses it in.
///
/// The app has always kept a copy of the feed so that a launch with no signal
/// still draws the country. What it kept was the *response* — 150 MB of XML —
/// and every launch paid to parse it again: four seconds on a laptop, most of
/// half a minute on a phone, in front of a curtain saying "Loading the network"
/// over data that was already on the device. Cached, in the sense that nothing
/// had to be fetched; not cached, in the sense that everything had to be
/// derived a second time.
///
/// So the cache is the parsed fleet instead: 16,000 journeys and half a million
/// calls, written the same way as the bundled stores — one shared string blob,
/// coordinates as `Int32` micro-degrees, everything else fixed-width — and read
/// back by walking the file once. About 25 MB, and a read that costs
/// materialising the objects rather than parsing anything.
///
/// What is *not* stored is anything derived: geometry, chains, layovers. Those
/// are rebuilt from the journeys on demand and would only go stale here.
public enum FleetCache {
    static let magic = "SVFLEET1"
    /// Bump on any change of layout. A cache written by another version is
    /// discarded rather than misread — it is a copy of something the network
    /// can supply again.
    ///
    /// Unchanged by the cancelled/extra call flags: both went into spare bits
    /// of flag bytes that were already written, so the layout is the same and a
    /// file from before them decodes with the bits clear — which is the right
    /// answer for a snapshot taken when the app did not know the fact.
    /// 2: `delay` became minutes rather than seconds. The layout is unchanged,
    /// so an old cache still *reads* — it just reports every delay sixty times
    /// too large, which is worse than not reading it at all. A units change is
    /// a layout change for this purpose.
    static let version: UInt32 = 2

    // MARK: - Writing

    public static func write(_ journeys: some Collection<Journey>, to url: URL) throws {
        var writer = BinaryWriter()
        writer.reserve(journeys.count * 1_600)

        var body = BinaryWriter()
        body.reserve(journeys.count * 1_500)
        var strings = StringTable()

        body.writeUInt32(UInt32(journeys.count))
        for journey in journeys { encode(journey, into: &body, &strings) }

        writer.writeMagic(magic, version: version)
        strings.write(into: &writer)
        writer.append(body)
        try writer.data.write(to: url, options: .atomic)
    }

    private static func encode(_ journey: Journey, into out: inout BinaryWriter, _ strings: inout StringTable) {
        out.writeUInt32(strings.index(journey.id))
        out.writeUInt32(strings.index(journey.mode.rawValue))
        out.writeUInt32(strings.index(journey.category))
        out.writeUInt32(strings.index(journey.line))
        out.writeUInt32(strings.index(journey.number))
        out.writeUInt32(strings.index(journey.operatorName))
        out.writeUInt32(strings.index(journey.operatorFull))
        out.writeUInt32(strings.index(journey.to))
        out.writeUInt32(strings.index(journey.from))
        out.writeUInt32(strings.index(journey.source))
        out.writeInt64(Int64(journey.start))
        out.writeInt64(Int64(journey.end))
        out.writeInt32(Int32(journey.delay ?? 0))

        var flags: UInt8 = 0
        if journey.complete { flags |= 1 }
        if journey.monitored { flags |= 2 }
        if journey.cancelled { flags |= 4 }
        if journey.delay != nil { flags |= 8 }
        if journey.extra { flags |= 16 }
        out.writeUInt8(flags)

        out.writeUInt32(UInt32(journey.stops.count))
        for call in journey.stops { encode(call, into: &out, &strings) }
    }

    private static func encode(_ call: Call, into out: inout BinaryWriter, _ strings: inout StringTable) {
        // A call's key is its reference and its visit number — `…:7000|1` — and
        // every one of the half million is different, so stored whole they
        // would be the largest thing in the file and the least compressible.
        // Where the key really is that pair it is written as the pair.
        var suffix: String?
        if let ref = call.ref, call.key.hasPrefix(ref), call.key.dropFirst(ref.count).hasPrefix("|") {
            suffix = String(call.key.dropFirst(ref.count + 1))
        }

        out.writeUInt32(strings.index(call.ref))
        out.writeUInt32(strings.index(suffix ?? call.key))
        out.writeUInt32(strings.index(call.name))
        out.writeUInt32(strings.index(call.platform))
        out.writeUInt32(strings.index(call.note))
        out.writeUInt32(strings.index(call.assigned))
        out.writeInt32(BinaryFormat.encode(call.lat))
        out.writeInt32(BinaryFormat.encode(call.lon))
        out.writeInt64(Int64(call.arr))
        out.writeInt64(Int64(call.dep))
        out.writeInt64(Int64(call.sched ?? 0))
        out.writeInt32(Int32(call.delay ?? 0))

        var flags: UInt8 = 0
        if call.precise { flags |= 1 }
        if call.observed { flags |= 2 }
        if call.delay != nil { flags |= 4 }
        if call.sched != nil { flags |= 8 }
        if suffix != nil { flags |= 16 }
        if call.cancelled { flags |= 32 }
        if call.extra { flags |= 64 }
        out.writeUInt8(flags)
    }

    // MARK: - Reading

    /// The fleet as it was written, or nil if this is not one of these files.
    ///
    /// Never throws for a caller: a cache that cannot be read is a cache that
    /// is not used, and the feed can supply the same thing again.
    public static func read(_ url: URL) -> [String: Journey]? {
        guard let file = try? MappedFile(url: url) else { return nil }
        var reader = BinaryReader(file)
        do {
            try reader.expect(magic: magic, version: version)
            let strings = try reader.readStringTable()
            let count = Int(try reader.readUInt32())

            var out = [String: Journey](minimumCapacity: count)
            for _ in 0..<count {
                let journey = try decodeJourney(&reader, strings)
                out[journey.id] = journey
            }
            return out
        } catch {
            return nil
        }
    }

    /// Whether a file is one of these at all, without reading it.
    ///
    /// The recorded snapshots in `archive/` are XML, and replaying one is how
    /// this app is checked against a daytime fleet at three in the morning. The
    /// reader decides by what the file *is* rather than by what it is called.
    public static func isFleetCache(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magic.utf8.count) else { return false }
        return String(decoding: head, as: UTF8.self) == magic
    }

    private static func decodeJourney(_ reader: inout BinaryReader, _ strings: [String]) throws -> Journey {
        func string(_ index: UInt32) -> String? {
            index == BinaryFormat.noString || Int(index) >= strings.count ? nil : strings[Int(index)]
        }

        let id = string(try reader.readUInt32()) ?? ""
        let mode = Mode(rawValue: string(try reader.readUInt32()) ?? "") ?? .other
        let category = string(try reader.readUInt32())
        let line = string(try reader.readUInt32()) ?? ""
        let number = string(try reader.readUInt32())
        let operatorName = string(try reader.readUInt32())
        let operatorFull = string(try reader.readUInt32())
        let to = string(try reader.readUInt32())
        let from = string(try reader.readUInt32()) ?? ""
        let source = string(try reader.readUInt32()) ?? "cache"
        let start = Timestamp(try reader.readInt64())
        let end = Timestamp(try reader.readInt64())
        let delay = Int(try reader.readInt32())
        let flags = try reader.readUInt8()

        let stopCount = Int(try reader.readUInt32())
        var stops: [Call] = []
        stops.reserveCapacity(stopCount)
        for _ in 0..<stopCount { stops.append(try decodeCall(&reader, strings)) }

        return Journey(
            id: id, mode: mode, category: category, line: line, number: number,
            operatorName: operatorName, operatorFull: operatorFull, to: to, from: from,
            delay: flags & 8 != 0 ? delay : nil, start: start, end: end,
            complete: flags & 1 != 0, monitored: flags & 2 != 0, cancelled: flags & 4 != 0,
            source: source, stops: stops, extra: flags & 16 != 0
        )
    }

    private static func decodeCall(_ reader: inout BinaryReader, _ strings: [String]) throws -> Call {
        func string(_ index: UInt32) -> String? {
            index == BinaryFormat.noString || Int(index) >= strings.count ? nil : strings[Int(index)]
        }

        let ref = string(try reader.readUInt32())
        let keyPart = string(try reader.readUInt32()) ?? ""
        let name = string(try reader.readUInt32()) ?? ""
        let platform = string(try reader.readUInt32())
        let note = string(try reader.readUInt32())
        let assigned = string(try reader.readUInt32())
        let lat = BinaryFormat.decode(try reader.readInt32())
        let lon = BinaryFormat.decode(try reader.readInt32())
        let arr = Timestamp(try reader.readInt64())
        let dep = Timestamp(try reader.readInt64())
        let sched = Timestamp(try reader.readInt64())
        let delay = Int(try reader.readInt32())
        let flags = try reader.readUInt8()

        return Call(
            key: flags & 16 != 0 ? "\(ref ?? "")|\(keyPart)" : keyPart,
            ref: ref, name: name, lat: lat, lon: lon, platform: platform,
            precise: flags & 1 != 0, arr: arr, dep: dep,
            delay: flags & 4 != 0 ? delay : nil,
            observed: flags & 2 != 0, note: note,
            sched: flags & 8 != 0 ? sched : nil,
            assigned: assigned,
            cancelled: flags & 32 != 0,
            extra: flags & 64 != 0
        )
    }
}

/// The write half of `BinaryReader`, for the one file this app produces itself.
///
/// Everything else here is packed offline by `scripts/pack-ios-data.mjs` and
/// only ever read, which is why there was no writer until now.
struct BinaryWriter {
    private(set) var data = Data()

    mutating func reserve(_ bytes: Int) { data.reserveCapacity(bytes) }

    mutating func writeMagic(_ magic: String, version: UInt32) {
        data.append(contentsOf: Array(magic.utf8))
        writeUInt32(version)
    }

    mutating func writeUInt8(_ value: UInt8) { data.append(value) }

    mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeInt32(_ value: Int32) { writeUInt32(UInt32(bitPattern: value)) }

    mutating func writeInt64(_ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func writeBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }

    mutating func append(_ other: BinaryWriter) { data.append(other.data) }
}

/// One entry per distinct string, in the order first seen.
///
/// Station names repeat across thousands of calls and line numbers across
/// hundreds of journeys, so the table is both what makes the file small and
/// what makes reading it cheap: each name is created once and then shared by
/// every call that carries it, which is a retain rather than an allocation.
struct StringTable {
    private var byValue: [String: UInt32] = [:]
    private var values: [String] = []

    mutating func index(_ value: String?) -> UInt32 {
        guard let value else { return BinaryFormat.noString }
        if let held = byValue[value] { return held }
        let next = UInt32(values.count)
        byValue[value] = next
        values.append(value)
        return next
    }

    func write(into writer: inout BinaryWriter) {
        writer.writeUInt32(UInt32(values.count))
        var offsets: [UInt32] = []
        offsets.reserveCapacity(values.count + 1)
        var blob: [UInt8] = []
        blob.reserveCapacity(values.count * 16)
        for value in values {
            offsets.append(UInt32(blob.count))
            blob.append(contentsOf: Array(value.utf8))
        }
        offsets.append(UInt32(blob.count))
        for offset in offsets { writer.writeUInt32(offset) }
        writer.writeBytes(blob)
    }
}
