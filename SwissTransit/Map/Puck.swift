import UIKit

// The location marker, drawn the way this phone draws it everywhere else.
//
// Mapbox's `location-indicator` layer takes three images and treats them
// differently, which is the whole reason the parts are split up the way they
// are below: the **shadow** goes underneath and does not turn, the **bearing**
// image sits above it and is rotated to the heading, and the **top** image goes
// over both and does not turn either. So the cone has to be the middle one and
// has to be drawn centred on its own image, with its point at the centre and
// its mouth toward the top — whatever direction it ends up pointing is the
// layer's business, not the drawing's.
//
// Drawn in code rather than shipped as assets. They are four circles and a
// wedge, they have to match the system's colour rather than a file's, and an
// asset catalogue entry would be three PNGs per image that nobody could correct
// without a drawing program.
enum Puck {

    /// The blue every map on this phone uses for "you".
    static let tint = UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)

    /// The dot: a blue disc inside a white ring.
    ///
    /// The ring is what makes it legible on a dark basemap and on a light one
    /// without changing colour between them, which is why every map has one.
    static let dot: UIImage = image(side: 26) { context, rect in
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: circle(at: centre, diameter: 22))
        context.setFillColor(tint.cgColor)
        context.fillEllipse(in: circle(at: centre, diameter: 15))
    }

    /// The shadow under it.
    ///
    /// A radial gradient rather than a blurred layer: this is a still image
    /// drawn once, and a gradient is exact, cheap and has no dependency on
    /// Core Image. It reaches a little past the white ring, so the marker
    /// stands off a busy map without a hard edge anywhere.
    static let shadow: UIImage = image(side: 34) { context, rect in
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                UIColor.black.withAlphaComponent(0.30).cgColor,
                UIColor.black.withAlphaComponent(0.22).cgColor,
                UIColor.black.withAlphaComponent(0.0).cgColor,
            ] as CFArray,
            locations: [0.0, 0.62, 1.0]
        ) else { return }
        context.drawRadialGradient(
            gradient, startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: 15, options: []
        )
    }

    /// The heading cone, pointing up.
    ///
    /// Its point sits at the centre of the image because that is the point the
    /// layer rotates about, and the image is square and generous so the cone is
    /// never clipped at any angle. It fades out along its length rather than
    /// ending in a line: the further from you it is, the less the heading
    /// actually claims.
    static let cone: UIImage = image(side: 76) { context, rect in
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let reach: CGFloat = 34
        // Sixty degrees, which is about what a compass fix is worth and about
        // what the system's own cone spans.
        let half = CGFloat.pi / 6

        let wedge = CGMutablePath()
        wedge.move(to: centre)
        wedge.addArc(
            center: centre, radius: reach,
            // Screen coordinates run down, and "up" is -y — so the arc is
            // centred on -90°.
            startAngle: -.pi / 2 - half, endAngle: -.pi / 2 + half,
            clockwise: false
        )
        wedge.closeSubpath()

        context.saveGState()
        context.addPath(wedge)
        context.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                tint.withAlphaComponent(0.55).cgColor,
                tint.withAlphaComponent(0.28).cgColor,
                tint.withAlphaComponent(0.0).cgColor,
            ] as CFArray,
            locations: [0.0, 0.55, 1.0]
        ) {
            context.drawRadialGradient(
                gradient, startCenter: centre, startRadius: 0,
                endCenter: centre, endRadius: reach, options: []
            )
        }
        context.restoreGState()
    }

    // MARK: - Drawing

    private static func circle(at centre: CGPoint, diameter: CGFloat) -> CGRect {
        CGRect(
            x: centre.x - diameter / 2, y: centre.y - diameter / 2,
            width: diameter, height: diameter
        )
    }

    /// A square image at the screen's own scale, so the layer sizes it in
    /// points and it is sharp on every device.
    private static func image(
        side: CGFloat, _ draw: (CGContext, CGRect) -> Void
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            draw(context.cgContext, bounds)
        }
    }
}
