import AppKit
import SwiftUI

/// A native text box attached to the bottom of a surface for composing input.
///
/// Editing happens in an NSTextView, so input methods (e.g. Chinese pinyin),
/// undo, selection and multi-line editing all behave natively. The text is
/// then inserted into the terminal as a paste, which is bracketed when the
/// running program enables it, so it lands in the program's own input line
/// for review. Enter is only sent on request. This makes writing long prompts
/// for coding agents much easier than editing them inside a TUI.
@MainActor
enum ComposeBox {
    /// Previously submitted texts, oldest first, shared across surfaces.
    fileprivate static var history: [String] = []
    private static let historyLimit = 100

    static func open(_ surfaceView: Ghostty.SurfaceView) {
        guard !surfaceView.readonly else {
            NSSound.beep()
            return
        }

        surfaceView.composeBoxVisible = true
    }

    static func close(_ surfaceView: Ghostty.SurfaceView) {
        surfaceView.composeBoxVisible = false
        Ghostty.moveFocus(to: surfaceView)
    }

    /// Sends the text to the terminal as a paste and closes the box. If
    /// `sendEnter` is true, an Enter key press follows the text.
    fileprivate static func submit(_ text: String, to surfaceView: Ghostty.SurfaceView, sendEnter: Bool) {
        guard let surface = surfaceView.surfaceModel else { return }

        // Trailing newlines would submit early or leave blank lines in the
        // prompt, so drop them. Enter is sent separately if requested.
        var text = text
        while text.last?.isNewline == true {
            text.removeLast()
        }

        if !text.isEmpty {
            surface.sendText(text)
            if history.last != text {
                history.append(text)
                if history.count > historyLimit {
                    history.removeFirst(history.count - historyLimit)
                }
            }
        }

        if sendEnter {
            for action: Ghostty.Input.Action in [.press, .release] {
                surface.sendKeyEvent(Ghostty.Input.KeyEvent(
                    synthesizing: .enter,
                    action: action,
                    mods: [],
                    translationMods: []
                ))
            }
        }

        surfaceView.composeDraft = ""
        close(surfaceView)
    }
}

// MARK: Views

struct ComposeBoxOverlay: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    /// The height of the laid out text, used to grow the box with its content.
    @State private var contentHeight: CGFloat = 0

    private let minTextHeight: CGFloat = 20
    private let maxTextHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                ComposeTextView(
                    initialText: surfaceView.composeDraft,
                    contentHeight: $contentHeight,
                    onChange: { surfaceView.composeDraft = $0 },
                    onSubmit: { text, sendEnter in
                        ComposeBox.submit(text, to: surfaceView, sendEnter: sendEnter)
                    },
                    onCancel: { ComposeBox.close(surfaceView) }
                )
                .frame(height: min(max(contentHeight, minTextHeight), maxTextHeight))

                Text("↩ Insert   ⌘↩ Insert and Send   ⇧↩ New Line   ↑↓ History   esc Close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.3))
            )
            .shadow(radius: 6)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct ComposeTextView: NSViewRepresentable {
    let initialText: String
    @Binding var contentHeight: CGFloat
    let onChange: (String) -> Void
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposeNSTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        // Prompts often contain code, so don't rewrite what the user types.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        textView.string = initialText
        textView.delegate = context.coordinator
        textView.onCommandReturn = { [weak coordinator = context.coordinator] in
            coordinator?.submit(sendEnter: true)
        }
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            context.coordinator.updateContentHeight()
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.updateContentHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeTextView
        weak var textView: NSTextView?

        /// The history index being browsed with the arrow keys, if any.
        private var historyIndex: Int?

        init(_ parent: ComposeTextView) {
            self.parent = parent
        }

        func submit(sendEnter: Bool) {
            guard let textView else { return }
            parent.onSubmit(textView.string, sendEnter)
        }

        func updateContentHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let height = ceil(layoutManager.usedRect(for: textContainer).height)
            if parent.contentHeight != height {
                parent.contentHeight = height
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            historyIndex = nil
            parent.onChange(textView.string)
            updateContentHeight()
        }

        // Input methods consume keys while composing (marked text), so the
        // commands below are only seen once composition has finished. This
        // is what keeps Enter from inserting a half-typed pinyin word.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    submit(sendEnter: false)
                }
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true

            case #selector(NSResponder.moveUp(_:)):
                return browseHistory(textView, older: true)

            case #selector(NSResponder.moveDown(_:)):
                return browseHistory(textView, older: false)

            default:
                return false
            }
        }

        /// Replaces the text with a history entry. Only active while the box
        /// is empty or already showing a history entry, so arrow keys keep
        /// moving the caret while editing.
        private func browseHistory(_ textView: NSTextView, older: Bool) -> Bool {
            let history = ComposeBox.history
            guard !history.isEmpty else { return false }
            guard textView.string.isEmpty || historyIndex != nil else { return false }

            let index: Int
            if let current = historyIndex {
                index = older ? current - 1 : current + 1
            } else if older {
                index = history.count - 1
            } else {
                return false
            }

            let text: String
            if index < 0 {
                return true
            } else if index >= history.count {
                text = ""
            } else {
                text = history[index]
            }

            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            parent.onChange(text)
            updateContentHeight()
            historyIndex = index < history.count ? index : nil
            return true
        }
    }
}

private final class ComposeNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+Return inserts and sends. It is fullscreen by default, so
        // handle it here, before the menu, while the box has focus.
        let returnKeyCodes: Set<UInt16> = [0x24, 0x4C]
        if event.type == .keyDown,
           window?.firstResponder === self,
           !hasMarkedText(),
           returnKeyCodes.contains(event.keyCode),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onCommandReturn?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

// MARK: Menu

extension AppDelegate {
    /// Adds "Compose Input…" to the Edit menu. The shortcut is fixed because
    /// this isn't a Ghostty keybind action; it can be changed in System
    /// Settings > Keyboard > Keyboard Shortcuts > App Shortcuts.
    func installComposeBoxMenuItem() {
        let editMenu = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .first { menu in menu.items.contains { $0.action == #selector(NSText.paste(_:)) } }
        guard let editMenu else { return }

        let item = NSMenuItem(
            title: "Compose Input…",
            action: #selector(toggleComposeBox(_:)),
            keyEquivalent: "i"
        )
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: nil)

        editMenu.addItem(.separator())
        editMenu.addItem(item)
    }

    @MainActor @objc func toggleComposeBox(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController else {
            NSSound.beep()
            return
        }

        // While the box has focus the surface may not be the focused one,
        // so look for an open box in the window first.
        if let open = controller.surfaceTree.first(where: { $0.composeBoxVisible }) {
            ComposeBox.close(open)
            return
        }

        guard let surfaceView = controller.focusedSurface else {
            NSSound.beep()
            return
        }

        ComposeBox.open(surfaceView)
    }
}
