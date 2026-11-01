import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file or directory listed in the files tab.
struct LocalFileEntry: Identifiable, Equatable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int?
    let modified: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
}

/// State behind the local half of the files tab: a tree of the directory the focused
/// surface is in, unless the user browsed somewhere else.
@MainActor
final class LocalFilesModel: ObservableObject {
    private static let queue = DispatchQueue(label: "com.mitchellh.ghostty.local-files", qos: .userInitiated)

    /// The directory at the top of the tree
    @Published private(set) var root: String?
    /// Whether `root` moves along with the focused surface's working directory
    @Published private(set) var followsTerminal = true
    @Published var showHidden = false {
        didSet { if showHidden != oldValue { reload() } }
    }
    @Published private(set) var expanded: Set<String> = []
    /// The listing of every loaded directory, by path
    @Published private(set) var listings: [String: [LocalFileEntry]] = [:]
    /// Directories that could not be read, with the reason
    @Published private(set) var errors: [String: String] = [:]
    @Published var selection: String?

    private var terminalDirectory: String?
    private var loading: Set<String> = []

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

    func toggle(_ entry: LocalFileEntry) {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            if listings[entry.path] == nil { load([entry.path]) }
        }
    }

    /// Re-reads the root and the expanded directories, publishing only what changed.
    func reload() {
        guard let root else { return }
        load([root] + expanded.filter { $0.hasPrefix(root) })
    }

    /// The rows to show: the root's entries with expanded directories' entries below them.
    var rows: [(entry: LocalFileEntry, depth: Int)] {
        guard let root else { return [] }
        var rows: [(LocalFileEntry, Int)] = []
        func append(_ directory: String, depth: Int) {
            for entry in listings[directory] ?? [] {
                rows.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.path) {
                    append(entry.path, depth: depth + 1)
                }
            }
        }
        append(root, depth: 0)
        return rows
    }

    private func setRoot(_ path: String) {
        guard path != root else { return }
        root = path
        expanded = []
        listings = [:]
        errors = [:]
        selection = nil
        reload()
    }

    private func load(_ directories: [String]) {
        let directories = directories.filter { !loading.contains($0) }
        guard !directories.isEmpty else { return }
        loading.formUnion(directories)
        let showHidden = self.showHidden

        Self.queue.async { [weak self] in
            let results = directories.map { ($0, Self.list($0, showHidden: showHidden)) }
            Task { @MainActor in
                guard let self else { return }
                self.loading.subtract(directories)
                // A listing made with the other hidden setting is out of date; the
                // reload the setting started brings the right one.
                guard showHidden == self.showHidden else { return }
                for (directory, result) in results {
                    switch result {
                    case .success(let entries):
                        if self.listings[directory] != entries { self.listings[directory] = entries }
                        if self.errors[directory] != nil { self.errors[directory] = nil }
                    case .failure(let error):
                        if self.listings[directory] != nil { self.listings[directory] = nil }
                        if directory != self.root {
                            // A directory that went away is no longer shown expanded.
                            self.expanded.remove(directory)
                        }
                        let message = error.localizedDescription
                        if self.errors[directory] != message { self.errors[directory] = message }
                    }
                }
            }
        }
    }

    nonisolated private static func list(_ directory: String, showHidden: Bool) -> Result<[LocalFileEntry], Error> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles])
            let entries = urls.map { url -> LocalFileEntry in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isSymlink = values?.isSymbolicLink ?? false
                // A link to a directory is listed as a directory.
                let isDirectory = isSymlink
                    ? (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    : values?.isDirectory ?? false
                return LocalFileEntry(
                    path: (directory as NSString).appendingPathComponent(url.lastPathComponent),
                    isDirectory: isDirectory,
                    isSymlink: isSymlink,
                    size: isDirectory ? nil : values?.fileSize,
                    modified: values?.contentModificationDate)
            }
            return .success(entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        } catch {
            return .failure(error)
        }
    }
}

struct LocalFilesView: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var files: LocalFilesModel

    var body: some View {
        VSplitView {
            local
                .frame(minHeight: 160, maxHeight: .infinity)
            remote
                .frame(minHeight: 80, idealHeight: 140, maxHeight: .infinity)
        }
        .onAppear { files.reload() }
    }

    private var local: some View {
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
                Button { files.showHidden.toggle() } label: {
                    Image(systemName: files.showHidden ? "eye" : "eye.slash")
                }
                .help(files.showHidden ? "隐藏隐藏文件" : "显示隐藏文件")
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let root = files.root {
                        if let error = files.errors[root] {
                            placeholder(error)
                        } else if files.listings[root]?.isEmpty == true {
                            placeholder("空目录")
                        }
                    } else {
                        placeholder("无法确定当前目录")
                    }

                    ForEach(files.rows, id: \.entry.id) { row in
                        LocalFileRow(
                            entry: row.entry,
                            depth: row.depth,
                            isExpanded: files.expanded.contains(row.entry.path),
                            isSelected: files.selection == row.entry.path,
                            files: files,
                            model: model)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var remote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("远程主机")
                .font(.headline)
            Text("SSH 登录后在此显示远程主机的目录（开发中）")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
    }
}

private struct LocalFileRow: View {
    let entry: LocalFileEntry
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let files: LocalFilesModel
    let model: ClaudeSessionsModel

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if entry.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 10)
            Image(nsImage: FileIcons.icon(for: entry))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .italic(entry.isSymlink)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12 + 2)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : hovered ? Color.primary.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded(open))
        .simultaneousGesture(TapGesture().onEnded {
            files.selection = entry.path
            if entry.isDirectory { files.toggle(entry) }
        })
        .onDrag {
            // Dropping on a terminal types the path, like a drag from Finder.
            NSItemProvider(contentsOf: entry.url) ?? NSItemProvider()
        }
        .help(tooltip)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if entry.isDirectory {
            Button("进入该目录") { files.browse(entry.path) }
            Button("在新标签页中打开") { model.runInNewTab("", directory: entry.path) }
            Button("在当前标签页中 cd 到该目录") { model.insert("cd " + entry.path.shellQuoted, execute: true) }
        } else {
            Button("打开") { NSWorkspace.shared.open(entry.url) }
        }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Divider()
        Button("将路径输入到当前标签页") { model.insert(entry.path.shellQuoted + " ", execute: false) }
        Button("复制路径") { copy(entry.path) }
        Button("复制名称") { copy(entry.name) }
    }

    /// Double-clicking opens a file with its default app and browses into a directory.
    private func open() {
        if entry.isDirectory {
            files.browse(entry.path)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var tooltip: String {
        var lines = [entry.path.abbreviatingHome]
        if let size = entry.size {
            lines.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let modified = entry.modified {
            lines.append("修改于 " + modified.formatted(date: .numeric, time: .shortened))
        }
        return lines.joined(separator: "\n")
    }
}

/// File type icons, cached by type since a tree can show many files of the same type.
@MainActor
private enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: LocalFileEntry) -> NSImage {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let key = entry.isDirectory ? "/" : ext
        if let icon = cache[key] { return icon }
        let type: UTType = entry.isDirectory ? .folder : UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}
