import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", category: "files-tab")

/// The local half of the files tab: a tree of the directory the focused surface is in,
/// unless the user browsed somewhere else.
@MainActor
final class LocalFilesModel: FileTreeModel {
    private static let queue = DispatchQueue(label: "com.mitchellh.ghostty.local-files", qos: .userInitiated)

    /// Whether `root` moves along with the focused surface's working directory
    @Published private(set) var followsTerminal = true

    private var terminalDirectory: String?

    /// The focused surface reported a new working directory.
    func terminalDirectoryDidChange(_ path: String) {
        terminalDirectory = path
        if followsTerminal { setRoot(path) }
    }

    /// Shows the directory at the top of the tree; it stops following the terminal
    /// unless it is the terminal's directory.
    func browse(_ path: String) {
        followsTerminal = path == terminalDirectory
        setRoot(path)
    }

    func browseParent() {
        guard let root, root != "/" else { return }
        browse((root as NSString).deletingLastPathComponent)
    }

    func followTerminal() {
        followsTerminal = true
        if let terminalDirectory { setRoot(terminalDirectory) }
    }

    override func list(_ directory: String) async -> Result<[FileEntry], Error> {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: Self.listSync(directory)) }
        }
    }

    nonisolated private static func listSync(_ directory: String) -> Result<[FileEntry], Error> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: keys)
            return .success(urls.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isSymlink = values?.isSymbolicLink ?? false
                // A link to a directory is listed as a directory.
                let isDirectory = isSymlink
                    ? (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    : values?.isDirectory ?? false
                return FileEntry(
                    path: FileEntry.join(directory, url.lastPathComponent),
                    isDirectory: isDirectory,
                    isSymlink: isSymlink,
                    size: isDirectory ? nil : values?.fileSize.map { UInt64(max($0, 0)) },
                    modified: values?.contentModificationDate)
            })
        } catch {
            return .failure(error)
        }
    }
}

/// The remote half of the files tab: the files of the host the focused surface is logged
/// in to with ssh, over an SFTP connection of its own.
@MainActor
final class RemoteFilesModel: FileTreeModel {
    enum State: Equatable {
        /// Nothing to browse: the focused surface isn't running ssh
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The login being browsed, e.g. `user@host`
    @Published private(set) var title: String?
    /// Whether the login is the one in the focused surface, rather than a saved host
    @Published private(set) var followsTerminal = true
    @Published private(set) var home: String?
    /// Whether `root` moves along with the remote shell's directory, read from the title
    @Published private(set) var followsShell = true
    /// The remote shell's directory, when the title says where it is on this host
    @Published private(set) var shellDirectory: String?
    /// Why the shell's directory isn't followed, like the shell being on another host
    @Published private(set) var shellNotice: ShellNotice?
    /// The logins from the first to the one browsed, like web01 and then db01 ssh'd to
    /// from web01, by title
    @Published private(set) var hops: [String] = []
    /// ssh logins found on the browsed host, when it isn't clear which to switch to
    @Published private(set) var nestedChoices: [NestedSSH] = []
    /// What switching to another login is doing, while it is
    @Published private(set) var nestedStatus: String?

    struct ShellNotice: Equatable {
        enum Action: Equatable {
            /// The shell is on a host ssh'd to from the browsed one
            case switchToNested
            /// The shell is back on the host of an earlier hop
            case returnTo(Int)
        }

        let text: String
        let action: Action?
    }

    /// A login in the chain from the first, and what is known about its host.
    private struct Hop {
        let connection: SSHConnector.Connection
        /// The host's name as `uname -n` gives it, to tell a title from this host from one
        /// from a host ssh'd to from here
        let hostname: String?
        let home: String
        /// The directory shown when the next hop was switched to, to show it again
        var root: String?
    }

    private var target: SSHTarget?
    private var hopStack: [Hop] = []
    private var connection: SSHConnector.Connection? { hopStack.last?.connection }
    private var hostname: String? { hopStack.last?.hostname }
    private var shellTitle: String?
    /// The browsed login's connection, also held by transfers using it, which closes when
    /// no one holds it
    private(set) var client: SFTPClient?
    private var connectTask: Task<Void, Never>?
    /// Logins that failed, with why, so that focusing their surface again doesn't retry
    /// (and ask for a password the user declined) until they reconnect.
    private var failures: [SSHTarget: String] = [:]

    /// Follows the ssh the focused surface runs, given its foreground process group.
    func update(foregroundProcessGroup pgid: Int?) {
        guard followsTerminal else { return }
        guard let process = pgid.flatMap(SSHProcess.find),
              let commandLine = SSHCommandLine.parse(process.arguments) else {
            if target != nil { disconnect() }
            return
        }
        let target = SSHTarget(commandLine: commandLine, authSocket: process.authSocket)
        guard target != self.target else { return }
        if let failure = failures[target] {
            disconnect()
            self.target = target
            title = commandLine.destination
            state = .failed(failure)
        } else {
            connect(target)
        }
    }

    /// Browses a saved host instead of the focused surface's login.
    func browse(_ host: SSHHost) {
        guard let commandLine = SSHCommandLine.parse(host.sshArguments) else { return }
        followsTerminal = false
        connect(SSHTarget(commandLine: commandLine, authSocket: nil))
    }

    /// Goes back to the focused surface's login, which the next `update` picks up.
    func followTerminal() {
        guard !followsTerminal else { return }
        followsTerminal = true
        disconnect()
    }

    func reconnect() {
        guard let target else { return }
        failures[target] = nil
        connect(target)
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        target = nil
        state = .idle
        title = nil
        clearHops()
        setRoot(nil)
    }

    /// Shows the directory; it stops following the shell unless it is the shell's directory.
    func browse(_ path: String) {
        followsShell = path == shellDirectory
        setRoot(path)
    }

    func browseParent() {
        guard let root, root != "/" else { return }
        browse((root as NSString).deletingLastPathComponent)
    }

    func browseHome() {
        if let home { browse(home) }
    }

    // MARK: Following the shell

    /// The focused surface's title changed; it may say where the remote shell is.
    func shellTitleDidChange(_ title: String) {
        shellTitle = title
        applyShellTitle()
    }

    /// Goes back to following the shell's directory.
    func followShell() {
        followsShell = true
        if let shellDirectory { setRoot(shellDirectory) }
    }

    private func applyShellTitle() {
        // Only the focused surface's login has its shell in the title.
        guard followsTerminal, state == .connected, let client, let shellTitle,
              let shell = ShellTitle.parse(shellTitle) else { return }

        if let hostname, !shell.isHost(hostname) {
            if let index = hopStack.indices.dropLast().last(where: { hopStack[$0].hostname.map(shell.isHost) ?? false }) {
                setShellNotice(.init(text: "终端已回到 \(shell.host)", action: .returnTo(index)))
            } else {
                setShellNotice(.init(text: "终端当前在 \(shell.host) 上，这里显示的是 \(hostname) 的文件",
                                     action: .switchToNested))
            }
            return
        }
        let user = connection?.user
        if let user, shell.user != user {
            setShellNotice(.init(text: "终端当前用户是 \(shell.user)，这里以 \(user) 的身份访问", action: nil))
        } else {
            setShellNotice(nil)
        }

        guard let path = shell.absolutePath(loginUser: user, home: home), path != shellDirectory else { return }
        Task {
            // Follow only to a directory that is there, as this user sees it.
            guard (try? await client.stat(path))?.isDirectory == true,
                  client === self.client, ShellTitle.parse(self.shellTitle ?? "") == shell else { return }
            self.shellDirectory = path
            if self.followsShell { self.setRoot(path) }
        }
    }

    private func setShellNotice(_ notice: ShellNotice?) {
        if shellNotice != notice { shellNotice = notice }
    }

    // MARK: Hosts ssh'd to from the browsed one

    /// Switches to the login the browsed host runs: the one the terminal's title names,
    /// or the only one, or else lets the user choose or type it.
    func switchToNested() {
        guard state == .connected, let connection, nestedStatus == nil else { return }
        let shell = shellTitle.flatMap(ShellTitle.parse)
        nestedChoices = []
        nestedStatus = "正在查找 \(connection.title) 上运行的 ssh…"
        Task {
            let found = await SSHConnector.findNested(on: connection)
            guard connection.client === self.client else { return }
            self.nestedStatus = nil
            let matching = shell.map { shell in found.filter { $0.matches(shell) } } ?? []
            if matching.count == 1 {
                self.switchTo(matching[0])
            } else if found.count == 1 {
                self.switchTo(found[0])
            } else if found.isEmpty {
                self.promptForNested(message: "在 \(connection.title) 上没有找到正在运行的 ssh。要切换到的主机（user@host:port）：")
            } else {
                self.nestedChoices = found
            }
        }
    }

    /// Asks for the host to switch to, logged in to from the browsed one.
    func promptForNested(message: String? = nil) {
        guard state == .connected, let connection, nestedStatus == nil else { return }
        nestedChoices = []
        guard let text = Prompt.text("切换到下一跳主机",
                                     message: message ?? "从 \(connection.title) 登录到（user@host:port）：",
                                     value: "", confirm: "切换") else { return }
        Task {
            guard let nested = await SSHConnector.nested(text, on: connection),
                  connection.client === self.client else { return }
            self.switchTo(nested)
        }
    }

    func cancelNestedChoice() {
        nestedChoices = []
    }

    /// Browses the host the login goes to, connecting through the browsed host.
    func switchTo(_ nested: NestedSSH) {
        guard let parent = connection else { return }
        nestedChoices = []
        nestedStatus = "正在切换到 \(nested.title)…需要密码时会弹出输入框"
        Task {
            do {
                let next = try await SSHConnector.connect(nested, through: parent)
                let home = try await next.client.realpath(".")
                let hostname = await next.run("uname -n")?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard parent.client === self.client else {
                    next.client.close()
                    return
                }
                self.nestedStatus = nil
                self.hopStack[self.hopStack.count - 1].root = self.root
                self.hopStack.append(Hop(connection: next, hostname: hostname?.isEmpty == false ? hostname : nil, home: home))
                self.activateLastHop(root: nil)
            } catch {
                guard parent.client === self.client else { return }
                self.nestedStatus = nil
                let alert = NSAlert()
                alert.messageText = "无法切换到 \(nested.title)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Goes back to an earlier login in the chain.
    func returnTo(_ index: Int) {
        guard hopStack.indices.contains(index), index < hopStack.count - 1 else { return }
        // The later logins' connections close once transfers using them finish.
        hopStack.removeSubrange((index + 1)...)
        nestedChoices = []
        activateLastHop(root: hopStack[index].root)
    }

    private func activateLastHop(root: String?) {
        guard let hop = hopStack.last else { return }
        let client = hop.connection.client
        self.client = client
        title = hop.connection.title
        home = hop.home
        hops = hopStack.map(\.connection.title)
        followsShell = true
        shellDirectory = nil
        shellNotice = nil
        state = .connected
        client.onClose { [weak self, weak client] error in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.client = nil
                self.state = .failed(error.localizedDescription)
            }
        }
        setRoot(root ?? hop.home)
        applyShellTitle()
    }

    private func clearHops() {
        // Not closed: transfers still using them keep them open until they finish.
        client = nil
        hopStack = []
        hops = []
        home = nil
        followsShell = true
        shellDirectory = nil
        shellNotice = nil
        nestedChoices = []
        nestedStatus = nil
    }

    /// The path with the home directory shown as `~`.
    func displayPath(_ path: String) -> String {
        guard let home, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    override func reload() {
        guard state == .connected else { return }
        super.reload()
    }

    private func connect(_ target: SSHTarget) {
        connectTask?.cancel()
        self.target = target
        state = .connecting
        title = target.commandLine.destination
        clearHops()
        setRoot(nil)

        connectTask = Task { [weak self] in
            do {
                let connection = try await SSHConnector.connect(target)
                let home = try await connection.client.realpath(".")
                let hostname = await connection.run("uname -n")?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, self.target == target, !Task.isCancelled else {
                    connection.client.close()
                    return
                }
                self.hopStack = [Hop(connection: connection, hostname: hostname?.isEmpty == false ? hostname : nil, home: home)]
                self.activateLastHop(root: nil)
            } catch {
                guard let self, self.target == target, !Task.isCancelled else { return }
                self.failures[target] = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Changes

    func createFolder(in directory: String) {
        guard let client, let name = Prompt.text("新建文件夹", message: "在 \(displayPath(directory)) 中新建：",
                                                 value: "未命名文件夹", confirm: "新建") else { return }
        run { try await client.mkdir(FileEntry.join(directory, name), permissions: 0o755) }
    }

    func rename(_ entry: FileEntry) {
        guard let client, let name = Prompt.text("重命名", message: "“\(entry.name)”的新名称：",
                                                 value: entry.name, confirm: "重命名"),
              name != entry.name else { return }
        let destination = FileEntry.join((entry.path as NSString).deletingLastPathComponent, name)
        run {
            // SFTP's rename doesn't replace, but check so the error says why.
            if (try? await client.lstat(destination)) != nil { throw RemoteChangeError.exists(name) }
            try await client.rename(entry.path, to: destination)
        }
    }

    func delete(_ entry: FileEntry) {
        guard let client else { return }
        let alert = NSAlert()
        alert.messageText = "删除“\(entry.name)”？"
        alert.informativeText = entry.isDirectory && !entry.isSymlink
            ? "将从 \(title ?? "远程主机") 永久删除该文件夹及其中的所有内容，无法恢复。"
            : "将从 \(title ?? "远程主机") 永久删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { try await SFTPTransfer.removeRecursively(entry.path, client: client) }
    }

    /// Runs a change, then shows the result or the error.
    private func run(_ change: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await change()
            } catch {
                NSAlert(error: error).runModal()
            }
            reload()
        }
    }

    override func list(_ directory: String) async -> Result<[FileEntry], Error> {
        guard let client else { return .failure(SFTPError.disconnected("")) }
        do {
            let items = try await client.listDirectory(directory)
            let entries = await withTaskGroup(of: FileEntry.self) { group in
                for item in items {
                    group.addTask {
                        let path = FileEntry.join(directory, item.name)
                        var attributes = item.attributes
                        let isSymlink = attributes.isSymlink
                        // A link is listed as what it points to, if that can be read.
                        if isSymlink, let target = try? await client.stat(path) { attributes = target }
                        return FileEntry(
                            path: path,
                            isDirectory: attributes.isDirectory,
                            isSymlink: isSymlink,
                            size: attributes.isDirectory ? nil : attributes.size,
                            modified: attributes.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            return .success(entries)
        } catch {
            return .failure(error)
        }
    }
}

enum RemoteChangeError: LocalizedError {
    case exists(String)

    var errorDescription: String? {
        switch self {
        case .exists(let name): return "“\(name)”已存在"
        }
    }
}

/// Asks for a line of text, like a new name.
@MainActor
enum Prompt {
    static func text(_ title: String, message: String, value: String, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("/") else { return nil }
        return text
    }
}

/// What dragging between the files tab's halves carries.
enum FileDrag {
    /// A remote path (declared in Info.plist)
    static let remoteType = UTType(exportedAs: "com.mitchellh.ghosttyRemoteFilePath")

    /// A local row's drag: its file URL, which a terminal types as a path, Finder copies,
    /// and the remote half uploads.
    static func localProvider(_ url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    /// A remote row's drag: its path for the local half, and the path as text for a
    /// terminal, which is likely logged in to the same host.
    static func remoteProvider(_ path: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: remoteType.identifier, visibility: .all) { completion in
            completion(Data(path.utf8), nil)
            return nil
        }
        provider.registerObject(path.shellQuoted as NSString, visibility: .all)
        return provider
    }

    static func loadRemotePaths(_ providers: [NSItemProvider], _ completion: @escaping @MainActor ([String]) -> Void) -> Bool {
        logger.notice("drop: \(providers.count) remote item(s)")
        guard !providers.isEmpty else { return false }
        collect(providers, completion) { provider, done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: remoteType.identifier) { data, error in
                if let error { logger.error("drop: loading a remote path failed: \(error.localizedDescription)") }
                done(data.map { String(decoding: $0, as: UTF8.self) })
            }
        }
        return true
    }

    /// Files dragged from the local half or Finder.
    static func loadFileURLs(_ providers: [NSItemProvider], _ completion: @escaping @MainActor ([String]) -> Void) -> Bool {
        logger.notice("drop: \(providers.count) file URL item(s)")
        guard !providers.isEmpty else { return false }
        collect(providers, completion) { provider, done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    return done(url.path)
                }
                if let error { logger.error("drop: loading a file URL failed: \(error.localizedDescription)") }
                // Some sources only give the URL as an object.
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    done((object as? URL)?.path)
                }
            }
        }
        return true
    }

    /// Loads a string from each provider, then calls `completion` on the main actor with
    /// them in the providers' order.
    private static func collect(
        _ providers: [NSItemProvider],
        _ completion: @escaping @MainActor ([String]) -> Void,
        load: (NSItemProvider, @escaping @Sendable (String?) -> Void) -> Void
    ) {
        let lock = NSLock()
        nonisolated(unsafe) var results = [String?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            load(provider) { value in
                lock.withLock { results[index] = value }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let paths = lock.withLock { results.compactMap { $0 } }
            logger.notice("drop: loaded \(paths.count) of \(providers.count) path(s)")
            Task { @MainActor in completion(paths) }
        }
    }
}

struct FilesView: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var files: LocalFilesModel
    @ObservedObject var remote: RemoteFilesModel
    @ObservedObject var transfers: FileTransfers

    var body: some View {
        VSplitView {
            LocalFilesPane(model: model, files: files, remote: remote)
                .frame(minHeight: 120, maxHeight: .infinity)
            VStack(spacing: 0) {
                RemoteFilesPane(model: model, files: files, remote: remote)
                if !transfers.items.isEmpty {
                    TransfersView(transfers: transfers)
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
        }
        .onAppear(perform: model.refresh)
    }
}

private struct LocalFilesPane: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var files: LocalFilesModel
    @ObservedObject var remote: RemoteFilesModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("本机文件")
                    .font(.headline)
                Spacer()
                Button(action: files.browseParent) {
                    Image(systemName: "arrow.up")
                }
                .help("上级目录")
                .disabled(files.root == nil || files.root == "/")
                Button(action: files.followTerminal) {
                    Image(systemName: files.followsTerminal ? "location.fill" : "location")
                        .foregroundColor(files.followsTerminal ? .accentColor : nil)
                }
                .help(files.followsTerminal ? "正在跟随当前标签页的目录" : "回到当前标签页的目录")
                HiddenFilesButton(tree: files)
                Button(action: files.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
            .buttonStyle(.borderless)

            Text(files.root?.abbreviatingHome ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(files.root ?? "")

            if files.root == nil {
                FileTreePlaceholder(text: "无法确定当前目录")
                Spacer(minLength: 0)
            } else {
                FileTreeList(tree: files) { entry, depth in
                    FileTreeRow(
                        entry: entry,
                        depth: depth,
                        tree: files,
                        tooltip: FileTreeRow<EmptyView>.tooltip(entry, path: entry.path.abbreviatingHome),
                        open: { open(entry) },
                        drag: {
                            // Dropping on a terminal types the path, like a drag from Finder;
                            // dropping on the remote half uploads it.
                            FileDrag.localProvider(url(entry))
                        },
                        drop: download(into: entry.path),
                        menu: { menu(entry) })
                }
                .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
                .fileTreeDrop(download(into: files.root ?? "/"), targeted: $targeted)
            }
        }
        .padding(.bottom, 6)
    }

    /// Downloads remote rows dropped on a folder into it.
    private func download(into directory: String) -> FileTreeDrop {
        FileTreeDrop(types: [FileDrag.remoteType]) { providers in
            FileDrag.loadRemotePaths(providers) { paths in
                guard let client = remote.client else { return logger.error("drop: no remote connection to download from") }
                model.transfers.download(paths, to: directory, client: client, host: remote.title ?? "")
            }
        }
    }

    private func url(_ entry: FileEntry) -> URL {
        URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)
    }

    /// Double-clicking browses into a directory, shows Markdown rendered in a new tab
    /// and opens any other file with its default app.
    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            files.browse(entry.path)
        } else if MarkdownTerminal.isMarkdown(entry.path) {
            model.viewMarkdown(entry.path)
        } else {
            NSWorkspace.shared.open(url(entry))
        }
    }

    @ViewBuilder
    private func menu(_ entry: FileEntry) -> some View {
        if remote.state == .connected, let client = remote.client, let destination = remote.root {
            Button("上传到 \(remote.displayPath(destination))") {
                model.transfers.upload([entry.path], to: destination, client: client,
                                       host: remote.title ?? "", displayDirectory: remote.displayPath(destination))
            }
            Divider()
        }
        if entry.isDirectory {
            Button("进入该目录") { files.browse(entry.path) }
            Button("在新标签页中打开") { model.runInNewTab("", directory: entry.path) }
            Button("在当前标签页中 cd 到该目录") { model.insert("cd " + entry.path.shellQuoted, execute: true) }
        } else if MarkdownTerminal.isMarkdown(entry.path) {
            Button("在新标签页中预览") { model.viewMarkdown(entry.path) }
            Button("用默认应用打开") { NSWorkspace.shared.open(url(entry)) }
        } else {
            Button("打开") { NSWorkspace.shared.open(url(entry)) }
        }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url(entry)]) }
        Divider()
        Button("将路径输入到当前标签页") { model.insert(entry.path.shellQuoted + " ", execute: false) }
        Button("复制路径") { Pasteboard.copy(entry.path) }
        Button("复制名称") { Pasteboard.copy(entry.name) }
    }
}

private struct RemoteFilesPane: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var files: LocalFilesModel
    @ObservedObject var remote: RemoteFilesModel
    @ObservedObject var hosts = SSHHostStore.shared
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("远程主机")
                    .font(.headline)
                Spacer()
                if remote.state == .connected {
                    Button(action: remote.browseParent) {
                        Image(systemName: "arrow.up")
                    }
                    .help("上级目录")
                    .disabled(remote.root == "/")
                    Button(action: remote.browseHome) {
                        Image(systemName: "house")
                    }
                    .help("家目录")
                    if remote.followsTerminal {
                        let following = remote.followsShell && remote.shellDirectory != nil
                        Button(action: remote.followShell) {
                            Image(systemName: following ? "location.fill" : "location")
                                .foregroundColor(following ? .accentColor : nil)
                        }
                        .help(remote.shellDirectory == nil
                            ? "跟随终端中远程 shell 的目录（从标签页标题读取，当前标题中没有目录信息）"
                            : following ? "正在跟随终端中远程 shell 的目录" : "回到终端中远程 shell 的目录")
                    }
                    Button {
                        if let root = remote.root { remote.createFolder(in: root) }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("新建文件夹")
                    HiddenFilesButton(tree: remote)
                    Button(action: remote.reload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                }
                optionsMenu
            }
            .buttonStyle(.borderless)

            if let title = remote.title {
                HStack(spacing: 3) {
                    // The earlier logins of a chain, to go back to.
                    ForEach(Array(remote.hops.dropLast().enumerated()), id: \.offset) { index, hop in
                        Button(hop) { remote.returnTo(index) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .help("返回 \(hop)")
                        Text("›")
                    }
                    Text(location(title))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(remote.root.map { "\(title):\($0)" } ?? title)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if remote.state == .connected {
                nestedControls
            }

            content
        }
        .padding(.top, 6)
    }

    /// The notice about where the shell is, and switching to a host ssh'd to from here.
    @ViewBuilder
    private var nestedControls: some View {
        if let status = remote.nestedStatus {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        } else if !remote.nestedChoices.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("选择要切换到的主机：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(remote.nestedChoices) { nested in
                    Button {
                        remote.switchTo(nested)
                    } label: {
                        Text(nested.tty.map { "\(nested.title)（\($0)）" } ?? nested.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help((["ssh"] + nested.commandLine.options + [nested.commandLine.destination]).joined(separator: " "))
                }
                HStack(spacing: 8) {
                    Button("手动输入…") { remote.promptForNested() }
                    Button("取消", action: remote.cancelNestedChoice)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } else if let notice = remote.shellNotice {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Label(notice.text, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .help(notice.text)
                switch notice.action {
                case .switchToNested:
                    Button("切换", action: remote.switchToNested)
                        .buttonStyle(.link)
                        .help("在这里浏览终端所在的主机")
                case .returnTo(let index):
                    Button("返回") { remote.returnTo(index) }
                        .buttonStyle(.link)
                case nil:
                    EmptyView()
                }
            }
            .font(.caption)
        }
    }

    private func location(_ title: String) -> String {
        guard let root = remote.root else { return title }
        return "\(title)  \(remote.displayPath(root))"
    }

    @ViewBuilder
    private var content: some View {
        switch remote.state {
        case .idle:
            FileTreePlaceholder(text: remote.followsTerminal
                ? "当前标签页没有运行 ssh。在终端中 ssh 登录后，这里会显示远程主机的文件；也可以从右上角菜单选择已保存的主机。"
                : "未连接")
            Spacer(minLength: 0)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在连接…需要密码时会弹出输入框")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            Spacer(minLength: 0)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                Button("重新连接", action: remote.reconnect)
                    .controlSize(.small)
            }
            .padding(.vertical, 6)
            Spacer(minLength: 0)
        case .connected:
            FileTreeList(tree: remote) { entry, depth in
                FileTreeRow(
                    entry: entry,
                    depth: depth,
                    tree: remote,
                    tooltip: FileTreeRow<EmptyView>.tooltip(entry, path: remote.displayPath(entry.path)),
                    open: { open(entry) },
                    drag: { FileDrag.remoteProvider(entry.path) },
                    drop: upload(into: entry.path),
                    menu: { menu(entry) })
            }
            .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .fileTreeDrop(upload(into: remote.root ?? "/"), targeted: $targeted)
        }
    }

    /// Uploads files from the local half or Finder dropped on a folder into it.
    private func upload(into directory: String) -> FileTreeDrop {
        FileTreeDrop(types: [.fileURL]) { providers in
            FileDrag.loadFileURLs(providers) { paths in
                guard let client = remote.client else { return logger.error("drop: no remote connection to upload to") }
                model.transfers.upload(paths, to: directory, client: client, host: remote.title ?? "",
                                       displayDirectory: remote.displayPath(directory))
            }
        }
    }

    /// Double-clicking browses into a directory and, from a temporary copy, shows
    /// Markdown rendered in a new tab and opens any other file with its default app.
    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            remote.browse(entry.path)
        } else if MarkdownTerminal.isMarkdown(entry.path) {
            preview(entry)
        } else {
            openWithDefaultApp(entry)
        }
    }

    private func preview(_ entry: FileEntry) {
        guard let client = remote.client else { return }
        let host = remote.title ?? ""
        let title = host.isEmpty ? entry.name : "\(host): \(entry.name)"
        model.transfers.open(entry.path, client: client, host: host) { [model] local in
            model.viewMarkdown(local.path, title: title)
        }
    }

    private func openWithDefaultApp(_ entry: FileEntry) {
        guard let client = remote.client else { return }
        model.transfers.open(entry.path, client: client, host: remote.title ?? "")
    }

    @ViewBuilder
    private func menu(_ entry: FileEntry) -> some View {
        if let client = remote.client, let destination = files.root {
            Button("下载到 \(destination.abbreviatingHome)") {
                model.transfers.download([entry.path], to: destination, client: client, host: remote.title ?? "")
            }
            if MarkdownTerminal.isMarkdown(entry.path) {
                Button("在新标签页中预览") { preview(entry) }
                Button("用默认应用打开（下载到临时文件夹）") { openWithDefaultApp(entry) }
            } else if !entry.isDirectory {
                Button("打开（下载到临时文件夹）") { openWithDefaultApp(entry) }
            }
            Divider()
        }
        if entry.isDirectory {
            Button("进入该目录") { remote.browse(entry.path) }
            if remote.followsTerminal {
                // The focused surface is logged in to this host, so a cd there moves its shell.
                Button("在当前标签页中 cd 到该目录") { model.insert("cd " + entry.path.shellQuoted, execute: true) }
            }
            Button("在此新建文件夹…") { remote.createFolder(in: entry.path) }
            Divider()
        }
        if remote.followsTerminal {
            Button("将路径输入到当前标签页") { model.insert(entry.path.shellQuoted + " ", execute: false) }
        }
        Button("复制路径") { Pasteboard.copy(entry.path) }
        Button("复制名称") { Pasteboard.copy(entry.name) }
        Divider()
        Button("重命名…") { remote.rename(entry) }
        Button("删除…") { remote.delete(entry) }
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                remote.followTerminal()
                model.refresh()
            } label: {
                if remote.followsTerminal {
                    Label("跟随当前标签页的 ssh", systemImage: "checkmark")
                } else {
                    Text("跟随当前标签页的 ssh")
                }
            }
            if !hosts.hosts.isEmpty {
                Menu("浏览已保存的主机") {
                    ForEach(hosts.hosts) { host in
                        Button(host.title) { remote.browse(host) }
                    }
                }
            }
            Divider()
            Button("切换到下一跳主机…", action: remote.switchToNested)
                .disabled(remote.state != .connected)
            Button("手动输入下一跳主机…") { remote.promptForNested() }
                .disabled(remote.state != .connected)
            if remote.hops.count > 1 {
                Button("返回 \(remote.hops[remote.hops.count - 2])") { remote.returnTo(remote.hops.count - 2) }
            }
            Divider()
            Button("重新连接", action: remote.reconnect)
                .disabled(remote.state == .idle)
            Button("断开", action: remote.disconnect)
                .disabled(remote.state == .idle)
            Divider()
            Button(SSHGlobalMultiplexing.isEnabled ? "移除全局连接复用…" : "为所有 ssh 登录启用连接复用…") {
                SSHGlobalMultiplexing.toggleWithConfirmation()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("远程选项")
    }
}

/// The transfer queue, below the remote files.
private struct TransfersView: View {
    @ObservedObject var transfers: FileTransfers

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text("传输")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if transfers.items.contains(where: { $0.status.isFinished }) {
                    Button("清除已完成", action: transfers.clearFinished)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(transfers.items.reversed()) { item in
                        TransferRow(item: item) { transfers.cancel(item.id) }
                    }
                }
            }
            // About three rows; more scroll.
            .frame(height: min(CGFloat(transfers.items.count) * 46, 140))
        }
        .padding(.top, 4)
    }
}

private struct TransferRow: View {
    let item: FileTransfers.Item
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundColor(.secondary)
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                statusIcon
            }
            .font(.caption)
            if item.status == .running {
                ProgressView(value: item.total > 0 ? min(Double(item.done) / Double(item.total), 1) : 0)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            Text(detail)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(help)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .queued, .running:
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("取消")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary)
        }
    }

    private var detail: String {
        let size = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
        switch item.status {
        case .queued:
            return "等待中 · 到 \(item.destination)"
        case .running:
            var text = item.total > 0 ? "\(size(item.done)) / \(size(item.total))" : size(item.done)
            if item.speed > 0 { text += " · \(size(UInt64(item.speed)))/s" }
            return text
        case .done:
            return "已完成 · \(size(item.total)) · 到 \(item.destination)"
        case .failed(let message):
            return "失败：\(message)"
        case .cancelled:
            return "已取消"
        }
    }

    private var help: String {
        let place = item.direction == .upload ? "\(item.host):\(item.destination)" : item.destination
        if case .failed(let message) = item.status { return "\(item.name) → \(place)\n\(message)" }
        return "\(item.name) → \(place)"
    }
}

private struct HiddenFilesButton: View {
    @ObservedObject var tree: FileTreeModel

    var body: some View {
        Button { tree.showHidden.toggle() } label: {
            Image(systemName: tree.showHidden ? "eye" : "eye.slash")
        }
        .help(tree.showHidden ? "隐藏隐藏文件" : "显示隐藏文件")
    }
}
