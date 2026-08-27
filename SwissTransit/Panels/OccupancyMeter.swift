import SwiftUI
import TransitCore

/// How full a vehicle is, as three bars.
///
/// Three because the forecast has three honest levels and no more: OJP states a
/// SIRI occupancy enumeration, Swiss operators use `manySeatsAvailable`,
/// `fewSeatsAvailable` and `standingRoomOnly`, and inventing a finer scale
/// would be drawing precision the source does not have.
///
/// Bars rather than a word, because this sits at the right-hand end of a stop
/// row beside a platform chip and a time, and there is no room for "Standing
/// only" there. The word is used where there is room — see `OccupancySummary`.
struct OccupancyMeter: View {
    let level: OccupancyLevel
    var height: CGFloat = 11

    private var filled: Int {
        switch level.crowding {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case nil: return 0
        }
    }

    /// Green, amber, red — the one place in this app a traffic-light scale is
    /// the right idiom, because it is the scale every operator already prints
    /// beside a departure and the one passengers read without a legend.
    private var tint: Color {
        switch level.crowding {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case nil: return .secondary
        }
    }

    var body: some View {
        if filled > 0 {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        // Rising bars, so the shape carries the reading as well
                        // as the colour — which is what makes it legible to
                        // somebody who cannot separate the three hues.
                        .frame(width: 3, height: height * (0.5 + 0.25 * Double(step)))
                        .foregroundStyle(step < filled ? tint : tint.opacity(0.22))
                }
            }
            .accessibilityElement()
            .accessibilityLabel(level.text)
        }
    }
}

/// The load in words, for the panel header where there is room for words.
///
/// Both classes where they differ, one where they agree: "Few seats free" says
/// everything when first and second are alike, and printing it twice reads as a
/// fault rather than as thoroughness.
struct OccupancySummary: View {
    let occupancy: Occupancy

    var body: some View {
        if let worst = occupancy.worst {
            HStack(spacing: 6) {
                OccupancyMeter(level: worst, height: 10)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var text: String {
        guard let first = occupancy.firstClass, let second = occupancy.secondClass,
              first != second
        else { return occupancy.worst?.text ?? "" }
        return "1st \(first.text.lowercased()) · 2nd \(second.text.lowercased())"
    }
}
