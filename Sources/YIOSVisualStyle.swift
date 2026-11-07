import AppKit
import SwiftUI

enum YIOSTheme {
    static let canvas = adaptive(light: 0xF4F6FA, dark: 0x14161B)
    static let sidebar = adaptive(light: 0xFAFBFD, dark: 0x191C22)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1E222A)
    static let surfaceSecondary = adaptive(light: 0xF7F9FC, dark: 0x252A33)
    static let border = adaptive(light: 0xE4E8F0, dark: 0x343A45)
    static let accent = Color(red: 0.16, green: 0.38, blue: 0.93)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

struct YIOSPageHeader: View {
    let title: String
    let subtitle: String
    var eyebrow: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 25, weight: .semibold, design: .default))
                .tracking(-0.6)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

struct YIOSActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color = YIOSTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? tint.opacity(configuration.isPressed ? 0.82 : 1) : YIOSTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isEnabled ? Color.clear : YIOSTheme.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(YIOSMotion.quick(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

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
        YIOSTheme.canvas
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
                .font(.system(size: 13, weight: .semibold))
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
                    .fill(YIOSTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        YIOSTheme.border.opacity(colorScheme == .dark ? 0.72 : 1),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(elevated ? (colorScheme == .dark ? 0.10 : 0.025) : 0),
                radius: elevated ? 5 : 0,
                x: 0,
                y: elevated ? 2 : 0
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
