// Exports every vehicle `VehicleMesh.swift` can build, as an axonometric SVG,
// from that same geometry — so the low-poly solids can be looked at without
// Xcode, a simulator or a map, the way `export.swift` beside it does for the
// top views.
//
// It is not part of the app and is not compiled into it. To run it, make a
// throwaway macOS package that path-depends on `Packages/TransitCore`, drop
// this file in as `main.swift`, and pass it the output directory:
//
//     swift run export-solid Design/vehicles/solid
//
// The projection is orthographic — no perspective — from a fixed yaw and
// elevation, with the faces painted back to front and shaded off their own
// normals. That is not what Mapbox does with these slabs, and it does not have
// to be: what this is for is seeing whether the *stack* is right — whether a
// tram is shorter than a coach, whether a cab rakes, whether a roof is drawn
// in far enough — and every one of those questions is answered by a picture
// from any single angle.

import Foundation
import TransitCore

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true
)
let store = VehicleLayoutStore()
/// Points per metre on the page.
let pointsPerMetre = 5.0
/// Map scale the solids are built for: close in, so nothing is exaggerated and
/// what is on the page is the vehicle's real proportions.
let metresPerPoint = 0.25

/// Where the camera stands: yaw around the vertical, and elevation above the
/// horizon. Shallow enough that the sides carry the drawing rather than the
/// roofs, which is also the angle the map is at when the solids appear.
let yaw = 20.0 * .pi / 180
let elevation = 24.0 * .pi / 180
/// Where the light comes from, as a unit vector in world axes (east, north, up).
let light = (x: -0.42, y: 0.30, z: 0.85)

let origin = Coord(lon: 7.4400, lat: 46.9480)

func sample(
    _ mode: Mode, category: String?, line: String, operatorName: String?
) -> (VehicleSnapshot, VehicleLayout) {
    let vehicle = VehicleSnapshot(
        id: "\(line)-\(operatorName ?? "")", mode: mode, category: category, line: line,
        operatorName: operatorName, from: "Bern", lon: origin.lon, lat: origin.lat,
        // Pointing west, so the train trails away to the east and reads nose
        // first from the left of the page.
        bearing: 270, moving: true, index: 0, progress: 0, stops: [], onTrack: false
    )
    return (vehicle, store.layout(for: vehicle, modeColour: mode.mapColour))
}

extension Mode {
    var mapColour: String {
        switch self {
        case .train: return "#ff3b30"
        case .tram: return "#34c759"
        case .bus: return "#0a84ff"
        case .metro: return "#bf5af2"
        case .boat: return "#5ac8fa"
        case .cable: return "#ff9f0a"
        case .other: return "#98989d"
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
    let (vehicle, layout) = sample(mode, category: category, line: line, operatorName: operatorName)
    let units = layout.units.count
    let caption = "\(layout.name ?? name) · \(units) \(units == 1 ? "body" : "bodies")"
        + " · \(Int(layout.length.rounded())) m"
    return Drawing(name: name, caption: caption, vehicle: vehicle, layout: layout)
}

let drawings: [Drawing] = [
    drawing("ic1-fv-dosto", .train, category: "IC", line: "IC1", operatorName: "SBB"),
    drawing("ic3-re460-ic2000", .train, category: "IC", line: "IC3", operatorName: "SBB"),
    drawing("ic5-icn", .train, category: "IC", line: "IC5", operatorName: "SBB"),
    drawing("ic2-giruno", .train, category: "IC", line: "IC2", operatorName: "SBB"),
    drawing("ir16-kiss", .train, category: "IR", line: "IR16", operatorName: "SBB"),
    drawing("s12-dtz", .train, category: "S", line: "S12", operatorName: "SBB"),
    drawing("s3-mutz", .train, category: "S", line: "S3", operatorName: "BLS"),
    drawing("r-thurbo-gtw", .train, category: "R", line: "R", operatorName: "THURBO"),
    drawing("r-rhb-capricorn", .train, category: "R", line: "R", operatorName: "RHB"),
    drawing("ice", .train, category: "ICE", line: "ICE", operatorName: "DB"),
    drawing("tram-zurich-cobra", .tram, category: "T", line: "9", operatorName: "VBZ"),
    drawing("tram-basel-flexity", .tram, category: "T", line: "8", operatorName: "BVB"),
    drawing("trolleybus-zurich", .bus, category: "B", line: "31", operatorName: "VBZ"),
    drawing("postauto", .bus, category: "B", line: "101", operatorName: "PAG"),
    drawing("metro-lausanne", .metro, category: "M", line: "M2", operatorName: "TL"),
    drawing("boat-cgn", .boat, category: "BAT", line: "1", operatorName: "CGN"),
    drawing("funicular", .cable, category: "FUN", line: "1", operatorName: nil),
]

// MARK: - Projection

/// Metres east and north of the origin.
func plane(_ point: Coord) -> (x: Double, y: Double) {
    (
        (point.lon - origin.lon) * 111_320 * cos(origin.lat * .pi / 180),
        (point.lat - origin.lat) * 111_320
    )
}

struct Vertex { var sx: Double; var sy: Double; var depth: Double }

func project(_ point: Coord, _ z: Double) -> Vertex {
    let flat = plane(point)
    let u = flat.x * cos(yaw) - flat.y * sin(yaw)
    let v = flat.x * sin(yaw) + flat.y * cos(yaw)
    return Vertex(
        sx: u,
        // SVG's y runs down, so a taller point has a smaller y.
        sy: v * sin(elevation) - z * cos(elevation),
        depth: v * cos(elevation) + z * sin(elevation)
    )
}

struct Face {
    var points: [Vertex]
    var fill: String
    var shade: Double
    var depth: Double
}

/// A colour multiplied by a shade, so a facet's own normal decides how lit it is.
func shaded(_ colour: String, _ amount: Double) -> String {
    var r = 128.0, g = 128.0, b = 128.0
    if colour.hasPrefix("#") {
        var digits = Array(colour.dropFirst())
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
        if digits.count == 6, let value = Int(String(digits), radix: 16) {
            r = Double((value >> 16) & 255); g = Double((value >> 8) & 255); b = Double(value & 255)
        }
    } else if colour.hasPrefix("rgb") {
        let inside = colour.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
        let fields = inside.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        if fields.count >= 3 { r = fields[0]; g = fields[1]; b = fields[2] }
    }
    func clamp(_ v: Double) -> Int { Int(min(255, max(0, v.rounded()))) }
    return String(format: "#%02x%02x%02x", clamp(r * amount), clamp(g * amount), clamp(b * amount))
}

/// How lit a facet with this normal is. Never black: a face turned away from
/// the light is still lit by the sky, and a solid rendered with true Lambert
/// falloff loses its whole shaded side into the background.
func lit(_ nx: Double, _ ny: Double, _ nz: Double) -> Double {
    let dot = nx * light.x + ny * light.y + nz * light.z
    return 0.55 + 0.45 * max(0, dot)
}

var index: [String] = []
for item in drawings {
    guard let shape = VehicleShape.footprint(
        of: item.vehicle, layout: item.layout, metresPerPoint: metresPerPoint, solid: true
    ), !shape.slabs.isEmpty else {
        print("no slabs for \(item.name)")
        continue
    }

    var faces: [Face] = []
    // A slab carries one outline or several — the pair of bogies under a
    // coach, the run of doors down a tram — so that everything belonging to
    // one wagon is grounded together on a hillside. Here there is no hillside
    // and each of them is simply drawn.
    for slab in shape.slabs {
      for ring in slab.rings {
        guard ring.count >= 3 else { continue }
        // Which way round the ring runs, so the side normals point outward
        // whichever way `outline` happened to wind it.
        var area = 0.0
        for i in 0..<ring.count {
            let a = plane(ring[i]), b = plane(ring[(i + 1) % ring.count])
            area += a.x * b.y - b.x * a.y
        }
        let winding = area >= 0 ? 1.0 : -1.0

        // The sides.
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let pa = plane(a), pb = plane(b)
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 1e-6 else { continue }
            let nx = winding * dy / len, ny = -winding * dx / len
            let quad = [
                project(a, slab.base), project(b, slab.base),
                project(b, slab.top), project(a, slab.top),
            ]
            faces.append(Face(
                points: quad, fill: slab.fill, shade: lit(nx, ny, 0),
                depth: quad.map(\.depth).reduce(0, +) / 4
            ))
        }
        // And the top.
        let cap = ring.map { project($0, slab.top) }
        faces.append(Face(
            points: cap, fill: slab.fill, shade: lit(0, 0, 1),
            depth: cap.map(\.depth).reduce(0, +) / Double(cap.count)
        ))
      }
    }

    // Back to front. `sorted(by:)` is fine here: this is a still picture and
    // nothing has to hold its order between one of them and the next.
    faces.sort { $0.depth > $1.depth }

    var minX = Double.infinity, maxX = -Double.infinity
    var minY = Double.infinity, maxY = -Double.infinity
    for face in faces {
        for point in face.points {
            minX = min(minX, point.sx); maxX = max(maxX, point.sx)
            minY = min(minY, point.sy); maxY = max(maxY, point.sy)
        }
    }
    let pad = 2.0
    let width = (maxX - minX + pad * 2) * pointsPerMetre
    let height = (maxY - minY + pad * 2) * pointsPerMetre

    var body = ""
    for face in faces {
        let points = face.points.map { point -> String in
            String(
                format: "%.2f,%.2f",
                (point.sx - minX + pad) * pointsPerMetre,
                (point.sy - minY + pad) * pointsPerMetre
            )
        }.joined(separator: " ")
        let fill = shaded(face.fill, face.shade)
        body += "  <polygon points=\"\(points)\" fill=\"\(fill)\" stroke=\"\(fill)\" "
            + "stroke-width=\"0.35\" stroke-linejoin=\"round\"/>\n"
    }

    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(width.rounded()))" \
    height="\(Int(height.rounded()))" viewBox="0 0 \(String(format: "%.2f", width)) \
    \(String(format: "%.2f", height))">
      <rect width="100%" height="100%" fill="#161616"/>
    \(body)</svg>

    """
    try svg.write(
        to: outputDirectory.appendingPathComponent("\(item.name).svg"),
        atomically: true, encoding: .utf8
    )
    index.append("""
      <figure><img src="\(item.name).svg" alt="\(item.name)">\
    <figcaption>\(item.name)<br><span>\(item.caption) · \(shape.slabs.count) slabs</span>\
    </figcaption></figure>
    """)
}

let page = """
<!doctype html>
<meta charset="utf-8">
<title>Vehicles as solids</title>
<style>
  body { background:#161616; color:#f2f2f2; font:14px -apple-system,system-ui,sans-serif;
         margin:0; padding:32px; }
  h1 { font-size:16px; font-weight:600; margin:0 0 4px; }
  p { color:#999; margin:0 0 28px; max-width:66ch; line-height:1.5; }
  figure { margin:0 0 26px; }
  figcaption { color:#888; font-size:12px; margin-top:8px; }
  figcaption span { color:#666; }
  img { display:block; max-width:100%; }
</style>
<h1>Vehicles as solids</h1>
<p>Generated from <code>Packages/TransitCore/Sources/TransitCore/VehicleMesh.swift</code>
   by <code>export-solid.swift</code> beside this file — the same slabs the map
   extrudes once the camera is tilted, painted back to front and shaded off
   their own normals. Five points per metre and one scale for all of them, so
   the heights are comparable: a low-floor tram really is a metre shorter than
   a coach, and a double-decker half a metre taller than either.</p>
\(index.joined(separator: "\n"))

"""
try page.write(
    to: outputDirectory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
)
print("wrote \(index.count) solids to \(outputDirectory.path)")
