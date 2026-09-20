import SwiftUI

#if canImport(ActivityKit) && os(iOS)

/// Lock-screen / banner body of a pinned departure or arrival.
///
/// Caption and clock share a row. The remaining time sits on the right of the
/// two service lines — line + destination, then platform — so it occupies
/// the same height as both.
public struct TripLockScreenView: View {
    public var attributes: TripActivityAttributes
    public var state: TripActivityAttributes.ContentState
    public var isStale: Bool

    public init(
        attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState,
        isStale: Bool = false
    ) {
        self.attributes = attributes
        self.state = state
        self.isStale = isStale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TripCaptionRow(attributes: attributes, state: state, compact: false)
            TripServiceAndRemaining(attributes: attributes, state: state, compact: false, isStale: isStale)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// "Arrival to Mülenen" with the clock and a small +3 on the same line.
/// The remaining minutes already include that delay.
struct TripCaptionRow: View {
    var attributes: TripActivityAttributes
    var state: TripActivityAttributes.ContentState
    var compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 8) {
            Text(TripActivityFormat.caption(kind: attributes.kind, station: attributes.station))
                .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: compact ? 6 : 8)
            if state.cancelled {
                Text("Cancelled")
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                if let delay = TripActivityFormat.delayText(
                    minutes: state.delayMinutes, mode: attributes.mode
                ) {
                    Text(delay)
                        .font(
                            compact
                                ? .caption.weight(.semibold).monospacedDigit()
                                : .subheadline.weight(.semibold).monospacedDigit()
                        )
                        .foregroundStyle(TripActivityFormat.delayColor)
                }
                Text(TripActivityFormat.clock(state.expected))
                    .font(
                        compact
                            ? .caption.weight(.semibold).monospacedDigit()
                            : .subheadline.weight(.semibold).monospacedDigit()
                    )
                    .foregroundStyle(showsDelay ? TripActivityFormat.delayColor : Color.primary)
            }
        }
    }

    private var showsDelay: Bool {
        TripActivityFormat.delayText(minutes: state.delayMinutes, mode: attributes.mode) != nil
    }
}

/// Line + destination and platform on the left; "in 42 min" on the right.
/// Remaining minutes are counted from the delayed time, so the +3 lives on
/// the caption row instead.
struct TripServiceAndRemaining: View {
    var attributes: TripActivityAttributes
    var state: TripActivityAttributes.ContentState
    var compact: Bool
    var isStale: Bool

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: compact ? 8 : 12) {
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                LineWithDestination(
                    line: attributes.line,
                    mode: attributes.mode,
                    headline: TripActivityFormat.headline(
                        kind: attributes.kind,
                        station: attributes.station,
                        destination: attributes.destination
                    ),
                    compact: compact
                )
                if let platform = state.platform, !platform.isEmpty {
                    Text(TripActivityFormat.platformPhrase(kind: attributes.kind, platform: platform))
                        .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                        .foregroundStyle(
                            state.platformChanged ? TripActivityFormat.delayColor : Color.secondary
                        )
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            remainingColumn
        }
    }

    @ViewBuilder
    private var remainingColumn: some View {
        if state.cancelled {
            EmptyView()
        } else {
            TripRemainingLabel(
                expected: state.expected,
                fallbackMinutes: state.remainingMinutes,
                isStale: isStale,
                size: compact ? 22 : 30,
                compact: compact
            )
        }
    }
}

/// iOS renders the changing minutes even when the app and extension are asleep.
/// An app update at the event minute changes the label to "now". ActivityKit's
/// stale presentation provides a fallback when the app is suspended, but that
/// transition is not guaranteed to happen exactly at the stale date.
struct TripRemainingLabel: View {
    var expected: Date
    var fallbackMinutes: Int
    var isStale: Bool
    var size: CGFloat
    var compact: Bool
    var minimal = false

    var body: some View {
        label
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private var label: some View {
        if isStale || fallbackMinutes <= 0 {
            Text("now")
        } else if #available(iOS 18.0, *) {
            let style = TripActivityFormat.countdownStyle(until: expected, minimal: minimal)
            // TimeDataSource text otherwise reserves a very wide frame in the
            // system's remote renderer. Size from ordinary text, then right-align
            // the live text inside it. Reserve the minute form even during an
            // hours-long wait, so crossing below an hour needs no app update.
            ZStack(alignment: .trailing) {
                Text(minimal ? "in 59m" : "in 59 min")
                Text(style.format(Date()))
            }
            .fixedSize(horizontal: true, vertical: false)
            // A minimal island can offer only a circle's width. Its timer must
            // accept that width instead of carrying the larger label's ideal size.
            .frame(width: minimal ? 28 : nil)
            // The remote timer's line box can be taller than ordinary Text's.
            // Leave vertical room so its glyphs are not clipped by the overlay.
            .padding(.vertical, 2)
            .hidden()
            .overlay(alignment: minimal ? .center : .trailing) {
                Text(.currentDate, format: style)
                    .multilineTextAlignment(minimal ? .center : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    // Text applies its environment locale at render time.
                    .environment(\.locale, style.locale)
            }
        } else {
            // iOS 17 has no minute-only system format. Keep its existing update path.
            Text(
                compact
                    ? TripActivityFormat.compactRemaining(minutes: fallbackMinutes)
                    : TripActivityFormat.remainingPhrase(minutes: fallbackMinutes)
            )
        }
    }
}

/// Expanded Dynamic Island: same two-column block as the lock screen, just
/// smaller, so the remaining time is not a third clipped row.
public struct TripIslandExpandedView: View {
    public var attributes: TripActivityAttributes
    public var state: TripActivityAttributes.ContentState
    public var isStale: Bool

    public init(
        attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState,
        isStale: Bool = false
    ) {
        self.attributes = attributes
        self.state = state
        self.isStale = isStale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TripCaptionRow(attributes: attributes, state: state, compact: true)
            TripServiceAndRemaining(attributes: attributes, state: state, compact: true, isStale: isStale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct TripIslandCompactLeading: View {
    public var line: String
    public var mode: String

    public init(line: String, mode: String) {
        self.line = line
        self.mode = mode
    }

    public var body: some View {
        TripLineBadge(line: line, mode: mode, compact: true)
    }
}

public struct TripIslandCompactTrailing: View {
    public var state: TripActivityAttributes.ContentState
    public var isStale: Bool

    public init(state: TripActivityAttributes.ContentState, isStale: Bool = false) {
        self.state = state
        self.isStale = isStale
    }

    public var body: some View {
        if state.cancelled {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        } else {
            TripRemainingLabel(
                expected: state.expected,
                fallbackMinutes: state.remainingMinutes,
                isStale: isStale,
                size: 13,
                compact: true
            )
        }
    }
}

public struct TripIslandMinimal: View {
    public var state: TripActivityAttributes.ContentState
    public var isStale: Bool
    public var mode: String

    public init(state: TripActivityAttributes.ContentState, mode: String, isStale: Bool = false) {
        self.state = state
        self.isStale = isStale
        self.mode = mode
    }

    public var body: some View {
        if state.cancelled {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        } else {
            TripRemainingLabel(
                expected: state.expected,
                fallbackMinutes: state.remainingMinutes,
                isStale: isStale,
                size: 10,
                compact: true,
                minimal: true
            )
                .foregroundStyle(
                    TripActivityFormat.delayText(minutes: state.delayMinutes, mode: mode) == nil
                        ? Color.primary : TripActivityFormat.delayColor
                )
        }
    }
}

/// Line plate and destination on one row. The plate is the destination's
/// cap-height plus three points above and below, centred on the letters so
/// the colour does not hang off the baseline.
private struct LineWithDestination: View {
    var line: String
    var mode: String
    var headline: String
    var compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            TripLineBadge(line: line, mode: mode, compact: compact, fillHeight: true)
                .frame(height: DestinationMetrics.plateHeight(compact: compact))
            Text(headline)
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .alignmentGuide(VerticalAlignment.center) { d in
                    d[.firstTextBaseline] - DestinationMetrics.capHeight(compact: compact) / 2
                }
        }
    }
}

struct TripLineBadge: View {
    var line: String
    var mode: String
    var compact = false
    var fillHeight = false

    private var label: String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ext" : trimmed
    }

    var body: some View {
        Text(label)
            .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, compact ? 4 : 6)
            .frame(maxHeight: fillHeight ? .infinity : nil)
            .padding(.vertical, fillHeight ? 0 : (compact ? 1 : 3))
            .background(TripActivityFormat.color(mode: mode), in: RoundedRectangle(cornerRadius: compact ? 3 : 5))
            .foregroundStyle(.white)
    }
}

#endif
