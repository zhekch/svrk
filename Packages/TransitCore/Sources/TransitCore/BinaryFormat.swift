import Foundation

/// The bundled data files, and how to read them.
///
/// The generated JSON this app is built on is 114 MB — 78 MB of OSM route
/// relations and 28 MB of railway graph. `JSONSerialization` on that costs tens
/// of seconds and several hundred megabytes of peak memory on a phone, which is
/// not a launch anybody would wait through. So the same data is packed offline
/// (see `scripts/pack-ios-data.mjs`) into files that can be memory-mapped and
/// read in place: no parse step, no allocation per coordinate, and the kernel
/// pages in only the parts actually touched.
///
/// Two conventions run through every file here:
///
/// - **Coordinates are `Int32` micro-degrees.** ±180° fits with room to spare
///   and the quantum is about 11 cm, well under the metre tolerance the
///   geometry pipeline simplifies to. Half the size of `Double`, and exact
///   under equality — which matters, because leg-joining compares endpoints.
/// - **Strings live in one blob**, addressed by index through an offset table.
///   Names repeat heavily ("Bern, Bahnhof" appears on thousands of calls), so
///   this both shrinks the file and lets equal names compare as equal indices.
public enum BinaryFormat {
    /// Degrees to the stored integer, and back.
    @inline(__always) public static func encode(_ degrees: Double) -> Int32 {
        Int32((degrees * 1_000_000).rounded())
    }

    @inline(__always) public static func decode(_ raw: Int32) -> Double {
        Double(raw) / 1_000_000
    }

    /// Marks an absent string. Index 0 is a real (empty) entry, so the sentinel
    /// has to be out of range rather than falsy.
    public static let noString: UInt32 = .max
}

/// A file mapped into the address space for the life of this object.
///
/// `Data(contentsOf:.mappedIfSafe)` would do, but its buffer pointer is only
/// promised valid inside `withUnsafeBytes`, and the relation store is 32 MB of
/// geometry that wants to be read in place rather than copied to the heap.
/// Owning the mapping outright makes the pointer's lifetime a fact rather than
/// an assumption — and `munmap` on deinit gives it back.
public final class MappedFile: @unchecked Sendable {
    public let buffer: UnsafeRawBufferPointer
    private let length: Int

    public init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        length = Int(info.st_size)

        guard let base = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        buffer = UnsafeRawBufferPointer(start: base, count: length)
    }

    deinit {
        if let base = UnsafeMutableRawPointer(mutating: buffer.baseAddress) {
            munmap(base, length)
        }
    }
}

/// Sequential little-endian reads over a mapped buffer.
///
/// Deliberately not a `Codable` decoder. Everything here is read once at load
/// into the shape the algorithms already want — flat arrays, mostly — and a
/// keyed decoder would allocate an intermediate representation of exactly the
/// data this format exists to avoid materialising.
public struct BinaryReader {
    public let bytes: UnsafeRawBufferPointer
    public private(set) var cursor: Int

    /// The mapping the bytes belong to, held so it cannot be unmapped while
    /// this reader still points into it.
    ///
    /// Without this the reader was a use-after-free waiting to happen: a
    /// caller writing `BinaryReader(try MappedFile(url:))` creates a mapping
    /// with no other strong reference, ARC releases it after the initialiser
    /// returns, `munmap` hands the pages back, and the first read segfaults.
    /// Ownership belongs with the thing holding the pointer.
    private let file: MappedFile?

    public init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
        self.cursor = 0
        self.file = nil
    }

    public init(_ file: MappedFile) {
        self.bytes = file.buffer
        self.cursor = 0
        self.file = file
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case truncated(needed: Int, available: Int)
        case badMagic(expected: String, found: String)
        case unsupportedVersion(UInt32)

        public var description: String {
            switch self {
            case let .truncated(needed, available):
                return "truncated: wanted \(needed) bytes, \(available) left"
            case let .badMagic(expected, found):
                return "wrong file type: expected \(expected), found \(found)"
            case let .unsupportedVersion(v):
                return "unsupported format version \(v)"
            }
        }
    }

    private mutating func take(_ count: Int) throws -> Int {
        let available = bytes.count - cursor
        guard count <= available else { throw Error.truncated(needed: count, available: available) }
        let at = cursor
        cursor += count
        return at
    }

    public mutating func expect(magic: String, version: UInt32) throws {
        let at = try take(8)
        let found = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[at..<(at + 8)]), as: UTF8.self)
        guard found == magic else { throw Error.badMagic(expected: magic, found: found) }
        let v = try readUInt32()
        guard v == version else { throw Error.unsupportedVersion(v) }
    }

    public mutating func readUInt8() throws -> UInt8 {
        let at = try take(1)
        return bytes.load(fromByteOffset: at, as: UInt8.self)
    }

    public mutating func readUInt32() throws -> UInt32 {
        let at = try take(4)
        return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readInt64() throws -> Int64 {
        let at = try take(8)
        return Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: Int64.self))
    }

    /// A run of fixed-width little-endian values, copied out in one go.
    ///
    /// The copy is the point for the graph arrays: Dijkstra touches them
    /// millions of times, and an `[Int32]` the optimiser can hold in registers
    /// beats re-deriving an offset into a mapped buffer on every edge.
    public mutating func readArray<T>(_ type: T.Type, count: Int) throws -> [T] {
        let at = try take(count * MemoryLayout<T>.size)
        guard let base = bytes.baseAddress else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialised in
            memcpy(buffer.baseAddress!, base.advanced(by: at), count * MemoryLayout<T>.size)
            initialised = count
        }
    }

    /// The shared string blob: a table of offsets, then the UTF-8 bytes.
    public mutating func readStringTable() throws -> [String] {
        let count = Int(try readUInt32())
        let offsets = try readArray(UInt32.self, count: count + 1)
        let blobLength = Int(offsets[count])
        let base = try take(blobLength)

        var out = [String]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let lo = base + Int(offsets[i])
            let hi = base + Int(offsets[i + 1])
            out.append(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[lo..<hi]), as: UTF8.self))
        }
        return out
    }

    /// Skip `count` bytes and report where they started — for sections read
    /// lazily later rather than copied out now.
    public mutating func skip(_ count: Int) throws -> Int {
        try take(count)
    }

    /// Pad the cursor up to `alignment`, matching the writer.
    public mutating func align(to alignment: Int) throws {
        let slack = cursor % alignment
        if slack != 0 { _ = try take(alignment - slack) }
    }
}
