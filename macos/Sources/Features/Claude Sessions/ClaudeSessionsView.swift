import AppKit
import SwiftUI

/// Shows the Claude Code sessions panel next to the terminal while it is open.
struct ClaudeSessionsSidebar: View {
    @ObservedObject var model: ClaudeSessionsModel

    var body: some View {
        if model.isOpen {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 2) {
                        tabButton(.sessions, systemImage: "bubble.left.and.bubble.right", help: "CC 会话")
                        tabButton(.commands, systemImage: "terminal", help: "CC 常用命令")
                        Spacer()
                        Button(action: model.close) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("关闭")
                    }

                    switch model.tab {
                    case .sessions: ClaudeSessionsView(model: model)
                    case .commands: ClaudeCommandsView(model: model)
                    }
                }
                .padding(8)
                .frame(width: 260)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
        }
    }

    private func tabButton(_ tab: ClaudePanelTab, systemImage: String, help: String) -> some View {
        Button { model.tab = tab } label: {
            Image(systemName: systemImage)
                .foregroundColor(model.tab == tab ? .accentColor : .secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(model.tab == tab ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ClaudeSessionsView: View {
    @ObservedObject var model: ClaudeSessionsModel
    @State private var collapsed: Set<ClaudeSessionGroup> = []

    private var groups: [(ClaudeSessionGroup, [ClaudeSession])] {
        let query = model.filter.trimmingCharacters(in: .whitespaces)
        let sessions = query.isEmpty ? model.sessions : model.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                ($0.gitBranch?.localizedCaseInsensitiveContains(query) ?? false) ||
                $0.id.hasPrefix(query)
        }
        return ClaudeSessionGroup.group(sessions)
    }

    private var displayDirectory: String {
        guard let directory = model.directory else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("CC 会话")
                    .font(.headline)
                Spacer()
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
            .buttonStyle(.borderless)

            Text(displayDirectory)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.directory ?? "")

            TextField("筛选", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.directory == nil {
                        placeholder("无法确定当前目录")
                    } else if model.sessions.isEmpty && !model.loading {
                        placeholder("该目录下还没有 Claude Code 会话")
                    }

                    ForEach(groups, id: \.0) { group, sessions in
                        groupHeader(group, count: sessions.count)
                        if !collapsed.contains(group) {
                            ForEach(sessions) { session in
                                ClaudeSessionRow(
                                    session: session,
                                    isLive: model.liveSessionIDs.contains(session.id),
                                    isActive: session.id == model.activeSessionID,
                                    resume: { model.resume(session, fork: $0) })
                            }
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
    }

    private func groupHeader(_ group: ClaudeSessionGroup, count: Int) -> some View {
        Button {
            if collapsed.contains(group) {
                collapsed.remove(group)
            } else {
                collapsed.insert(group)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed.contains(group) ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .frame(width: 12)
                Text(group.label)
                Spacer()
                Text("\(count)")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let isLive: Bool
    let isActive: Bool
    let resume: (_ fork: Bool) -> Void

    @State private var hovered = false

    var body: some View {
        Button { resume(false) } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isLive ? Color.green : Color.clear)
                    .frame(width: 6, height: 6)
                    .help(isLive ? "运行中" : "")
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Self.relativeTime(session.lastActivity))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.accentColor.opacity(0.25) : hovered ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tooltip)
        .contextMenu {
            Button(isLive ? "切换到该会话" : "恢复会话") { resume(false) }
            Button("在新标签页中派生会话") { resume(true) }
            Divider()
            Button("复制会话 ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }

    private var tooltip: String {
        var lines = [session.title]
        if let branch = session.gitBranch { lines.append("分支：\(branch)") }
        lines.append(session.id)
        return lines.joined(separator: "\n")
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时" }
        let days = minutes / (24 * 60)
        if days < 7 { return "\(days) 天" }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
