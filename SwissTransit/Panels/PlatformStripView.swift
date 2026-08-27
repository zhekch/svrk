import SwiftUI
import TransitCore

/// The platform, end to end, with the train on it and the ways off it.
///
/// The drawing above this one is a picture of *the train*: it is as long as the
/// train is, its sector bands are as wide as the coaches standing in them, and
/// short trains are stretched to fill the card because scale was never what it
/// was for. All of which is right for "which coach", and none of which can
/// answer the question that follows — the stairs are ninety metres behind you.
///
/// So this is a picture of *the platform* instead, and the one rule it keeps is
/// the one the train drawing gives up: everything on it is where it really is.
/// The bar is the platform's true length, the train sits at its true position
/// along it, and a staircase at 44% is drawn 44% of the way across. That is the
/// whole reason it exists, so nothing here may be stretched to look better.
///
/// It fits the panel rather than scrolling with the train above it. A platform
/// you have to scroll to see the end of cannot tell you how far away the end is.
struct PlatformStripView: View {
    let strip: PlatformStrip
    /// Where the train stands, or nil when it could not be placed — an unmapped
    /// geometry, or a formation with no length. The platform and its stairs are
    /// still worth drawing without it.
    let span: StripSpan?
    /// The sectors of the train, front first, each as a share of the train's
    /// length. Taken from the drawing above so the two cannot disagree about
    /// which coaches are in sector C.
    let sectors: [(sector: String?, share: Double)]

    private static let barHeight: CGFloat = 16
    private static let markerSize: CGFloat = 13
    /// How many rows the markers may use before they start sharing one.
    ///
    /// Two, because Zürich's platform 10 has a staircase, a lift and an
    /// escalator inside five percent of its length and one row of glyphs drew
    /// them on top of each other — a single unreadable blot at exactly the
    /// place with the most ways up. Stacking is vertical only: moving a marker
    /// sideways to make room would be moving it away from where it is, which is
    /// the one thing this drawing may not do.
    private static let markerRows = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    platform
                    if let span { train(in: width, span: span) }
                    ForEach(Array(Self.rows(strip.access, in: width).enumerated()), id: \.offset) {
                        _, placed in
                        marker(placed.point, at: placed.x, row: placed.row)
                    }
                }
            }
            .frame(height: Self.barHeight + markerBandHeight + 3)

            caption
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    // MARK: - The platform itself

    /// How much room the markers need above the bar: one row, or two where
    /// something on this platform collides.
    private var markerBandHeight: CGFloat {
        CGFloat(Self.markerRows) * Self.markerSize
    }

    private var platform: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.quaternary)
            .frame(height: Self.barHeight)
            .padding(.top, markerBandHeight + 3)
    }

    /// The stretch of platform the train covers, with its sectors on it.
    ///
    /// The nose gets an edge the tail does not: a train is not a symmetrical
    /// object and which end of the platform its front door is at is the fact
    /// somebody is standing there working out.
    private func train(in width: CGFloat, span: StripSpan) -> some View {
        let from = CGFloat(span.lower) * width
        let to = CGFloat(span.upper) * width
        let extent = to - from
        return HStack(spacing: 0) {
            ForEach(Array(bands(span: span).enumerated()), id: \.offset) { index, band in
                // In points, not in shares. Comparing the *share* against a
                // point width silently hid every letter: a quarter of a train
                // is 0.25, which is not greater than 11, so no sector on any
                // platform in the country was ever labelled.
                let points = band.width * extent
                ZStack {
                    Rectangle().fill(.tint.opacity(0.25))
                    if let sector = band.sector, points > 11 {
                        Text(sector)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tint)
                            .fixedSize()
                    }
                }
                .frame(width: points)
                // A hairline where one sector becomes the next. Without it the
                // bands are one continuous block of tint and the letters float
                // in it with nothing to say where C stops and D starts.
                .overlay(alignment: .leading) {
                    if index > 0 {
                        Rectangle().fill(.background).frame(width: 1).opacity(0.7)
                    }
                }
            }
        }
        .frame(height: Self.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(alignment: span.reversed ? .trailing : .leading) {
            Rectangle().fill(.tint).frame(width: 2)
        }
        .padding(.top, markerBandHeight + 3)
        .offset(x: from)
    }

    /// The sectors as fractions *of the train*, in platform order.
    ///
    /// The list arrives front-first, which on a train standing the other way
    /// round is right-to-left on the strip — so it is reversed rather than
    /// re-sorted. Sorting into A, B, C would throw away the one thing the order
    /// says, which is which way the train is pointing; see `orderedSectors`.
    private func bands(span: StripSpan) -> [(sector: String?, width: CGFloat)] {
        let total = sectors.reduce(0) { $0 + $1.share }
        guard total > 0 else { return [] }
        let scaled = sectors.map { (sector: $0.sector, width: CGFloat($0.share / total)) }
        return span.reversed ? scaled.reversed() : scaled
    }

    // MARK: - The ways off

    private func marker(_ point: AccessPoint, at x: CGFloat, row: Int) -> some View {
        Image(systemName: Self.symbol(point.kind))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(point.kind == .stairs ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(width: Self.markerSize, height: Self.markerSize)
            // The lowest row sits against the bar, so a lone marker is next to
            // the platform rather than floating above it.
            .offset(x: x, y: CGFloat(Self.markerRows - 1 - row) * Self.markerSize)
    }

    /// Each access point's horizontal place, and which row it goes in.
    ///
    /// Walked in platform order, which `PlatformStrip` guarantees, so a
    /// collision is always with something already placed. A marker takes the
    /// lowest row that has room for it and falls back to the bottom one when
    /// every row is occupied — three ways up within one glyph's width is rare
    /// enough that the third may overlap.
    static func rows(
        _ access: [AccessPoint], in width: CGFloat
    ) -> [(point: AccessPoint, x: CGFloat, row: Int)] {
        var lastX = [CGFloat](repeating: -.greatestFiniteMagnitude, count: markerRows)
        var out: [(point: AccessPoint, x: CGFloat, row: Int)] = []
        for point in access {
            // Centred on its fraction, then held inside the bar at both ends: an
            // access point at 0 is at the very end of the platform and its icon
            // would otherwise sit half off the card.
            let x = min(
                max(0, CGFloat(point.fraction) * width - markerSize / 2),
                max(0, width - markerSize)
            )
            let row = (0..<markerRows).first { x - lastX[$0] >= markerSize } ?? 0
            lastX[row] = x
            out.append((point, x, row))
        }
        return out
    }

    /// The four kinds, as the symbols that read fastest at ten points.
    ///
    /// A lift gets the doors rather than an arrow: `arrow.up.arrow.down` is
    /// also the sort symbol and at this size the two are the same picture.
    ///
    /// There is no escalator in SF Symbols — `escalator.up` reads like it ought
    /// to exist and does not, and a missing symbol draws nothing at all, which
    /// is how two escalators at Zürich came to be legended and then not drawn.
    /// The arrow is the substitute: up and along is what an escalator does, and
    /// it is the one glyph here that is not a figure, so it does not read as a
    /// third kind of person.
    static func symbol(_ kind: AccessPoint.Kind) -> String {
        switch kind {
        case .stairs: return "figure.stairs"
        case .escalator: return "arrow.up.right"
        case .lift: return "door.sliding.right.hand.closed"
        case .ramp: return "figure.roll"
        }
    }

    // MARK: - Words

    /// What the strip says out loud, for anyone who is not looking at it.
    ///
    /// The one thing a screen reader cannot get from the drawing is the drawing,
    /// so this is the drawing in words: how long the platform is, and what is
    /// where along it.
    private var spoken: String {
        var parts = ["Platform \(Int(strip.length.rounded())) metres"]
        if let span {
            let from = Int((span.lower * strip.length).rounded())
            let to = Int((span.upper * strip.length).rounded())
            parts.append("train from \(from) to \(to) metres")
        }
        for point in strip.access {
            let at = Int((point.fraction * strip.length).rounded())
            parts.append("\(Self.name(point.kind)) at \(at) metres")
        }
        return parts.joined(separator: ", ")
    }

    static func name(_ kind: AccessPoint.Kind) -> String {
        switch kind {
        case .stairs: return "stairs"
        case .escalator: return "escalator"
        case .lift: return "lift"
        case .ramp: return "ramp"
        }
    }

    /// The legend, which says only what is actually on this platform.
    ///
    /// A fixed legend listing all four would put "ramp" under every platform in
    /// the country and mean nothing at three of them. The count goes in front
    /// of the word where there is more than one, because "3 stairs" and "stairs"
    /// answer different questions.
    private var caption: some View {
        HStack(spacing: 10) {
            Text("\(Int(strip.length.rounded())) m")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            ForEach(Self.kindsPresent(strip.access), id: \.kind) { entry in
                HStack(spacing: 3) {
                    Image(systemName: Self.symbol(entry.kind)).font(.system(size: 9))
                    Text(entry.count > 1 ? "\(entry.count) \(Self.name(entry.kind))" : Self.name(entry.kind))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    static func kindsPresent(_ access: [AccessPoint]) -> [(kind: AccessPoint.Kind, count: Int)] {
        // Fixed order rather than order of appearance, so the legend does not
        // reshuffle itself as the reader steps through the stops of a run.
        let order: [AccessPoint.Kind] = [.lift, .escalator, .stairs, .ramp]
        return order.compactMap { kind in
            let count = access.count { $0.kind == kind }
            return count > 0 ? (kind, count) : nil
        }
    }
}
