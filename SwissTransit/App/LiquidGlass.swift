import SwiftUI

/// Liquid Glass for the map's own controls.
///
/// iOS 26 draws the real material — refraction, specular highlights, sampling
/// of whatever is under the control. Older systems keep the ultra-thin
/// material those controls already had, so the layout does not change.
///
/// These sit in the *functional* layer above the map. Content — sheets, the
/// loading curtain, the frame readout — stays on standard materials. See
/// Apple's materials guidance: Liquid Glass is for controls, not for the
/// document.
struct LiquidGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    /// The glass a map control sits on. Capsule, circle, or a continuous
    /// rounded rectangle — whatever the control already was.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: shape
            )
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
