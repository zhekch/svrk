import Foundation

/// Byte-level scanning helpers for the SIRI stream.
///
/// The response is about 150 MB of XML. Decoding that to `String` to search it
/// would cost more than everything else the app does put together, so the
/// parser works on the bytes and converts only the values it actually keeps.
enum ByteScan {
    /// A search pattern with its skip table already built.
    ///
    /// Building the table per call was the first version and it was badly
    /// wrong: a national snapshot does roughly six million tag lookups, and a
    /// 256-entry array allocated and filled for each one costs more than the
    /// scanning it accelerates. The tag names are fixed, so the tables are
    /// built once and reused for the life of the process.
    struct Needle {
        let bytes: [UInt8]
        let skip: [Int]

        init(_ text: String) {
            let bytes = Array(text.utf8)
            self.bytes = bytes
            var skip = [Int](repeating: bytes.count, count: 256)
            if bytes.count > 1 {
                for i in 0..<(bytes.count - 1) { skip[Int(bytes[i])] = bytes.count - 1 - i }
            }
            self.skip = skip
        }
    }

    /// Index of the first occurrence of `needle` in `haystack[from...]`, or nil.
    ///
    /// Boyer–Moore–Horspool. The needles here are XML tags — 10 to 25 bytes,
    /// with a last byte (`>`) that is common, but first bytes that are not — so
    /// the skip table earns its keep over the whole document even though each
    /// individual search is short.
    static func find(_ needle: Needle, in haystack: UnsafeRawBufferPointer, from: Int) -> Int? {
        let n = needle.bytes.count
        let h = haystack.count
        guard n > 0, h >= n, from >= 0, from <= h - n else { return nil }

        return needle.bytes.withUnsafeBufferPointer { pattern in
            needle.skip.withUnsafeBufferPointer { skip in
                var pos = from
                let last = n - 1
                while pos <= h - n {
                    var i = last
                    while haystack[pos + i] == pattern[i] {
                        if i == 0 { return pos }
                        i -= 1
                    }
                    pos += skip[Int(haystack[pos + last])]
                }
                return nil
            }
        }
    }

    /// The five predefined XML entities; SIRI uses no others.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// ISO instant to unix seconds.
    ///
    /// Hand-parsed rather than handed to `ISO8601DateFormatter`: a national
    /// snapshot carries roughly 300,000 of these, and the formatter costs about
    /// a microsecond each — a third of a second per refresh, spent entirely on
    /// re-deriving a calendar that never changes.
    ///
    /// SIRI stamps UTC with a trailing `Z` essentially always; an explicit
    /// offset is handled anyway, because being wrong by an hour is a worse
    /// failure than a branch that rarely runs.
    static func parseInstant(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> Timestamp? {
        // YYYY-MM-DDTHH:MM:SS
        guard range.count >= 19 else { return nil }
        let base = range.lowerBound

        @inline(__always) func digits(_ offset: Int, _ count: Int) -> Int? {
            var value = 0
            for i in 0..<count {
                let byte = bytes[base + offset + i]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2)
        else { return nil }

        var seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second

        // A trailing offset, where there is one: `+02:00`.
        var i = base + 19
        // Skip fractional seconds.
        if i < range.upperBound, bytes[i] == UInt8(ascii: ".") {
            i += 1
            while i < range.upperBound, bytes[i] >= 48, bytes[i] <= 57 { i += 1 }
        }
        if i < range.upperBound, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
            let sign = bytes[i] == UInt8(ascii: "+") ? 1 : -1
            let offset = i + 1 - base
            if let h = digits(offset, 2), let m = digits(offset + 3, 2) {
                seconds -= sign * (h * 3600 + m * 60)
            }
        }
        return seconds
    }

    /// Days since 1970-01-01 from a civil date. Howard Hinnant's algorithm —
    /// no calendar object, no allocation, exact for every date this feed can
    /// carry.
    @inline(__always)
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
