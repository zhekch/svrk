import Foundation
@_spi(Experimental) import MapboxMaps
import TransitCore

// The shapes, given to the renderer once and referred to afterwards by name.
//
// This is the half of the model rendering that does not happen every frame, and
// keeping it out of the frame is the whole reason the models exist. A wagon's
// mesh is a few thousand triangles; the map draws several hundred wagons and
// wants to move them thirty times a second. Sending the triangles each time was
// what the extrusions did, and it cost both the bandwidth and — far worse — the
// coherence, because a renderer handed loose polygons treats them as loose.
//
// Sent once, a mesh becomes an id. What crosses per frame afterwards is a
// point, a heading and a tilt, and the wagon cannot come apart because none of
// its parts is being sent for anything to come apart *from*.
//
// **A file, because that is what the SDK takes.** `addStyleModel` wants a URI,
// not bytes, so each mesh is written into the caches directory and handed over
// as a `file://` URL. They are small — 20 to 45 kB — and there are rarely more
// than a few dozen distinct ones on screen at once, because a key is what a
// wagon *is* rather than which wagon it is: a sixteen-coach IC is five models
// and eleven repeats.
//
// **Cleared on the way in.** The meshes are generated from code that changes,
// and a stale `.glb` left over from the last build would be silently believed.
// Rewriting them costs a few milliseconds per model and buys never having to
// wonder.
@MainActor
final class VehicleModelStore {
    /// What each mesh is called in the style, once it has been registered.
    private var registered: [VehicleModelKey: String] = [:]
    /// Keys that could not be baked or registered, so a broken one is not
    /// retried thirty times a second for as long as it is on screen.
    private var refused: Set<VehicleModelKey> = []
    private var nextId = 0
    private let directory: URL?

    /// Whether anything has been registered successfully.
    ///
    /// What the map asks before deciding whether it still needs the extruded
    /// fallback. Models are an experimental corner of the SDK and this is a
    /// device somebody's train is on: if the very first registration is
    /// refused, the map goes back to drawing prisms rather than drawing
    /// nothing.
    private(set) var working: Bool?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        directory = caches?.appendingPathComponent("vehicle-models", isDirectory: true)
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    /// How many new meshes are baked and registered in one go.
    ///
    /// A cap rather than a queue, because the work is not urgent and the frame
    /// it would land in is. Tilting the map over a busy station asks for every
    /// distinct wagon in view at once — forty-odd meshes, each a file written
    /// and a style call — and doing that inside one frame is a visible stall on
    /// the one gesture the whole feature exists to answer. Spread over a few
    /// frames it is a tenth of a second nobody can point at, during which the
    /// wagons still waiting are simply drawn flat a moment longer.
    private static let perTick = 6

    /// How many meshes are kept registered at once.
    ///
    /// A session spent panning across the country meets a great many distinct
    /// wagons — the library is dozens of families and each operator paints them
    /// differently — and nothing ever asked for one back. At forty-odd
    /// kilobytes each that is a slow leak of both disk and whatever the
    /// renderer holds them in, so there is a ceiling, and it is high enough
    /// that a busy station is nowhere near it: a viewport has tens of distinct
    /// wagons in it, not hundreds.
    private static let keep = 384

    /// Register whatever is needed for these placements, and say what to call
    /// each one.
    ///
    /// Called once per rebuild with the whole viewport's worth, rather than
    /// per wagon, so the budget above is spent on the most common meshes first
    /// — a coach that appears eleven times is worth more than a shunter that
    /// appears once.
    func names(
        for placements: [UnitPlacement], in style: MapboxMap
    ) -> [VehicleModelKey: String] {
        var wanted: [VehicleModelKey: Int] = [:]
        for placement in placements where registered[placement.model] == nil {
            guard !refused.contains(placement.model) else { continue }
            wanted[placement.model, default: 0] += 1
        }
        if registered.count + wanted.count > Self.keep {
            evict(keeping: Set(placements.map(\.model)), from: style)
        }
        for key in wanted.sorted(by: { $0.value > $1.value }).prefix(Self.perTick).map(\.key) {
            add(key, to: style)
        }
        return registered
    }

    /// Drop everything not on screen right now.
    ///
    /// A sweep rather than a running least-recently-used order, because the
    /// bookkeeping for the latter would run per wagon per frame to answer a
    /// question that is asked about once a session. What is on screen is
    /// already in hand; everything else can be baked again in a millisecond if
    /// it comes back.
    private func evict(keeping wanted: Set<VehicleModelKey>, from style: MapboxMap) {
        for (key, name) in registered where !wanted.contains(key) {
            try? style.removeStyleModel(modelId: name)
            registered[key] = nil
        }
        refused.removeAll(keepingCapacity: true)
    }

    private func add(_ key: VehicleModelKey, to style: MapboxMap) {
        guard let directory else { refused.insert(key); return }
        let name = "transit-wagon-\(nextId)"
        let file = directory.appendingPathComponent("\(name).glb")
        guard let data = VehicleGLB.encode(key.mesh(), name: name) else {
            // A mesh with nothing in it. Rare and not an error — a unit so
            // short that every level rakes past its own body — but there is
            // nothing to register and no point asking again.
            refused.insert(key)
            return
        }
        do {
            try data.write(to: file, options: .atomic)
            try style.addStyleModel(modelId: name, modelUri: file.absoluteString)
            registered[key] = name
            nextId += 1
            working = true
        } catch {
            refused.insert(key)
            if working == nil {
                working = false
                Diagnostics.note("vehicle models unavailable: \(error)")
            }
        }
    }

    /// Forget everything, for a style that has been thrown away and rebuilt.
    ///
    /// The models belong to the style rather than to this object: a new style
    /// has never heard of them, and an id left in this table would name a mesh
    /// the renderer cannot find — which draws nothing, silently, for as long as
    /// the app is open.
    func styleChanged() {
        registered.removeAll(keepingCapacity: true)
        refused.removeAll(keepingCapacity: true)
        working = nil
    }
}
