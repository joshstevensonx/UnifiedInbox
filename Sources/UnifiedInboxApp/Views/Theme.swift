import AppKit
import InboxCore
import SwiftUI

/// Dark glass, minimalist design tokens.
enum Theme {
    // Text
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    // Surfaces
    static let hairline = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.05)
    static let fillHover = Color.white.opacity(0.08)
    static let fillSelected = Color.white.opacity(0.12)

    // Single restrained accent; platform colours only appear as small dots.
    static let accent = Color(red: 0.55, green: 0.70, blue: 1.0)
    static let priority = Color(red: 1.0, green: 0.80, blue: 0.35)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.35)

    static let radius: CGFloat = 12
    static let smallRadius: CGFloat = 8

    static func tint(_ p: Platform) -> Color {
        let (r, g, b) = p.accentRGB
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Glass surfaces

/// Behind-window blur (the "frosted" desktop show-through).
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

extension View {
    /// A floating glass card: Liquid Glass on macOS 26+, thin material + hairline before that.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Theme.radius) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    /// Subtle filled surface for rows / chips (no blur, cheap to render in long lists).
    func softFill(_ color: Color = Theme.fill, cornerRadius: CGFloat = Theme.smallRadius) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Makes the hosting window translucent with a transparent, full-height title bar.
    func glassWindow() -> some View {
        background(WindowConfigurator())
    }
}

/// Reaches the NSWindow to make it frameless-looking and translucent.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Small building blocks

/// Initials avatar with a tiny platform dot: replaces the loud coloured app tiles.
struct Avatar: View {
    @EnvironmentObject private var presence: AppPresenceMonitor
    let title: String
    let platform: Platform
    var size: CGFloat = 30

    private var initials: String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "•" : letters
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(initials)
                .font(.system(size: size * 0.36, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.fillSelected))
                .overlay(Circle().strokeBorder(Theme.hairline))
            Circle()
                .fill(Theme.tint(platform))
                .frame(width: size * 0.32, height: size * 0.32)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1.5))
                .offset(x: 1, y: 1)
        }
        .help("\(platform.displayName): \(presence.presence[platform]?.label ?? "status unknown")")
    }
}

/// Tiny uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.tertiary)
    }
}

/// Minimal count text (instead of system badges).
struct CountText: View {
    let count: Int
    var highlight = false
    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(highlight ? Theme.primary : Theme.secondary)
        }
    }
}

/// Borderless icon button with hover highlight.
struct GlassIconButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.primary : Theme.secondary)
                .frame(width: 26, height: 24)
                .softFill(hovering ? Theme.fillHover : .clear, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Glass pill banner used for setup / closed-app notices.
struct GlassBanner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        // Stacked layout: fits narrow columns without truncating or overlapping neighbours.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(tint).font(.system(size: 12))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                actions()
            }
            .controlSize(.small)
        }
        .padding(12)
        .glassCard()
    }
}
