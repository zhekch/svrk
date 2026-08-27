import MapboxMaps
import UIKit

/// The platforms you stand on and the blobs that hold them.
///
/// The railway *network* on this map is drawn from the routing graph — the same
/// OpenStreetMap railway the app routes trains over, already on the device and
/// correct with no signal. Platform footprints are not in that graph. They are
/// areas rather than track, they are not part of routing, and packing them would
/// be a second copy of geometry the phone would then have to keep current.
///
/// So these come from OpenRailwayMap's vector tiles, exactly as the web app gets
/// them, and this file is that style ported to the native SDK rather than a new
/// design: the same source, the same source layers, the same seven layers in the
/// same order and the same colours, so a station looks the same in both places.
///
/// What it costs is honesty about the network: these are the one thing on the
/// map that needs one. When the tiles do not arrive the shapes are simply not
/// drawn — and because the plates stand down wherever a footprint is drawn,
/// `MapCoordinator` watches the source and tells the model, so a platform is
/// never left with neither a shape nor a plate.
enum RailwayShapes {
    static let sourceId = "orm-railway"

    /// The five source layers, asked for as one TileJSON. Comma-separated is
    /// OpenRailwayMap's own convention for a combined tileset.
    static let tileJSON = """
        https://openrailwaymap.app/\
        standard_railway_grouped_station_areas,\
        standard_railway_grouped_stations,\
        standard_railway_platform_edges,\
        standard_railway_platforms,\
        standard_railway_stop_positions
        """

    static let attribution =
        "<a href=\"https://www.openrailwaymap.org/\">OpenRailwayMap</a> | Data " +
        "<a href=\"https://www.openstreetmap.org/copyright\">© OpenStreetMap contributors</a> (ODbL)"

    enum Layer {
        static let stationArea = "orm-station-area"
        static let stationFill = "orm-station-fill"
        static let stationOutline = "orm-station-outline"
        static let platformFill = "orm-platform-fill"
        static let platformOutline = "orm-platform-outline"
        static let platformLine = "orm-platform-line"
        static let platformEdge = "orm-platform-edge"
        static let platformSelected = "orm-platform-selected"
        static let platformEdgeSelected = "orm-platform-edge-selected"
        static let stopPosition = "orm-stop-position"
    }

    /// The tile layer the station blobs come from, for the merge below.
    static let stationSourceLayer = SourceLayer.stations

    private enum SourceLayer {
        static let stationAreas = "standard_railway_grouped_station_areas"
        static let stations = "standard_railway_grouped_stations"
        static let platforms = "standard_railway_platforms"
        static let platformEdges = "standard_railway_platform_edges"
        static let stopPositions = "standard_railway_stop_positions"
    }

    /// The layers a tap on a platform is answered from — the footprint drawn as
    /// an area, as a line, and the platform edges, which are the two sides of an
    /// island platform.
    static let platformLayers = [
        Layer.platformEdge, Layer.platformLine, Layer.platformOutline, Layer.platformFill,
    ]

    /// The dots on the track where a service stops.
    ///
    /// Kept apart from the blobs they sit on because they are asked about
    /// separately and much more tightly: four points across, on top of
    /// everything, and the thing somebody aiming at a tram stop actually hits.
    static let stopDotLayers = [Layer.stopPosition]

    /// The layers a tap on a station is answered from, once the dots have had
    /// their chance. The blob is the fallback, and it is enormous.
    static let stationLayers = [Layer.stationFill, Layer.stationOutline, Layer.stationArea]

    static let allLayers = platformLayers + stopDotLayers + stationLayers
        + [Layer.platformSelected, Layer.platformEdgeSelected]

    // MARK: - Palette
    //
    // OpenRailwayMap's own, kept to the letter. The station colours say what
    // kind of railway it is — tram pink, subway blue, funicular red, main line
    // orange — and inventing a palette here would make the same station a
    // different colour in the two apps for no reason.

    private static func stationColour() -> Exp {
        Exp(.match) {
            Exp(.get) { "station" }
            "light_rail"; "#00bd14"
            "subway"; "#0300c3"
            "monorail"; "#00bd8b"
            "miniature"; "#7d7094"
            "funicular"; "#d87777"
            "tram"; "#d877b8"
            "#ff8100"
        }
    }

    /// Out of service, but still there: drawn in grey rather than in the colour
    /// of a railway that runs.
    private static func stationColour(dark: Bool) -> Exp {
        Exp(.switchCase) {
            Exp(.inExpression) {
                Exp(.get) { "state" }
                Exp(.literal) { ["disused", "preserved"] }
            }
            dark ? "#dadada" : "#535353"
            stationColour()
        }
    }

    /// Whatever is neither a station nor a stop: sites, junctions, and the
    /// spur junctions ORM groups with them. Drawing those would put a dashed box
    /// around every set of points in the country.
    private static func isStation(includingYards: Bool) -> Exp {
        var excluded = ["site", "junction", "spur_junction"]
        if !includingYards { excluded.insert("yard", at: 0) }
        return Exp(.not) {
            Exp(.inExpression) {
                Exp(.get) { "feature" }
                Exp(.literal) { excluded }
            }
        }
    }

    /// A station that is being built, or was demolished, is not one you can
    /// stand in. ORM keeps them in the tiles and styles them apart; here they
    /// are simply not drawn, which is the same answer to the only question this
    /// map asks of a station blob.
    private static var isBuilt: Exp {
        Exp(.match) {
            Exp(.get) { "state" }
            "construction"; false
            "proposed"; false
            "abandoned"; false
            "razed"; false
            true
        }
    }

    // MARK: - Install

    /// Say who is asking.
    ///
    /// OpenRailwayMap's tile server refuses a request that arrives with no
    /// `Referer` — plain hotlink protection, and the reason the web app gets
    /// these tiles while the phone got `403 Forbidden` on every one of them: a
    /// browser sends the header for the page it is drawing, and a native HTTP
    /// stack has no page to name.
    ///
    /// So the app names itself. Not their own address, which would be a request
    /// pretending to come from their site — this is the app's own identifier, so
    /// the server log says exactly what is asking. Anything else here is
    /// unchanged: the interceptor is global, and every request that is not
    /// theirs is passed through untouched.
    ///
    /// The tiles are free to use for OpenStreetMap projects with attribution,
    /// which the source carries. A refresh loop pulling them harder than a
    /// person panning a map would be a different question.
    private final class Referer: NSObject, HttpServiceInterceptorInterface {
        static let host = "https://openrailwaymap.app/"
        static let value = "swisstransit://com.kexts.swisstransit"

        func onRequest(
            for request: HttpRequest, continuation: @escaping HttpServiceInterceptorRequestContinuation
        ) {
            if request.url.hasPrefix(Self.host), request.headers["Referer"] == nil {
                var headers = request.headers
                headers["Referer"] = Self.value
                request.headers = headers
            }
            continuation(HttpRequestOrResponse.fromHttpRequest(request))
        }

        func onResponse(
            for response: HttpResponse, continuation: @escaping HttpServiceInterceptorResponseContinuation
        ) {
            continuation(response)
        }
    }

    private static var refererInstalled = false

    /// Registered once for the process: the interceptor is a property of the
    /// HTTP stack rather than of a style, and a style reload must not stack a
    /// second one on top of the first.
    static func announceSelf() {
        guard !refererInstalled else { return }
        refererInstalled = true
        HttpServiceFactory.setHttpServiceInterceptorForInterceptor(Referer())
    }

    static func installSource(_ style: MapboxMap) throws {
        announceSelf()

        guard !style.sourceExists(withId: sourceId) else { return }
        var source = VectorSource(id: sourceId)
        source.url = tileJSON
        source.attribution = attribution
        // The shapes are only drawn from zoom 13, and asking for a coarser tile
        // to blur up from would fetch tiles nothing will ever draw.
        source.prefetchZoomDelta = 0
        try style.addSource(source)
    }

    /// The blobs and the footprints, in OpenRailwayMap's own order: the station
    /// area first, then the station itself, then the platforms inside it.
    ///
    /// Added below the app's own railway lines, which is where ORM puts them
    /// too — the rails run over the platform, not under it.
    static func installShapes(_ style: MapboxMap, dark: Bool) throws {
        // The dashed boundary of the grouped station area — the outer edge of
        // everything the station is, sidings included.
        var area = LineLayer(id: Layer.stationArea, source: sourceId)
        area.sourceLayer = SourceLayer.stationAreas
        area.minZoom = 13
        area.filter = isStation(includingYards: true)
        area.lineColor = .constant(StyleColor(dark ? .white : .black))
        area.lineWidth = .constant(2)
        area.lineDasharray = .constant([4, 4])
        try style.addLayer(area)

        // The station itself: the shaded block you can tap anywhere inside.
        var fill = FillLayer(id: Layer.stationFill, source: sourceId)
        fill.sourceLayer = SourceLayer.stations
        fill.minZoom = blobMinZoom
        fill.filter = stationFillFilter(hiding: [])
        fill.fillColor = .expression(stationColour(dark: dark))
        fill.fillOpacity = .constant(0.2)
        try style.addLayer(fill)

        var outline = LineLayer(id: Layer.stationOutline, source: sourceId)
        outline.sourceLayer = SourceLayer.stations
        outline.minZoom = blobMinZoom
        outline.filter = stationOutlineFilter(hiding: [])
        outline.lineColor = .expression(
            Exp(.switchCase) {
                Exp(.eq) { Exp(.get) { "feature" }; "yard" }
                dark ? "#ffa35f" : "#87491D"
                stationColour()
            }
        )
        // A yard is a large faint wash; a station is a thin firm edge.
        outline.lineOpacity = .expression(
            Exp(.match) { Exp(.get) { "feature" }; "yard"; 0.2; 0.3 }
        )
        outline.lineWidth = .expression(
            Exp(.match) { Exp(.get) { "feature" }; "yard"; 6.0; 2.0 }
        )
        try style.addLayer(outline)

        // The platform itself, however OSM happens to have mapped it: as an
        // area with a footprint, or as a bare line down its middle.
        var platformFill = FillLayer(id: Layer.platformFill, source: sourceId)
        platformFill.sourceLayer = SourceLayer.platforms
        platformFill.minZoom = 15
        platformFill.filter = isArea
        platformFill.fillColor = .constant(StyleColor(UIColor(white: 0.667, alpha: 1)))
        try style.addLayer(platformFill)

        var platformOutline = LineLayer(id: Layer.platformOutline, source: sourceId)
        platformOutline.sourceLayer = SourceLayer.platforms
        platformOutline.minZoom = 15
        platformOutline.filter = isArea
        platformOutline.lineJoin = .constant(.round)
        platformOutline.lineWidth = .constant(2)
        platformOutline.lineColor = .constant(StyleColor(UIColor(white: 0.667, alpha: 1)))
        try style.addLayer(platformOutline)

        var platformLine = LineLayer(id: Layer.platformLine, source: sourceId)
        platformLine.sourceLayer = SourceLayer.platforms
        platformLine.minZoom = 15
        platformLine.filter = Exp(.eq) { Exp(.geometryType); "LineString" }
        platformLine.lineColor = .constant(StyleColor(UIColor(white: 0.667, alpha: 1)))
        platformLine.lineWidth = .expression(
            Exp(.interpolate) { Exp(.linear); Exp(.zoom); 15; 2.0; 18; 6.0; 20; 10.0 }
        )
        try style.addLayer(platformLine)

        // The edges: the side of a platform a train actually comes to, and the
        // one thing here that carries a track number in OSM.
        var edges = LineLayer(id: Layer.platformEdge, source: sourceId)
        edges.sourceLayer = SourceLayer.platformEdges
        edges.minZoom = 17
        edges.lineJoin = .constant(.round)
        edges.lineWidth = .constant(3)
        edges.lineColor = .constant(StyleColor(
            dark ? UIColor(red: 0, green: 0.16, blue: 0.55, alpha: 1) : .blue
        ))
        try style.addLayer(edges)

        // Selecting a platform outlines *the platform* — the shape you would
        // stand on — rather than putting a tag beside it. The footprint is
        // already the right object: it says which platform, how long it is and
        // which way it runs, all of which a marker leaves out.
        //
        // Two layers, because either kind of shape can be the thing under the
        // finger and the two tile layers key differently: the platforms carry
        // `way-421636561`, the edges a bare integer. A filter has to compare
        // against the right type, so each gets its own.
        try style.addLayer(highlight(id: Layer.platformSelected, sourceLayer: SourceLayer.platforms))
        try style.addLayer(highlight(id: Layer.platformEdgeSelected, sourceLayer: SourceLayer.platformEdges))
    }

    /// The dots on the track where a service stops — pink for a tram, orange for
    /// a train. Above the rails rather than under them, which is where ORM draws
    /// them and the only place they are legible.
    static func installStopPositions(_ style: MapboxMap, dark: Bool) throws {
        var dots = CircleLayer(id: Layer.stopPosition, source: sourceId)
        dots.sourceLayer = SourceLayer.stopPositions
        dots.minZoom = 16
        dots.circleRadius = .expression(
            Exp(.interpolate) { Exp(.linear); Exp(.zoom); 16; 2.0; 19; 5.0 }
        )
        dots.circleColor = .expression(
            Exp(.match) {
                Exp(.get) { "type" }
                "train"; "#ff8100"
                "tram"; "#d877b8"
                "light_rail"; "#00bd14"
                "subway"; "#0300c3"
                "funicular"; "#d87777"
                "monorail"; "#00bd8b"
                "miniature"; "#7d7094"
                "#000000"
            }
        )
        dots.circleStrokeWidth = .constant(2)
        dots.circleStrokeColor = .constant(StyleColor(
            dark ? UIColor(white: 0.2, alpha: 1) : .white
        ))
        try style.addLayer(dots)
    }

    /// Where the station blobs start being drawn. Their own `minzoom`, and the
    /// floor under the merge below — there is nothing to merge above nothing.
    static let blobMinZoom = 13.0

    private static func stationFillFilter(hiding ids: [String]) -> Exp {
        Exp(.all) { isStation(includingYards: false); isBuilt; notOneOf(ids) }
    }

    private static func stationOutlineFilter(hiding ids: [String]) -> Exp {
        Exp(.all) {
            isStation(includingYards: true)
            isBuilt
            Exp(.not) {
                Exp(.inExpression) {
                    Exp(.get) { "state" }
                    Exp(.literal) { ["disused", "abandoned", "preserved", "construction", "proposed"] }
                }
            }
            notOneOf(ids)
        }
    }

    private static func notOneOf(_ ids: [String]) -> Exp {
        guard !ids.isEmpty else { return Exp(.literal) { true } }
        return Exp(.not) {
            Exp(.inExpression) { Exp(.get) { "id" }; Exp(.literal) { ids } }
        }
    }

    /// Draw one blob per station.
    ///
    /// A stop mapped as several nodes gets several blobs: Bern's tram stop is
    /// three `railway=tram_stop` nodes all named "Bern Bahnhof", and
    /// OpenRailwayMap buffers each into its own circle. Overlapping, their fills
    /// stack into darker lenses and one stop reads as three — which is not what
    /// is there.
    ///
    /// A style cannot union tile polygons, so the merge is a choice instead of a
    /// dissolve: of the blobs that resolve to the same station, the largest is
    /// drawn and the rest are filtered out. Largest, so the least ground is
    /// given up; measured over every copy of a shape, because a polygon crossing
    /// a tile boundary arrives as one feature per tile.
    ///
    /// Blobs that resolve to no station at all are left alone. Nothing says they
    /// are duplicates of anything.
    static func merge(_ style: MapboxMap, hiding ids: [String]) {
        try? style.updateLayer(withId: Layer.stationFill, type: FillLayer.self) {
            $0.filter = stationFillFilter(hiding: ids)
        }
        try? style.updateLayer(withId: Layer.stationOutline, type: LineLayer.self) {
            $0.filter = stationOutlineFilter(hiding: ids)
        }
    }

    private static var isArea: Exp {
        Exp(.any) {
            Exp(.eq) { Exp(.geometryType); "Polygon" }
            Exp(.eq) { Exp(.geometryType); "MultiPolygon" }
        }
    }

    private static func highlight(id: String, sourceLayer: String) -> LineLayer {
        var layer = LineLayer(id: id, source: sourceId)
        layer.sourceLayer = sourceLayer
        layer.minZoom = 14
        layer.lineCap = .constant(.round)
        layer.lineJoin = .constant(.round)
        layer.lineColor = .constant(StyleColor(UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)))
        layer.lineWidth = .expression(
            Exp(.interpolate) { Exp(.linear); Exp(.zoom); 14; 2.0; 17; 3.5 }
        )
        layer.filter = Exp(.eq) { Exp(.get) { "id" }; "__none__" }
        return layer
    }

    // MARK: - Selection

    /// Outline one shape, or none.
    ///
    /// The id comes from the board that is open, so the outline cannot outlive
    /// the selection or point at something else: there is one answer to "what is
    /// selected" and both the panel and the map read it.
    static func highlight(_ style: MapboxMap, shape id: String?) {
        // The platform layer writes its id prefixed, the edge layer writes a
        // bare integer. Comparing a string against a number matches nothing and
        // fails silently, so each layer is given the form its own tiles use.
        let prefixed = id.flatMap { $0.allSatisfy(\.isNumber) ? nil : $0 } ?? "__none__"
        let bare = id.flatMap { Double($0) }

        try? style.updateLayer(withId: Layer.platformSelected, type: LineLayer.self) {
            $0.filter = Exp(.eq) { Exp(.get) { "id" }; prefixed }
        }
        try? style.updateLayer(withId: Layer.platformEdgeSelected, type: LineLayer.self) {
            $0.filter = bare.map { number in Exp(.eq) { Exp(.get) { "id" }; number } }
                ?? Exp(.eq) { Exp(.get) { "id" }; "__none__" }
        }
    }

    static func setVisible(_ style: MapboxMap, _ visible: Bool) {
        for id in allLayers where style.layerExists(withId: id) {
            try? style.setLayerProperty(
                for: id, property: "visibility", value: visible ? "visible" : "none"
            )
        }
    }
}
