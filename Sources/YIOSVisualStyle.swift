import AppKit
import SwiftUI

enum YIOSMotion {
    static func quick(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.20)
    }

    static func workspace(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }
}

struct YIOSWorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color

    init(accent: Color = .blue) {
        self.accent = accent
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    accent.opacity(colorScheme == .dark ? 0.030 : 0.020),
                    Color.clear,
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct YIOSPanelHeader: View {
    let title: String
    let systemImage: String
    let accent: Color?

    init(_ title: String, systemImage: String, accent: Color? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(iconColor.opacity(0.11))
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 25, height: 25)
            .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color { accent ?? .blue }
}

struct YIOSPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.90 : 1)
            .animation(YIOSMotion.quick(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

private struct YIOSCardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let accent: Color?
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .controlBackgroundColor),
                                tint.opacity(accent == nil
                                    ? (colorScheme == .dark ? 0.025 : 0.016)
                                    : (colorScheme == .dark ? 0.060 : 0.030))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        (accent ?? Color(nsColor: .separatorColor))
                            .opacity(accent == nil ? (colorScheme == .dark ? 0.46 : 0.34) : 0.25),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(elevated ? (colorScheme == .dark ? 0.18 : 0.055) : 0),
                radius: elevated ? 9 : 0,
                x: 0,
                y: elevated ? 3 : 0
            )
    }

    private var tint: Color { accent ?? .blue }
}

extension View {
    func yiosCardSurface(
        accent: Color? = nil,
        cornerRadius: CGFloat = 12,
        elevated: Bool = true
    ) -> some View {
        modifier(
            YIOSCardSurfaceModifier(
                accent: accent,
                cornerRadius: cornerRadius,
                elevated: elevated
            )
        )
    }
}
