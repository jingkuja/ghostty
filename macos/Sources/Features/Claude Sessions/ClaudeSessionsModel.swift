import AppKit
import Combine

/// The tabs of the panel on the left of a terminal window.
enum ClaudePanelTab {
    case commands
    case files
    case ssh
    case sessions
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
    @Published var tab: ClaudePanelTab = .commands
    @Published private(set) var directory: String?
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var loading = false
    /// Sessions that a `claude` process in one of the surfaces currently has open
    @Published private(set) var liveSessionIDs: Set<String> = []
    /// The session open in this window's focused surface
    @Published private(set) var activeSessionID: String?
    @Published var filter = ""

    /// The files tab's local half, following the focused surface's working directory
    let files = LocalFilesModel()
    /// The files tab's remote half, following the host the focused surface is logged in to
    let remote = RemoteFilesModel()
    /// Copies between the files tab's halves
    let transfers = FileTransfers()

    private weak var controller: TerminalController?
    /// The surface whose title the remote files follow, and that subscription
    private weak var titleSurface: Ghostty.SurfaceView?
    private var titleCancellable: AnyCancellable?
    private var liveSurfaces: [String: Weak<Ghostty.SurfaceView>] = [:]
    /// Surfaces by foreground PID, as collected for the refresh in progress
    private var refreshSurfaces: [Int: Weak<Ghostty.SurfaceView>] = [:]
    private var timer: Timer?
    private var refreshing = false
    private var refreshPending = false

    init(controller: TerminalController) {
        self.controller = controller
        // Show what a transfer added. Both, since a remote folder can be on this Mac's disk.
        transfers.didFinish = { [weak self] _ in
            self?.files.reload()
            self?.remote.reload()
        }
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
        // Don't hold a connection (and the master it keeps alive) for a closed panel.
        remote.disconnect()
        titleCancellable = nil
        titleSurface = nil
    }

    /// The focused surface reported a new working directory.
    func directoryDidChange(_ path: String) {
        guard path != directory else { return }
        setDirectory(path)
        refresh()
    }

    private func setDirectory(_ path: String) {
        files.terminalDirectoryDidChange(path)
        guard path != directory else { return }
        directory = path
        sessions = []
    }

    /// Re-reads the sessions and which surfaces run them. Cheap when nothing changed.
    func refresh() {
        guard isOpen else { return }
        if tab == .files {
            files.reload()
            let focused = controller?.focusedSurface
            remote.update(foregroundProcessGroup: focused?.surfaceModel?.foregroundPID)
            observeTitle(of: focused)
            remote.reload()
        }
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

    /// Passes the surface's title, which can say where a remote shell is, to the remote files.
    private func observeTitle(of surface: Ghostty.SurfaceView?) {
        guard surface !== titleSurface || titleCancellable == nil else { return }
        titleSurface = surface
        titleCancellable = surface?.$title
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] title in self?.remote.shellTitleDidChange(title) }
    }

    /// Opens a new tab in this window that types the command, if any, into its shell and runs it,
    /// so the command is found on the shell's PATH and the shell stays open after it exits.
    func runInNewTab(_ command: String, directory: String? = nil) {
        guard let controller else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory ?? self.directory
        if !command.isEmpty { config.initialInput = command + "\n" }
        _ = TerminalController.newTab(controller.ghostty, from: controller.window, withBaseConfig: config)
    }

    /// Shows a Markdown file rendered for the terminal in a new tab, paged with `less`.
    /// The pager is the tab's command, so quitting it closes the tab. Falls back to the
    /// default app for a file that is too large or not text.
    func viewMarkdown(_ path: String, title: String? = nil) {
        guard let controller else { return }
        let file = URL(fileURLWithPath: path)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var encoding = String.Encoding.utf8
        guard size <= 4 << 20, let text = try? String(contentsOf: file, usedEncoding: &encoding) else {
            NSWorkspace.shared.open(file)
            return
        }

        // Laid out for the focused surface's width, which a new tab in this window shares.
        let columns = controller.focusedSurface?.surfaceSize.map { Int($0.columns) } ?? 100
        let name = file.lastPathComponent
        // Named like the original, which is what less shows in its prompt.
        let rendered = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ghostty Markdown", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: rendered.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try MarkdownTerminal.render(text, columns: columns).write(to: rendered, atomically: true, encoding: .utf8)
        } catch {
            NSWorkspace.shared.open(file)
            return
        }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = file.deletingLastPathComponent().path
        // -R passes colors and hyperlinks through; -L keeps a LESSOPEN preprocessor from
        // reformatting the .md file. The script is one `sh -c` word because on macOS the
        // command runs as `bash -c "exec -l <command>"`, which would exec just its first part.
        let script = "printf '\\033]2;%s\\007' \((title ?? name).shellQuoted); "
            + "exec /usr/bin/less -R -L -- \(rendered.path.shellQuoted)"
        config.command = "/bin/sh -c \(script.shellQuoted)"
        config.environmentVariables["LESSCHARSET"] = "utf-8"
        _ = TerminalController.newTab(controller.ghostty, from: controller.window, withBaseConfig: config)
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
