import AppKit
import Foundation

/// A login to browse files on: where the ssh command line logs in to, and the agent it uses.
struct SSHTarget: Hashable, Sendable {
    let commandLine: SSHCommandLine
    let authSocket: String?
}

/// Opens SFTP connections for the files tab, authenticating as little as possible:
///
/// 1. A multiplexed connection that is already logged in (one started from the SSH hosts
///    tab, or by a ControlMaster in the user's ssh config) is reused without asking anything.
/// 2. Otherwise a new one is started, with ControlPersist so later connections reuse it.
///    Keys and the agent are tried first, without prompting.
/// 3. If they aren't enough, ssh asks for what it needs (a password, a key's passphrase, a
///    one-time code, trusting a new host key) in dialogs. Nothing is stored.
enum SSHConnector {
    struct Connection {
        let client: SFTPClient
        /// The login as `user@host`, with the port if it isn't 22
        let title: String
    }

    /// Options for a connection that only transfers files, ahead of the user's so they
    /// win, whatever the user's config says.
    private static let fileTransferOptions = [
        "-o", "RemoteCommand=none",
        "-o", "RequestTTY=no",
        "-o", "ClearAllForwardings=yes",
        "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no",
        "-o", "PermitLocalCommand=no",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=30",
    ]

    static func connect(_ target: SSHTarget) async throws -> Connection {
        let commandLine = target.commandLine
        let config = await background { commandLine.resolve() }
        let title = title(config, fallback: commandLine.destination)

        let environment: [String: String] = {
            var environment = ProcessInfo.processInfo.environment
            if let socket = target.authSocket { environment["SSH_AUTH_SOCK"] = socket }
            for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY"] { environment[key] = nil }
            return environment
        }()
        let sftp = commandLine.options + ["-s", commandLine.destination, "sftp"]

        // 1. An existing master.
        if let path = config["controlpath"], path != "none", FileManager.default.fileExists(atPath: path) {
            let check = await background {
                SSHRunner.run(["-O", "check"] + commandLine.options + [commandLine.destination],
                              environment: environment)
            }
            if check.status == 0,
               let client = try? await SFTPClient.connect(
                   sshArguments: fileTransferOptions
                       + ["-o", "ControlMaster=no", "-o", "ControlPath=\(path)", "-o", "BatchMode=yes"] + sftp,
                   environment: environment) {
                return Connection(client: client, title: title)
            }
        }

        // 2. A new master, without prompting.
        createSSHDirectory()
        let master = fileTransferOptions + [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(SSHHost.controlPath)",
            "-o", "ControlPersist=10m",
        ]
        do {
            let client = try await SFTPClient.connect(
                sshArguments: master + ["-o", "BatchMode=yes"] + sftp, environment: environment)
            return Connection(client: client, title: title)
        } catch SFTPError.disconnected(let message) where needsPrompt(message) {
            // 3. Prompting, below.
        }

        var prompting = environment
        prompting["SSH_ASKPASS"] = try installAskpass()
        prompting["SSH_ASKPASS_REQUIRE"] = "force"
        prompting["GHOSTTY_SSH_TARGET"] = title
        let client = try await SFTPClient.connect(
            sshArguments: master + ["-o", "BatchMode=no"] + sftp, environment: prompting)
        return Connection(client: client, title: title)
    }

    /// Whether a login failed for want of something only the user can give.
    private static func needsPrompt(_ message: String) -> Bool {
        ["Permission denied", "Host key verification failed", "passphrase",
         "Too many authentication failures", "No more authentication methods"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func title(_ config: [String: String], fallback: String) -> String {
        guard let host = config["hostname"] else { return fallback }
        var title = config["user"].map { "\($0)@\(host)" } ?? host
        if let port = config["port"], port != "22" { title += ":\(port)" }
        return title
    }

    /// ssh can't create a multiplexed connection's socket in a directory that doesn't exist.
    static func createSSHDirectory() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Runs blocking work, like waiting for an ssh process, off the concurrency pool.
    private static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    /// The program ssh runs to ask the user something, with what to ask as its argument.
    /// A yes/no question (whether to trust a new host key) gets buttons, anything else a
    /// hidden text field. Cancelling exits non-zero, which makes ssh give up.
    static let askpassScript = """
        #!/bin/sh
        # Written by Ghostty: asks what ssh needs to log in from the files tab, in a dialog.
        prompt="$1"
        target="${GHOSTTY_SSH_TARGET:-ssh}"
        case "$prompt" in
          *"(yes/no"*)
            exec /usr/bin/osascript \\
              -e 'on run argv' -e 'activate' \\
              -e 'display dialog ("Ghostty 正在连接 " & item 2 of argv & return & return & item 1 of argv) with title "SSH" buttons {"取消", "信任并连接"} default button 2 cancel button 1 with icon caution' \\
              -e 'return "yes"' -e 'end run' "$prompt" "$target" ;;
          *)
            exec /usr/bin/osascript \\
              -e 'on run argv' -e 'activate' \\
              -e 'display dialog ("Ghostty 正在连接 " & item 2 of argv & return & return & item 1 of argv) with title "SSH" default answer "" with hidden answer buttons {"取消", "登录"} default button 2 cancel button 1' \\
              -e 'text returned of result' -e 'end run' "$prompt" "$target" ;;
        esac
        """

    private static func installAskpass() throws -> String {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("ssh-askpass")
        if (try? String(contentsOf: url, encoding: .utf8)) != askpassScript {
            try askpassScript.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }
}

/// The optional block in `~/.ssh/config` that makes every ssh login share its connection,
/// so the files tab can reuse logins typed in a terminal without authenticating again.
enum SSHGlobalMultiplexing {
    private static let begin = "# >>> Ghostty: share SSH connections >>>"
    private static let end = "# <<< Ghostty: share SSH connections <<<"

    static let block = """
        \(begin)
        # Added by Ghostty so its files tab can reuse logins; remove this block to undo.
        Host *
            ControlMaster auto
            ControlPath \(SSHHost.controlPath)
            ControlPersist 10m
        \(end)
        """

    /// The config file, through a symlink (e.g. to a dotfiles repository) if it is one.
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config").resolvingSymlinksInPath()
    }

    static var isEnabled: Bool {
        ((try? String(contentsOf: configURL, encoding: .utf8)) ?? "").contains(begin)
    }

    static func enable() throws {
        SSHConnector.createSSHDirectory()
        let url = configURL
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = adding(to: text)
        if updated != text { try write(updated, to: url) }
    }

    static func disable() throws {
        let url = configURL
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = removing(from: text)
        if updated != text { try write(updated, to: url) }
    }

    /// The config with the block appended, at the end so that settings for specific hosts
    /// above it win.
    static func adding(to text: String) -> String {
        guard !text.contains(begin) else { return text }
        var text = text
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        return text + block + "\n"
    }

    /// The config without the block, and without the line break and blank line `adding` put.
    static func removing(from text: String) -> String {
        guard let start = text.range(of: begin),
              let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else { return text }
        var lower = start.lowerBound
        var upper = finish.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        if lower > text.startIndex, text[text.index(before: lower)] == "\n" {
            let before = text.index(before: lower)
            if before > text.startIndex, text[text.index(before: before)] == "\n" { lower = before }
        }
        var updated = text
        updated.removeSubrange(lower..<upper)
        return updated
    }

    private static func write(_ text: String, to url: URL) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if !exists { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    /// Asks before changing the user's ssh config, then adds or removes the block.
    @MainActor
    static func toggleWithConfirmation() {
        let alert = NSAlert()
        let enabled = isEnabled
        if enabled {
            alert.messageText = "移除全局连接复用？"
            alert.informativeText = "将从 ~/.ssh/config 中删除 Ghostty 添加的配置。之后在终端中手动登录的主机，文件面板需要重新认证。"
            alert.addButton(withTitle: "移除")
        } else {
            alert.messageText = "为所有 ssh 登录启用连接复用？"
            alert.informativeText = """
                将在 ~/.ssh/config 末尾添加：

                \(block)

                之后在终端中 ssh 登录的主机，文件面板可以直接复用该登录，无需再次输入密码。\
                连接在最后一个会话关闭后会保留 10 分钟；已有的配置（写在前面的 Host）优先。
                """
            alert.addButton(withTitle: "添加")
        }
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if enabled { try disable() } else { try enable() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
