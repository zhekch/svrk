import SwiftUI

/// One compatibility point for the watch UI. watchOS 26 gets native Liquid
/// Glass; older watches retain the same layout with a lightweight material.
struct WatchGlassCard<Content: View>: View {
    private let padding: CGFloat
    private let interactive: Bool
    private let content: Content

    init(
        padding: CGFloat = 10,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        if #available(watchOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(
                    .regular.interactive(interactive),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        } else {
            content
                .padding(padding)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
    }
}

struct WatchGlassIcon: View {
    let systemName: String
    var tint: Color?
    var isBusy = false

    var body: some View {
        Group {
            if isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: systemName)
                    .font(.headline)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 34, height: 34)
        .watchGlassEffect(shape: Circle(), tint: tint, interactive: true)
    }
}

struct WatchGlassActionLabel: View {
    let title: String
    let systemName: String
    var tint: Color?

    var body: some View {
        Label(title, systemImage: systemName)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .watchGlassEffect(
                shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                tint: tint,
                interactive: true
            )
    }
}

private extension View {
    @ViewBuilder
    func watchGlassEffect<S: Shape>(
        shape: S,
        tint: Color?,
        interactive: Bool
    ) -> some View {
        if #available(watchOS 26.0, *) {
            glassEffect(
                .regular.tint(tint).interactive(interactive),
                in: shape
            )
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.13))
                    }
                }
        }
    }
}

extension View {
    func watchGlassScreen() -> some View {
        background {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.10),
                    .black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}
