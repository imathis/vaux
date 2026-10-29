import AppKit
import SwiftUI

/// Picks an icon: one of the few offered (a line's, or an effect's), or an
/// emoji of your own.
struct IconChoices: View {
    enum Layout {
        /// All in a line, the emoji last: the Live panel's.
        case row
        /// The offered ones in a square, bigger, and the emoji on a line of
        /// its own, labeled: a popover's.
        case square
    }

    @Binding var icon: String?
    var layout = Layout.row
    var choices = Overlay.icons
    /// Shown for the choice of none.
    var noneSymbol = "circle.slash"
    /// An icon was picked, offered or emoji.
    var picked: () -> Void = {}

    var body: some View {
        switch layout {
        case .row:
            HStack(spacing: 2) {
                ForEach(choices, id: \.label) { button(for: $0, size: CGSize(width: 30, height: 24)) }
                EmojiField(icon: $icon, size: CGSize(width: 40, height: 24))
            }
        case .square:
            let count = choices.count
            let columns = Int(Double(count).squareRoot().rounded(.up))
            let cell = CGSize(width: 36, height: 30)
            VStack(alignment: .leading, spacing: 10) {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(Array(stride(from: 0, to: count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(choices[start..<min(start + columns, count)], id: \.label) { button(for: $0, size: cell) }
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text("Emoji")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    EmojiField(icon: $icon, size: CGSize(width: cell.width * 1.5, height: cell.height), picked: picked)
                }
                .frame(width: cell.width * Double(columns) + 2 * Double(columns - 1))
            }
        }
    }

    private func button(for choice: (symbol: String?, label: String), size: CGSize) -> some View {
        let selected = icon == choice.symbol
        return Button {
            icon = choice.symbol
            picked()
        } label: {
            OverlayIcon(icon: choice.symbol ?? noneSymbol)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.label)
    }
}

/// An emoji of your own, from the macOS emoji picker (or typed or pasted
/// in). Shows the one in use, unless it's one of those offered.
private struct EmojiField: View {
    @Binding var icon: String?
    let size: CGSize
    /// An emoji was picked.
    var picked: () -> Void = {}

    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        let custom = Self.custom(icon)
        Button {
            // The picker types into what has focus: the field behind this,
            // once it has it.
            typing = true
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                NSApp.orderFrontCharacterPalette(nil)
            }
        } label: {
            Group {
                if let custom {
                    Text(custom)
                } else {
                    Image(systemName: "face.smiling")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 5).fill(custom != nil ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pick an emoji (or type or paste one)")
        .background {
            TextField("Emoji", text: $text)
                .focused($typing)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear { text = custom ?? "" }
        .onChange(of: icon) { _, icon in text = Self.custom(icon) ?? "" }
        .onChange(of: text) { _, typed in
            // One added beside the one in use replaces it.
            guard let newest = typed.filter(Self.isEmoji).first(where: { String($0) != icon }) else { return }
            icon = String(newest)
            text = String(newest)
            picked()
        }
    }

    private static func custom(_ icon: String?) -> String? {
        guard let icon, OverlayIcon.isEmoji(icon), !Overlay.icons.contains(where: { $0.symbol == icon }) else { return nil }
        return icon
    }

    /// Drawn as an emoji: not a digit or # that only becomes one when asked.
    private static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && character.unicodeScalars.count > 1)
    }
}
