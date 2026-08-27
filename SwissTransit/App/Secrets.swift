import Foundation

/// Tokens, read from a generated plist rather than compiled in as literals.
///
/// `scripts/make-ios-secrets.mjs` writes `Secrets.plist` from the repository's
/// `.env` files, and the plist is gitignored. That keeps the same tokens the
/// Node server uses in one place and keeps them out of the source tree — the
/// `.env` note about never `source`-ing that file applies here too, which is
/// why the script reads it rather than any shell.
enum Secrets {
    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String]
        else { return [:] }
        return plist
    }()

    /// The public Mapbox token. Public by design — it is the one that ships in
    /// the app and is scoped to reads.
    static var mapboxAccessToken: String? { nonEmpty("mapbox_public") }

    /// The national estimated timetable. Without it the app runs entirely on
    /// whatever snapshot it has stored, which is a real mode rather than a
    /// broken one.
    static var realtimeToken: String? { nonEmpty("tedp_gtfs_rt_plan") }

    /// The train formation service. A separate subscription with its own token
    /// and its own limits, which is why it is not the SIRI one.
    static var formationToken: String? { nonEmpty("formation_service_plan") }

    /// Situation exchange — disruption notices. One token covers both the
    /// planned works catalogue and the unplanned incident wire, which are
    /// separate paths on one subscription and one daily budget.
    static var sxToken: String? { nonEmpty("siri_sx_plan") }

    /// Open Journey Planner 2.0. Asked per journey rather than downloaded, and
    /// the only interface on the platform that publishes how full a train is.
    static var ojpToken: String? { nonEmpty("ojp_2.0_plan") }

    private static func nonEmpty(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }
}
