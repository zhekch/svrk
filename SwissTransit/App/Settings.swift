import Foundation

/// The settings that outlive the app.
///
/// A preference that comes back changed is worse than one that was never
/// offered: the refresh cadence set to Off and found on again next launch does
/// not read as a default, it reads as the app forgetting — and the only way to
/// keep it is to set it again every time. So everything the two settings sheets
/// offer is written when it changes and read back when the model is built.
///
/// **A namespace of its own, deliberately.** The development launch arguments
/// — `-terrain3D 1`, `-trackOpacity 100`, `-startLat` — are read from this same
/// `UserDefaults`, under bare names, because `NSArgumentDomain` is where the
/// system puts them. Two of them are not even in the units of the property they
/// set: `-trackOpacity` and `-terrainRelief` are per cent, while the properties
/// are a fraction and a multiplier. Persisting under those same keys would mean
/// a stored `0.55` read back through the launch-argument path as `0.0055` — a
/// track overlay that faded a hundredfold every time the app was opened. So the
/// remembered settings live under `setting.` and the two mechanisms cannot
/// meet.
///
/// The launch arguments still win where both exist, because they are applied
/// after the model is built rather than being read here at all.
enum Settings {
    /// Not private: the camera is stored as a dictionary rather than a scalar
    /// and so is written from `OpeningCamera`'s own file, which still has to
    /// land in the same namespace as everything else here.
    static let prefix = "setting."
    private static var store: UserDefaults { .standard }

    /// Whether anything has ever been stored for `key`.
    ///
    /// The distinction `bool(forKey:)` cannot draw: a setting deliberately
    /// switched off and one never touched both come back `false`, and taking
    /// the second for the first is how every default in the app would quietly
    /// become "off" on first launch.
    private static func stored(_ key: String) -> Bool {
        store.object(forKey: prefix + key) != nil
    }

    // MARK: - Switches

    static func bool(_ key: String, or fallback: Bool) -> Bool {
        stored(key) ? store.bool(forKey: prefix + key) : fallback
    }

    static func set(_ value: Bool, _ key: String) {
        store.set(value, forKey: prefix + key)
    }

    // MARK: - Dials

    /// A dial, clamped on the way back in.
    ///
    /// A stored number is only as trustworthy as the build that wrote it, and a
    /// slider handed a value outside its own range is a control that cannot be
    /// dragged back into range.
    static func double(
        _ key: String, or fallback: Double, in range: ClosedRange<Double>
    ) -> Double {
        guard stored(key) else { return fallback }
        return min(max(store.double(forKey: prefix + key), range.lowerBound), range.upperBound)
    }

    static func set(_ value: Double, _ key: String) {
        store.set(value, forKey: prefix + key)
    }

    // MARK: - Choices

    /// One choice, by its raw value.
    ///
    /// A spelling the current build does not know falls back rather than
    /// failing: a case renamed or dropped between versions should cost the one
    /// setting, not leave the app unable to read the rest of them.
    static func choice<T: RawRepresentable>(_ key: String, or fallback: T) -> T
    where T.RawValue == String {
        guard let raw = store.string(forKey: prefix + key) else { return fallback }
        return T(rawValue: raw) ?? fallback
    }

    static func set<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        store.set(value.rawValue, forKey: prefix + key)
    }

    /// A set of choices — the modes switched off, and nothing else so far.
    ///
    /// Stored sorted, so the same set always writes the same list and a
    /// defaults dump is readable.
    static func choices<T: RawRepresentable & Hashable>(_ key: String, or fallback: Set<T>) -> Set<T>
    where T.RawValue == String {
        guard let raw = store.array(forKey: prefix + key) as? [String] else { return fallback }
        return Set(raw.compactMap(T.init(rawValue:)))
    }

    static func set<T: RawRepresentable & Hashable>(_ value: Set<T>, _ key: String)
    where T.RawValue == String {
        store.set(value.map(\.rawValue).sorted(), forKey: prefix + key)
    }
}
