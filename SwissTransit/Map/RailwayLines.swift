import MapboxMaps

/// The railway network, in OpenRailwayMap's own colours.
///
/// The app's own overlay — `transit-tracks` in `MapCoordinator` — is drawn from
/// the routing graph: two flat colours at whatever opacity the dial is set to,
/// which is exactly right as a hint under the vehicles and nearly invisible
/// when what you actually want to read is the railway itself.
///
/// This is the other answer, and it is ORM's: the same standard style the web
/// map draws, where an orange line is a main line, yellow a branch, olive a
/// narrow gauge and black a siding, each with a casing so parallel tracks come
/// apart. It comes from ORM's own vector tiles rather than from the graph,
/// because the graph does not carry `usage`, `service` or `highspeed` — the
/// three tags the whole palette is made of.
///
/// What it costs is a network. The graph overlay is on the device and correct
/// with no signal; these are tiles. So the app's own overlay only stands down
/// once a line tile has actually been seen — see `AppModel.railwayLines`, which
/// is the same bargain `RailwayShapes` already makes for the platforms.
///
/// Two simplifications against ORM's own 297 layers, both deliberate:
/// bridges lose their railing, and a tunnel is drawn like open track rather
/// than with a dashed casing. Everything that carries *meaning* — which class
/// of railway, and how fast — is here.
enum RailwayLines {
    /// Below zoom 7 ORM serves a thinned main-line-only tileset, and above it
    /// the full one. Two sources because they are two tilesets; the layers
    /// hand over at 7, which is where ORM hands over too.
    static let lowSourceId = "orm-line-low"
    static let highSourceId = "orm-line-high"

    static let lowTileJSON = "https://openrailwaymap.app/standard_railway_line_low"
    static let highTileJSON = "https://openrailwaymap.app/railway_line_high"

    /// The two source ids, for the coordinator's watch on whether tiles arrive.
    static let sourceIds: Set<String> = [lowSourceId, highSourceId]

    private enum SourceLayer {
        static let low = "standard_railway_line_low"
        static let high = "railway_line_high"
    }

    // MARK: - Palette
    //
    // OpenRailwayMap's own, kept to the letter, for the same reason the station
    // colours are: a line that is orange on their map and something else on
    // this one would be a second vocabulary for one railway.

    private enum Colour {
        static let main: StyleColor = "#ff8100"
        static let highspeed: StyleColor = "#ff0c00"
        static let branch: StyleColor = "#c4b600"
        static let narrow: StyleColor = "#c0da00"
        static let lightRail: StyleColor = "#00bd14"
        static let monorail: StyleColor = "#00bd8b"
        static let subway: StyleColor = "#0300c3"
        static let tram: StyleColor = "#d877b8"
        static let funicular: StyleColor = "#d87777"
        static let tourism: StyleColor = "#5b4d70"
        static let industrial: StyleColor = "#87491d"
        static let service: StyleColor = "#000000"
    }

    /// The outline that keeps two tracks a metre apart from reading as one.
    ///
    /// White over a light basemap and near-black over a dark one — ORM's own
    /// two themes, and the one thing in this file that is not a constant.
    private static func casingColour(dark: Bool) -> StyleColor {
        dark ? "#333333" : "#ffffff"
    }

    // MARK: - Classes

    /// One class of railway, and how ORM draws it.
    private struct Track {
        let name: String
        let minZoom: Double
        let filter: Exp
        let colour: Value<StyleColor>
        let width: Value<Double>
    }

    /// Least important first, so a main line is laid over the sidings that
    /// leave it rather than under them. This is ORM's own order.
    private static let classes: [Track] = [
        Track(
            name: "service",
            minZoom: 10,
            // `rail` with no `usage` at all: sidings, yards, crossovers, and
            // the spurs that leave a line for a factory.
            filter: Exp(.all) {
                Exp(.eq) { Exp(.get) { "feature" }; "rail" }
                Exp(.not) { Exp(.has) { "usage" } }
            },
            colour: .expression(
                Exp(.match) {
                    Exp(.get) { "service" }
                    "spur"; Colour.industrial.rawValue
                    Colour.service.rawValue
                }
            ),
            width: .expression(
                Exp(.interpolate) {
                    Exp(.exponential) { 1.2 }
                    Exp(.zoom)
                    8; serviceWidth
                    15; serviceWidth
                    16; 2
                }
            )
        ),
        Track(
            name: "industrial",
            minZoom: 9,
            filter: Exp(.all) {
                Exp(.eq) { Exp(.get) { "usage" }; "industrial" }
                Exp(.inExpression) {
                    Exp(.get) { "feature" }
                    Exp(.literal) { ["rail", "narrow_gauge"] }
                }
            },
            colour: .constant(Colour.industrial),
            width: .expression(
                Exp(.interpolate) {
                    Exp(.exponential) { 1.2 }
                    Exp(.zoom)
                    8; 1.5
                    14; 1.5
                    16; 2
                }
            )
        ),
        Track(
            // ORM also draws a *preserved* railway in this colour, which cannot
            // reach here: everything below is filtered to `state = present`.
            name: "tourism",
            minZoom: 9,
            filter: Exp(.eq) { Exp(.get) { "usage" }; "tourism" },
            colour: .constant(Colour.tourism),
            width: .constant(2)
        ),
        Track(
            name: "funicular",
            minZoom: 12,
            filter: Exp(.eq) { Exp(.get) { "feature" }; "funicular" },
            colour: .constant(Colour.funicular),
            width: .constant(2)
        ),
        Track(
            name: "light-rail",
            minZoom: 9,
            filter: Exp(.inExpression) {
                Exp(.get) { "feature" }
                Exp(.literal) { ["subway", "tram", "light_rail", "monorail"] }
            },
            colour: .expression(
                Exp(.match) {
                    Exp(.get) { "feature" }
                    "light_rail"; Colour.lightRail.rawValue
                    "monorail"; Colour.monorail.rawValue
                    "subway"; Colour.subway.rawValue
                    "tram"; Colour.tram.rawValue
                    Colour.service.rawValue
                }
            ),
            width: .constant(2)
        ),
        Track(
            name: "narrow-gauge",
            minZoom: 10,
            filter: Exp(.all) {
                Exp(.eq) { Exp(.get) { "feature" }; "narrow_gauge" }
                Exp(.neq) { Exp(.get) { "usage" }; "industrial" }
            },
            colour: .constant(Colour.narrow),
            width: .constant(2)
        ),
        Track(
            // From 7 rather than ORM's 8, which is where their own med-zoom
            // pair takes over from the low tileset. One layer covering both
            // bands says the same thing with half the layers.
            name: "branch",
            minZoom: 7,
            filter: Exp(.all) {
                Exp(.eq) { Exp(.get) { "feature" }; "rail" }
                Exp(.eq) { Exp(.get) { "usage" }; "branch" }
            },
            colour: .constant(Colour.branch),
            width: mainWidth
        ),
        Track(
            name: "main",
            minZoom: 7,
            filter: Exp(.all) {
                Exp(.eq) { Exp(.get) { "feature" }; "rail" }
                Exp(.eq) { Exp(.get) { "usage" }; "main" }
            },
            colour: .expression(
                Exp(.switchCase) {
                    Exp(.get) { "highspeed" }
                    Colour.highspeed.rawValue
                    Colour.main.rawValue
                }
            ),
            width: mainWidth
        ),
    ]

    /// Everything the low tileset holds is a main line, so it is one layer
    /// rather than eight — the same picture the country-wide view had before,
    /// in the colours it should have had.
    private static let lowClass = Track(
        name: "low",
        minZoom: 0,
        filter: Exp(.neq) { Exp(.get) { "feature" }; "ferry" },
        colour: .expression(
            Exp(.switchCase) {
                Exp(.get) { "highspeed" }
                Colour.highspeed.rawValue
                Colour.main.rawValue
            }
        ),
        width: .expression(
            Exp(.interpolate) {
                Exp(.exponential) { 1.2 }
                Exp(.zoom)
                0; 0.5
                7; 2
            }
        )
    )

    private static var mainWidth: Value<Double> {
        .expression(
            Exp(.interpolate) {
                Exp(.exponential) { 1.2 }
                Exp(.zoom)
                7; 2
                14; 2
                16; 3
            }
        )
    }

    /// A yard track is drawn finer than a siding, which is ORM saying that a
    /// depot full of them should read as texture rather than as railway.
    private static var serviceWidth: Exp {
        Exp(.match) {
            Exp(.get) { "service" }
            "yard"; 1.0
            1.5
        }
    }

    /// Under construction, proposed, torn up: still in the tiles, and not
    /// railway you can be carried along. ORM styles them apart; here, as with
    /// the stations, they are simply not drawn.
    private static var isOpen: Exp {
        Exp(.eq) { Exp(.get) { "state" }; "present" }
    }

    // MARK: - Layers

    private static func casingId(_ name: String) -> String { "orm-line-\(name)-casing" }
    private static func fillId(_ name: String) -> String { "orm-line-\(name)-fill" }

    /// Every layer this file installs, bottom to top: all the casings, then all
    /// the fills. Both halves in one pass rather than casing-then-fill per
    /// class, so a siding's dark outline is never drawn across the main line it
    /// joins.
    static var allLayers: [String] {
        classes.map { casingId($0.name) } + [casingId(lowClass.name)]
            + classes.map { fillId($0.name) } + [fillId(lowClass.name)]
    }

    static func installSources(_ style: MapboxMap) throws {
        RailwayShapes.announceSelf()

        for (id, url) in [(lowSourceId, lowTileJSON), (highSourceId, highTileJSON)] {
            guard !style.sourceExists(withId: id) else { continue }
            var source = VectorSource(id: id)
            source.url = url
            source.attribution = RailwayShapes.attribution
            // No blurred-up placeholder from a coarser tile: the overlay is off
            // by default, and when it is on the tiles it wants are the ones on
            // screen. Fetching a second set to tide it over is a request ORM
            // pays for and nobody looks at.
            source.prefetchZoomDelta = 0
            try style.addSource(source)
        }
    }

    /// Installed hidden. Mapbox asks for no tiles for a source no visible layer
    /// draws from, so the overlay costs nothing at all until it is switched on.
    static func installLines(_ style: MapboxMap, dark: Bool) throws {
        let casing = casingColour(dark: dark)

        for track in classes { try style.addLayer(layer(track, casing: casing, on: .high)) }
        try style.addLayer(layer(lowClass, casing: casing, on: .low))
        for track in classes { try style.addLayer(layer(track, casing: nil, on: .high)) }
        try style.addLayer(layer(lowClass, casing: nil, on: .low))
    }

    private enum Band { case low, high }

    /// One class of railway, as either its casing or its fill.
    ///
    /// The two differ in three properties and agree in every other, which is
    /// what makes a casing a casing: same geometry, same width, drawn as a pair
    /// of strokes with a one-point gap down the middle for the fill to sit in.
    private static func layer(_ track: Track, casing: StyleColor?, on band: Band) -> LineLayer {
        let isCasing = casing != nil
        var layer = LineLayer(
            id: isCasing ? casingId(track.name) : fillId(track.name),
            source: band == .low ? lowSourceId : highSourceId
        )
        layer.sourceLayer = band == .low ? SourceLayer.low : SourceLayer.high
        layer.minZoom = track.minZoom
        // The two tilesets meet at 7. Anything else would draw the country
        // twice through the band where they overlap.
        if band == .low { layer.maxZoom = 7 }
        layer.filter = Exp(.all) {
            isOpen
            track.filter
        }
        layer.lineJoin = .constant(.round)
        layer.lineCap = .constant(.round)
        layer.lineColor = casing.map { Value<StyleColor>.constant($0) } ?? track.colour
        layer.lineWidth = track.width
        if isCasing { layer.lineGapWidth = .constant(1) }
        layer.visibility = .constant(Visibility.none)
        return layer
    }

    // MARK: - Control

    static func setVisible(_ style: MapboxMap, _ visible: Bool) {
        for id in allLayers where style.layerExists(withId: id) {
            try? style.setLayerProperty(
                for: id, property: "visibility", value: visible ? "visible" : "none"
            )
        }
    }

    /// The same dial the app's own overlay answers to, so switching between the
    /// two keeps whatever weight the map was set to.
    static func setOpacity(_ style: MapboxMap, _ opacity: Double) {
        for id in allLayers where style.layerExists(withId: id) {
            try? style.setLayerProperty(for: id, property: "line-opacity", value: opacity)
        }
    }
}
