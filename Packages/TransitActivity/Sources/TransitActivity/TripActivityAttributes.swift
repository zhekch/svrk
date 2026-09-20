import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// One pinned departure or arrival, as the lock screen and Dynamic Island
/// know it.
///
/// Static fields are the identity of the watch — which service, which station,
/// which kind of event. The times, the delay and (for an arrival) where the
/// vehicle currently is live in `ContentState`, because those are the numbers
/// the background poll rewrites.
public struct TripActivityAttributes: ActivityAttributes {
    public typealias Kind = TripWatchKind

    public struct ContentState: Codable, Hashable, Sendable {
        /// Expected event time, delay already folded in.
        public var expected: Date
        /// Printed timetable time, before any delay.
        public var scheduled: Date
        /// Minutes late. Zero or negative is on time; whether that is worth
        /// drawing is a presentation question, not a storage one.
        public var delayMinutes: Int
        /// App-refreshed countdown for iOS 17 and the "now" handoff on all versions.
        /// iOS 18+ renders positive countdowns directly from `expected`.
        public var remainingMinutes: Int
        public var platform: String?
        /// True while the live platform is not the one that was booked when
        /// the watch started. Drawn orange, same as a delay.
        public var platformChanged: Bool
        public var cancelled: Bool
        /// Arrival watches only: the stop the vehicle is at or running toward.
        public var currentStop: String?
        public var atCurrentStop: Bool

        public init(
            expected: Date,
            scheduled: Date,
            delayMinutes: Int = 0,
            remainingMinutes: Int? = nil,
            platform: String? = nil,
            platformChanged: Bool = false,
            cancelled: Bool = false,
            currentStop: String? = nil,
            atCurrentStop: Bool = false
        ) {
            self.expected = expected
            self.scheduled = scheduled
            self.delayMinutes = delayMinutes
            self.remainingMinutes = remainingMinutes
                ?? TripActivityFormat.remainingMinutes(until: expected)
            self.platform = platform
            self.platformChanged = platformChanged
            self.cancelled = cancelled
            self.currentStop = currentStop
            self.atCurrentStop = atCurrentStop
        }
    }

    public var kind: Kind
    public var line: String
    public var mode: String
    public var station: String
    public var destination: String
    /// Stable across Live Activity updates so a second swipe of the same row
    /// refreshes rather than stacking another island.
    public var watchID: String
    /// OJP journey reference, where the run has one. The background poll asks
    /// about this; a missing value means the countdown still runs off the
    /// timetable and delays will not be rewritten.
    public var journeyRef: String?
    public var day: String
    public var stopRef: String?
    /// Platform at the moment the watch was pinned. A later, different
    /// platform is a change, and is drawn orange.
    public var bookedPlatform: String?

    public init(
        kind: Kind,
        line: String,
        mode: String,
        station: String,
        destination: String,
        watchID: String,
        journeyRef: String? = nil,
        day: String,
        stopRef: String? = nil,
        bookedPlatform: String? = nil
    ) {
        self.kind = kind
        self.line = line
        self.mode = mode
        self.station = station
        self.destination = destination
        self.watchID = watchID
        self.journeyRef = journeyRef
        self.day = day
        self.stopRef = stopRef
        self.bookedPlatform = bookedPlatform
    }
}

extension TripActivityAttributes {
    public static var previewDeparture: TripActivityAttributes {
        TripActivityAttributes(
            kind: .departure,
            line: "IC61",
            mode: "train",
            station: "Spiez",
            destination: "Basel SBB",
            watchID: "preview-departure",
            journeyRef: "preview",
            day: "2026-09-11",
            stopRef: nil
        )
    }

    public static var previewArrival: TripActivityAttributes {
        TripActivityAttributes(
            kind: .arrival,
            line: "IC81",
            mode: "train",
            station: "Thun",
            destination: "Interlaken Ost",
            watchID: "preview-arrival",
            journeyRef: "preview",
            day: "2026-09-11",
            stopRef: nil
        )
    }
}

extension TripActivityAttributes.ContentState {
    public static var previewOnTime: Self {
        let expected = Date().addingTimeInterval(4 * 60 + 20)
        return Self(expected: expected, scheduled: expected, platform: "3")
    }

    public static var previewDelayed: Self {
        let scheduled = Date().addingTimeInterval(12 * 60)
        return Self(
            expected: scheduled.addingTimeInterval(3 * 60),
            scheduled: scheduled,
            delayMinutes: 3,
            platform: "2"
        )
    }

    public static var previewArrival: Self {
        let scheduled = Date().addingTimeInterval(18 * 60)
        return Self(
            expected: scheduled.addingTimeInterval(5 * 60),
            scheduled: scheduled,
            delayMinutes: 5,
            platform: "1",
            currentStop: "Spiez",
            atCurrentStop: false
        )
    }

    public static var previewCancelled: Self {
        Self(
            expected: Date().addingTimeInterval(20 * 60),
            scheduled: Date().addingTimeInterval(20 * 60),
            platform: "7",
            cancelled: true
        )
    }
}
#endif
