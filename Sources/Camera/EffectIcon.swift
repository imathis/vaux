import AppKit
import SwiftUI

/// How an effect looks on its keys and in your list: an icon and a color,
/// each its own or picked for it.
extension Effect {
    enum Tint: String, Codable, CaseIterable, Sendable {
        case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray

        /// The system's colors as they look in dark mode: bright on a black key.
        var rgb: (red: Double, green: Double, blue: Double) {
            switch self {
            case .red: (1, 0.271, 0.227)
            case .orange: (1, 0.624, 0.039)
            case .yellow: (1, 0.839, 0.039)
            case .green: (0.188, 0.820, 0.345)
            case .mint: (0.388, 0.902, 0.886)
            case .teal: (0.251, 0.784, 0.878)
            case .blue: (0.039, 0.518, 1)
            case .indigo: (0.369, 0.361, 0.902)
            case .purple: (0.749, 0.353, 0.949)
            case .pink: (1, 0.216, 0.373)
            case .gray: (0.557, 0.557, 0.576)
            }
        }

        var color: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue) }
        var nsColor: NSColor { NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
        var label: String { rawValue.capitalized }

        /// Handed out by place in the list, so neighbors differ.
        static let byPlace: [Tint] = [.blue, .orange, .purple, .green, .pink, .teal, .yellow, .red, .indigo, .mint]
    }

    /// Icons offered for an effect, besides any emoji; none picks one from
    /// what's in it.
    static let iconChoices: [(symbol: String?, label: String)] = [
        (nil, "Automatic"),
        ("sparkles", "Sparkles"),
        ("cup.and.saucer.fill", "Break"),
        ("eye.slash.fill", "Hidden"),
        ("hand.raised.fill", "Hand"),
        ("eyes", "Eyes"),
        ("burst.fill", "Burst"),
        ("moon.fill", "Moon"),
        ("camera.filters", "Filters"),
        ("waveform", "Waveform"),
        ("bubble.left.fill", "Speech"),
        ("phone.fill", "Phone"),
        ("clock.fill", "Clock"),
        ("star.fill", "Star"),
        ("heart.fill", "Heart"),
        ("flame.fill", "Flame"),
        ("bolt.fill", "Bolt"),
        ("sun.max.fill", "Sun"),
        ("snowflake", "Snow"),
        ("theatermasks.fill", "Drama"),
        ("party.popper.fill", "Party"),
        ("music.note", "Music"),
        ("plus.magnifyingglass", "Zoom"),
        ("exclamationmark.triangle.fill", "Warning"),
        ("poop", "Poop"),
    ]

    /// Its own icon, else its first text line's, else one for what it
    /// mostly is.
    var shownIcon: String {
        if let icon { return icon }
        if let lineIcon = overlays.lazy.flatMap(\.lines).compactMap(\.icon).first { return lineIcon }
        if let overlay = overlays.first { return overlay.kind == .text ? "textformat" : "photo" }
        if look != nil { return "camera.filters" }
        if pushIn != nil { return "plus.magnifyingglass" }
        if shake != nil { return "rectangle.on.rectangle.angled" }
        if !includes.isEmpty { return "square.stack.3d.up" }
        return "sparkles"
    }

    /// Its own color, else the one for its place in the list.
    func shownTint(atPlace place: Int) -> Tint {
        color ?? Tint.byPlace[place % Tint.byPlace.count]
    }
}

/// An effect's icon in its color, as in the list and its editor.
struct EffectBadge: View {
    let icon: String
    let tint: Effect.Tint

    var body: some View {
        OverlayIcon(icon: icon)
            .foregroundStyle(tint.color)
    }
}

/// Picks an effect's icon: automatic, one offered, or an emoji. Shows the
/// one it has, in its color.
struct EffectIconPicker: View {
    @Binding var icon: String?
    let shown: String
    let tint: Effect.Tint

    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 6) {
                EffectBadge(icon: shown, tint: tint)
                    .frame(width: 22)
                Text(icon == nil ? "Automatic" : "Change")
            }
        }
        .help(icon == nil ? "From what's in it: change it" : "Change the icon")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            IconChoices(icon: $icon, layout: .square, choices: Effect.iconChoices, noneSymbol: "wand.and.stars") { choosing = false }
                .padding(12)
        }
    }
}

/// Picks an effect's color: automatic (by its place in the list) or one of
/// the tints.
struct TintPicker: View {
    @Binding var color: Effect.Tint?
    /// The one automatic gives it.
    let automatic: Effect.Tint

    var body: some View {
        HStack(spacing: 5) {
            swatch(nil, fill: automatic, help: "Automatic: \(automatic.label.lowercased()), by its place in the list")
            Divider()
                .frame(height: 16)
            ForEach(Effect.Tint.allCases, id: \.self) { tint in
                swatch(tint, fill: tint, help: tint.label)
            }
        }
    }

    private func swatch(_ choice: Effect.Tint?, fill: Effect.Tint, help: String) -> some View {
        let selected = color == choice
        return Button { color = choice } label: {
            ZStack {
                Circle()
                    .fill(fill.color)
                    .frame(width: 16, height: 16)
                if choice == nil {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
