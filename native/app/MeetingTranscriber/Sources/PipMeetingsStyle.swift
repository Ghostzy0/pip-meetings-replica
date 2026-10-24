#if PIP_EDITION
import SwiftUI
import AppKit

/// Paper tokens adapted to native points and the system text family. The original
/// character below is a new still drawing, not the reserved Pip motion library.
enum PipMeetingsMetrics {
    static let tight: CGFloat = 4
    static let gap: CGFloat = 8
    static let row: CGFloat = 12
    static let inset: CGFloat = 16
    static let section: CGFloat = 24
    static let generous: CGFloat = 32
    static let cardRadius: CGFloat = 18
    static let smallRadius: CGFloat = 10
    static let sidebar: CGFloat = 280
    static let control: CGFloat = 34
    static let detailWidth: CGFloat = 880
}

struct PipMeetingsPalette {
    let canvas: Color
    let surface: Color
    let fill: Color
    let line: Color
    let ink: Color
    let secondary: Color
    let danger: Color
    let success: Color

    init(_ scheme: ColorScheme) {
        #if PIP_NEUTRAL
        canvas = Color(nsColor: .windowBackgroundColor)
        surface = Color(nsColor: .controlBackgroundColor)
        fill = Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
        line = Color(nsColor: .separatorColor)
        ink = Color.primary
        secondary = Color.secondary
        danger = Color.red
        success = Color.green
        #else
        let dark = scheme == .dark
        canvas = Color(rgb: dark ? 0x0F0F0E : 0xFFFFFF)
        surface = Color(rgb: dark ? 0x171716 : 0xFAFAFA)
        fill = Color(rgb: dark ? 0x212120 : 0xF3F3F3)
        line = Color(rgb: dark ? 0x2A2A29 : 0xEBEBEB)
        ink = Color(rgb: dark ? 0xF1F1EE : 0x121211)
        secondary = Color(rgb: dark ? 0xA3A3A0 : 0x555555)
        danger = Color(rgb: dark ? 0xFF8B7E : 0xAE2A1F)
        success = Color(rgb: dark ? 0x5FD394 : 0x1D7A46)
        #endif
    }

    var accent: Color {
        #if PIP_NEUTRAL
        Color.accentColor
        #else
        ink
        #endif
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct PipStillMark: View {
    @Environment(\.colorScheme) private var scheme
    var size: CGFloat = 64
    var active = false

    var body: some View {
        #if PIP_NEUTRAL
        Image(systemName: active ? "waveform.circle.fill" : "text.bubble")
            .font(.system(size: size * 0.65))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        #else
        let colours = PipMeetingsPalette(scheme)
        ZStack {
            PipPebbleShape().fill(colours.ink)
            HStack(spacing: size * 0.12) {
                Capsule().fill(colours.canvas).frame(width: size * 0.055, height: size * (active ? 0.14 : 0.10))
                Capsule().fill(colours.canvas).frame(width: size * 0.055, height: size * (active ? 0.14 : 0.10))
            }
            .offset(x: size * 0.06, y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        #endif
    }
}

private struct PipPebbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.17, y: rect.height * 0.29))
        path.addCurve(to: CGPoint(x: rect.width * 0.76, y: rect.height * 0.13), control1: CGPoint(x: rect.width * 0.26, y: rect.height * 0.03), control2: CGPoint(x: rect.width * 0.62, y: rect.height * 0.01))
        path.addCurve(to: CGPoint(x: rect.width * 0.91, y: rect.height * 0.67), control1: CGPoint(x: rect.width * 0.95, y: rect.height * 0.27), control2: CGPoint(x: rect.width * 1.03, y: rect.height * 0.51))
        path.addCurve(to: CGPoint(x: rect.width * 0.31, y: rect.height * 0.91), control1: CGPoint(x: rect.width * 0.81, y: rect.height * 0.92), control2: CGPoint(x: rect.width * 0.53, y: rect.height * 0.99))
        path.addCurve(to: CGPoint(x: rect.width * 0.17, y: rect.height * 0.29), control1: CGPoint(x: rect.width * 0.05, y: rect.height * 0.83), control2: CGPoint(x: rect.width * 0.03, y: rect.height * 0.55))
        path.closeSubpath()
        return path
    }
}

struct PipSectionHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.tight) {
            Text(title).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
    }
}
#endif
