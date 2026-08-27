// Exports every shape `VehicleFootprint.swift` can draw, as SVG, from that same
// geometry — so the top views can be opened and looked at without Xcode, a
// simulator or a network, the way `Design/wagons/` does for the side views.
//
// It is not part of the app and is not compiled into it. To run it, make a
// throwaway macOS package that path-depends on `Packages/TransitCore`, drop
// this file in as `main.swift`, and pass it the output directory:
//
//     swift run export Design/vehicles
//
// Each vehicle is drawn on straight track running left to right, front first,
// at four points per metre — so an intercity really is nine times the length of
// a bus on the page, which is the whole point of drawing them this way.

import Foundation
import TransitCore

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let store = VehicleLayoutStore()
/// Points per metre on the page.
let pointsPerMetre = 4.0
/// Map scale the shapes are built for: close enough that every marking is
/// emitted, which is what these drawings are for.
let metresPerPoint = 0.25

let origin = Coord(lon: 7.4400, lat: 46.9480)

func sample(
    _ mode: Mode, category: String?, line: String, operatorName: String?
) -> (VehicleSnapshot, VehicleLayout) {
    let vehicle = VehicleSnapshot(
        id: "\(line)-\(operatorName ?? "")", mode: mode, category: category, line: line,
        operatorName: operatorName, from: "Bern", lon: origin.lon, lat: origin.lat,
        // Pointing west, so the train trails away to the east and reads left to
        // right on the page with its nose at the left.
        bearing: 270, moving: true, index: 0, progress: 0, stops: [], onTrack: false
    )
    return (vehicle, store.layout(for: vehicle, modeColour: mode.mapColour))
}

extension Mode {
    /// The dot colours, copied rather than imported: the palette lives in the
    /// app target and this is not the app.
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

/// Metres east and north of the origin, which is where the vehicle's nose is.
func plane(_ point: Coord) -> (x: Double, y: Double) {
    (
        (point.lon - origin.lon) * 111_320 * cos(origin.lat * .pi / 180),
        (point.lat - origin.lat) * 111_320
    )
}

var index: [String] = []
for item in drawings {
    guard let shape = VehicleShape.footprint(
        of: item.vehicle, layout: item.layout, metresPerPoint: metresPerPoint
    ) else { continue }

    var minX = Double.infinity, maxX = -Double.infinity
    var minY = Double.infinity, maxY = -Double.infinity
    for part in shape.parts {
        for point in part.ring {
            let flat = plane(point)
            minX = min(minX, flat.x); maxX = max(maxX, flat.x)
            minY = min(minY, flat.y); maxY = max(maxY, flat.y)
        }
    }
    let pad = 3.0
    let width = (maxX - minX + pad * 2) * pointsPerMetre
    let height = (maxY - minY + pad * 2) * pointsPerMetre

    var body = ""
    for part in shape.parts {
        let points = part.ring.map { point -> String in
            let flat = plane(point)
            let x = (flat.x - minX + pad) * pointsPerMetre
            // SVG's y runs down and the world's runs up.
            let y = (maxY - flat.y + pad) * pointsPerMetre
            return String(format: "%.2f,%.2f", x, y)
        }.joined(separator: " ")
        let stroke = part.role == .body
            ? " stroke=\"\(shape.stroke)\" stroke-width=\"0.9\" stroke-linejoin=\"round\""
            : ""
        body += "  <polygon points=\"\(points)\" fill=\"\(part.fill)\"\(stroke)/>\n"
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
    <figcaption>\(item.name)<br><span>\(item.caption)</span></figcaption></figure>
    """)
}

let page = """
<!doctype html>
<meta charset="utf-8">
<title>Vehicles from above</title>
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
<h1>Vehicles from above</h1>
<p>Generated from <code>Packages/TransitCore/Sources/TransitCore/VehicleFootprint.swift</code>
   by <code>export.swift</code> beside this file — the same outlines the map draws,
   on straight track, front to the left. Four points per metre and one scale for
   all of them, so the lengths are comparable: that is what the map is saying
   when a dot turns into a vehicle. Composition comes from
   <code>LayoutLibrary.swift</code>, which is what each line normally runs;
   tapping a train replaces it with the formation the service files for that
   train.</p>
\(index.joined(separator: "\n"))

"""
try page.write(
    to: outputDirectory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8
)
print("wrote \(index.count) drawings to \(outputDirectory.path)")
