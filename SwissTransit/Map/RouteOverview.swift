import UIKit
import MapboxMaps
import TransitCore

/// Static map geometry. Mapbox projects this in the same render pass as the
/// vehicles and labels; camera gestures never rebuild or upload the route.
final class NativeRouteRenderer {
    static let source = "transit-route"
    /// Static extras — a selected line, a splitting branch — do not need
    /// line-metrics. Sharing the progress source put them on the metrics
    /// shader, which extrudes a short tile-local segment into a meridian
    /// down to the tile's south edge (the equator at z1).
    static let extras = "transit-route-extra"
    static let marks = "transit-route-marks"
    static let casing = "transit-route-casing"
    static let extraCasing = "transit-route-extra-casing"
    static let ahead = "transit-route-ahead"
    static let solid = "transit-route-solid"
    static let dotsCasing = "transit-route-dots-casing"
    static let dots = "transit-route-dots"
    static let arrows = "transit-route-arrows"
    static let layers = [casing, extraCasing, ahead, solid, dotsCasing, dots, arrows]
    /// Black overview outline. Fully opaque below this, faded out by the next
    /// zoom. Two steps higher than the original cutoff so it is already on
    /// before the map has gone fully city-scale.
    private static let casingUntil = 12.0
    private var metrics: RouteProgress?
    private var latitude = 47.0
    private var progressKey: [Double] = []
    private var inferred: [ClosedRange<Double>] = []
    private var patterns: [(pattern: RoutePattern, main: Bool, solid: Bool)] = []
    private var detailBounds: BBox?
    private var detailSpacing = 0.0
    private(set) var pointCount = 0

    func install(_ map: MapboxMap) throws {
        for id in [Self.source, Self.extras, Self.marks] {
            if !map.sourceExists(withId: id) {
                var source = GeoJSONSource(id: id)
                source.data = .featureCollection(FeatureCollection(features: []))
                source.lineMetrics = id == Self.source
                // Pixel simplification at low zoom collapses a local S-Bahn to
                // two points; the metrics shader then treats that as a
                // degenerate segment and draws a meridian. Keep the vertices.
                source.tolerance = 0
                source.maxzoom = 20
                source.buffer = 128
                source.prefetchZoomDelta = 0
                try map.addSource(source)
            }
            try? map.setSourceProperty(for: id, property: "prefetch-zoom-delta", value: 0)
            try? map.setSourceProperty(for: id, property: "tolerance", value: 0)
        }
        let imageID = "transit-route-chevron"
        if !map.imageExists(withId: imageID) {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 14)).image { _ in
                let arrow = UIBezierPath()
                arrow.move(to: CGPoint(x: 3, y: 10))
                arrow.addLine(to: CGPoint(x: 8, y: 4))
                arrow.addLine(to: CGPoint(x: 13, y: 10))
                arrow.lineCapStyle = .round
                arrow.lineJoinStyle = .round
                // A fine dark edge separates the white arrow from the white
                // route, including over bright roads and snowy terrain.
                UIColor.black.withAlphaComponent(0.65).setStroke()
                arrow.lineWidth = 4
                arrow.stroke()
                UIColor.white.setStroke()
                arrow.lineWidth = 2.5
                arrow.stroke()
            }
            try map.addImage(image, id: imageID)
        }
        let width: [Any] = ["interpolate", ["linear"], ["zoom"], 8, 2.6, 16, 5.0]
        // ~1.1 px of black either side of the white stroke, matching the fill
        // at zoom 8 (2.6 + 2.2) and tracking it up to the outline cutoff.
        let casingWidth: [Any] = ["interpolate", ["linear"], ["zoom"], 8, 4.8, Self.casingUntil, 6.0]
        let casingOpacity: [Any] = ["interpolate", ["linear"], ["zoom"], Self.casingUntil - 1, 1.0, Self.casingUntil, 0.0]
        for (index, id) in [Self.casing, Self.extraCasing, Self.ahead, Self.solid].enumerated() {
            let isCasing = index < 2
            if !map.layerExists(withId: id) {
                let filter: [Any] = index.isMultiple(of: 2) ? ["get", "main"]
                    : (isCasing ? ["!", ["get", "main"]] : ["all", ["!", ["get", "main"]], ["get", "solid"]])
                var paint: [String: Any] = ["line-color": isCasing ? "black" : "white", "line-width": width,
                                             "line-opacity": 1, "line-emissive-strength": 1, "line-occlusion-opacity": 0]
                if isCasing {
                    paint["line-width"] = casingWidth
                    paint["line-opacity"] = casingOpacity
                }
                // A route is painted onto the ground, in the same slot as the
                // rails, so 3D buildings stand in front of it. Elevated lines
                // use a separate pass that can composite over GeoJSON vehicle
                // models, even with line-occlusion-opacity set to zero.
                let layout: [String: Any] = ["line-cap": "round", "line-join": "round"]
                let sourceId = index.isMultiple(of: 2) ? Self.source : Self.extras
                var properties: [String: Any] = ["id": id, "type": "line", "source": sourceId, "slot": "middle",
                                                 "filter": filter, "layout": layout, "paint": paint]
                if isCasing { properties["maxzoom"] = Self.casingUntil }
                try map.addLayer(with: properties, layerPosition: nil)
            } else if isCasing {
                try? map.setLayerProperty(for: id, property: "line-width", value: casingWidth)
                try? map.setLayerProperty(for: id, property: "line-opacity", value: casingOpacity)
                try? map.updateLayer(withId: id, type: LineLayer.self) { $0.maxZoom = Self.casingUntil }
            }
        }
        let dotImageID = "transit-route-dot"
        let dotCasingImageID = "transit-route-dot-casing"
        func addCircle(id: String, color: UIColor) throws {
            guard !map.imageExists(withId: id) else { return }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                context.cgContext.setFillColor(color.cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            try map.addImage(image, id: id)
        }
        try addCircle(id: dotImageID, color: .white)
        try addCircle(id: dotCasingImageID, color: .black)
        let markFilter: [Any] = [">", ["zoom"], ["get", "dotMinZoom"]]
        let markPaint: [String: Any] = [
            "icon-opacity": 0, "icon-opacity-transition": ["duration": 0, "delay": 0],
            "icon-emissive-strength": 1, "icon-occlusion-opacity": 0, "occlusion-opacity-mode": "pixel"
        ]
        if !map.layerExists(withId: Self.dotsCasing) {
            // Under the white dots, same zoom window as the remaining-path
            // casing, so the travelled stretch gets the same black ring.
            let belowDots: LayerPosition? = map.layerExists(withId: Self.dots) ? .below(Self.dots) : nil
            try map.addLayer(with: [
                "id": Self.dotsCasing, "type": "symbol", "source": Self.marks, "slot": "middle",
                "maxzoom": Self.casingUntil,
                "filter": markFilter,
                "layout": ["icon-image": dotCasingImageID,
                           "icon-size": ["interpolate", ["linear"], ["zoom"], 8, 0.6, Self.casingUntil, 0.75],
                           "icon-pitch-alignment": "map", "icon-rotation-alignment": "viewport",
                           "icon-allow-overlap": true, "icon-ignore-placement": true],
                "paint": markPaint
            ], layerPosition: belowDots)
        } else {
            try? map.updateLayer(withId: Self.dotsCasing, type: SymbolLayer.self) { $0.maxZoom = Self.casingUntil }
        }
        if !map.layerExists(withId: Self.dots) {
            try map.addLayer(with: [
                "id": Self.dots, "type": "symbol", "source": Self.marks, "slot": "middle",
                // Use the same round, spaced dots at overview and street
                // zooms. The nested marker grid controls density at each zoom.
                "filter": markFilter,
                "layout": ["icon-image": dotImageID,
                           "icon-size": ["interpolate", ["linear"], ["zoom"], 8, 0.325, 16, 0.625],
                           "icon-pitch-alignment": "map", "icon-rotation-alignment": "viewport",
                           "icon-allow-overlap": true, "icon-ignore-placement": true],
                "paint": markPaint
            ], layerPosition: nil)
        }
        if !map.layerExists(withId: Self.arrows) {
            try map.addLayer(with: [
                "id": Self.arrows, "type": "symbol", "source": Self.marks, "slot": "middle",
                // Evaluated in the map renderer, including during a gesture.
                "filter": ["all", [">", ["zoom"], ["get", "arrowMinZoom"]],
                           ["any", ["<", ["pitch"], 45], ["<", ["distance-from-center"], 0.2]]],
                "layout": ["icon-image": imageID, "icon-rotate": ["get", "bearing"],
                           "icon-size": ["interpolate", ["linear"], ["zoom"], 8, 0.5, 16, 0.8],
                           "icon-pitch-alignment": "map", "icon-rotation-alignment": "map",
                           "icon-allow-overlap": true, "icon-ignore-placement": true],
                "paint": ["icon-opacity": 0, "icon-opacity-transition": ["duration": 0, "delay": 0],
                          "icon-emissive-strength": 1, "icon-occlusion-opacity": 0, "occlusion-opacity-mode": "pixel"]
            ], layerPosition: nil)
        }
        progressKey = []
    }

    func setGeometry(_ map: MapboxMap, main: [Coord], extras: [(path: [Coord], solid: Bool)],
                     inferred: [ClosedRange<Double>] = []) {
        let mainPath = Self.sanitized(main)
        let extraRuns = extras.map { (Self.sanitized($0.path), $0.solid) }
        metrics = mainPath.count > 1 ? RouteProgress(path: mainPath) : nil
        self.inferred = inferred
        latitude = mainPath.first?.lat ?? extraRuns.first?.0.first?.lat ?? 47
        patterns = []
        detailBounds = nil
        pointCount = mainPath.count + extraRuns.reduce(0) { $0 + $1.0.count }
        func feature(_ path: [Coord], main: Bool, solid: Bool) -> Feature? {
            guard path.count > 1 else { return nil }
            var line = Feature(geometry: .lineString(LineString(path.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            })))
            line.properties = ["main": .boolean(main), "solid": .boolean(solid)]
            patterns.append((RoutePattern(path: path), main, solid))
            return line
        }
        let mainLines = [feature(mainPath, main: true, solid: true)].compactMap { $0 }
        let extraLines = extraRuns.compactMap { feature($0.0, main: false, solid: $0.1) }
        map.updateGeoJSONSource(withId: Self.source, geoJSON: .featureCollection(FeatureCollection(features: mainLines)))
        map.updateGeoJSONSource(withId: Self.extras, geoJSON: .featureCollection(FeatureCollection(features: extraLines)))
        map.updateGeoJSONSource(withId: Self.marks, geoJSON: .featureCollection(FeatureCollection(features: [])))
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "dumpRoute") {
            let path = mainPath.count > 1 ? mainPath : extraRuns.first?.0 ?? []
            let lats = path.map(\.lat), lons = path.map(\.lon)
            Diagnostics.note("route dump n=\(path.count) lat \(lats.min() ?? 0)...\(lats.max() ?? 0) lon \(lons.min() ?? 0)...\(lons.max() ?? 0)")
        }
        #endif
        // Static confidence mask; progress still uses native trimming. The
        // previous vehicle-selected drawing made every inferred chord solid.
        do {
            if inferred.isEmpty {
                try map.setLayerProperty(for: Self.ahead, property: "line-gradient", value: NSNull())
            } else {
                var gradient: [Any] = ["step", ["line-progress"],
                                       inferred.first?.lowerBound == 0 ? "transparent" : "white"]
                for range in inferred {
                    let lower = metrics?.fraction(atGroundDistance: range.lowerBound) ?? 0
                    let upper = metrics?.fraction(atGroundDistance: range.upperBound) ?? 0
                    if lower > 0 { gradient += [lower, "transparent"] }
                    if upper > lower { gradient += [upper, "white"] }
                }
                try map.setLayerProperty(for: Self.ahead, property: "line-gradient", value: gradient)
            }
        } catch { Diagnostics.note("route confidence rejected: \(error)") }
        progressKey = []
        updateProgress(map, distance: 0)
    }

    /// Drop non-finite vertices and centimetre-apart repeats. A zero-length
    /// step is what the line-metrics shader extrudes into a meridian.
    static func sanitized(_ path: [Coord]) -> [Coord] {
        var out: [Coord] = []
        out.reserveCapacity(path.count)
        for point in path {
            guard point.lat.isFinite, point.lon.isFinite, point.isPlaced,
                  abs(point.lat) <= 85, abs(point.lon) <= 180 else { continue }
            if let last = out.last,
               Geo.flatMetres(last.lon, last.lat, point.lon, point.lat) < 0.4 {
                continue
            }
            out.append(point)
        }
        return out
    }

    /// Prepare only nearby decorations at the current detail level. Keep a
    /// padded cache during gestures; the native renderer moves fixed points.
    /// Load newly exposed areas as needed, and refine after zoom gestures.
    func updateDetail(_ map: MapboxMap, viewport: BBox, metresPerPoint: Double, settled: Bool) {
        guard !patterns.isEmpty, metresPerPoint.isFinite, metresPerPoint > 0 else { return }
        let requestedStep = max(8, pow(2, floor(log2(metresPerPoint * 6))))
        let outsideCache = !(detailBounds?.contains(viewport) ?? false)
        guard detailSpacing != requestedStep || outsideCache else { return }
        guard settled || outsideCache else { return }
        let bounds = viewport.padded(by: 0.25)
        detailBounds = bounds; detailSpacing = requestedStep
        // At steep pitch the geographic viewport can extend for hundreds of
        // kilometres. Bound preparation and GPU geometry even in that case.
        let visibleLength = patterns.reduce(0.0) { $0 + $1.pattern.visibleLength(in: bounds) }
        let budgetStep = pow(2, ceil(log2(max(8, visibleLength / 1500))))
        let step = max(requestedStep, budgetStep)
        let metresAtZero = Geo.metresPerDegree * 360 * cos(latitude * .pi / 180) / 512
        var marks: [Feature] = []
        for run in patterns {
            for mark in run.pattern.marks(spacing: step, in: bounds) {
                let index = max(1, Int((mark.distance / 8).rounded()))
                let spacing = 8 * pow(2, Double(min(20, index.trailingZeroBitCount)))
                var feature = Feature(geometry: .point(Point(CLLocationCoordinate2D(
                    latitude: mark.coordinate.lat, longitude: mark.coordinate.lon
                ))))
                feature.properties = ["main": .boolean(run.main), "solid": .boolean(run.solid),
                                      "inferred": .boolean(run.main && inferred.contains { $0.contains(mark.distance) }),
                                      "distance": .number(mark.distance), "spacing": .number(spacing),
                                      "bearing": .number(Geo.bearing(mark.coordinate, mark.direction)),
                                      "dotMinZoom": .number(log2(metresAtZero * 12 / (spacing * 2))),
                                      "arrowMinZoom": .number(log2(metresAtZero * 80 / (spacing * 2)))]
                marks.append(feature)
            }
        }
        // Fragmented/reversing routes can exceed the length estimate by one
        // mark per crossing. Enforce the budget using the same nested grid.
        var cappedStep = step
        while marks.count > 1500 {
            cappedStep *= 2
            let divisor = Int((cappedStep / 8).rounded())
            marks.removeAll { feature in
                guard case let .number(distance) = feature.properties?["distance"] else { return true }
                return !Int((distance / 8).rounded()).isMultiple(of: divisor)
            }
        }
        map.updateGeoJSONSource(withId: Self.marks, geoJSON: .featureCollection(FeatureCollection(features: marks)))
    }

    func updateProgress(_ map: MapboxMap, distance: Double) {
        guard [distance] != progressKey else { return }
        progressKey = [distance]
        let cutoff = metrics?.fraction(atGroundDistance: distance) ?? 0
        let past: [Any] = ["case", ["get", "main"], ["any", ["get", "inferred"], ["<=", ["get", "distance"], distance]], ["!", ["get", "solid"]]]
        let ahead: [Any] = ["case", ["get", "main"], ["all", ["!", ["get", "inferred"]], [">", ["get", "distance"], distance]], ["get", "solid"]]
        func opacity(spacing: Double, visible: [Any], alpha: Double, fadeOutAt: Double? = nil) -> [Any] {
            var expression: [Any] = ["interpolate", ["linear"], ["zoom"]]
            let metresAtZero = Geo.metresPerDegree * 360 * cos(latitude * .pi / 180) / 512
            for zoom in 0...24 {
                var level = alpha
                if let fadeOutAt {
                    level *= max(0, min(1, fadeOutAt - Double(zoom)))
                }
                let target = metresAtZero * spacing / pow(2, Double(zoom))
                expression += [zoom, ["case", visible,
                    ["*", level, ["max", 0, ["min", 1, ["-", 2, ["/", target, ["get", "spacing"]]]]]], 0] as [Any]]
            }
            return expression
        }
        do {
            try map.setLayerProperty(for: Self.casing, property: "line-trim-offset", value: [0, cutoff])
            try map.setLayerProperty(for: Self.ahead, property: "line-trim-offset", value: [0, cutoff])
            try map.setLayerProperty(for: Self.dotsCasing, property: "icon-opacity",
                                     value: opacity(spacing: 12, visible: past, alpha: 1, fadeOutAt: Self.casingUntil))
            try map.setLayerProperty(for: Self.dots, property: "icon-opacity", value: opacity(spacing: 12, visible: past, alpha: 1))
            try map.setLayerProperty(for: Self.arrows, property: "icon-opacity", value: opacity(spacing: 80, visible: ahead, alpha: 0.95))
        } catch { Diagnostics.note("native route progress rejected: \(error)") }
    }
}
