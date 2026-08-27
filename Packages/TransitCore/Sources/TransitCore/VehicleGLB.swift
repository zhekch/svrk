import Foundation

// A wagon, as a file a renderer can be handed once and asked for by name.
//
// Everything else in this module hands geometry over: here are the polygons,
// draw them, and here they are again next frame. That is unavoidable for a flat
// drawing and it was a mistake for a solid, because "here are the polygons" is
// an invitation to treat them as unrelated — which is exactly what a renderer
// standing them up over a terrain does, and exactly why a train coming down a
// valley used to come apart along its length.
//
// A model is the other kind of answer. The shape goes across once, as a mesh,
// and is thereafter referred to by an id; what crosses per frame is a point, a
// heading and a tilt. Nothing inside the wagon can move relative to the rest of
// it, not because anything is holding it together but because there is nothing
// to hold — the wagon is one object, and the only things anybody is allowed to
// say about it are the things you can say about a rigid body.
//
// **Why generate it rather than ship it.** A hand-modelled `.glb` per family is
// the ordinary way to do this and it would cost the thing this whole module is
// built to protect: the solid's silhouette from above is *exactly* the flat
// drawing, because both come from the same `outline`. An artist's mesh cannot
// promise that, and the moment it stops being true the change from flat to
// solid stops reading as one object being tilted. Generating the mesh from the
// same plan outlines keeps the promise by construction — and gets every livery
// of every operator for free, which no asset pipeline was ever going to.
//
// **Flat-shaded, on purpose.** Every triangle carries its own three vertices
// and its own face normal. Sharing vertices between faces would save about a
// third of a small file and would smooth the very edges the look depends on:
// this is a low-poly drawing, and the crease where a shoulder turns into a roof
// is a line somebody reads the vehicle by. A wagon comes out around 45 kB,
// which is nothing against being asked for it once instead of thirty times a
// second.
//
// The vertices are nonetheless *indexed*, with the identity list every unshared
// mesh has — 0, 1, 2, 3, … — because the renderer's loader dereferences the
// index accessor without checking for one and takes the process down with it if
// it is missing. See `assemble`.

/// One wagon as a binary glTF.
public enum VehicleGLB {

    /// The bytes of a `.glb` for this mesh, or nil if there is nothing in it.
    ///
    /// Deterministic: the same mesh gives the same bytes, so a file already
    /// written for a key can be trusted without comparing it to anything.
    public static func encode(_ mesh: UnitMesh, name: String) -> Data? {
        var groups: [Paint: [Triangle]] = [:]
        for slab in mesh.slabs {
            let paint = Paint(colour: slab.fill, lit: slab.role == .lamp)
            for triangle in triangles(of: slab, centredOn: mesh.length / 2) {
                groups[paint, default: []].append(triangle)
            }
        }
        guard !groups.isEmpty else { return nil }
        return assemble(groups, name: name)
    }

    /// A colour, and whether the surface wearing it makes its own light.
    ///
    /// Grouped on both rather than on the colour alone, because a lamp is not a
    /// painted patch the same colour: it is lit from inside, and a material
    /// that says so is the difference between a headlight and a cream-coloured
    /// rectangle on the front of a train. It is also the whole of why the lamps
    /// can be part of the mesh at all — a self-lit material survives being
    /// shaded by a basemap's midnight, which is exactly what the separate lamp
    /// layer had to be kept outside the scene to achieve.
    struct Paint: Hashable {
        var colour: String
        var lit: Bool
    }

    // MARK: - From slabs to triangles

    /// Three corners and the way the face they make is looking.
    struct Triangle {
        var a: (x: Double, y: Double, z: Double)
        var b: (x: Double, y: Double, z: Double)
        var c: (x: Double, y: Double, z: Double)
        var normal: (x: Double, y: Double, z: Double)
    }

    /// glTF's axes are not this module's.
    ///
    /// A vehicle is built in its own metres — `x` forward from its back end,
    /// `y` to the right of the way it faces, height up — and glTF is a Y-up
    /// right-handed frame whose conventional forward is `-Z`. So forward
    /// becomes `-Z`, up becomes `+Y`, and the sideways axis becomes `+X`, which
    /// leaves the frame right-handed and the wagon facing the way an imported
    /// model is expected to face.
    ///
    /// `alongCentre` moves the origin from the wagon's tail to its middle,
    /// because a model turns about its origin and a wagon turns about its
    /// middle. Anchored at the tail, a coach swinging through a station throat
    /// would scythe its nose across the platform.
    @inline(__always)
    static func point(
        along: Double, across: Double, up: Double, alongCentre: Double
    ) -> (x: Double, y: Double, z: Double) {
        (x: across, y: up, z: -(along - alongCentre))
    }

    /// One slab's walls and its two caps.
    static func triangles(of slab: LocalSlab, centredOn alongCentre: Double) -> [Triangle] {
        var out: [Triangle] = []
        for ring in slab.rings where ring.count >= 3 {
            // The middle of the outline, which is what says which way is out.
            //
            // Normals are worked out against it rather than off the winding of
            // the ring, and that is deliberate: `outline` is free to wind
            // either way and does, the boxes below are written by hand, and a
            // single ring that came out the other way round would be a wagon
            // with one surface lit from inside. Measuring outward from the
            // centre cannot be got backwards.
            var cx = 0.0, cy = 0.0
            for p in ring { cx += p.x; cy += p.y }
            cx /= Double(ring.count); cy /= Double(ring.count)

            let base = slab.base, top = slab.top
            for i in ring.indices {
                let p = ring[i], q = ring[(i + 1) % ring.count]
                let dx = q.x - p.x, dy = q.y - p.y
                let span = (dx * dx + dy * dy).squareRoot()
                guard span > 1e-6 else { continue }
                // Perpendicular to the edge, turned to face away from the
                // middle of the outline.
                var nx = dy / span, ny = -dx / span
                let mx = (p.x + q.x) / 2 - cx, my = (p.y + q.y) / 2 - cy
                if nx * mx + ny * my < 0 { nx = -nx; ny = -ny }
                let normal = point(along: nx, across: ny, up: 0, alongCentre: 0)

                let pb = point(along: p.x, across: p.y, up: base, alongCentre: alongCentre)
                let qb = point(along: q.x, across: q.y, up: base, alongCentre: alongCentre)
                let qt = point(along: q.x, across: q.y, up: top, alongCentre: alongCentre)
                let pt = point(along: p.x, across: p.y, up: top, alongCentre: alongCentre)
                out.append(Triangle(a: pb, b: qb, c: qt, normal: normal))
                out.append(Triangle(a: pb, b: qt, c: pt, normal: normal))
            }

            // The caps, as a fan from the middle. Every outline here is convex
            // or very nearly — a body tapering to a nose, a box with its
            // corners knocked off — so a fan from the centre covers it without
            // needing a general triangulator.
            for (height, up) in [(top, 1.0), (base, -1.0)] {
                let normal = (x: 0.0, y: up, z: 0.0)
                let middle = point(
                    along: cx, across: cy, up: height, alongCentre: alongCentre
                )
                for i in ring.indices {
                    let p = ring[i], q = ring[(i + 1) % ring.count]
                    out.append(Triangle(
                        a: middle,
                        b: point(along: p.x, across: p.y, up: height, alongCentre: alongCentre),
                        c: point(along: q.x, across: q.y, up: height, alongCentre: alongCentre),
                        normal: normal
                    ))
                }
            }
        }
        return out
    }

    // MARK: - From triangles to a file

    private static func assemble(_ groups: [Paint: [Triangle]], name: String) -> Data? {
        var binary = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var materials: [[String: Any]] = []
        var primitives: [[String: Any]] = []

        // Sorted, so the same mesh always writes the same bytes.
        for paint in groups.keys.sorted(by: {
            ($0.colour, $0.lit ? 1 : 0) < ($1.colour, $1.lit ? 1 : 0)
        }) {
            let triangles = groups[paint] ?? []
            guard !triangles.isEmpty else { continue }

            var positions = Data()
            var normals = Data()
            var low = (x: Double.infinity, y: Double.infinity, z: Double.infinity)
            var high = (x: -Double.infinity, y: -Double.infinity, z: -Double.infinity)
            for triangle in triangles {
                for corner in [triangle.a, triangle.b, triangle.c] {
                    append(&positions, corner)
                    append(&normals, triangle.normal)
                    low = (min(low.x, corner.x), min(low.y, corner.y), min(low.z, corner.z))
                    high = (max(high.x, corner.x), max(high.y, corner.y), max(high.z, corner.z))
                }
            }
            let count = triangles.count * 3

            let positionView = view(&binary, positions, target: 34962, into: &bufferViews)
            accessors.append([
                "bufferView": positionView, "componentType": 5126, "count": count,
                "type": "VEC3",
                // Required on a position accessor, and not decoration: a viewer
                // uses it to cull and to frame the model without reading the
                // buffer.
                "min": [low.x, low.y, low.z], "max": [high.x, high.y, high.z],
            ])
            let positionIndex = accessors.count - 1

            let normalView = view(&binary, normals, target: 34962, into: &bufferViews)
            accessors.append([
                "bufferView": normalView, "componentType": 5126, "count": count,
                "type": "VEC3",
            ])
            let normalIndex = accessors.count - 1

            // The indices, which are 0, 1, 2, 3, … and are not optional.
            //
            // glTF says a primitive without `indices` draws its vertices in
            // the order they are stored, and every triangle here already
            // carries its own three, so this buffer says nothing the file did
            // not already say. It has to be written anyway: the renderer's
            // model loader reads the index accessor without first checking
            // that there is one, and a primitive that leaves it out crashes
            // the process — a null dereference on the loader's own thread,
            // inside a closed-source frame, the moment the camera tilts far
            // enough to ask for a wagon. See `VehicleGLBTests`, which is where
            // that stays fixed.
            //
            // Sixteen bits wide wherever they fit, which is every wagon there
            // has ever been: a mesh here is a few thousand vertices and the
            // ceiling is 65,536. Thirty-two bit indices are also accepted and
            // the renderer says what it thinks of them — "unsigned integer
            // index buffers not supported, re-encoding" — once per primitive
            // per load, which is a few hundred conversions for a station's
            // worth of trains, all of them avoidable by writing the narrower
            // type in the first place.
            var indices = Data()
            let wide = count > 65_535
            for i in 0..<count {
                if wide {
                    withUnsafeBytes(of: UInt32(i).littleEndian) { indices.append(contentsOf: $0) }
                } else {
                    withUnsafeBytes(of: UInt16(i).littleEndian) { indices.append(contentsOf: $0) }
                }
            }
            let indexView = view(&binary, indices, target: 34963, into: &bufferViews)
            accessors.append([
                "bufferView": indexView, "componentType": wide ? 5125 : 5123,
                "count": count, "type": "SCALAR",
            ])
            let indexIndex = accessors.count - 1

            materials.append(material(paint))
            primitives.append([
                "attributes": ["POSITION": positionIndex, "NORMAL": normalIndex],
                "indices": indexIndex,
                "material": materials.count - 1,
                "mode": 4,
            ])
        }
        guard !primitives.isEmpty else { return nil }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "SwissTransit VehicleGLB"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": name]],
            "meshes": [["primitives": primitives, "name": name]],
            "materials": materials,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": binary.count]],
        ]
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: json, options: [.sortedKeys]
        ) else { return nil }
        return container(json: encoded, binary: binary)
    }

    /// One material, in the colour a slab is painted.
    ///
    /// **Linear, not sRGB.** glTF's `baseColorFactor` is a linear-light value
    /// and every colour in this app is written the way CSS writes them, which
    /// is sRGB. Handed straight across, a mid-tone red goes in at 0.8 where it
    /// should be 0.6 and the whole fleet comes out washed out and chalky —
    /// worst on the dark greys under a coach, which are where most of the
    /// difference between an sRGB and a linear ramp lives.
    ///
    /// **Double-sided.** A closed box does not need it and it is worth having
    /// anyway: it makes a ring that happened to be wound the other way a
    /// non-event rather than a wagon with a hole in its side, and at this
    /// triangle count the culling it gives up is not measurable.
    private static func material(_ paint: Paint) -> [String: Any] {
        let rgb = VehicleShape.rgb(paint.colour) ?? (r: 128, g: 128, b: 128)
        func linear(_ channel: Int) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        var material: [String: Any] = [
            "pbrMetallicRoughness": [
                "baseColorFactor": [linear(rgb.r), linear(rgb.g), linear(rgb.b), 1.0],
                // Painted steel and glass, neither of which is a mirror at this
                // size. Fully rough came out flat and dead under a low sun;
                // this keeps a little of the sheen that says the side is curved.
                "metallicFactor": 0.0,
                "roughnessFactor": 0.62,
            ],
            "doubleSided": true,
            "name": paint.colour + (paint.lit ? "-lit" : ""),
        ]
        if paint.lit {
            // Emission at nearly full strength, because a lamp's whole job is
            // to be brighter than what is around it. Not *quite* full: a lamp
            // is a lens with a filament behind it, and a face at 1.0 in a scene
            // lit to 1.0 has no shading left at all, which reads as a hole in
            // the front of the train rather than a light on it.
            material["emissiveFactor"] = [
                linear(rgb.r) * 0.9, linear(rgb.g) * 0.9, linear(rgb.b) * 0.9,
            ]
        }
        return material
    }

    /// Copy `bytes` into the buffer at a four-byte boundary and record the view.
    private static func view(
        _ buffer: inout Data, _ bytes: Data, target: Int,
        into views: inout [[String: Any]]
    ) -> Int {
        pad(&buffer, to: 4, with: 0)
        views.append([
            "buffer": 0, "byteOffset": buffer.count,
            "byteLength": bytes.count, "target": target,
        ])
        buffer.append(bytes)
        return views.count - 1
    }

    /// The `.glb` wrapper: a header and two chunks, each padded to four bytes —
    /// the JSON with spaces and the buffer with zeroes, which is what the
    /// specification asks for by name.
    private static func container(json: Data, binary: Data) -> Data {
        var jsonChunk = json
        pad(&jsonChunk, to: 4, with: 0x20)
        var binaryChunk = binary
        pad(&binaryChunk, to: 4, with: 0)

        var out = Data()
        // `glTF`, little-endian, and the capital T is load-bearing: written
        // `0x4674_6C67` this spells `gltF`, which is not the magic, so every
        // wagon written was a file the renderer rejected. It rejects it
        // *asynchronously* — `addStyleModel` only takes a URI and returns
        // without complaint — so the store concluded models were working,
        // `bakedModels` went true, and the extruded fallback was switched off
        // on the strength of it. The fleet went invisible and its lamps, which
        // are symbols and no part of the mesh, stayed lit.
        append(&out, UInt32(0x4654_6C67))          // "glTF"
        append(&out, UInt32(2))
        append(&out, UInt32(12 + 8 + jsonChunk.count + 8 + binaryChunk.count))
        append(&out, UInt32(jsonChunk.count))
        append(&out, UInt32(0x4E4F_534A))          // "JSON"
        out.append(jsonChunk)
        append(&out, UInt32(binaryChunk.count))
        append(&out, UInt32(0x004E_4942))          // "BIN\0"
        out.append(binaryChunk)
        return out
    }

    private static func pad(_ data: inout Data, to alignment: Int, with byte: UInt8) {
        let over = data.count % alignment
        guard over != 0 else { return }
        data.append(contentsOf: [UInt8](repeating: byte, count: alignment - over))
    }

    private static func append(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func append(
        _ data: inout Data, _ point: (x: Double, y: Double, z: Double)
    ) {
        for component in [Float(point.x), Float(point.y), Float(point.z)] {
            withUnsafeBytes(of: component.bitPattern.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
    }
}
