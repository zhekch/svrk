import SwiftUI

// One railway vehicle, drawn as an outline.
//
// The line is white on a dark sheet and there is nothing inside it but the
// class number: at the size a phone gives a sixteen-coach train, glass and
// doors and livery are noise. What has to survive is the *profile* — how long
// the vehicle is next to the one behind it, and what shape its front is.
//
// The front is the part worth getting right. A driving cab is not a rectangle
// with a bigger corner radius; that reads as a blob. A Re 460 has a short, hard
// wedge: the windscreen rakes back from the roof at about fifty degrees, kinks
// at the top of the nose, and drops almost vertically to the buffer beam. A
// driving trailer or a multiple unit has the opposite — one long, low sweep
// from well back on the roof down to a nose that nearly touches the rail. Two
// different shapes, and telling them apart is most of what makes a drawing of a
// train look like a train.
//
// So every outline here is a *polyline with rounded joints* rather than a
// rounded box. `WagonBody.outline` takes a list of corners, each with its own
// radius, and rounds each one by as much as its two edges allow. A profile is
// then just five or six points, which is both easy to read and easy to tune —
// and easy to export, which is how the shapes in `Design/wagons/` are made.
//
// The drawing is laid out in one coordinate space, `height` tall:
//
//     0      ─────────────── roof line, top of the body
//     0.70H  ─────────────── solebar, bottom of the body
//     0.84H  ─────────────── axle centres
//
// Widths are metres × `Wagon.pointsPerMetre`, so a 26.4 m intercity coach is
// visibly longer than an 18.7 m regional car and the whole train is drawn to
// one scale.

// MARK: - What is being drawn

/// The kind of vehicle, as far as the drawing cares.
enum WagonRole: Equatable {
    /// Short, a hard wedge at both ends, a pantograph on the roof.
    case locomotive
    /// The ordinary thing: a long body, and a swept cab on the end that has one.
    case coach
    /// Shorter and blunter, with a glyph instead of a class number.
    case van
}

/// One vehicle's drawing, resolved.
struct WagonSpec: Equatable {
    var role: WagonRole = .coach
    /// Body length in points. Set from the vehicle's real length where the
    /// rolling-stock register knows it.
    var width: CGFloat = 84
    /// A driving cab on the leading end, which is what makes the front of a
    /// train a nose rather than a wall.
    var cabFront: Bool = false
    /// A driving cab on the trailing end.
    var cabBack: Bool = false
    /// The yellow marking along the top of the body.
    var stripe: Stripe = .none
    /// What is written inside the body: `1`, `2`, `1·2`.
    var plate: String?
    /// Drawn beside the class number, or instead of one where the vehicle has
    /// no class. A dining car has both: it is a second-class coach *and* it is
    /// where the food is, and dropping either half of that is how a restaurant
    /// car came to be drawn as a plain `2`.
    var symbol: String?
    /// The floor between the two decks, drawn faintly across the middle of the
    /// body. The one thing a side elevation can say about a double-decker that
    /// a rectangle cannot.
    var doubleDeck: Bool = false
    /// Drawn as an outline of dashes: the coach is on the train but shut.
    var isClosed: Bool = false

    /// How much of the body length the yellow marking runs along, and at which
    /// end.
    ///
    /// A coach that is first class throughout carries it end to end; one that
    /// is half of each carries it over the first-class half only. The service
    /// does not say which half that is, so it is read off the train around the
    /// coach — see `FormationView.stripe(for:)`. Getting it wrong is not a
    /// cosmetic miss: the band is the only thing on the drawing that says which
    /// door to walk to, and drawn at the wrong end it sends a first-class
    /// ticket to the far end of the coach.
    enum Stripe: Equatable { case none, full, leadingHalf, trailingHalf }

    /// Which of the three end profiles this vehicle's cab is drawn with.
    var cabProfile: WagonBody.Profile {
        role == .locomotive ? .wedge : .swept
    }
}

// MARK: - The outline

/// The side profile of a vehicle body.
///
/// Built from corner points rather than from a rectangle, because the ends are
/// not corners of a rectangle. Each end contributes two or three points and the
/// straight roof and solebar join them up.
struct WagonBody: Shape {
    var cabFront: Bool
    var cabBack: Bool
    /// The shape of whichever ends have cabs.
    var profile: Profile = .swept

    /// What a driving end looks like.
    enum Profile: Equatable {
        /// One long low sweep from well back on the roof to a nose near the
        /// rail. A driving trailer, or either end of a multiple unit.
        case swept
        /// A raked windscreen, a kink at the top of the nose, and a short
        /// near-vertical drop to the buffer beam. A locomotive.
        case wedge
    }

    func path(in rect: CGRect) -> Path {
        Self.outline(Self.corners(
            width: rect.width, height: rect.height,
            cabFront: cabFront, cabBack: cabBack, profile: profile
        ))
        .offsetBy(dx: rect.minX, dy: rect.minY)
    }

    /// How far back from the front the roof line starts, for a given end.
    ///
    /// Public because everything painted on the side has to keep out of the
    /// nose: a class number centred on the whole width sits in the windscreen
    /// of a driving car.
    static func noseDepth(width: CGFloat, height: CGFloat, profile: Profile) -> CGFloat {
        switch profile {
        case .swept: return min(width * 0.34, height * 1.5)
        // Short. A Re 460 is a slab with a raked screen on each end, not a
        // wedge: taking a quarter of an eighteen-metre locomotive at each end
        // left almost no flat roof and the whole thing read as a dome.
        case .wedge: return min(width * 0.17, height * 0.42)
        }
    }

    /// The corners of the body, clockwise from the point where the roof begins
    /// at the front, each with the radius its joint should be rounded by.
    static func corners(
        width w: CGFloat, height h: CGFloat,
        cabFront: Bool, cabBack: Bool, profile: Profile
    ) -> [(point: CGPoint, radius: CGFloat)] {
        // A plain end is a corner with a small radius. Everything else is a
        // profile, and profiles are written front-facing and mirrored for the
        // back so the two ends of a unit are the same shape.
        let blunt = h * 0.14

        func front() -> (roof: (CGPoint, CGFloat), rising: [(CGPoint, CGFloat)]) {
            guard cabFront else {
                return ((CGPoint(x: 0, y: 0), blunt), [(CGPoint(x: 0, y: h), blunt)])
            }
            let d = noseDepth(width: w, height: h, profile: profile)
            switch profile {
            case .swept:
                // Roof, then one sweep to a low nose, then a short face to the
                // rail. The big radius at the nose is what makes it a nose and
                // not a point.
                return ((CGPoint(x: d, y: 0), d * 0.5),
                        [(CGPoint(x: w * 0.030, y: h), h * 0.16),
                         (CGPoint(x: 0, y: h * 0.62), h * 0.42)])
            case .wedge:
                // Roof, raked windscreen down to a hard kink, then a straight
                // vertical front to the buffer beam.
                //
                // Vertical, and not leaning out. Putting the bottom of the nose
                // ahead of the kink made the body wider at the floor than at
                // the roof, and a short vehicle that flares at the bottom reads
                // as a van — which is exactly what the locomotive looked like.
                //
                // The screen also takes only the top third of the body. Run
                // down to half height it stopped being a windscreen and became
                // a shoulder, which flared the same way for the same reason.
                return ((CGPoint(x: d, y: 0), d * 0.22),
                        [(CGPoint(x: 0, y: h), h * 0.09),
                         (CGPoint(x: 0, y: h * 0.34), h * 0.12)])
            }
        }

        func back() -> [(CGPoint, CGFloat)] {
            guard cabBack else {
                return [(CGPoint(x: w, y: 0), blunt), (CGPoint(x: w, y: h), blunt)]
            }
            let d = noseDepth(width: w, height: h, profile: profile)
            switch profile {
            case .swept:
                return [(CGPoint(x: w - d, y: 0), d * 0.5),
                        (CGPoint(x: w, y: h * 0.62), h * 0.42),
                        (CGPoint(x: w - w * 0.030, y: h), h * 0.16)]
            case .wedge:
                return [(CGPoint(x: w - d, y: 0), d * 0.22),
                        (CGPoint(x: w, y: h * 0.34), h * 0.12),
                        (CGPoint(x: w, y: h), h * 0.09)]
            }
        }

        let (roof, rising) = front()
        return [roof] + back() + rising
    }

    /// A closed outline through the given corners, each rounded by its own
    /// radius — or by as much of it as the two edges meeting there can spare.
    ///
    /// The clamp is what keeps a short vehicle from folding in on itself: ask
    /// for a radius longer than half the edge and two roundings would overlap
    /// and the path would cross itself.
    static func outline(_ corners: [(point: CGPoint, radius: CGFloat)]) -> Path {
        var path = Path()
        let n = corners.count
        guard n >= 3 else { return path }

        func step(_ a: CGPoint, _ b: CGPoint) -> (dx: CGFloat, dy: CGFloat, length: CGFloat) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
            return (dx / length, dy / length, length)
        }

        for index in 0..<n {
            let previous = corners[(index + n - 1) % n].point
            let corner = corners[index]
            let next = corners[(index + 1) % n].point
            let incoming = step(previous, corner.point)
            let outgoing = step(corner.point, next)
            let radius = min(corner.radius, incoming.length / 2, outgoing.length / 2)

            let start = CGPoint(x: corner.point.x - incoming.dx * radius,
                                y: corner.point.y - incoming.dy * radius)
            let end = CGPoint(x: corner.point.x + outgoing.dx * radius,
                              y: corner.point.y + outgoing.dy * radius)

            if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
            if radius > 0.01 { path.addQuadCurve(to: end, control: corner.point) }
        }
        path.closeSubpath()
        return path
    }

    /// The windscreen, as one line lying along the rake a little inside it.
    ///
    /// Cheap and decisive: without it a swept end is a wedge of nothing, and
    /// with it the end of the vehicle is obviously where the driver sits.
    static func windscreen(
        width w: CGFloat, height h: CGFloat, profile: Profile, front: Bool
    ) -> (CGPoint, CGPoint)? {
        let d = noseDepth(width: w, height: h, profile: profile)
        let top: CGPoint
        let bottom: CGPoint
        switch profile {
        case .swept:
            top = CGPoint(x: d, y: 0)
            bottom = CGPoint(x: 0, y: h * 0.62)
        case .wedge:
            top = CGPoint(x: d, y: 0)
            bottom = CGPoint(x: 0, y: h * 0.34)
        }
        // Along the rake, then in from it by a constant amount.
        let dx = bottom.x - top.x, dy = bottom.y - top.y
        let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
        let inward = CGPoint(x: dy / length, y: -dx / length)
        let inset = h * 0.17
        func at(_ t: CGFloat) -> CGPoint {
            let x = top.x + dx * t + inward.x * inset
            let y = top.y + dy * t + inward.y * inset
            return front ? CGPoint(x: x, y: y) : CGPoint(x: w - x, y: y)
        }
        return (at(0.16), at(0.74))
    }
}

// MARK: - Where the lines sit

/// The horizontal divisions of the drawing, for a given total height.
///
/// Pulled out of `WagonView` so that the SVG export in `Design/wagons/` can be
/// generated from the same numbers rather than from a second copy of them —
/// two sets of fractions that have to be kept in step is exactly the kind of
/// thing that quietly stops being true.
struct WagonMetrics {
    var height: CGFloat

    /// Clearance above the roof line, kept on every vehicle rather than only on
    /// the ones that use it, so that every roof in the train is at the same
    /// height. Only a locomotive draws anything up here.
    var roofClearance: CGFloat { height * 0.14 }
    var bodyHeight: CGFloat { height * 0.61 }
    var axle: CGFloat { height * 0.87 }
    var wheel: CGFloat { height * 0.17 }

    /// Where the flat part of the body starts and ends. Nothing painted on the
    /// side may stray outside it, or it ends up in a windscreen.
    func flat(_ spec: WagonSpec) -> (low: CGFloat, high: CGFloat) {
        let depth = WagonBody.noseDepth(
            width: spec.width, height: bodyHeight, profile: spec.cabProfile)
        return (spec.cabFront ? depth * 0.72 : bodyHeight * 0.22,
                spec.width - (spec.cabBack ? depth * 0.72 : bodyHeight * 0.22))
    }

    /// Where the roof line is actually flat.
    ///
    /// Not the same as `flat`, and the difference matters for anything drawn up
    /// against the roof. `flat` keeps clear of the *body* of the nose, which is
    /// enough for a class number sitting at mid height; the yellow marking sits
    /// a fifth of the way down from the roof, and at that height the nose has
    /// already begun to fall away — so a marking that started where `flat` does
    /// stuck out above the outline.
    func roof(_ spec: WagonSpec) -> (low: CGFloat, high: CGFloat) {
        let depth = WagonBody.noseDepth(
            width: spec.width, height: bodyHeight, profile: spec.cabProfile)
        let margin = bodyHeight * 0.10
        let low = spec.cabFront ? depth + margin : bodyHeight * 0.22
        let high = spec.width - (spec.cabBack ? depth + margin : bodyHeight * 0.22)
        return (low, max(low + 6, high))
    }

    /// The two axle centres, kept under the flat part of the body so that a
    /// long nose does not end up with a wheel beneath it.
    func axles(_ spec: WagonSpec) -> (CGFloat, CGFloat) {
        let flat = flat(spec)
        let low = max(wheel, flat.low + wheel * 0.4)
        let high = min(spec.width - wheel, flat.high - wheel * 0.4)
        return (low, max(low + wheel, high))
    }
}

// MARK: - The vehicle

/// One vehicle, drawn.
struct WagonView: View {
    let spec: WagonSpec
    /// Total height: the strip above the roof, the body, and the wheels.
    var height: CGFloat = 50
    /// Whether this is the coach the reader has tapped.
    var isSelected: Bool = false

    private var metrics: WagonMetrics { WagonMetrics(height: height) }
    private var roofClearance: CGFloat { metrics.roofClearance }
    private var bodyHeight: CGFloat { metrics.bodyHeight }
    private var axle: CGFloat { metrics.axle }
    private var wheel: CGFloat { metrics.wheel }

    private var bodyRect: CGRect {
        CGRect(x: 0, y: roofClearance, width: spec.width, height: bodyHeight)
    }

    private var outline: WagonBody {
        WagonBody(cabFront: spec.cabFront, cabBack: spec.cabBack, profile: spec.cabProfile)
    }

    /// White on a dark sheet, near-black on a light one. The operator's app is
    /// dark and the line in it is white; `primary` is that line in whichever
    /// appearance the reader is actually in.
    private var ink: Color { .primary }
    private var lineColour: Color {
        isSelected ? .accentColor : ink.opacity(spec.isClosed ? 0.32 : 0.85)
    }

    private var flat: (low: CGFloat, high: CGFloat) { metrics.flat(spec) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            wheels
            markingStripe.offset(y: roofClearance)
            outline.path(in: bodyRect)
                .stroke(
                    lineColour,
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2 : 1.4,
                        lineJoin: .round,
                        dash: spec.isClosed ? [3, 2.5] : []
                    )
                )
            Group {
                windscreens
                pantograph
                deckLine
                lettering
            }
            .offset(y: roofClearance)
        }
        .frame(width: spec.width, height: height, alignment: .topLeading)
    }

    // MARK: Under the solebar

    /// Two wheels, and only two. A bogie is four axles of detail nobody is
    /// reading at this size; a pair of circles is enough to say the body is a
    /// vehicle and not a container.
    private var wheels: some View {
        let (low, high) = metrics.axles(spec)
        return ZStack(alignment: .topLeading) {
            wheelMark(at: low)
            wheelMark(at: high)
        }
    }

    private func wheelMark(at centre: CGFloat) -> some View {
        // The wheels are part of the vehicle, so they are part of the
        // selection. Ringing the body alone left them behind in grey, which
        // read as a selected box sitting on somebody else's wheels.
        Circle()
            .strokeBorder(
                isSelected ? Color.accentColor : ink.opacity(spec.isClosed ? 0.28 : 0.65),
                lineWidth: isSelected ? 1.8 : 1.3
            )
            .frame(width: wheel, height: wheel)
            .position(x: centre, y: axle)
    }

    // MARK: On the ends

    @ViewBuilder
    private var windscreens: some View {
        Path { path in
            if spec.cabFront, let line = WagonBody.windscreen(
                width: spec.width, height: bodyHeight, profile: spec.cabProfile, front: true) {
                path.move(to: line.0)
                path.addLine(to: line.1)
            }
            if spec.cabBack, let line = WagonBody.windscreen(
                width: spec.width, height: bodyHeight, profile: spec.cabProfile, front: false) {
                path.move(to: line.0)
                path.addLine(to: line.1)
            }
        }
        .stroke(
            lineColour.opacity(0.75),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )
    }

    // MARK: On the roof

    /// The one mark that says a vehicle is the one pulling.
    @ViewBuilder
    private var pantograph: some View {
        if spec.role == .locomotive {
            // Single-arm, which is what a Re 460 carries: one knee leaning back
            // from the roof, and the contact strip across the top of it.
            let foot = flat.low + (flat.high - flat.low) * 0.34
            let head = foot + roofClearance * 0.75
            let bar = roofClearance * 0.9
            Path { path in
                path.move(to: CGPoint(x: foot, y: 0))
                path.addLine(to: CGPoint(x: head, y: -roofClearance * 0.62))
                path.move(to: CGPoint(x: head - bar, y: -roofClearance * 0.62))
                path.addLine(to: CGPoint(x: head + bar, y: -roofClearance * 0.62))
            }
            .stroke(
                lineColour.opacity(0.7),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )
        }
    }

    // MARK: On the side

    /// The yellow marking, along the top of the body inside the outline.
    @ViewBuilder
    private var markingStripe: some View {
        if spec.stripe != .none {
            let roof = metrics.roof(spec)
            let available = max(6, roof.high - roof.low)
            let run = spec.stripe == .full ? available : available * 0.46
            // A half-length band sits against the end it belongs to rather than
            // floating in the middle: the point of drawing half of it is to say
            // which half of the coach the first class is in.
            let start = spec.stripe == .trailingHalf ? roof.high - run : roof.low
            Capsule()
                .fill(Color(red: 1.0, green: 0.80, blue: 0.05).opacity(spec.isClosed ? 0.35 : 1))
                .frame(width: run, height: 3)
                .position(x: start + run / 2, y: bodyHeight * 0.20)
        }
    }

    /// The floor between the decks of a double-decker.
    ///
    /// Faint, and along the flat run of the body only: it is the one line here
    /// that is not the vehicle's own edge, and drawn at the weight of the
    /// outline it would read as two coaches stacked rather than one coach with
    /// two floors. It runs under the lettering rather than around it, which is
    /// what the number painted on the side of a real one does.
    @ViewBuilder
    private var deckLine: some View {
        if spec.doubleDeck {
            Path { path in
                path.move(to: CGPoint(x: flat.low, y: bodyHeight * 0.5))
                path.addLine(to: CGPoint(x: flat.high, y: bodyHeight * 0.5))
            }
            .stroke(
                isSelected ? Color.accentColor.opacity(0.5)
                           : ink.opacity(spec.isClosed ? 0.14 : 0.28),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
    }

    /// The class number, and the glyph that goes with it.
    ///
    /// Both, side by side, where the vehicle has both — a `W2` is a dining car
    /// *and* a second-class coach. Only one where it has one, which is a
    /// restaurant car with no class of its own, or an ordinary coach.
    @ViewBuilder
    private var lettering: some View {
        HStack(spacing: bodyHeight * 0.12) {
            if let symbol = spec.symbol {
                Image(systemName: symbol)
                    .font(.system(size: bodyHeight * 0.42, weight: .medium))
            }
            if let plate = spec.plate {
                Text(plate)
                    .font(.system(size: bodyHeight * 0.48, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(
            isSelected ? AnyShapeStyle(Color.accentColor)
                       : AnyShapeStyle(ink.opacity(spec.isClosed ? 0.4 : 0.9))
        )
        .position(x: (flat.low + flat.high) / 2, y: bodyHeight * 0.58)
    }
}

// MARK: - Scale

enum Wagon {
    /// Points per metre of real vehicle.
    ///
    /// Deliberately generous. A coach drawn as tall as it is wide reads as a
    /// square with a number in it; at this scale a 26.4 m coach is 84 points
    /// against a 32 point body, which is roughly the proportion of the real
    /// thing and unmistakably a wagon.
    static let pointsPerMetre: CGFloat = 3.2
    static let minWidth: CGFloat = 52
    static let maxWidth: CGFloat = 110

    /// The drawn length of a vehicle whose real length is known.
    ///
    /// Nil where it is not, or where what came back is not a length: the field
    /// is optional in the register and zero in a good number of records.
    static func width(metres: Double?) -> CGFloat? {
        guard let metres, metres > 4, metres < 200 else { return nil }
        return min(maxWidth, max(minWidth, CGFloat(metres) * pointsPerMetre))
    }
}

// MARK: - The vocabulary, in one place

/// Every shape this file can draw, side by side.
///
/// The same set is exported to `Design/wagons/` as SVG, from this same
/// geometry, so the shapes can be opened and looked at outside Xcode.
#Preview("Wagons") {
    let ic = Wagon.width(metres: 26.4) ?? 84
    let regio = Wagon.width(metres: 18.7) ?? 60
    let loco = Wagon.width(metres: 18.5) ?? 59

    return ScrollView(.horizontal) {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 4) {
                WagonView(spec: WagonSpec(role: .locomotive, width: loco, cabFront: true, cabBack: true))
                WagonView(spec: WagonSpec(width: ic, stripe: .full, plate: "1"))
                WagonView(spec: WagonSpec(width: ic, symbol: "fork.knife"))
                WagonView(spec: WagonSpec(width: ic, stripe: .trailingHalf, plate: "1·2"))
                WagonView(spec: WagonSpec(width: ic, plate: "2"))
                WagonView(spec: WagonSpec(width: ic, cabBack: true, plate: "2"))
            }
            HStack(spacing: 4) {
                WagonView(spec: WagonSpec(width: regio, cabFront: true, plate: "2"), isSelected: true)
                WagonView(spec: WagonSpec(width: regio, stripe: .leadingHalf, plate: "1·2"))
                WagonView(spec: WagonSpec(width: regio, cabBack: true, plate: "2"))
            }
            HStack(spacing: 4) {
                WagonView(spec: WagonSpec(role: .van, width: Wagon.minWidth, symbol: "suitcase.fill"))
                WagonView(spec: WagonSpec(width: Wagon.maxWidth, cabFront: true, plate: "2", isClosed: true))
            }
        }
        .padding(26)
    }
    .preferredColorScheme(.dark)
}
