import SwiftUI
import TransitCore

/// The clock the map is drawn against.
///
/// Positions come from the timetable rather than from observation, so "now" is
/// just a number the renderer is handed — which means the same code shows any
/// hour. What used to bound it was the *snapshot*: SIRI-ET describes the fleet
/// around the minute it was fetched, journeys drop out once they have run and
/// were never sent before they were filed, so an hour either way most of the
/// country was simply missing.
///
/// This control was built around that. It measured the falloff and drew it as a
/// strip of bars under the buttons, so the thinning was something you could see
/// coming rather than a map that quietly emptied — and the steps stopped at the
/// edge of what the snapshot could answer for, which was about two hours.
///
/// The archive removed the reason for all of it. `timetable.bin` is a year of
/// service days and answers for any minute in it off the file, so there is no
/// falloff to draw and no couple of hours to stay inside. The bars had also
/// stopped being true: with the map drawn from the timetable, the fleet in hand
/// is whatever window was last expanded around the clock — half an hour behind
/// and an hour ahead — so the strip was drawing the shape of the *expansion
/// window*, measured against a "now" the clock had already been dragged away
/// from, and a scrub of an hour or two left it empty with every step button
/// dead. So the strip is gone, and the picker offers the whole year.
struct TimeControl: View {
    @Bindable var model: AppModel
    @State private var offsetMinutes: Double = 0
    @State private var showPicker = false
    @State private var pickedDate = Date()

    private let steps: [Int] = [5, 15, 30]

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.isClockPlaying.toggle()
            } label: {
                Image(systemName: model.isClockPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isClockPlaying ? "Pause the map" : "Play the map")

            ForEach(steps.reversed(), id: \.self) { minutes in
                stepButton(-minutes)
            }

            Button {
                pickedDate = shown
                showPicker = true
            } label: {
                VStack(spacing: 0) {
                    Text(Format.time(model.clock.nowSeconds()))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 84)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(steps, id: \.self) { minutes in
                stepButton(minutes)
            }

            if offsetMinutes != 0 || !model.isClockPlaying {
                Button {
                    set(offset: 0)
                    model.clock.reset()
                    model.isClockPlaying = true
                } label: {
                    Text("Now").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        // The clock may already be offset before this view exists — restored
        // state, or a development launch argument. Read it rather than assume
        // zero, or the buttons would step from a number the clock disagrees with.
        .onAppear { offsetMinutes = (model.clock.offset() / 60).rounded() }
        .sheet(isPresented: $showPicker) {
            TimePickerSheet(
                date: $pickedDate,
                bounds: model.timeSpan,
                onPick: applyPickedDate
            )
            .presentationDetents([.height(380)])
        }
    }

    private var shown: Date {
        Date(timeIntervalSince1970: TimeInterval(model.clock.nowSeconds()))
    }

    /// The offset while the view is on today, the date once it is not.
    ///
    /// "+31h 40m" is a true statement about the clock and a useless one about
    /// the map: past a day out what somebody wants to read under the time is
    /// which day they are looking at.
    private var subtitle: String? {
        guard offsetMinutes != 0 else { return nil }
        let moment = shown
        guard Calendar.current.isDateInToday(moment) else { return Format.day(moment) }
        return Clock.formatOffset(offsetMinutes * 60)
    }

    private func stepButton(_ minutes: Int) -> some View {
        Button {
            set(offset: offsetMinutes + Double(minutes))
        } label: {
            VStack(spacing: 2) {
                Image(systemName: minutes < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text("\(abs(minutes))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
            .frame(width: 26, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canStep(minutes) ? .primary : .tertiary)
        .disabled(!canStep(minutes))
    }

    /// A step past the end of the archive is not offered.
    ///
    /// In practice this only ever refuses at the two edges of the packed year,
    /// where there is genuinely nothing to draw — not, as it once did, an hour
    /// out on a thin snapshot.
    private func canStep(_ minutes: Int) -> Bool {
        model.scrubRange.contains(offsetMinutes + Double(minutes))
    }

    private func set(offset minutes: Double) {
        let range = model.scrubRange
        let clamped = min(max(minutes, range.lowerBound), range.upperBound)
        guard clamped != offsetMinutes else {
            // The picker can land back on the same minute after a scrub that
            // the clock has already applied; still ask for a frame so a pause
            // at "now" is visible at once.
            model.requestTick()
            return
        }
        offsetMinutes = clamped
        model.clock.setOffset(clamped * 60)
        // Coalesced, not queued. A drag emits a value per frame, and one
        // `Task { await tick() }` each left 239 full ticks in flight on a main
        // actor that then could not answer a tap. See `AppModel.requestTick`.
        model.requestTick()
    }

    private func applyPickedDate(_ chosen: Date) {
        let delta = chosen.timeIntervalSince1970 - Date().timeIntervalSince1970
        set(offset: (delta / 60).rounded())
    }
}

/// Pick a moment — any moment the archive covers.
///
/// Date as well as time, which is the whole difference the timetable made. The
/// sheet used to offer an hour wheel bounded by a measured couple of hours,
/// because that was all a downloaded snapshot could answer for; a packed year
/// answers for next Tuesday morning as readily as for this afternoon.
struct TimePickerSheet: View {
    @Binding var date: Date
    let bounds: ClosedRange<Date>
    let onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revertTo: Date?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DatePicker(
                    "", selection: $date, in: bounds,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .onChange(of: date) { _, chosen in
                    onPick(chosen)
                }

                Text("The timetable covers \(Format.day(bounds.lowerBound)) to \(Format.day(bounds.upperBound)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .navigationTitle("Show the map at")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if let revertTo { onPick(revertTo) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { revertTo = date }
        }
    }
}

#Preview("Time controls") {
    ZStack {
        Color.black.ignoresSafeArea()
        TimeControl(model: AppModel())
    }
    .preferredColorScheme(.dark)
}

#Preview("Time picker") {
    TimePickerSheet(
        date: .constant(Date()),
        bounds: Date().addingTimeInterval(-86_400 * 30)...Date().addingTimeInterval(86_400 * 300),
        onPick: { _ in }
    )
    .preferredColorScheme(.dark)
}
