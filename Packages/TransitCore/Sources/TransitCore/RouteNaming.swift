import Foundation

/// The route title beside a separate line badge, shared by every route panel.
public enum RouteNaming {
    /// Missing mapped endpoints are absent information, not an itinerary.
    /// The line badge still identifies a route with no usable title.
    public static func headline(name: String?, from: String?, to: String?) -> String? {
        func usable(_ value: String?) -> String? {
            guard let value else { return nil }
            let title = StopNaming.displayRoute(value)
            guard !title.isEmpty, title != "?" else { return nil }
            return title
        }
        if let name = usable(name) { return name }
        switch (usable(from), usable(to)) {
        case let (from?, to?): return "\(from) → \(to)"
        case let (from?, nil): return "From \(from)"
        case let (nil, to?): return "To \(to)"
        case (nil, nil): return nil
        }
    }

    /// Mapped names commonly use `service: origin => destination`. The service
    /// can be a brand rather than the badge's ref (GoldenPass Express / GPX),
    /// so recognise that structure rather than maintain a list of line names.
    public static func trim(_ headline: String, ref: String) -> String {
        let title = arrows(in: headline).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = title.firstIndex(of: ":") else { return title }
        let prefix = String(title[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let route = String(title[title.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !route.isEmpty else { return title }

        // Do not strip a colon inside an itinerary that has already started,
        // e.g. `Basel → Museum: main entrance`.
        let separators: Set<Character> = ["→", "↔", "↦", "⟶", "⇒"]
        guard !prefix.contains(where: separators.contains) else { return title }
        let endpoints = route.split(whereSeparator: separators.contains)
        if endpoints.count >= 2,
           endpoints.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return route
        }

        // A one-destination title can still repeat its badge. Ignore spacing
        // and case (`IC8` / `IC 8`), and allow short descriptive words such as
        // `Tram` before the ref without confusing line 18 with line 8.
        func compact(_ value: String) -> String {
            value.lowercased().filter { !$0.isWhitespace }
        }
        let label = compact(prefix), badge = compact(ref)
        guard !badge.isEmpty, label.hasSuffix(badge) else { return title }
        let descriptor = label.dropLast(badge.count)
        guard descriptor.count <= 14, descriptor.allSatisfy(\.isLetter) else { return title }
        return route
    }

    private static func arrows(in title: String) -> String {
        StopNaming.arrows(in: StopNaming.unfoldMappedLegs(title))
    }
}

/// Stop names as they should be read, not as the register filed them.
///
/// Swiss DiDok and OSM both decorate names: country codes in brackets for a
/// station abroad (`Basel Bad Bf (D)`), and wrapping parentheses on a mapped
/// fragment that is not the line's real origin (`(Basel Bad Bf)`). Neither
/// belongs on a board.
public enum StopNaming {
    public static func display(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("("), text.hasSuffix(")"), text.count > 2 {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(where: { $0 == "(" || $0 == ")" }) {
                text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let open = text.lastIndex(of: "("),
           let close = text.lastIndex(of: ")"),
           close == text.index(before: text.endIndex) {
            let code = text[text.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            if (1...3).contains(code.count), code.allSatisfy(\.isLetter) {
                text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    /// Operating points the passenger never boards: the Bahn 2000 stretch,
    /// junctions, yard tracks. They are real GTFS stops and wreck a stop list.
    public static func isTechnical(_ name: String) -> Bool {
        let folded = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "de_CH")
        ).replacingOccurrences(of: " ", with: "")
        if folded.contains("bahn-2000") || folded.contains("bahn2000") { return true }
        if folded.contains("dienststation") { return true }
        if folded.hasPrefix("abzw") || folded.contains("abzweigung") { return true }
        if folded.contains("uberholgleis") { return true }
        if folded.contains("anschlussgleis") { return true }
        return false
    }

    /// OSM writes a stub terminus in brackets with its own arrow:
    /// `(Basel Bad Bf =>) Karlsruhe => München`. Keep the station, drop the
    /// brackets, so the title is a normal itinerary.
    public static func unfoldMappedLegs(_ title: String) -> String {
        var text = title
        text = text.replacingOccurrences(
            of: #"\(\s*([^)]+?)\s*(?:=>|->|→)\s*\)"#,
            with: "$1 => ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\(\s*(?:=>|->|→)\s*([^)]+?)\s*\)"#,
            with: " => $1",
            options: .regularExpression
        )
        return text
    }

    static func arrows(in title: String) -> String {
        title.replacingOccurrences(
            of: #"\s*(?:=>|->|→)\s*"#, with: " → ", options: .regularExpression
        )
    }

    /// Each end of a `A → B` title, so a fragment's wrapping parentheses
    /// do not survive beside the badge.
    public static func displayRoute(_ title: String) -> String {
        let normalized = arrows(in: unfoldMappedLegs(title))
        let arrows: Set<Character> = ["→", "↔", "↦", "⟶", "⇒"]
        var parts: [String] = []
        var current = ""
        var separators: [Character] = []
        for ch in normalized {
            if arrows.contains(ch) {
                parts.append(display(current))
                separators.append(ch)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(display(current))
        guard parts.count == separators.count + 1, !separators.isEmpty else {
            return display(normalized)
        }
        var out = parts[0]
        for (i, sep) in separators.enumerated() {
            out += " \(sep) \(parts[i + 1])"
        }
        return out.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Destinations as two feeds write them: `Weissenbühl` against
    /// `Bern, Weissenbühl`, `Bern Bahnhof` against `Bern, Bahnhof`.
    ///
    /// The comma form is the register's "place, stop". The local half is the
    /// same terminus the timetable files without the city. `Bern` against
    /// `Bern, Bollwerk` is not this — Bollwerk is a different stop.
    ///
    /// Lives here rather than on `Fleet` so the watch board, which compiles
    /// this file and not the fleet actor, groups the same two writings of a
    /// terminus into one card.
    public static func sameBoardDestination(_ a: String, _ b: String) -> Bool {
        if sameListedStop(a, b) { return true }
        let la = localDestination(a), lb = localDestination(b)
        if sameListedStop(la, lb) { return true }
        return sameListedStop(la, b) || sameListedStop(a, lb)
    }

    /// `Domodossola (I)` and `Domodossola` are one station.
    public static func sameListedStop(_ a: String, _ b: String) -> Bool {
        if squash(a) == squash(b) { return true }
        return squash(core(a)) == squash(core(b))
    }

    public static func localDestination(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comma = trimmed.firstIndex(of: ",") else { return trimmed }
        let local = trimmed[trimmed.index(after: comma)...]
            .trimmingCharacters(in: .whitespaces)
        return local.isEmpty ? trimmed : String(local)
    }

    private static func core(_ name: String) -> String {
        var text = name
        if let paren = text.lastIndex(of: "(") { text = String(text[..<paren]) }
        return text
    }

    private static func squash(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US"))
            .filter { $0.isLetter || $0.isNumber }
    }
}
