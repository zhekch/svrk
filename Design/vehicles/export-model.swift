// Renders the *baked* vehicles — the ones the map actually draws — by reading
// back the `.glb` files `VehicleGLB` writes, and drawing what is in them.
//
// `export-solid.swift` beside this file draws the slabs. This draws the model,
// and the difference is the whole point of it: between the slab and the screen
// there is now a mesh, a binary container, a change of axes and a placement,
// and every one of those is somewhere a wagon can come out mirrored, rotated,
// inside out or a hundred metres long. Reading the file back and drawing what
// is *in* it is the only check that covers all four at once — if this picture
// matches the one `export-solid` makes, then the bake, the encoding, the origin
// and the placement all agree, and the only thing left unverified is what
// Mapbox itself does with a glTF.
//
// It is not part of the app. To run it, make a throwaway macOS package that
// path-depends on `Packages/TransitCore`, drop this in as `main.swift`, and
// pass it the output directory:
//
//     swift run export-model Design/vehicles/model

import Foundation
import TransitCore

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true
)
let store = VehicleLayoutStore()
let pointsPerMetre = 5.0
let metresPerPoint = 0.25
let yaw = 20.0 * .pi / 180
let elevation = 24.0 * .pi / 180
let light = (x: -0.42, y: 0.30, z: 0.85)
let origin = Coord(lon: 7.4400, lat: 46.9480)

func sample(
    _ mode: Mode, category: String?, line: String, operatorName: String?
) -> (VehicleSnapshot, VehicleLayout) {
    let vehicle = VehicleSnapshot(
        id: "\(line)-\(operatorName ?? "")", mode: mode, category: category, line: line,
        operatorName: operatorName, from: "Bern", lon: origin.lon, lat: origin.lat,
        bearing: 270, moving: true, index: 0, progress: 0, stops: [], onTrack: false
    )
    return (vehicle, store.layout(for: vehicle, modeColour: mode.mapColour))
}

extension Mode {
    var mapColour: String {
        switch self {
        case .train: return "#ff3b30"
        case .tram: return "#0a84ff"
        case .bus: return "#ffd60a"
        case .metro: return "#bf5af2"
        case .cable: return "#30d158"
        case .boat: return "#5ac8fa"
        case .other: return "#8e8e93"
        }
    }
}

struct Drawing {
    var name: String
    var caption: String
    var vehicle: VehicleSnapshot
    var layout: VehicleLayout
}

func drawing(
    _ name: String, _ mode: Mode, category: String?, line: String, operatorName: String?
) -> Drawing {
    let (vehicle, layout) = sample(
        mode, category: category, line: line, operatorName: operatorName
    )
    return Drawing(
        name: name, caption: layout.name ?? line, vehicle: vehicle, layout: layout
    )
}

let drawings: [Drawing] = [
    drawing("ic1-fv-dosto", .train, category: "IC", line: "IC1", operatorName: "SBB"),
    drawing("ic2-giruno", .train, category: "IC", line: "IC2", operatorName: "SBB"),
    drawing("ic3-re460-ic2000", .train, category: "IC", line: "IC3", operatorName: "SBB"),
    drawing("ic5-icn", .train, category: "IC", line: "IC5", operatorName: "SBB"),
    drawing("ir16-kiss", .train, category: "IR", line: "IR16", operatorName: "SBB"),
    drawing("s12-dtz", .train, category: "S", line: "S12", operatorName: "SBB"),
    drawing("r-thurbo-gtw", .train, category: "R", line: "S8", operatorName: "THURBO"),
    drawing("r-rhb-capricorn", .train, category: "R", line: "R", operatorName: "RhB"),
    drawing("tram-zurich-cobra", .tram, category: "T", line: "11", operatorName: "VBZ"),
    drawing("tram-basel-flexity", .tram, category: "T", line: "8", operatorName: "BVB"),
    drawing("trolleybus-zurich", .bus, category: "B", line: "31", operatorName: "VBZ"),
    drawing("postauto", .bus, category: "B", line: "101", operatorName: "PAG"),
    drawing("metro-lausanne", .metro, category: "M", line: "M2", operatorName: "TL"),
    drawing("boat-cgn", .boat, category: "BAT", line: "1", operatorName: "CGN"),
    drawing("funicular", .cable, category: "FUN", line: "1", operatorName: nil),
]

// MARK: - Reading a `.glb` back

/// One triangle out of a file, in the model's own axes.
struct BakedTriangle {
    var corners: [(x: Double, y: Double, z: Double)]
    var normal: (x: Double, y: Double, z: Double)
    var fill: String
}

/// Everything in a `.glb`, as triangles.
///
/// A deliberately literal reader: it follows exactly the path a renderer would
/// — chunks, then the JSON, then the accessors, then the buffer views, then the
/// floats — so a file that this can read is a file whose structure is sound.
func readGLB(_ data: Data) -> [BakedTriangle] {
    func u32(_ at: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { out in
                out.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[at..<(at + 4)]))
            }
            return UInt32(littleEndian: value)
        }
    }
    guard data.count > 20, u32(0) == 0x4674_6C67, u32(1 * 4) == 2 else {
        print("  not a glb"); return []
    }
    let jsonLength = Int(u32(12))
    guard u32(16) == 0x4E4F_534A else { print("  no json chunk"); return [] }
    let jsonStart = 20
    let json = data.subdata(in: jsonStart..<(jsonStart + jsonLength))
    let binaryHeader = jsonStart + jsonLength
    guard data.count >= binaryHeader + 8, u32(binaryHeader + 4) == 0x004E_4942 else {
        print("  no bin chunk"); return []
    }
    let binaryStart = binaryHeader + 8
    let binaryLength = Int(u32(binaryHeader))
    guard data.count >= binaryStart + binaryLength else { print("  short bin"); return [] }

    guard
        let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
        let meshes = root["meshes"] as? [[String: Any]], let mesh = meshes.first,
        let primitives = mesh["primitives"] as? [[String: Any]],
        let accessors = root["accessors"] as? [[String: Any]],
        let views = root["bufferViews"] as? [[String: Any]],
        let materials = root["materials"] as? [[String: Any]]
    else { print("  unreadable json"); return [] }

    /// One accessor's worth of `VEC3` floats.
    func vectors(_ index: Int) -> [(x: Double, y: Double, z: Double)] {
        guard index < accessors.count,
              let accessor = accessors[index] as [String: Any]?,
              let viewIndex = accessor["bufferView"] as? Int, viewIndex < views.count,
              let count = accessor["count"] as? Int,
              let offset = views[viewIndex]["byteOffset"] as? Int
        else { return [] }
        var out: [(x: Double, y: Double, z: Double)] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let at = binaryStart + offset + i * 12
            func float(_ k: Int) -> Double {
                Double(Float(bitPattern: u32(at + k * 4)))
            }
            out.append((float(0), float(1), float(2)))
        }
        return out
    }

    /// A material's colour, back out of linear light into the sRGB it was
    /// written from.
    func colour(_ index: Int) -> String {
        guard index < materials.count,
              let pbr = materials[index]["pbrMetallicRoughness"] as? [String: Any],
              let factor = pbr["baseColorFactor"] as? [Double], factor.count >= 3
        else { return "#888888" }
        func srgb(_ value: Double) -> Int {
            let out = value <= 0.0031308
                ? value * 12.92
                : 1.055 * pow(value, 1 / 2.4) - 0.055
            return Int(min(255, max(0, (out * 255).rounded())))
        }
        return String(format: "#%02x%02x%02x", srgb(factor[0]), srgb(factor[1]), srgb(factor[2]))
    }

    var out: [BakedTriangle] = []
    for primitive in primitives {
        guard let attributes = primitive["attributes"] as? [String: Int],
              let positionIndex = attributes["POSITION"],
              let normalIndex = attributes["NORMAL"],
              let materialIndex = primitive["material"] as? Int
        else { continue }
        let positions = vectors(positionIndex)
        let normals = vectors(normalIndex)
        let fill = colour(materialIndex)
        guard positions.count == normals.count, positions.count % 3 == 0 else { continue }
        for i in stride(from: 0, to: positions.count, by: 3) {
            out.append(BakedTriangle(
                corners: [positions[i], positions[i + 1], positions[i + 2]],
                normal: normals[i], fill: fill
            ))
        }
    }
    return out
}

// MARK: - Putting a model back on the map

/// The transform a renderer applies to a placed model, done here by hand.
///
/// Scale in the model's own axes, then turn to the heading, then move to where
/// the wagon stands. Written out rather than assumed, because it is the step
/// where an axis convention that is one negation out stops being an opinion and
/// becomes a train facing backwards.
func world(
    _ point: (x: Double, y: Double, z: Double), _ placement: UnitPlacement,
    translating: Bool
) -> (east: Double, north: Double, up: Double) {
    // glTF axes back into the vehicle's own: forward is -Z, up is +Y, and the
    // sideways axis is +X. See `VehicleGLB.point`.
    let along = -point.z
    let across = point.x * (translating ? placement.widthScale : 1)
    let up = point.y * (translating ? placement.heightScale : 1)

    let radians = placement.heading * .pi / 180
    let s = sin(radians), c = cos(radians)
    var east = along * s + across * c
    var north = along * c - across * s
    if translating {
        let flat = (
            (placement.at.lon - origin.lon) * 111_320 * cos(origin.lat * .pi / 180),
            (placement.at.lat - origin.lat) * 111_320
        )
        east += flat.0
        north += flat.1
    }
    return (east, north, up)
}

struct Vertex { var sx: Double; var sy: Double; var depth: Double }

func project(_ world: (east: Double, north: Double, up: Double)) -> Vertex {
    let u = world.east * cos(yaw) - world.north * sin(yaw)
    let v = world.east * sin(yaw) + world.north * cos(yaw)
    return Vertex(
        sx: u,
        sy: v * sin(elevation) - world.up * cos(elevation),
        depth: v * cos(elevation) + world.up * sin(elevation)
    )
}

struct Face { var points: [Vertex]; var fill: String; var shade: Double; var depth: Double }

func shaded(_ colour: String, _ amount: Double) -> String {
    var r = 128.0, g = 128.0, b = 128.0
    if colour.hasPrefix("#") {
        var digits = Array(colour.dropFirst())
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        if digits.count == 6, let value = Int(String(digits), radix: 16) {
            r = Double((value >> 16) & 255); g = Double((value >> 8) & 255); b = Double(value & 255)
        }
    }
    func clamp(_ v: Double) -> Int { Int(min(255, max(0, v.rounded()))) }
    return String(format: "#%02x%02x%02x", clamp(r * amount), clamp(g * amount), clamp(b * amount))
}

func lit(_ n: (east: Double, north: Double, up: Double)) -> Double {
    let length = (n.east * n.east + n.north * n.north + n.up * n.up).squareRoot()
    guard length > 1e-9 else { return 1 }
    let dot = (n.east * light.x + n.north * light.y + n.up * light.z) / length
    return 0.55 + 0.45 * max(0, dot)
}

// MARK: - Drawing

var index: [String] = []
var totalBytes = 0
for item in drawings {
    guard let shape = VehicleShape.footprint(
        of: item.vehicle, layout: item.layout,
        metresPerPoint: metresPerPoint, solid: true, extruded: false
    ), !shape.placements.isEmpty else {
        print("no placements for \(item.name)")
        continue
    }

    // One file per distinct mesh, exactly as the app caches them.
    var files: [VehicleModelKey: [BakedTriangle]] = [:]
    var bytes = 0
    for placement in shape.placements where files[placement.model] == nil {
        guard let data = VehicleGLB.encode(placement.model.mesh(), name: item.name) else {
            continue
        }
        bytes += data.count
        files[placement.model] = readGLB(data)
    }
    totalBytes += bytes

    var faces: [Face] = []
    for placement in shape.placements {
        guard let triangles = files[placement.model] else { continue }
        for triangle in triangles {
            let corners = triangle.corners.map {
                project(world($0, placement, translating: true))
            }
            faces.append(Face(
                points: corners,
                fill: triangle.fill,
                shade: lit(world(triangle.normal, placement, translating: false)),
                // The *farthest* corner, not the average.
                //
                // A cap here is a fan of long slivers reaching from the middle
                // of an outline to its rim, and a sliver's average depth is
                // near its middle — so sorted on the average, the far half of a
                // roof is drawn as if it were at the centre of the roof, over
                // whatever is actually in front of it. A train came out with
                // red streaks along its whole length. There is no depth buffer
                // in an SVG; the farthest corner is the conservative answer,
                // and it is only this file that needs one.
                depth: corners.map(\.depth).min() ?? 0
            ))
        }
    }

    faces.sort { $0.depth < $1.depth }

    let xs = faces.flatMap { $0.points.map(\.sx) }
    let ys = faces.flatMap { $0.points.map(\.sy) }
    guard let minX = xs.min(), let maxX = xs.max(),
          let minY = ys.min(), let maxY = ys.max() else { continue }
    let margin = 2.0
    let width = (maxX - minX + margin * 2) * pointsPerMetre
    let height = (maxY - minY + margin * 2) * pointsPerMetre

    var svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width.rounded()))" \
    height="\(Int(height.rounded()))" viewBox="0 0 \(Int(width.rounded())) \
    \(Int(height.rounded()))">\n
    """
    for face in faces {
        let points = face.points.map {
            let x = ($0.sx - minX + margin) * pointsPerMetre
            let y = ($0.sy - minY + margin) * pointsPerMetre
            return String(format: "%.2f,%.2f", x, y)
        }.joined(separator: " ")
        let colour = shaded(face.fill, face.shade)
        // A hairline of the face's own colour closes the seams between
        // triangles that a rasteriser leaves along shared edges.
        svg += "<polygon points=\"\(points)\" fill=\"\(colour)\" "
        svg += "stroke=\"\(colour)\" stroke-width=\"0.35\"/>\n"
    }
    svg += "</svg>\n"

    let file = outputDirectory.appendingPathComponent("\(item.name).svg")
    try? svg.write(to: file, atomically: true, encoding: .utf8)
    index.append("""
        <figure><img src="\(item.name).svg" alt="\(item.name)">
        <figcaption>\(item.name)<br><span>\(item.caption) · \
    \(files.count) model\(files.count == 1 ? "" : "s") · \
    \(faces.count) triangles · \(bytes / 1024) kB</span></figcaption></figure>
    """)
    print("\(item.name): \(files.count) models, \(faces.count) triangles, \(bytes) bytes")
}

let page = """
<!doctype html><meta charset="utf-8"><title>Baked vehicles</title>
<style>
 body { background:#f4f4f2; font:14px/1.5 -apple-system,system-ui,sans-serif; margin:32px; }
 figure { margin:0 0 40px; }
 img { display:block; max-width:100%; }
 figcaption { margin-top:8px; color:#333; }
 span { color:#777; }
</style>
<h1>Baked vehicles</h1>
<p>Read back out of the <code>.glb</code> files
   <code>VehicleGLB.swift</code> writes, and placed by the
   <code>UnitPlacement</code>s the map sends. Compare with
   <code>../solid/</code>, which draws the same wagons as slabs.</p>
\(index.joined(separator: "\n"))
"""
try? page.write(
    to: outputDirectory.appendingPathComponent("index.html"),
    atomically: true, encoding: .utf8
)
print("wrote \(index.count) models to \(outputDirectory.path), \(totalBytes / 1024) kB total")
