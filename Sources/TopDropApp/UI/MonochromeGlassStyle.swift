import SwiftUI

/// Adaptive monochrome chrome for TopDrop's glass tray and Scroll Shelf.
/// Content colors (for example annotation colors and thumbnails) remain intact.
struct TopDropNeutralGlass: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.18)
                    : Color.white.opacity(0.28)
            )
        }
    }
}

struct MonochromeProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.42))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Color.primary.opacity(
                    isEnabled ? (configuration.isPressed ? 0.18 : 0.10) : 0.035
                ),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        Color.primary.opacity(isEnabled ? 0.42 : 0.12),
                        lineWidth: configuration.isPressed ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct MonochromeActionCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay {
                Capsule().stroke(Color.primary.opacity(0.28), lineWidth: 1)
            }
    }
}

extension View {
    func monochromeActionCapsule() -> some View {
        modifier(MonochromeActionCapsule())
    }
}
