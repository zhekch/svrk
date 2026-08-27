import Foundation

/// Read SIRI-SX, both halves of it.
///
/// Shaped after `SiriParser` and for the same reason: the planned feed is 113
/// MB of XML (4.3 MB on the wire), so notices are cut out of the byte stream
/// one at a time and the consumed prefix dropped. The unplanned feed is 330 kB
/// and would not need any of that; it gets it anyway rather than carry a second
/// reader for the same grammar.
///
/// One thing here that `SiriParser` deliberately does not do: **read
/// attributes**. The estimated timetable has none on any element this app
/// touches, and its tag reader says so. SX carries the whole point of itself in
/// one — `<SummaryText xml:lang="EN">` — so the text reader below scans the
/// open tag rather than assuming it ends at the first `>` after the name.
final class SituationParser {
    /// Notices outside this window of now are dropped as they are parsed.
    ///
    /// The planned feed's validity runs 2024 to 2027 and nearly all of it is
    /// about some weekend in two months. Keeping it would mean keeping 130,982
    /// journey references to serve the ~1,000 that are about today.
    static let defaultHorizon: TimeInterval = 24 * 3600

    struct Tag {
        let open: ByteScan.Needle
        let close: ByteScan.Needle
        let openLength: Int
        let closeLength: Int

        init(_ name: String) {
            open = ByteScan.Needle("<\(name)>")
            close = ByteScan.Needle("</\(name)>")
            openLength = name.utf8.count + 2
            closeLength = name.utf8.count + 3
        }
    }

    /// An element that carries `xml:lang`, matched on its name alone so the
    /// attributes after it are still in front of the reader.
    struct OpenTag {
        let partial: ByteScan.Needle
        let close: ByteScan.Needle
        let closeLength: Int

        init(_ name: String) {
            partial = ByteScan.Needle("<\(name)")
            close = ByteScan.Needle("</\(name)>")
            closeLength = name.utf8.count + 3
        }
    }

    struct Tags {
        let situation = Tag("PtSituationElement")
        let number = Tag("SituationNumber")
        let cause = Tag("AlertCause")
        let versioned = Tag("VersionedAtTime")
        let validity = Tag("ValidityPeriod")
        let start = Tag("StartTime")
        let end = Tag("EndTime")
        let uri = Tag("Uri")

        let summary = OpenTag("SummaryText")
        let description = OpenTag("DescriptionText")
        let reason = OpenTag("ReasonText")
        let consequence = OpenTag("ConsequenceText")
        let duration = OpenTag("DurationText")
        let advice = OpenTag("RecommendationText")

        let publishedLine = Tag("PublishedLineName")
        let stopPlaceRef = Tag("StopPlaceRef")
        let journeyRef = Tag("DatedVehicleJourneyRef")
        let operatorRef = Tag("OperatorRef")

        /// The containers the three above are only meaningful inside. See
        /// `unique(_:_:within:_:)`.
        let affectedStopPlace = Tag("AffectedStopPlace")
        let affectedLine = Tag("AffectedLine")
        let affectedOperator = Tag("AffectedOperator")
    }

    private static let tags = Tags()

    private let planned: Bool
    private let now: Timestamp
    private let horizon: TimeInterval
    private var held: [UInt8] = []

    private(set) var seen = 0
    private(set) var kept = 0

    init(planned: Bool, now: Timestamp, horizon: TimeInterval = SituationParser.defaultHorizon) {
        self.planned = planned
        self.now = now
        self.horizon = horizon
        held.reserveCapacity(1 << 20)
    }

    func consume(_ chunk: Data, onSituation: (Situation) -> Void) {
        held.append(contentsOf: chunk)
        // A notice runs to a few kB; a planned one naming thousands of journeys
        // runs to a great deal more, so the buffer is allowed to grow rather
        // than scanned at every chunk.
        if held.count > 1 << 18 { drain(onSituation: onSituation) }
    }

    func finish(onSituation: (Situation) -> Void) {
        drain(onSituation: onSituation)
    }

    private func drain(onSituation: (Situation) -> Void) {
        var consumedTo = 0
        held.withUnsafeBytes { raw in
            consumedTo = scan(raw, upTo: raw.count, onSituation: onSituation)
        }
        if consumedTo > 0 { held.removeFirst(consumedTo) }
    }

    private func scan(
        _ raw: UnsafeRawBufferPointer, upTo: Int, onSituation: (Situation) -> Void
    ) -> Int {
        var at = 0
        while at < upTo {
            guard let start = ByteScan.find(Self.tags.situation.open, in: raw, from: at),
                  start < upTo
            else { return max(at, upTo - Self.tags.situation.openLength) }
            guard let end = ByteScan.find(Self.tags.situation.close, in: raw, from: start) else {
                return start
            }

            seen += 1
            let body = (start + Self.tags.situation.openLength)..<end
            if let situation = parse(raw, body), situation.isWithin(horizon, of: now) {
                kept += 1
                onSituation(situation)
            }
            at = end + Self.tags.situation.closeLength
        }
        return at
    }

    // MARK: - One notice

    private func parse(_ raw: UnsafeRawBufferPointer, _ body: Range<Int>) -> Situation? {
        guard let id = text(raw, body, Self.tags.number) else { return nil }

        return Situation(
            id: id,
            planned: planned,
            cause: text(raw, body, Self.tags.cause),
            updated: instant(raw, body, Self.tags.versioned),
            windows: windows(raw, body),
            summary: localised(raw, body, Self.tags.summary),
            detail: localised(raw, body, Self.tags.description),
            reason: localised(raw, body, Self.tags.reason),
            consequence: localised(raw, body, Self.tags.consequence),
            duration: localised(raw, body, Self.tags.duration),
            advice: localised(raw, body, Self.tags.advice),
            link: text(raw, body, Self.tags.uri),
            lines: unique(raw, body, within: Self.tags.affectedLine, Self.tags.publishedLine),
            stopPlaces: unique(
                raw, body, within: Self.tags.affectedStopPlace, Self.tags.stopPlaceRef
            ),
            // Only the planned feed has these, and a national snapshot of it
            // carries 130,982 — which is why the horizon filter above runs
            // before any of this is retained.
            journeys: planned ? unique(raw, body, Self.tags.journeyRef) : [],
            operators: unique(raw, body, within: Self.tags.affectedOperator, Self.tags.operatorRef)
        )
    }

    private func windows(_ raw: UnsafeRawBufferPointer, _ body: Range<Int>) -> [Situation.Window] {
        var out: [Situation.Window] = []
        forEachBlock(raw, body, Self.tags.validity) { range in
            guard let from = instant(raw, range, Self.tags.start) else { return }
            out.append(Situation.Window(from: from, until: instant(raw, range, Self.tags.end)))
        }
        return out
    }

    // MARK: - Tag reading

    /// The preferred translation of a repeated, language-tagged element.
    ///
    /// Two choices, and both are firsts.
    ///
    /// **English where the feed has it, German otherwise** — German being the
    /// one language every notice in both feeds is written in, and the language
    /// the app's existing `CallNote` lookup was already built around.
    ///
    /// **The first block, not the last.** Every notice carries the same text
    /// three times over, once per `Perspective` — `general`, `stopPoint`,
    /// `vehicleJourney` — and they are not translations of each other but
    /// re-tellings at increasing length. Thalwil's broken lift is "Restricted
    /// wheelchair access Thalwil", then "Access to station Thalwil is
    /// restricted", then "Step-free access for passengers with reduced mobility
    /// to station Thalwil is no longer guaranteed." The general one comes first
    /// and is the only one of the three that fits on a phone.
    private func localised(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: OpenTag
    ) -> String? {
        var fallback: String?
        var at = range.lowerBound

        while let found = ByteScan.find(tag.partial, in: raw, from: at), found < range.upperBound {
            // Past the attributes to the end of the opening tag. A malformed
            // document with no `>` is not read past the bound it was given.
            guard let opened = closingAngle(raw, from: found, upTo: range.upperBound),
                  let end = ByteScan.find(tag.close, in: raw, from: opened),
                  end < range.upperBound
            else { return fallback }

            let attributes = decode(raw, (found)..<opened)
            let value = Self.tidy(decode(raw, (opened + 1)..<end))
            if attributes.contains("\"EN\"") || attributes.contains("\"en\"") {
                // The first English one settles it; there is nothing later in
                // the document that is a better answer to the same question.
                return value
            } else if fallback == nil {
                fallback = value
            }
            at = end + tag.closeLength
        }
        return fallback
    }

    /// The feed's text as a paragraph rather than as it sits in the document.
    ///
    /// Several operators write theirs across indented lines — a sign-off of
    /// "Thank you for your understanding." arrives preceded by a newline and
    /// twenty spaces — and a card laying that out honestly gets a ragged hole
    /// in the middle of it. Runs of whitespace become one space; the words are
    /// untouched.
    static func tidy(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pending = false
        for character in text {
            if character.isWhitespace {
                pending = !out.isEmpty
            } else {
                if pending { out.append(" ") }
                pending = false
                out.append(character)
            }
        }
        return out
    }

    private func closingAngle(
        _ raw: UnsafeRawBufferPointer, from: Int, upTo: Int
    ) -> Int? {
        var at = from
        while at < upTo {
            if raw[at] == UInt8(ascii: ">") { return at }
            at += 1
        }
        return nil
    }

    private func decode(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> String {
        ByteScan.decodeEntities(
            String(decoding: UnsafeRawBufferPointer(rebasing: raw[range]), as: UTF8.self)
        )
    }

    private func text(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag) -> String? {
        guard let body = tagRange(raw, range, tag) else { return nil }
        return decode(raw, body)
    }

    private func instant(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag
    ) -> Timestamp? {
        guard let body = tagRange(raw, range, tag) else { return nil }
        return ByteScan.parseInstant(raw, body)
    }

    private func tagRange(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag
    ) -> Range<Int>? {
        guard let start = ByteScan.find(tag.open, in: raw, from: range.lowerBound),
              start < range.upperBound,
              let end = ByteScan.find(tag.close, in: raw, from: start), end < range.upperBound
        else { return nil }
        return (start + tag.openLength)..<end
    }

    /// Every value of a repeated element, in order, without repeats.
    ///
    /// Repeats are the norm rather than the exception: an affected stop place
    /// is named once under `Affects` and again under the publishing action, and
    /// the planned feed lists a journey once per call it makes.
    private func unique(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag
    ) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        forEachBlock(raw, range, tag) { body in
            let value = decode(raw, body)
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            out.append(value)
        }
        return out
    }

    /// Every value of a repeated element, but only where it appears inside
    /// `container`.
    ///
    /// The scoping is the whole point and it is not defensive. A planned notice
    /// states what it affects twice over: once as `<AffectedStopPlace>`, the
    /// handful of stops the works are at, and again as the complete call list
    /// of every journey caught up in them. In the recorded national feed that
    /// is 5,033 of the first against **462,538** of the second — so an
    /// unscoped sweep for `<StopPlaceRef>` attaches a fortnight of track work
    /// between Bilten and Reichenburg to Frankfurt (Main) Hbf and Konstanz,
    /// which are simply stops a through service happens to call at. `OperatorRef`
    /// is the same shape of trap, 132,583 against 1,601.
    private func unique(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, within container: Tag, _ tag: Tag
    ) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        forEachBlock(raw, range, container) { scope in
            forEachBlock(raw, scope, tag) { body in
                let value = decode(raw, body)
                guard !value.isEmpty, seen.insert(value).inserted else { return }
                out.append(value)
            }
        }
        return out
    }

    private func forEachBlock(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ tag: Tag,
        _ body: (Range<Int>) -> Void
    ) {
        var at = range.lowerBound
        while true {
            guard let start = ByteScan.find(tag.open, in: raw, from: at), start < range.upperBound,
                  let end = ByteScan.find(tag.close, in: raw, from: start), end < range.upperBound
            else { return }
            body((start + tag.openLength)..<end)
            at = end + tag.closeLength
        }
    }
}
