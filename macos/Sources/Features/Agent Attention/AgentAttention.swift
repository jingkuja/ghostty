import AppKit

/// The attention state of a terminal, aimed at terminals running coding agents.
///
/// The state is derived only from signals agents already emit: the bell (or a
/// desktop notification while unfocused) means the agent is waiting for the
/// user, and OSC 9;4 progress reports mean it is working or has failed.
/// Cases are ordered by priority so the state of a tab is the max of its splits.
enum AgentState: Int, Comparable {
    case idle
    case running
    case error
    case waiting

    init(bell: Bool, progressReport: Ghostty.Action.ProgressReport?) {
        if bell {
            self = .waiting
            return
        }

        switch progressReport?.state {
        case .error:
            self = .error
        case .set, .indeterminate, .pause:
            self = .running
        case .remove, nil:
            self = .idle
        }
    }

    static func < (lhs: AgentState, rhs: AgentState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The prefix shown in front of the window and tab title.
    var titlePrefix: String? {
        switch self {
        case .idle: nil
        case .running: "⏳"
        case .error: "❗"
        case .waiting: "🔔"
        }
    }

    /// The SF Symbol shown for this state in the command palette.
    var symbolName: String? {
        switch self {
        case .idle: nil
        case .running: "hourglass"
        case .error: "exclamationmark.triangle.fill"
        case .waiting: "bell.fill"
        }
    }

    /// A short label shown as a badge in the command palette.
    var label: String? {
        switch self {
        case .idle: nil
        case .running: "Running"
        case .error: "Error"
        case .waiting: "Waiting"
        }
    }
}

extension Ghostty.SurfaceView {
    var agentState: AgentState {
        AgentState(bell: bell, progressReport: progressReport)
    }
}

enum AgentAttention {
    /// All terminal surfaces in a stable order: windows (tabs) in creation
    /// order, then the surfaces of each window in split tree order.
    static func allSurfaces() -> [Ghostty.SurfaceView] {
        let controllers = TerminalController.all.sorted { lhs, rhs in
            let lhsNumber: Int = lhs.window?.windowNumber ?? 0
            let rhsNumber: Int = rhs.window?.windowNumber ?? 0
            return lhsNumber < rhsNumber
        }

        var result: [Ghostty.SurfaceView] = []
        for controller in controllers {
            result.append(contentsOf: controller.surfaceTree)
        }
        return result
    }

    /// All surfaces that are currently waiting for the user.
    static func waitingSurfaces() -> [Ghostty.SurfaceView] {
        allSurfaces().filter { $0.agentState == .waiting }
    }

    /// The focused surface of the key terminal window, if any.
    static var currentSurface: Ghostty.SurfaceView? {
        TerminalController.all.first { $0.window?.isKeyWindow == true }?.focusedSurface
    }

    /// Present the first waiting surface after `current`, wrapping around.
    /// Returns false if no surface is waiting.
    @discardableResult
    static func focusNextWaiting(after current: Ghostty.SurfaceView? = currentSurface) -> Bool {
        let surfaces = allSurfaces()
        guard !surfaces.isEmpty else { return false }

        let start = current.flatMap { surfaces.firstIndex(of: $0) } ?? -1
        for offset in 1...surfaces.count {
            let surface = surfaces[(start + offset) % surfaces.count]
            guard surface.agentState == .waiting else { continue }
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyPresentTerminal,
                object: surface
            )
            return true
        }

        return false
    }
}

// MARK: Menu

extension AppDelegate {
    /// Adds "Jump to Next Waiting Agent" to the Window menu. The shortcut is
    /// fixed because this isn't a Ghostty keybind action; it can be changed in
    /// System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts.
    func installAgentAttentionMenuItem() {
        guard let menu = NSApp.windowsMenu else { return }

        let item = NSMenuItem(
            title: "Jump to Next Waiting Agent",
            action: #selector(jumpToNextWaitingAgent(_:)),
            keyEquivalent: "j"
        )
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        item.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)

        menu.addItem(.separator())
        menu.addItem(item)
    }

    @objc func jumpToNextWaitingAgent(_ sender: Any?) {
        if !AgentAttention.focusNextWaiting() {
            NSSound.beep()
        }
    }
}
