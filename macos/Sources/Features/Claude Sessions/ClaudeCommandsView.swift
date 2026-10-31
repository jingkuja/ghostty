import AppKit
import SwiftUI

/// A frequently used command shown in the panel's commands tab.
struct ClaudeCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
}

/// The commands listed in the panel, shared by all windows and kept in the user defaults.
@MainActor
final class ClaudeCommandStore: ObservableObject {
    static let shared = ClaudeCommandStore()

    private static let defaultsKey = "ClaudeCommands"

    static let defaultCommands: [ClaudeCommand] = [
        .init(name: "添加目录并加载其 CLAUDE.md",
              command: "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir "),
        .init(name: "继续最近的会话", command: "claude --continue"),
        .init(name: "选择会话恢复", command: "claude --resume"),
        .init(name: "以计划模式启动", command: "claude --permission-mode plan"),
        .init(name: "跳过权限确认", command: "claude --dangerously-skip-permissions"),
        .init(name: "列出 MCP 服务器", command: "claude mcp list"),
        .init(name: "检查安装状态", command: "claude doctor"),
        .init(name: "更新 Claude Code", command: "claude update"),
    ]

    @Published private(set) var commands: [ClaudeCommand]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let commands = try? JSONDecoder().decode([ClaudeCommand].self, from: data) {
            self.commands = commands
        } else {
            self.commands = Self.defaultCommands
        }
    }

    /// Adds the command, or replaces the one with the same ID.
    func save(_ command: ClaudeCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
        persist()
    }

    func remove(_ command: ClaudeCommand) {
        commands.removeAll { $0.id == command.id }
        persist()
    }

    /// Moves the command one place up (`offset` -1) or down (`offset` 1).
    func move(_ command: ClaudeCommand, by offset: Int) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }),
              commands.indices.contains(index + offset) else { return }
        commands.swapAt(index, index + offset)
        persist()
    }

    func restoreDefaults() {
        commands = Self.defaultCommands
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

struct ClaudeCommandsView: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var store = ClaudeCommandStore.shared
    @State private var filter = ""
    /// The command being added or edited in the sheet
    @State private var editing: ClaudeCommand?

    private var commands: [ClaudeCommand] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.commands }
        return store.commands.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.command.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("CC 常用命令")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("添加命令…") { editing = ClaudeCommand(name: "", command: "") }
                    Divider()
                    Button("恢复默认命令", action: store.restoreDefaults)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("添加命令")
            }

            Text("点击输入到当前标签页，右键可执行或复制")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            TextField("筛选", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.commands.isEmpty {
                        Text("还没有常用命令")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    }

                    ForEach(commands) { command in
                        ClaudeCommandRow(
                            command: command,
                            insert: { model.insert(command.command, execute: $0) },
                            edit: { editing = command },
                            move: { store.move(command, by: $0) },
                            remove: { store.remove(command) })
                    }
                }
            }
        }
        .sheet(item: $editing) { command in
            ClaudeCommandEditor(command: command) { saved in
                if let saved { store.save(saved) }
                editing = nil
            }
        }
    }
}

private struct ClaudeCommandRow: View {
    let command: ClaudeCommand
    let insert: (_ execute: Bool) -> Void
    let edit: () -> Void
    let move: (_ offset: Int) -> Void
    let remove: () -> Void

    @State private var hovered = false

    var body: some View {
        Button { insert(false) } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.name.isEmpty ? command.command : command.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !command.name.isEmpty {
                        Text(command.command)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if hovered {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovered ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(command.command)
        .contextMenu {
            Button("输入到当前标签页") { insert(false) }
            Button("输入并执行") { insert(true) }
            Button("复制", action: copy)
            Divider()
            Button("编辑…", action: edit)
            Button("上移") { move(-1) }
            Button("下移") { move(1) }
            Divider()
            Button("删除", action: remove)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.command, forType: .string)
    }
}

private struct ClaudeCommandEditor: View {
    @State var command: ClaudeCommand
    /// Called with the edited command, or nil when cancelled.
    let done: (ClaudeCommand?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(command.command.isEmpty ? "添加常用命令" : "编辑常用命令")
                .font(.headline)
            TextField("名称（可选）", text: $command.name)
            TextField("命令", text: $command.command)
                .font(.system(.body, design: .monospaced))
            Text("命令末尾的空格会保留，便于继续输入参数。")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("取消") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { done(command) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .frame(width: 420)
    }
}
