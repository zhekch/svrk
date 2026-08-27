import Foundation

/// The operator register: SBOID → the name a passenger would recognise.
///
/// SIRI-ET identifies who runs a service only by its business-organisation id,
/// `ch:1:sboid:100015`. Shown raw that reads as "Train from Münchenbuchsee ·
/// 100015", which is worse than saying nothing at all — it looks like a bug and
/// tells the reader less than the blank would. The federal register maps it to
/// "BLS", which is what is written on the front of the train.
public final class OperatorRegister: @unchecked Sendable {
    private var table: [String: (short: String, full: String?)] = [:]

    public init() {}

    public var isReady: Bool { !table.isEmpty }
    public var count: Int { table.count }

    public func load(_ url: URL) throws {
        var reader = BinaryReader(try MappedFile(url: url))
        try reader.expect(magic: "SVOPERTR", version: 1)
        let strings = try reader.readStringTable()
        try reader.align(to: 4)

        let count = Int(try reader.readUInt32())
        var rows = [String: (String, String?)](minimumCapacity: count)
        for _ in 0..<count {
            let ref = strings[Int(try reader.readUInt32())]
            let short = strings[Int(try reader.readUInt32())]
            let fullIndex = try reader.readUInt32()
            rows[ref] = (short, fullIndex == BinaryFormat.noString ? nil : strings[Int(fullIndex)])
        }
        table = rows
    }

    /// The short company code — SBB, BLS, PAG, SVB — or nil.
    ///
    /// Nil rather than the id, deliberately: a caller that cannot name the
    /// operator should leave the field out rather than print an opaque number.
    public func name(for ref: String?) -> String? {
        guard let ref else { return nil }
        return table[ref]?.short
    }

    /// The full registered name, where it says more than the code does.
    ///
    /// The register is a legal one, so it lists companies rather than the
    /// brands they trade under: Bernmobil is "Städtische Verkehrsbetriebe Bern
    /// (SVB)". Useful as a subtitle, too long for a panel line.
    public func fullName(for ref: String?) -> String? {
        guard let ref, let row = table[ref] else { return nil }
        return row.full ?? row.short
    }
}
