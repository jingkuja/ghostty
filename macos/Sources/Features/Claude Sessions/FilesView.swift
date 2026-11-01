import AppKit
import SwiftUI

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

    private var target: SSHTarget?
    private var client: SFTPClient?
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
        client?.close()
        client = nil
        target = nil
        state = .idle
        title = nil
        home = nil
        setRoot(nil)
    }

    func browse(_ path: String) { setRoot(path) }

    func browseParent() {
        guard let root, root != "/" else { return }
        setRoot((root as NSString).deletingLastPathComponent)
    }

    func browseHome() {
        if let home { setRoot(home) }
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
        client?.close()
        client = nil
        self.target = target
        state = .connecting
        title = target.commandLine.destination
        home = nil
        setRoot(nil)

        connectTask = Task { [weak self] in
            do {
                let connection = try await SSHConnector.connect(target)
                let home = try await connection.client.realpath(".")
                guard let self, self.target == target, !Task.isCancelled else {
                    connection.client.close()
                    return
                }
                let client = connection.client
                self.client = client
                self.title = connection.title
                self.home = home
                self.state = .connected
                client.onClose { [weak self, weak client] error in
                    Task { @MainActor in
                        guard let self, let client, self.client === client else { return }
                        self.client = nil
                        self.state = .failed(error.localizedDescription)
                    }
                }
                self.setRoot(home)
            } catch {
                guard let self, self.target == target, !Task.isCancelled else { return }
                self.failures[target] = error.localizedDescription
                self.state = .failed(error.localizedDescription)
            }
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

struct FilesView: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var files: LocalFilesModel
    @ObservedObject var remote: RemoteFilesModel

    var body: some View {
        VSplitView {
            LocalFilesPane(model: model, files: files)
                .frame(minHeight: 120, maxHeight: .infinity)
            RemoteFilesPane(model: model, remote: remote)
                .frame(minHeight: 120, maxHeight: .infinity)
        }
        .onAppear(perform: model.refresh)
    }
}

private struct LocalFilesPane: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var files: LocalFilesModel

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
                            // Dropping on a terminal types the path, like a drag from Finder.
                            NSItemProvider(contentsOf: url(entry)) ?? NSItemProvider()
                        },
                        menu: { menu(entry) })
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func url(_ entry: FileEntry) -> URL {
        URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)
    }

    /// Double-clicking opens a file with its default app and browses into a directory.
    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            files.browse(entry.path)
        } else {
            NSWorkspace.shared.open(url(entry))
        }
    }

    @ViewBuilder
    private func menu(_ entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button("进入该目录") { files.browse(entry.path) }
            Button("在新标签页中打开") { model.runInNewTab("", directory: entry.path) }
            Button("在当前标签页中 cd 到该目录") { model.insert("cd " + entry.path.shellQuoted, execute: true) }
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
    @ObservedObject var remote: RemoteFilesModel
    @ObservedObject var hosts = SSHHostStore.shared

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
                Text(location(title))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(remote.root.map { "\(title):\($0)" } ?? title)
            }

            content
        }
        .padding(.top, 6)
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
                    open: { if entry.isDirectory { remote.browse(entry.path) } },
                    menu: { menu(entry) })
            }
        }
    }

    @ViewBuilder
    private func menu(_ entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button("进入该目录") { remote.browse(entry.path) }
            if remote.followsTerminal {
                // The focused surface is logged in to this host, so a cd there moves its shell.
                Button("在当前标签页中 cd 到该目录") { model.insert("cd " + entry.path.shellQuoted, execute: true) }
            }
            Divider()
        }
        if remote.followsTerminal {
            Button("将路径输入到当前标签页") { model.insert(entry.path.shellQuoted + " ", execute: false) }
        }
        Button("复制路径") { Pasteboard.copy(entry.path) }
        Button("复制名称") { Pasteboard.copy(entry.name) }
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

private struct HiddenFilesButton: View {
    @ObservedObject var tree: FileTreeModel

    var body: some View {
        Button { tree.showHidden.toggle() } label: {
            Image(systemName: tree.showHidden ? "eye" : "eye.slash")
        }
        .help(tree.showHidden ? "隐藏隐藏文件" : "显示隐藏文件")
    }
}
