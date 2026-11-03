import SwiftUI

/// The look shared by the Claude Code panel and the terminal beside it: both sit in
/// rounded cards outlined with a hairline, separated by a narrow gutter.
enum PanelStyle {
    static let cornerRadius: CGFloat = 10
    /// The space around and between the cards
    static let gutter: CGFloat = 6
    static let hairline = Color.primary.opacity(0.12)
    /// Lifts the panel's card a little off the window background.
    static let cardFill = Color.primary.opacity(0.035)
    static let fieldFill = Color.primary.opacity(0.06)
    static let hoverFill = Color.primary.opacity(0.07)
    static let rowCornerRadius: CGFloat = 7

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

/// Lays out the panel and the terminal as cards while the panel is open, and leaves the
/// terminal edge to edge while it is closed.
struct ClaudePanelLayout<Terminal: View>: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ViewBuilder let terminal: Terminal

    var body: some View {
        let open = model.isOpen
        HStack(spacing: 0) {
            ClaudeSessionsSidebar(model: model)

            // The modifiers stay the same either way so the terminal's surfaces keep
            // their identity when the panel is toggled.
            terminal
                .clipShape(RoundedRectangle(cornerRadius: open ? PanelStyle.cornerRadius : 0, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: open ? PanelStyle.cornerRadius : 0, style: .continuous)
                        .strokeBorder(open ? PanelStyle.hairline : .clear, lineWidth: 1)
                        .allowsHitTesting(false))
        }
        .padding(open ? PanelStyle.gutter : 0)
    }
}

/// A section's title with its controls on the trailing side, and a line of detail under it.
struct PanelHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var subtitleHelp: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .frame(height: 22)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitleHelp ?? "")
            }
        }
        .padding(.horizontal, 2)
    }
}

/// A search field with a magnifying glass and a button that clears it.
struct PanelSearchField: View {
    @Binding var text: String
    var prompt = "筛选"

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: PanelStyle.rowCornerRadius, style: .continuous)
                .fill(PanelStyle.fieldFill))
        .overlay(
            RoundedRectangle(cornerRadius: PanelStyle.rowCornerRadius, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : PanelStyle.hairline, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// The background of a row in the panel's lists: highlighted while selected or hovered.
struct PanelRowBackground: View {
    var selected = false
    var hovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: PanelStyle.rowCornerRadius, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.22) : hovered ? PanelStyle.hoverFill : Color.clear)
    }
}

/// A small rounded tile with a white symbol, like an app icon.
struct PanelIconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundColor(.white))
            .frame(width: size, height: size)
    }
}
