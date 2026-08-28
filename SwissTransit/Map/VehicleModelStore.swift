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
//
// **Baked off the main actor.** Building a mesh, encoding it as glTF and
// writing it out is about two milliseconds, and it used to happen inside the
// frame that asked for it — six of them, so twelve to fifteen milliseconds of a
// thirty-three millisecond frame, and precisely when the map could least afford
// it: tilting into a station full of stock nothing has baked yet is both the
// gesture that wants the most new meshes and the gesture whose smoothness the
// whole feature exists for.
//
// None of those three steps touches the map. A mesh is a pure function of a
// key; the encode is arithmetic over an array; the write is a file. Only
// `addStyleModel` has to be on the main thread, because only the map is — so
// the work happens on a background task and lands in `ready`, and the next
// rebuild hands the style a handful of `file://` URIs. What is left on the
// main actor is the part that could not leave it.
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

    /// How many meshes are being baked at any one time.
    ///
    /// A cap on *concurrency* now, not on work per frame, and the difference
    /// is the whole of this file's second act.
    ///
    /// It used to be six-per-tick because baking happened on the main actor:
    /// a mesh, a glTF encode and a file write, six times, inside the frame
    /// that asked for them. Measured, that is about two milliseconds each and
    /// twelve to fifteen a rebuild — half a frame at thirty a second, spent on
    /// the one gesture the whole feature exists to answer, which is tilting the
    /// map over a station full of stock nothing has baked yet. The reader saw
    /// it as the tick dropping "only with stock that was not loaded yet".
    ///
    /// None of that work needs the main actor. A mesh is built from a key and
    /// a table of constants; the encode is arithmetic over an array; the write
    /// is a file. Only `addStyleModel` has to be on the main thread, because
    /// only the map is. So the three that do not are gone from it, and what
    /// stays is a URI handed to the SDK.
    ///
    /// Six at once rather than everything at once because the work is not
    /// urgent and the device has other things to do — a viewport's worth of new
    /// stock is forty-odd meshes and there is no reason to want all of them in
    /// the same millisecond.
    private static let inFlight = 6

    /// A mesh that has been baked and written and is waiting for a frame to
    /// hand it to the style.
    private struct Baked {
        var key: VehicleModelKey
        var name: String
        var file: URL?
    }

    /// Keys whose mesh is being built on a background thread right now.
    ///
    /// Held so a wagon on screen for thirty frames is not baked thirty times.
    /// Once the bake finishes the key moves to `registered` or to `refused`
    /// and stops being wanted.
    private var baking: Set<VehicleModelKey> = []

    /// Meshes that finished baking since the last rebuild.
    ///
    /// The seam between the two threads, and it is a queue rather than a call
    /// back into the map for one reason: `MapboxMap` is not something to hand
    /// to a background task. So the background half produces bytes on disk and
    /// says so here, and the next rebuild — which already has the style in its
    /// hand — does the one part that has to happen on the main actor.
    private var ready: [Baked] = []

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
        // Anything that finished baking while the last frame was drawn. This
        // is all that is left of the work on this thread: a handful of URIs
        // handed over, with the mesh, the encode and the write already done.
        drain(into: style)

        var wanted: [VehicleModelKey: Int] = [:]
        for placement in placements where registered[placement.model] == nil {
            guard !refused.contains(placement.model),
                  !baking.contains(placement.model) else { continue }
            wanted[placement.model, default: 0] += 1
        }
        if registered.count + wanted.count > Self.keep {
            evict(keeping: Set(placements.map(\.model)), from: style)
        }
        let room = Self.inFlight - baking.count
        if room > 0 {
            for key in wanted.sorted(by: { $0.value > $1.value }).prefix(room).map(\.key) {
                bake(key)
            }
        }
        return registered
    }

    /// Hand the style everything that has finished baking.
    private func drain(into style: MapboxMap) {
        guard !ready.isEmpty else { return }
        let finished = ready
        ready.removeAll(keepingCapacity: true)
        for baked in finished {
            baking.remove(baked.key)
            // No file means the mesh had nothing in it. Rare and not an error
            // — a unit so short that every level rakes past its own body — but
            // there is nothing to register and no point asking again.
            guard let file = baked.file else { refused.insert(baked.key); continue }
            do {
                try style.addStyleModel(modelId: baked.name, modelUri: file.absoluteString)
                registered[baked.key] = baked.name
                working = true
            } catch {
                refused.insert(baked.key)
                if working == nil {
                    working = false
                    Diagnostics.note("vehicle models unavailable: \(error)")
                }
            }
        }
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

    /// Build one mesh, off this thread.
    ///
    /// The name and the file path are decided here, on the main actor, so the
    /// counter behind them is never touched from two places; everything after
    /// that is pure work on a value and lands back here as bytes on disk.
    private func bake(_ key: VehicleModelKey) {
        guard let directory else { refused.insert(key); return }
        let name = "transit-wagon-\(nextId)"
        nextId += 1
        let file = directory.appendingPathComponent("\(name).glb")
        baking.insert(key)
        Task.detached(priority: .utility) {
            // The three expensive steps, none of which needs the map: build the
            // shape, encode it, put it on disk. A nil file at the end means one
            // of them had nothing to work with, which `drain` reads as "refuse
            // this key" rather than as an error.
            var written: URL?
            if let data = VehicleGLB.encode(key.mesh(), name: name),
               (try? data.write(to: file, options: .atomic)) != nil {
                written = file
            }
            let result = written
            await MainActor.run { [weak self] in
                self?.ready.append(Baked(key: key, name: name, file: result))
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
        // Anything half-baked belonged to the old style and must not be
        // registered against the new one under a name it never had. The task
        // itself is left to finish and drop its result on the floor — it is a
        // millisecond of arithmetic and cancelling it costs more bookkeeping
        // than letting it land.
        baking.removeAll(keepingCapacity: true)
        ready.removeAll(keepingCapacity: true)
        working = nil
    }
}
