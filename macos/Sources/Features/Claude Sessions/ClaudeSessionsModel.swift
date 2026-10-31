import AppKit
import Combine

/// The tabs of the panel on the left of a terminal window.
enum ClaudePanelTab {
    case sessions
    case commands
}

/// State behind the Claude Code sessions panel on the left of a terminal window.
///
/// The panel lists the sessions recorded for the focused surface's working directory.
/// Clicking a session focuses the surface already running it, or resumes it with
/// `claude --resume` in a new tab.
@MainActor
final class ClaudeSessionsModel: ObservableObject {
    /// How often the session files are checked for changes while the panel is open
    private static let refreshInterval: TimeInterval = 2

    /// Shared by all windows so session files are parsed once; only used on `queue`.
    nonisolated(unsafe) private static let index = ClaudeSessionIndex()
    private static let queue = DispatchQueue(label: "com.mitchellh.ghostty.claude-sessions", qos: .utility)

    @Published private(set) var isOpen = false
    @Published var tab: ClaudePanelTab = .sessions
    @Published private(set) var directory: String?
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var loading = false
    /// Sessions that a `claude` process in one of the surfaces currently has open
    @Published private(set) var liveSessionIDs: Set<String> = []
    /// The session open in this window's focused surface
    @Published private(set) var activeSessionID: String?
    @Published var filter = ""

    private weak var controller: TerminalController?
    private var liveSurfaces: [String: Weak<Ghostty.SurfaceView>] = [:]
    /// Surfaces by foreground PID, as collected for the refresh in progress
    private var refreshSurfaces: [Int: Weak<Ghostty.SurfaceView>] = [:]
    private var timer: Timer?
    private var refreshing = false
    private var refreshPending = false

    init(controller: TerminalController) {
        self.controller = controller
    }

    func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    func open() {
        if let pwd = controller?.focusedSurface?.pwd, !pwd.isEmpty {
            setDirectory(pwd)
        }
        isOpen = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                self.refresh()
            }
        }
        refresh()
    }

    func close() {
        isOpen = false
        timer?.invalidate()
        timer = nil
    }

    /// The focused surface reported a new working directory.
    func directoryDidChange(_ path: String) {
        guard path != directory else { return }
        setDirectory(path)
        refresh()
    }

    private func setDirectory(_ path: String) {
        guard path != directory else { return }
        directory = path
        sessions = []
    }

    /// Re-reads the sessions and which surfaces run them. Cheap when nothing changed.
    func refresh() {
        guard isOpen else { return }
        guard !refreshing else {
            refreshPending = true
            return
        }

        // Collect the foreground process of every surface; for a running `claude`
        // this is the process that registers its session.
        var surfaces: [Int: Weak<Ghostty.SurfaceView>] = [:]
        for controller in TerminalController.all {
            for surface in controller.surfaceTree {
                if let pid = surface.surfaceModel?.foregroundPID {
                    surfaces[pid] = .init(surface)
                }
            }
        }
        refreshSurfaces = surfaces
        let pids = Array(surfaces.keys)
        let focused = controller?.focusedSurface
        let directory = self.directory

        refreshing = true
        // Only the first load of a directory shows as loading; polls don't redraw the panel.
        if sessions.isEmpty && !loading { loading = true }
        Self.queue.async { [weak self] in
            let sessions = directory.map { Self.index.list(cwd: $0) } ?? []
            let live = pids.compactMap { pid in Self.index.liveSessionID(pid: pid).map { ($0, pid) } }

            Task { @MainActor in
                guard let self else { return }
                self.refreshing = false
                if self.loading { self.loading = false }
                // The directory changed while reading; the follow-up refresh shows the right one.
                if directory == self.directory, sessions != self.sessions {
                    self.sessions = sessions
                }
                self.liveSurfaces = Dictionary(live.compactMap { id, pid in self.refreshSurfaces[pid].map { (id, $0) } },
                                               uniquingKeysWith: { first, _ in first })
                let liveIDs = Set(self.liveSurfaces.keys)
                if liveIDs != self.liveSessionIDs { self.liveSessionIDs = liveIDs }
                let active = self.liveSurfaces.first { $0.value.value === focused }?.key
                if active != self.activeSessionID { self.activeSessionID = active }

                if self.refreshPending || directory != self.directory {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    /// Focuses the surface already running the session, or resumes it in a new tab.
    /// With `fork`, the session is always continued as a new session in a new tab.
    func resume(_ session: ClaudeSession, fork: Bool = false) {
        if !fork, let surface = liveSurfaces[session.id]?.value,
           let owner = TerminalController.all.first(where: { $0.surfaceTree.contains(surface) }) {
            owner.focusSurface(surface)
            return
        }

        guard let controller else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = session.cwd ?? directory
        // Typed into the user's shell rather than run as the command, so `claude` is found
        // on the shell's PATH and the shell stays open after it exits.
        config.initialInput = "claude --resume \(session.id)\(fork ? " --fork-session" : "")\n"
        _ = TerminalController.newTab(controller.ghostty, from: controller.window, withBaseConfig: config)
        refresh()
    }

    /// Types the command into this window's focused surface and focuses it, so the
    /// command can be completed or edited before it runs. With `execute`, Enter follows.
    func insert(_ command: String, execute: Bool) {
        guard let surfaceView = controller?.focusedSurface,
              !surfaceView.readonly,
              let surface = surfaceView.surfaceModel else { return }

        // A trailing newline would run the command; Enter is sent separately if asked.
        var text = command
        while text.last?.isNewline == true {
            text.removeLast()
        }

        if !text.isEmpty { surface.sendText(text) }
        if execute { surface.sendEnter() }
        Ghostty.moveFocus(to: surfaceView)
    }
}
