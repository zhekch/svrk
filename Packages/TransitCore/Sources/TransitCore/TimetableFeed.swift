import Foundation

/// Finding the national timetable on opentransportdata.swiss, without being
/// told where it is.
///
/// The archive in the bundle expires — the Swiss timetable turns over on the
/// second Sunday of December — and the whole point of fetching a new one is
/// that nobody has to ship a build to make it happen. That only works if the
/// app can *find* the next feed on its own, and the shape of the site makes
/// that possible: every year's feed lives at a slug carrying its own year, and
/// `permalink` redirects to whatever file is current for it.
///
///     https://data.opentransportdata.swiss/dataset/timetable-2026-gtfs2020/permalink
///
/// Three facts about that URL, all measured against the live site rather than
/// assumed:
///
/// - **The next year is published long before it starts.** On 2026-08-23 the
///   2027 slug already resolved, to `gtfs_fp2027_20260819.zip` — filed the same
///   day as the 2026 one. So there is no window where the app is stuck: the
///   replacement is on the server months before the archive it replaces runs
///   out.
/// - **A year that does not exist yet is a clean 404**, and a year that has
///   passed is a 401. Both are answers, so probing is cheap and unambiguous.
/// - **The final URL is a presigned R2 link that expires in sixty seconds.** It
///   is therefore never worth storing; the permalink is the stable name and is
///   what gets re-resolved for a resumed download.
public struct TimetableFeed: Sendable, Equatable {
    /// The timetable year, as the site numbers it — `2027` is the year the
    /// period *ends* in, which is how the Swiss feed is labelled.
    public var year: Int
    /// The permalink, which is stable. Not the presigned URL it redirects to.
    public var url: URL
    /// The published file name, `gtfs_fp2027_20260819.zip`, which carries both
    /// the period and the date it was filed. Used to tell one publication of a
    /// year from a later one.
    public var fileName: String
    /// Bytes on the wire, from the ranged probe. 235 MB for the 2026 feed.
    public var bytes: Int

    public init(year: Int, url: URL, fileName: String, bytes: Int) {
        self.year = year
        self.url = url
        self.fileName = fileName
        self.bytes = bytes
    }

    public static func permalink(year: Int) -> URL {
        URL(string: "https://data.opentransportdata.swiss/dataset/timetable-\(year)-gtfs2020/permalink")!
    }
}

/// Asks the site which feed to fetch.
public struct TimetableFeedFinder: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// The feed that actually covers `moment`.
    ///
    /// Not "the newest one published", which is a trap the site sets: on
    /// 2026-08-24 the 2027 feed already resolved but was 59.4 MB against the
    /// 2026 feed's 235.1 MB, because a year is filed early and fills in as
    /// operators submit. Switching to it on the day it appears would trade a
    /// complete timetable for a fifth of one.
    ///
    /// The right feed is decided by the calendar, not by what exists. A Swiss
    /// timetable year is named for the year it *ends* in and turns over on the
    /// second Sunday of December, so anything from that Sunday onward belongs
    /// to the next year's feed. That is computable with no network at all;
    /// the site is then asked only to confirm the file is there.
    public func feed(
        covering moment: Date = Date(),
        zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
    ) async -> TimetableFeed? {
        await describe(year: Self.timetableYear(of: moment, zone: zone))
    }

    /// The timetable year a moment falls in.
    ///
    /// December's turnover is the second Sunday, so `2026-12-13` is already
    /// timetable year 2027 while `2026-12-12` is still 2026 — which is exactly
    /// where the bundled archive's last service day sits.
    public static func timetableYear(
        of moment: Date,
        zone: TimeZone = TimeZone(identifier: "Europe/Zurich") ?? .current
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: moment)
        guard let turnover = secondSundayOfDecember(year: year, calendar: calendar) else {
            return year + 1
        }
        return moment < turnover ? year : year + 1
    }

    /// The second Sunday of December in `year`, at that day's local midnight.
    static func secondSundayOfDecember(year: Int, calendar: Calendar) -> Date? {
        var parts = DateComponents()
        parts.year = year
        parts.month = 12
        parts.day = 1
        guard let first = calendar.date(from: parts) else { return nil }
        // 1 is Sunday in Gregorian `weekday`. Step to the first Sunday, then a
        // week past it.
        let weekday = calendar.component(.weekday, from: first)
        let toSunday = (8 - weekday) % 7
        return calendar.date(byAdding: .day, value: toSunday + 7, to: first)
    }

    /// Resolve one year, or nil if the site has no such feed.
    ///
    /// A one-byte ranged GET rather than a HEAD, deliberately: the permalink
    /// ends at a presigned S3-style URL, and those are signed for the method
    /// they were issued for — a HEAD against one comes back 403 even though the
    /// object is there and readable. The `Content-Range` on a range request
    /// carries the full length, so this costs one byte and answers both
    /// questions at once.
    public func describe(year: Int) async -> TimetableFeed? {
        let permalink = TimetableFeed.permalink(year: year)
        var request = URLRequest(url: permalink)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              // 206 for the range, 200 if the server ignored it.
              http.statusCode == 206 || http.statusCode == 200
        else { return nil }

        let total = Self.totalBytes(from: http)
        // The redirect chain ends at the object, whose last path component is
        // the published file name.
        let name = http.url?.lastPathComponent ?? "gtfs_fp\(year).zip"
        guard total > 0 else { return nil }
        return TimetableFeed(
            year: year, url: permalink,
            fileName: name.hasSuffix(".zip") ? name : "gtfs_fp\(year).zip",
            bytes: total
        )
    }

    /// The object's full length: out of `Content-Range` for a 206, and out of
    /// `Content-Length` when the server declined to range.
    static func totalBytes(from response: HTTPURLResponse) -> Int {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/") {
            let tail = range[range.index(after: slash)...]
            if let total = Int(tail.trimmingCharacters(in: .whitespaces)) { return total }
        }
        if response.statusCode == 200,
           let length = response.value(forHTTPHeaderField: "Content-Length"),
           let total = Int(length) {
            return total
        }
        return 0
    }
}
