import Foundation

/// How to run ssh to a host the files tab is connected to without authenticating again:
/// from this Mac over the host's multiplexed connection, or from the host before it in a
/// chain of ssh logins, through that host's own invocation.
indirect enum SSHInvocation: Sendable {
    /// ssh on this Mac, with options that reuse the logged in connection
    case local(options: [String], destination: String)
    /// ssh on the parent's host, using that host's keys, config and known hosts
    case remote(parent: SSHInvocation, authSocket: String?, options: [String], destination: String)

    /// The arguments to this Mac's ssh that run a shell command line on the host.
    func arguments(running command: String) -> [String] {
        switch self {
        case .local(let options, let destination):
            return options + [destination, "--", command]
        case .remote(let parent, _, _, let destination):
            return parent.arguments(running: remoteSSH([destination, "--"]) + " " + command.shellQuoted)
        }
    }

    /// The arguments to this Mac's ssh that start the host's sftp subsystem.
    var sftpArguments: [String] {
        switch self {
        case .local(let options, let destination):
            return options + ["-s", destination, "sftp"]
        case .remote(let parent, _, _, let destination):
            return parent.arguments(running: remoteSSH(["-s", destination, "sftp"]))
        }
    }

    /// The arguments to this Mac's ssh that connect its stdin and stdout to a TCP port
    /// the host can reach, like ProxyJump does.
    func tunnelArguments(to host: String, port: String) -> [String] {
        let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        switch self {
        case .local(let options, let destination):
            return options + ["-W", address, destination]
        case .remote(let parent, _, _, let destination):
            return parent.arguments(running: remoteSSH(["-W", address, destination]))
        }
    }

    /// The command line that runs ssh on the parent's host with these arguments after the
    /// options. `env` sets the agent in any login shell, fish and csh too.
    private func remoteSSH(_ arguments: [String]) -> String {
        guard case .remote(_, let authSocket, let options, _) = self else { return "" }
        let words = (authSocket.map { ["env", "SSH_AUTH_SOCK=\($0)"] } ?? []) + ["ssh"] + options + arguments
        return words.map(\.shellQuoted).joined(separator: " ")
    }
}

/// An ssh client running on a host the files tab is connected to: a login from there to
/// another host, which the files tab can switch to.
struct NestedSSH: Identifiable, Hashable, Sendable {
    let pid: Int
    /// Where it logs in to and how, as run on the parent host
    let commandLine: SSHCommandLine
    /// The agent it uses there, often one forwarded from this Mac with `ssh -A`
    let authSocket: String?
    let tty: String?
    /// Where it logs in to, as the parent's ssh config resolves it
    let hostname: String
    let port: String
    let user: String?

    var id: Int { pid }

    var title: String {
        var title = user.map { "\($0)@\(hostname)" } ?? hostname
        if port != "22" { title += ":\(port)" }
        return title
    }

    /// Whether a terminal title's host, a short host name, names this login's host.
    func matches(_ shell: ShellTitle) -> Bool {
        shell.isHost(hostname) || shell.isHost(commandLine.destination.split(separator: "@").last.map(String.init) ?? "")
    }
}

enum NestedSSHError: LocalizedError {
    case failed(throughHost: String, viaHost: Error, fromMac: Error)

    var errorDescription: String? {
        switch self {
        case .failed(let host, let viaHost, let fromMac):
            return """
                用 \(host) 上的 ssh 连接失败：\(viaHost.localizedDescription)
                从本机经 \(host) 跳转也失败：\(fromMac.localizedDescription)
                """
        }
    }
}

extension SSHConnector {
    /// Lists the ssh clients the logged in user is running on the connection's host,
    /// except tunnels (ProxyJump's own, `-W`) and the files tab's own.
    static func findNested(on connection: Connection) async -> [NestedSSH] {
        guard let output = await connection.run("sh -c " + nestedSSHScript.shellQuoted) else { return [] }

        // Records start with "P pid"; then the parent PID, the TTY, each argument, the agent.
        var records: [(pid: Int, ppid: Int?, tty: String?, arguments: [String], authSocket: String?)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.count >= 2, line.dropFirst().first == " " else { continue }
            let value = String(line.dropFirst(2))
            switch line.first {
            case "P": if let pid = Int(value) { records.append((pid, nil, nil, [], nil)) }
            case "Q": if !records.isEmpty { records[records.count - 1].ppid = Int(value.trimmingCharacters(in: .whitespaces)) }
            case "T": if !records.isEmpty, !value.isEmpty, value != "?", value != "??" { records[records.count - 1].tty = value }
            case "A": if !records.isEmpty { records[records.count - 1].arguments.append(value) }
            case "E": if !records.isEmpty, !value.isEmpty { records[records.count - 1].authSocket = value }
            default: break
            }
        }

        let pids = Set(records.map(\.pid))
        var found: [NestedSSH] = []
        for record in records {
            // A child of another ssh is a tunnel it started (ProxyJump).
            if let ppid = record.ppid, pids.contains(ppid) { continue }
            // A multiplexing master names itself "ssh: <socket> [mux]".
            if record.arguments.first?.hasPrefix("ssh:") == true { continue }
            let arguments = Array(record.arguments.dropFirst())
            if arguments.contains("-W") { continue }
            if arguments.last == "sftp" && arguments.contains("-s") { continue }
            guard let commandLine = SSHCommandLine.parse(arguments) else { continue }

            let resolve = (["ssh", "-G"] + commandLine.options + [commandLine.destination])
                .map(\.shellQuoted).joined(separator: " ")
            let config = SSHCommandLine.parseConfig(await connection.run(resolve) ?? "")
            found.append(NestedSSH(
                pid: record.pid,
                commandLine: commandLine,
                authSocket: record.authSocket,
                tty: record.tty.map { $0.hasPrefix("/dev/") ? String($0.dropFirst(5)) : $0 },
                hostname: config["hostname"] ?? commandLine.destination,
                port: config["port"] ?? "22",
                user: config["user"]))
        }
        return found
    }

    /// A login to `user@host[:port]` from the connection's host, typed by the user when
    /// the ssh client running there can't be found.
    static func nested(_ text: String, on connection: Connection) async -> NestedSSH? {
        var destination = text.trimmingCharacters(in: .whitespaces)
        var options: [String] = []
        // host:port, but not an IPv6 address
        if let colon = destination.lastIndex(of: ":"), destination.filter({ $0 == ":" }).count == 1,
           let port = Int(destination[destination.index(after: colon)...]) {
            options = ["-p", String(port)]
            destination = String(destination[..<colon])
        }
        guard !destination.isEmpty, !destination.contains(" ") else { return nil }
        let commandLine = SSHCommandLine(options: options, destination: destination)
        let resolve = (["ssh", "-G"] + options + [destination]).map(\.shellQuoted).joined(separator: " ")
        let config = SSHCommandLine.parseConfig(await connection.run(resolve) ?? "")
        return NestedSSH(
            pid: 0,
            commandLine: commandLine,
            authSocket: nil,
            tty: nil,
            hostname: config["hostname"] ?? destination,
            port: config["port"] ?? options.last ?? "22",
            user: config["user"])
    }

    /// Connects to a host logged in to from the connection's host, in two ways:
    ///
    /// a. With the parent host's ssh, so the same keys, config, known hosts and agent as
    ///    the login in the terminal apply. It can't ask for a password there.
    /// b. With this Mac's ssh, tunnelled through the parent's connection, with this Mac's
    ///    keys and agent, asking for a password in a dialog if needed. The parent host has
    ///    to allow TCP forwarding.
    ///
    /// Neither authenticates to the parent host again. `extraOptions` are added to b's.
    static func connect(
        _ nested: NestedSSH,
        through parent: Connection,
        extraOptions: [String] = []
    ) async throws -> Connection {
        let viaHost: Error
        let invocation = SSHInvocation.remote(
            parent: parent.invocation,
            authSocket: nested.authSocket,
            options: fileTransferOptions + ["-o", "BatchMode=yes"] + nested.commandLine.options,
            destination: nested.commandLine.destination)
        do {
            let client = try await SFTPClient.connect(sshArguments: invocation.sftpArguments, environment: parent.environment)
            return Connection(client: client, title: nested.title, user: nested.user,
                              invocation: invocation, environment: parent.environment)
        } catch {
            viaHost = error
        }

        // ssh expands % tokens in ProxyCommand; the tunnel's own (like a ControlPath's %C)
        // are for the inner ssh to expand.
        let proxy = (["/usr/bin/ssh"] + parent.invocation.tunnelArguments(to: nested.hostname, port: nested.port))
            .map(\.shellQuoted).joined(separator: " ")
            .replacingOccurrences(of: "%", with: "%%")
        var options = ["-o", "ProxyCommand=\(proxy)", "-p", nested.port]
        if let user = nested.user { options += ["-l", user] }
        let target = SSHTarget(
            commandLine: SSHCommandLine(options: options + extraOptions, destination: nested.hostname),
            authSocket: parent.environment["SSH_AUTH_SOCK"])
        do {
            let connection = try await connect(target)
            return Connection(client: connection.client, title: nested.title, user: nested.user ?? connection.user,
                              invocation: connection.invocation, environment: connection.environment)
        } catch {
            throw NestedSSHError.failed(throughHost: parent.title, viaHost: viaHost, fromMac: error)
        }
    }

    /// Prints a record for each ssh process of the user: from /proc on Linux, which keeps
    /// the arguments apart and has the agent, or else from ps.
    private static let nestedSSHScript = #"""
        if [ -r /proc/self/cmdline ]; then
          for d in /proc/[0-9]*; do
            [ -O "$d" ] || continue
            [ "$(cat "$d/comm" 2>/dev/null)" = ssh ] || continue
            echo "P ${d#/proc/}"
            awk '/^PPid:/ { print "Q " $2 }' "$d/status" 2>/dev/null
            echo "T $(readlink "$d/fd/0" 2>/dev/null)"
            tr '\0' '\n' < "$d/cmdline" 2>/dev/null | sed 's/^/A /'
            tr '\0' '\n' < "$d/environ" 2>/dev/null | sed -n 's/^SSH_AUTH_SOCK=/E /p'
          done
        else
          set -f
          ps -U "$(id -u)" -o pid= -o ppid= -o tty= -o comm= -o args= 2>/dev/null |
          while read -r pid ppid tty comm args; do
            [ "${comm##*/}" = ssh ] || continue
            echo "P $pid"
            echo "Q $ppid"
            echo "T $tty"
            for a in $args; do echo "A $a"; done
          done
        fi
        """#
}
