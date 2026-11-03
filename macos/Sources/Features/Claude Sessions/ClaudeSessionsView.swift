import AppKit
import SwiftUI

/// Shows the Claude Code sessions panel next to the terminal while it is open.
struct ClaudeSessionsSidebar: View {
    @ObservedObject var model: ClaudeSessionsModel

    /// The panel's width, which dragging its trailing edge changes and new windows reuse.
    @AppStorage("ClaudePanelWidth") private var width: Double = 260
    /// The width when the current drag began, nil when not dragging.
    @State private var dragStartWidth: Double?

    private static let widthRange: ClosedRange<Double> = 180...900

    @Namespace private var tabNamespace
    /// Whether the pointer is over the resize handle or dragging it, which shows its grip.
    @State private var handleHovered = false

    var body: some View {
        if model.isOpen {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    tabBar
                    Button(action: model.toggle) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("隐藏侧边栏")
                }

                switch model.tab {
                case .commands: ClaudeCommandsView(model: model)
                case .files: FilesView(model: model, files: model.files, remote: model.remote, transfers: model.transfers)
                case .ssh: SSHHostsView(model: model)
                case .sessions: ClaudeSessionsView(model: model)
                }
            }
            .padding(10)
            .frame(width: width.clamped(to: Self.widthRange))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(PanelStyle.cardShape.fill(PanelStyle.cardFill))
            .overlay(PanelStyle.cardShape.strokeBorder(PanelStyle.hairline, lineWidth: 1))
            // In the gutter, so it sits under neither the panel nor the terminal.
            .overlay(alignment: .trailing) { resizeHandle.offset(x: PanelStyle.gutter) }
            .padding(.trailing, PanelStyle.gutter)
        }
    }

    /// The tabs as a segmented control whose selection slides between them.
    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(.ssh, systemImage: "network", help: "SSH 主机")
            tabButton(.commands, systemImage: "terminal", help: "CLI 命令")
            tabButton(.files, systemImage: "folder", help: "文件")
            tabButton(.sessions, systemImage: "bubble.left.and.bubble.right", help: "CC 会话")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(PanelStyle.fieldFill))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(PanelStyle.hairline, lineWidth: 1))
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.tab)
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(Color.primary.opacity(handleHovered || dragStartWidth != nil ? 0.35 : 0))
            .frame(width: 3, height: 36)
            .frame(width: PanelStyle.gutter)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: handleHovered)
            .backport.pointerStyle(.resizeLeftRight)
            .onHover { isHovered in
                handleHovered = isHovered
                // macOS 15+ uses pointerStyle above.
                if #available(macOS 15, *) { return }
                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            // Global, since the handle moves with the width it changes.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? width.clamped(to: Self.widthRange)
                    dragStartWidth = start
                    width = (start + value.translation.width).clamped(to: Self.widthRange)
                }
                .onEnded { _ in dragStartWidth = nil })
            .help("拖动调整宽度")
    }

    private func tabButton(_ tab: ClaudePanelTab, systemImage: String, help: String) -> some View {
        let selected = model.tab == tab
        return Button { model.tab = tab } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .accentColor : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.11))
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selection", in: tabNamespace)
                    }
                }
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
        model.directory?.abbreviatingHome ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(title: "CC 会话", subtitle: displayDirectory, subtitleHelp: model.directory) {
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }

            PanelSearchField(text: $model.filter)

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
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(PanelRowBackground(selected: isActive, hovered: hovered))
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
