import SwiftUI
import TransitCore

/// One disruption notice, as a row.
///
/// Deliberately *not* a card of its own. Drawn with its own background and
/// border it sat inset from the formation above it and the stop list below,
/// with a different corner radius from either — a third shape on a panel that
/// has two. So it is an ordinary list row with a tinted `listRowBackground`,
/// which means the inset-grouped list gives it exactly the geometry every other
/// row on the panel has, and there is nothing left to keep in step by hand.
///
/// The feed gives six texts and they are not equal. Laid out in full they took
/// more of the panel than the train did: a summary, an impact, a cause, a
/// duration stamp and a source label, three of them competing on one line and
/// wrapping into each other. The row shows the two that answer *what* and
/// *why*, and keeps the rest behind **More**.
struct DisruptionRow: View {
    let situation: Situation
    /// Whether this is one of the notices worth colouring for. Live incidents
    /// are; planned works, which sit below the stop list precisely because they
    /// are not urgent, are drawn in the panel's ordinary voice.
    var prominent: Bool = true

    @State private var expanded = false

    /// What More reveals. Duration last: a date range is the least of it and
    /// the one most likely to be a stamp nobody reads.
    private var extra: [String] {
        [situation.consequence, situation.detail, situation.reason, situation.advice,
         situation.duration]
            .compactMap { $0 }
            .filter { $0 != situation.summary }
    }

    private var hasMore: Bool { !extra.isEmpty || situation.link != nil }
    private var tint: Color { prominent ? .orange : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                    // Holds the first line rather than centring on the block, so
                    // a summary that wraps to two lines does not leave the icon
                    // floating between them.
                    .frame(height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    if let headline = situation.headline {
                        Text(headline)
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let cause = situation.causeText {
                        Text(cause).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if hasMore {
                    Button(expanded ? "Less" : "More") {
                        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(prominent ? .orange : .accentColor)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(extra, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let link = situation.link, let url = URL(string: link) {
                        Link(destination: url) {
                            Label(url.host() ?? link, systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        .padding(.top, 2)
                    }
                }
                // Indented to the summary rather than to the row, so the detail
                // reads as belonging to the line above it.
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if situation.planned { return "hammer.fill" }
        switch situation.cause {
        case "liftFailure": return "figure.roll"
        case "poorWeather": return "cloud.heavyrain.fill"
        case "vehicleFailure": return "wrench.adjustable.fill"
        case "emergencyServicesCall": return "flame.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

extension Situation {
    /// The tint a live notice's row is filled with. Kept beside the row rather
    /// than at each call site so the two lists cannot drift apart.
    static let alertBackground = Color.orange.opacity(0.18)
}
