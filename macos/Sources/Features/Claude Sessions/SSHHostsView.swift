import AppKit
import SwiftUI

/// A host in the panel's SSH tab, connected to with the system `ssh`.
///
/// No password is kept: logging in without one relies on a key, which the tab can install
/// on the host with `ssh-copy-id`.
struct SSHHost: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    /// Empty for ssh's default user
    var user = ""
    /// Empty for ssh's default port
    var port = ""
    /// The local public key installed on the host, e.g. `~/.ssh/id_ed25519.pub`. Its private
    /// key (the same path without `.pub`) is the one used to log in. Empty for ssh's defaults.
    var publicKey = ""
    /// Shares one connection between this host's tabs and transfers, so it is
    /// authenticated once (ssh's ControlMaster).
    var multiplex = true

    /// Where the multiplexed connections' sockets are kept; `%C` is a hash of the
    /// connection, which keeps the path short.
    static let controlPath = "~/.ssh/ghostty-%C"

    init() {}

    init(from decoder: Decoder) throws {
        // Every field is optional so hosts saved by an older version still load.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        port = try container.decodeIfPresent(String.self, forKey: .port) ?? ""
        publicKey = try container.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        multiplex = try container.decodeIfPresent(Bool.self, forKey: .multiplex) ?? true
    }

    var destination: String {
        let host = host.trimmingCharacters(in: .whitespaces)
        let user = user.trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    var title: String { name.isEmpty ? destination : name }

    private var trimmedPort: String { port.trimmingCharacters(in: .whitespaces) }

    var trimmedPublicKey: String { publicKey.trimmingCharacters(in: .whitespaces) }

    /// The private key paired with `publicKey`, as written by the user
    var privateKey: String? {
        let key = trimmedPublicKey
        guard key.hasSuffix(".pub") else { return key.isEmpty ? nil : key }
        return String(key.dropLast(4))
    }

    var publicKeyExists: Bool {
        !trimmedPublicKey.isEmpty && FileManager.default.fileExists(atPath: trimmedPublicKey.expandingTilde)
    }

    var privateKeyExists: Bool {
        guard let privateKey else { return false }
        return FileManager.default.fileExists(atPath: privateKey.expandingTilde)
    }

    var isValid: Bool {
        let host = host.trimmingCharacters(in: .whitespaces)
        return !host.isEmpty && !host.contains(" ") && (trimmedPort.isEmpty || UInt16(trimmedPort) != nil)
    }

    /// The options shared by every ssh command for this host, before the destination.
    /// `multiplex` is left to the caller since not every command should start a connection.
    private var commonArguments: [String] {
        var args: [String] = []
        if privateKeyExists, let privateKey {
            // Only offer the chosen key, so other keys in the agent don't use up the
            // server's authentication attempts.
            args += ["-i", privateKey, "-o", "IdentitiesOnly=yes"]
        }
        if !trimmedPort.isEmpty { args += ["-p", trimmedPort] }
        return args
    }

    /// The arguments to `ssh` that log in to the host.
    var sshArguments: [String] {
        var args: [String] = []
        if multiplex {
            args += ["-o", "ControlMaster=auto",
                     "-o", "ControlPath=\(Self.controlPath)",
                     "-o", "ControlPersist=10m"]
        }
        return args + commonArguments + [destination]
    }

    var sshCommand: String {
        (["ssh"] + sshArguments).map(\.shellQuoted).joined(separator: " ")
    }

    /// Installs `publicKey` on the host, generating the key pair first if it doesn't
    /// exist yet. The command asks for the host's password once.
    var copyIDCommand: String {
        var copy = ["ssh-copy-id"]
        if !trimmedPublicKey.isEmpty { copy += ["-i", trimmedPublicKey] }
        // Reuse a connection that is already logged in, if there is one, instead of
        // asking for the password again. Without ControlMaster this never starts one.
        if multiplex { copy += ["-o", "ControlPath=\(Self.controlPath)"] }
        if !trimmedPort.isEmpty { copy += ["-p", trimmedPort] }
        copy.append(destination)
        let command = copy.map(\.shellQuoted).joined(separator: " ")

        guard !trimmedPublicKey.isEmpty, !publicKeyExists, !privateKeyExists, let privateKey else {
            return command
        }
        let keygen = ["ssh-keygen", "-t", "ed25519", "-f", privateKey].map(\.shellQuoted).joined(separator: " ")
        return keygen + " && " + command
    }

    /// The arguments that check logging in with a key works, without a password prompt or
    /// an existing multiplexed connection.
    var testArguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ControlPath=none"]
            + commonArguments + [destination, "true"]
    }
}

/// The SSH hosts listed in the panel, shared by all windows and kept in the user defaults.
@MainActor
final class SSHHostStore: ObservableObject {
    static let shared = SSHHostStore()

    private static let defaultsKey = "SSHHosts"

    @Published private(set) var hosts: [SSHHost]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let hosts = try? JSONDecoder().decode([SSHHost].self, from: data) {
            self.hosts = hosts
        } else {
            self.hosts = []
        }
    }

    /// Adds the host, or replaces the one with the same ID.
    func save(_ host: SSHHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    func remove(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    /// Moves the host one place up (`offset` -1) or down (`offset` 1).
    func move(_ host: SSHHost, by offset: Int) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }),
              hosts.indices.contains(index + offset) else { return }
        hosts.swapAt(index, index + offset)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// The public keys in `~/.ssh`, offered when choosing a host's key.
    static func localPublicKeys() -> [String] {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".pub") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { "~/.ssh/" + $0 }
    }
}

/// The outcome of checking that a host accepts its key.
enum SSHKeyTest: Equatable {
    case running
    case passed
    case failed(String)
}

struct SSHHostsView: View {
    @ObservedObject var model: ClaudeSessionsModel
    @ObservedObject var store = SSHHostStore.shared
    @State private var filter = ""
    /// The host being added or edited in the sheet
    @State private var editing: SSHHost?
    @State private var tests: [UUID: SSHKeyTest] = [:]

    private var hosts: [SSHHost] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.hosts }
        return store.hosts.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.destination.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("SSH 主机")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("添加主机…") { editing = SSHHost() }
                    Divider()
                    Button("生成新密钥（ssh-keygen）") {
                        model.runInNewTab("ssh-keygen -t ed25519", directory: NSHomeDirectory())
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("添加主机")
            }

            Text("点击在新标签页连接，右键可配置公钥")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            TextField("筛选", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.hosts.isEmpty {
                        Text("还没有 SSH 主机，点击 + 添加")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    }

                    ForEach(hosts) { host in
                        SSHHostRow(
                            host: host,
                            test: tests[host.id],
                            connect: { newTab in connect(host, newTab: newTab) },
                            copyID: { model.runInNewTab(host.copyIDCommand, directory: NSHomeDirectory()) },
                            runTest: { runTest(host) },
                            edit: { editing = host },
                            move: { store.move(host, by: $0) },
                            remove: { store.remove(host) })
                    }
                }
            }
        }
        .sheet(item: $editing) { host in
            SSHHostEditor(host: host) { saved in
                if let saved {
                    store.save(saved)
                    tests[saved.id] = nil
                }
                editing = nil
            }
        }
    }

    private func connect(_ host: SSHHost, newTab: Bool) {
        if host.multiplex {
            // ssh can't create the connection's socket in a directory that doesn't exist.
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if newTab {
            model.runInNewTab(host.sshCommand, directory: NSHomeDirectory())
        } else {
            model.insert(host.sshCommand, execute: true)
        }
    }

    /// Checks in the background that the host lets its key log in without a password.
    private func runTest(_ host: SSHHost) {
        tests[host.id] = .running
        let arguments = host.testArguments
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.test(arguments)
            Task { @MainActor in tests[host.id] = result }
        }
    }

    nonisolated private static func test(_ arguments: [String]) -> SSHKeyTest {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .passed }
        let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "ssh 退出码 \(process.terminationStatus)" : message)
    }
}

private struct SSHHostRow: View {
    let host: SSHHost
    let test: SSHKeyTest?
    let connect: (_ newTab: Bool) -> Void
    let copyID: () -> Void
    let runTest: () -> Void
    let edit: () -> Void
    let move: (_ offset: Int) -> Void
    let remove: () -> Void

    @State private var hovered = false

    var body: some View {
        Button { connect(true) } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                testIndicator
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
        .help(host.sshCommand)
        .contextMenu {
            Button("在新标签页中连接") { connect(true) }
            Button("在当前标签页中连接") { connect(false) }
            Divider()
            Button(copyIDLabel, action: copyID)
            Button("测试免密登录", action: runTest)
            Divider()
            Button("复制 ssh 命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(host.sshCommand, forType: .string)
            }
            Button("编辑…", action: edit)
            Button("上移") { move(-1) }
            Button("下移") { move(1) }
            Divider()
            Button("删除", action: remove)
        }
    }

    private var subtitle: String {
        var text = host.destination
        let port = host.port.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty { text += ":\(port)" }
        return text
    }

    private var copyIDLabel: String {
        if host.trimmedPublicKey.isEmpty { return "配置默认公钥到该主机" }
        if !host.publicKeyExists && !host.privateKeyExists { return "生成密钥并配置到该主机" }
        return "配置公钥到该主机"
    }

    @ViewBuilder
    private var testIndicator: some View {
        switch test {
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help("可以免密登录")
        case .failed(let message):
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .help("无法免密登录：\n\(message)")
        case nil:
            EmptyView()
        }
    }
}

private struct SSHHostEditor: View {
    @State var host: SSHHost
    /// Called with the edited host, or nil when cancelled.
    let done: (SSHHost?) -> Void

    @State private var localKeys: [String] = []
    private let isNew: Bool

    init(host: SSHHost, done: @escaping (SSHHost?) -> Void) {
        _host = State(initialValue: host)
        self.done = done
        isNew = host.host.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "添加 SSH 主机" : "编辑 SSH 主机")
                .font(.headline)

            Form {
                TextField("名称", text: $host.name, prompt: Text("可选"))
                TextField("主机", text: $host.host, prompt: Text("域名或 IP"))
                TextField("用户", text: $host.user, prompt: Text("可选，默认为 ssh 的默认用户"))
                TextField("端口", text: $host.port, prompt: Text("22"))
                HStack(spacing: 4) {
                    TextField("公钥", text: $host.publicKey, prompt: Text("~/.ssh/id_ed25519.pub"))
                        .font(.system(.body, design: .monospaced))
                    Menu {
                        ForEach(localKeys, id: \.self) { key in
                            Button(key) { host.publicKey = key }
                        }
                        if !localKeys.isEmpty { Divider() }
                        Button("选择文件…", action: chooseKey)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("选择本机的公钥")
                }
                Toggle("复用连接（登录一次，新标签页和文件传输无需再认证）", isOn: $host.multiplex)
            }

            keyStatus
                .font(.caption)

            HStack {
                Spacer()
                Button("取消") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { done(host) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!host.isValid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .frame(width: 460)
        .onAppear { localKeys = SSHHostStore.localPublicKeys() }
    }

    @ViewBuilder
    private var keyStatus: some View {
        if host.trimmedPublicKey.isEmpty {
            Text("未指定公钥时，ssh 使用默认密钥（~/.ssh/id_ed25519 等）。")
                .foregroundColor(.secondary)
        } else if !host.trimmedPublicKey.hasSuffix(".pub") {
            Text("请选择公钥文件（.pub），登录时使用同名的私钥。")
                .foregroundColor(.orange)
        } else if !host.publicKeyExists {
            Text(host.privateKeyExists
                ? "找不到该公钥文件。"
                : "该密钥还不存在，“配置公钥到该主机”时会先用 ssh-keygen 生成。")
                .foregroundColor(.orange)
        } else if !host.privateKeyExists {
            Text("找不到私钥 \(host.privateKey ?? "")，登录时由 ssh 选择密钥（例如 ssh-agent 中的）。")
                .foregroundColor(.orange)
        } else {
            Text("登录时使用私钥 \(host.privateKey ?? "")。右键主机可将公钥配置到主机上。")
                .foregroundColor(.secondary)
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "选择公钥文件（.pub）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host.publicKey = url.path.abbreviatingHome
    }
}
