import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file or directory listed in one of the files tab's trees.
struct FileEntry: Identifiable, Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64?
    let modified: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    var isHidden: Bool { name.hasPrefix(".") }

    /// Directories first, then by name as Finder sorts them.
    static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}

/// A tree of directories that loads them as they are expanded. Subclasses list a directory.
@MainActor
class FileTreeModel: ObservableObject {
    /// The directory at the top of the tree
    @Published private(set) var root: String?
    /// Listings include hidden files; this only decides whether rows show them.
    @Published var showHidden = false
    @Published private(set) var expanded: Set<String> = []
    /// The listing of every loaded directory, by path
    @Published private(set) var listings: [String: [FileEntry]] = [:]
    /// Directories that could not be read, with the reason
    @Published private(set) var errors: [String: String] = [:]
    @Published var selection: String?

    private var loading: Set<String> = []
    /// Bumped when the root changes, so listings of the previous root are dropped.
    private var generation = 0

    /// Lists the directory. Overridden by subclasses.
    func list(_ directory: String) async -> Result<[FileEntry], Error> {
        .success([])
    }

    func setRoot(_ path: String?) {
        guard path != root else { return }
        root = path
        generation += 1
        expanded = []
        listings = [:]
        errors = [:]
        loading = []
        selection = nil
        reload()
    }

    func toggle(_ entry: FileEntry) {
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
        load([root] + expanded)
    }

    /// The rows to show: the root's entries with expanded directories' entries below them.
    var rows: [(entry: FileEntry, depth: Int)] {
        guard let root else { return [] }
        var rows: [(FileEntry, Int)] = []
        func append(_ directory: String, depth: Int) {
            for entry in listings[directory] ?? [] where showHidden || !entry.isHidden {
                rows.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.path) {
                    append(entry.path, depth: depth + 1)
                }
            }
        }
        append(root, depth: 0)
        return rows
    }

    private func load(_ directories: [String]) {
        let directories = directories.filter { !loading.contains($0) }
        guard !directories.isEmpty else { return }
        loading.formUnion(directories)
        let generation = self.generation

        Task { @MainActor in
            for directory in directories {
                let result = await self.list(directory)
                guard generation == self.generation else { return }
                self.loading.remove(directory)
                switch result {
                case .success(let entries):
                    let entries = FileEntry.sorted(entries)
                    if self.listings[directory] != entries { self.listings[directory] = entries }
                    if self.errors[directory] != nil { self.errors[directory] = nil }
                case .failure(let error):
                    if self.listings[directory] != nil { self.listings[directory] = nil }
                    // A directory that went away is no longer shown expanded.
                    if directory != self.root { self.expanded.remove(directory) }
                    let message = error.localizedDescription
                    if self.errors[directory] != message { self.errors[directory] = message }
                }
            }
        }
    }
}

/// The scrolling list of a tree's rows, with the root's error or emptiness shown above them.
struct FileTreeList<Row: View>: View {
    @ObservedObject var tree: FileTreeModel
    @ViewBuilder let row: (_ entry: FileEntry, _ depth: Int) -> Row

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let root = tree.root {
                    if let error = tree.errors[root] {
                        FileTreePlaceholder(text: error)
                    } else if let listing = tree.listings[root],
                              !listing.contains(where: { tree.showHidden || !$0.isHidden }) {
                        FileTreePlaceholder(text: "空目录")
                    }
                }

                ForEach(tree.rows, id: \.entry.id) { item in
                    row(item.entry, item.depth)
                }
            }
        }
    }
}

struct FileTreePlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of a file tree. Clicking a directory expands it; double-clicking calls `open`.
struct FileTreeRow<Menu: View>: View {
    let entry: FileEntry
    let depth: Int
    @ObservedObject var tree: FileTreeModel
    let tooltip: String
    let open: () -> Void
    /// Gives what dragging the row carries; the row can't be dragged without it.
    var drag: (() -> NSItemProvider)?
    @ViewBuilder let menu: () -> Menu

    @State private var hovered = false

    private var isSelected: Bool { tree.selection == entry.path }

    var body: some View {
        content
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
                tree.selection = entry.path
                if entry.isDirectory { tree.toggle(entry) }
            })
            .modifier(DragModifier(provider: drag))
            .help(tooltip)
            .contextMenu { menu() }
    }

    private var content: some View {
        HStack(spacing: 3) {
            Group {
                if entry.isDirectory {
                    Image(systemName: tree.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
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
    }

    /// The path, size and modification date of the entry, shown as a row's tooltip.
    static func tooltip(_ entry: FileEntry, path: String) -> String {
        var lines = [path]
        if let size = entry.size {
            lines.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
        }
        if let modified = entry.modified {
            lines.append("修改于 " + modified.formatted(date: .numeric, time: .shortened))
        }
        return lines.joined(separator: "\n")
    }
}

private struct DragModifier: ViewModifier {
    let provider: (() -> NSItemProvider)?

    func body(content: Content) -> some View {
        if let provider {
            content.onDrag(provider)
        } else {
            content
        }
    }
}

/// File type icons, cached by type since a tree can show many files of the same type.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: FileEntry) -> NSImage {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let key = entry.isDirectory ? "/" : ext
        if let icon = cache[key] { return icon }
        let type: UTType = entry.isDirectory ? .folder : UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
