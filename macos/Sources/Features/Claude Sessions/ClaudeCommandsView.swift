import AppKit
import SwiftUI

/// The top-level groups of the commands tab, each shown as a collapsible branch.
enum CommandGroup: String, Codable, CaseIterable, Identifiable {
    case ssh
    case claudeCode
    case openCode
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: "SSH"
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        case .local: "本机"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .ssh: "network"
        case .claudeCode: "asterisk"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        case .local: "laptopcomputer"
        }
    }

    /// The tile's top and bottom colors, in the style of an app icon.
    fileprivate var colors: [Color] {
        switch self {
        case .ssh: [Color(red: 0.33, green: 0.62, blue: 1.0), Color(red: 0.13, green: 0.42, blue: 0.92)]
        case .claudeCode: [Color(red: 0.92, green: 0.53, blue: 0.40), Color(red: 0.80, green: 0.40, blue: 0.27)]
        case .openCode: [Color(white: 0.32), Color(white: 0.12)]
        case .local: [Color(red: 0.40, green: 0.78, blue: 0.47), Color(red: 0.18, green: 0.60, blue: 0.30)]
        }
    }
}

/// A frequently used CLI command shown in the panel's commands tab.
struct ClaudeCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var group: CommandGroup = .claudeCode
}

extension ClaudeCommand {
    /// Commands saved before there were groups were all Claude Code commands.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        group = (try? container.decodeIfPresent(CommandGroup.self, forKey: .group)) ?? .claudeCode
    }
}

/// The commands listed in the panel, shared by all windows and kept in the user defaults.
@MainActor
final class ClaudeCommandStore: ObservableObject {
    static let shared = ClaudeCommandStore()

    private static let defaultsKey = "ClaudeCommandsV2"
    /// Claude Code commands saved before there were groups
    private static let legacyDefaultsKey = "ClaudeCommands"

    static let defaultCommands: [ClaudeCommand] = [
        .init(name: "列出已加载的密钥", command: "ssh-add -l", group: .ssh),
        .init(name: "生成 ed25519 密钥", command: "ssh-keygen -t ed25519 -C ", group: .ssh),
        .init(name: "把公钥安装到主机", command: "ssh-copy-id ", group: .ssh),
        .init(name: "本地端口转发", command: "ssh -N -L 8080:localhost:8080 ", group: .ssh),
        .init(name: "查看主机的有效配置", command: "ssh -G ", group: .ssh),

        .init(name: "添加目录并加载其 CLAUDE.md",
              command: "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 claude --add-dir "),
        .init(name: "继续最近的会话", command: "claude --continue"),
        .init(name: "选择会话恢复", command: "claude --resume"),
        .init(name: "以计划模式启动", command: "claude --permission-mode plan"),
        .init(name: "跳过权限确认", command: "claude --dangerously-skip-permissions"),
        .init(name: "列出 MCP 服务器", command: "claude mcp list"),
        .init(name: "检查安装状态", command: "claude doctor"),
        .init(name: "更新 Claude Code", command: "claude update"),

        .init(name: "启动 OpenCode", command: "opencode", group: .openCode),
        .init(name: "继续最近的会话", command: "opencode --continue", group: .openCode),
        .init(name: "非交互运行提示词", command: "opencode run ", group: .openCode),
        .init(name: "列出可用模型", command: "opencode models", group: .openCode),
        .init(name: "登录模型提供方", command: "opencode auth login", group: .openCode),
        .init(name: "更新 OpenCode", command: "opencode upgrade", group: .openCode),

        .init(name: "在访达中打开当前目录", command: "open .", group: .local),
        .init(name: "列出监听中的端口", command: "lsof -nP -iTCP -sTCP:LISTEN", group: .local),
        .init(name: "当前目录各项占用", command: "du -sh * | sort -h", group: .local),
        .init(name: "更新 Homebrew 软件包", command: "brew update && brew upgrade", group: .local),
        .init(name: "阻止休眠", command: "caffeinate -dims", group: .local),
    ]

    @Published private(set) var commands: [ClaudeCommand]

    private init() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Self.defaultsKey),
           let commands = try? decoder.decode([ClaudeCommand].self, from: data) {
            self.commands = commands
        } else if let data = defaults.data(forKey: Self.legacyDefaultsKey),
                  let legacy = try? decoder.decode([ClaudeCommand].self, from: data) {
            // Keep the user's Claude Code commands and add the other groups' defaults.
            self.commands = Self.defaultCommands.filter { $0.group != .claudeCode } + legacy
        } else {
            self.commands = Self.defaultCommands
        }
    }

    func commands(in group: CommandGroup) -> [ClaudeCommand] {
        commands.filter { $0.group == group }
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

    /// Moves the command one place up (`offset` -1) or down (`offset` 1) within its group.
    func move(_ command: ClaudeCommand, by offset: Int) {
        let siblings = commands.indices.filter { commands[$0].group == command.group }
        guard let position = siblings.firstIndex(where: { commands[$0].id == command.id }),
              siblings.indices.contains(position + offset) else { return }
        commands.swapAt(siblings[position], siblings[position + offset])
        persist()
    }

    func restoreDefaults() {
        commands = Self.defaultCommands
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
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
    /// The groups shown expanded, kept across launches as their raw values joined by commas
    @AppStorage("ClaudeCommandsExpandedGroups") private var expandedGroups = CommandGroup.claudeCode.rawValue

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private func commands(in group: CommandGroup) -> [ClaudeCommand] {
        let commands = store.commands(in: group)
        guard !query.isEmpty else { return commands }
        return commands.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.command.localizedCaseInsensitiveContains(query)
        }
    }

    private func isExpanded(_ group: CommandGroup) -> Bool {
        // While filtering, every group with a match is open.
        !query.isEmpty || expandedGroups.split(separator: ",").contains { $0 == group.rawValue }
    }

    private func toggle(_ group: CommandGroup) {
        var groups = Set(expandedGroups.split(separator: ",").map(String.init))
        if groups.contains(group.rawValue) {
            groups.remove(group.rawValue)
        } else {
            groups.insert(group.rawValue)
        }
        expandedGroups = CommandGroup.allCases.map(\.rawValue).filter(groups.contains).joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("CLI 命令")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(CommandGroup.allCases) { group in
                        Button("添加到 \(group.title)…") { add(to: group) }
                    }
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
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(CommandGroup.allCases) { group in
                        let commands = commands(in: group)
                        if query.isEmpty || !commands.isEmpty {
                            CommandGroupRow(
                                group: group,
                                count: commands.count,
                                expanded: isExpanded(group),
                                toggle: { toggle(group) },
                                add: { add(to: group) })
                            if isExpanded(group) {
                                if commands.isEmpty {
                                    Text("还没有命令，右键分组可添加")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, CommandGroupRow.childIndent)
                                        .padding(.vertical, 3)
                                }
                                ForEach(commands) { command in
                                    ClaudeCommandRow(
                                        command: command,
                                        insert: { model.insert(command.command, execute: $0) },
                                        edit: { editing = command },
                                        move: { store.move(command, by: $0) },
                                        remove: { store.remove(command) })
                                        .padding(.leading, CommandGroupRow.childIndent)
                                }
                            }
                        }
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

    private func add(to group: CommandGroup) {
        editing = ClaudeCommand(name: "", command: "", group: group)
        if !isExpanded(group) { toggle(group) }
    }
}

/// A group's branch: a disclosure chevron, an app-icon-like tile and the name.
private struct CommandGroupRow: View {
    /// How far a group's commands are indented, to line up with its name
    static let childIndent: CGFloat = 40

    let group: CommandGroup
    let count: Int
    let expanded: Bool
    let toggle: () -> Void
    let add: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                CommandGroupIcon(group: group)
                Text(group.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: expanded)
        .contextMenu {
            Button(expanded ? "折叠" : "展开", action: toggle)
            Button("添加命令…", action: add)
        }
    }
}

/// A rounded tile with a white symbol, styled like a small app icon.
private struct CommandGroupIcon: View {
    let group: CommandGroup

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(LinearGradient(colors: group.colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .overlay(
                Image(systemName: group.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white))
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
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
            Picker("分组", selection: $command.group) {
                ForEach(CommandGroup.allCases) { Text($0.title).tag($0) }
            }
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
