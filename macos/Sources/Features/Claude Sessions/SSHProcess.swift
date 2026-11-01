import Darwin
import Foundation

/// The `ssh` client a surface is running in its foreground, found from the surface's
/// foreground process group.
struct SSHProcess: Equatable {
    let pid: pid_t
    /// The arguments after `ssh`
    let arguments: [String]
    /// The agent the process uses, which may not be the one the app sees (e.g. one set
    /// up by the shell's rc files).
    let authSocket: String?

    /// The ssh client in the foreground process group `pgid`. With `ghostty +ssh` or a
    /// ProxyJump the group has more than one process, and the client is the ssh whose
    /// parent isn't another ssh.
    static func find(inProcessGroup pgid: Int) -> SSHProcess? {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listpgrppids(pid_t(pgid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }

        var parents: [pid_t: pid_t] = [:]
        for pid in pids where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: info.pbi_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name == "ssh" { parents[pid] = pid_t(info.pbi_ppid) }
        }

        guard let pid = parents.keys.sorted().first(where: { parents[parents[$0]!] == nil }),
              let (argv, environment) = processArguments(pid), argv.count > 1 else { return nil }
        let authSocket = environment.first { $0.hasPrefix("SSH_AUTH_SOCK=") }
            .map { String($0.dropFirst("SSH_AUTH_SOCK=".count)) }
        return SSHProcess(pid: pid, arguments: Array(argv.dropFirst()), authSocket: authSocket)
    }

    /// The process's arguments and environment, read with `KERN_PROCARGS2`.
    private static func processArguments(_ pid: pid_t) -> ([String], [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // The argument count, the executable path, NUL padding, then the arguments and
        // the environment as NUL terminated strings.
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var strings: [String] = []
        while index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            if start == index { break }
            strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        guard strings.count >= argc else { return nil }
        return (Array(strings.prefix(argc)), Array(strings.dropFirst(argc)))
    }
}

/// The parts of an ssh command line that say where to log in and how, without what the
/// login does there (a command, forwarded ports, a TTY), so they can be used for other
/// connections to the same host.
struct SSHCommandLine: Hashable, Sendable {
    /// Options that pick the host and how to authenticate, with their values
    let options: [String]
    let destination: String

    /// ssh's options that take a value (from its getopt string)
    private static let valueOptions = Set("bcDeEFiIJlLmoOpPQRSwWB")
    /// The value options kept for other connections
    private static let keptValueOptions = Set("bcFiIJlmoPpB")
    /// The flags kept for other connections
    private static let keptFlags = Set("46C")

    /// Parses the arguments ssh was run with. ssh also takes options after the destination
    /// and before the command.
    static func parse(_ arguments: [String]) -> SSHCommandLine? {
        var options: [String] = []
        var destination: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                if destination == nil, index < arguments.count { destination = arguments[index] }
                break
            }
            guard argument.hasPrefix("-"), argument.count > 1 else {
                // The first word that isn't an option is the destination, the next the command.
                if destination != nil { break }
                destination = argument
                continue
            }

            var characters = Substring(argument.dropFirst())
            while let option = characters.first {
                characters = characters.dropFirst()
                guard valueOptions.contains(option) else {
                    if keptFlags.contains(option) { options.append("-\(option)") }
                    continue
                }
                let value: String
                if !characters.isEmpty {
                    value = String(characters)
                } else if index < arguments.count {
                    value = arguments[index]
                    index += 1
                } else {
                    return nil
                }
                if option == "S" {
                    // A control socket given on the command line; as an option, ours go first.
                    options += ["-o", "ControlPath=\(value)"]
                } else if keptValueOptions.contains(option) {
                    options += ["-\(option)", value]
                }
                break
            }
        }

        guard let destination, !destination.isEmpty else { return nil }
        return SSHCommandLine(options: options, destination: destination)
    }

    /// Resolves the configuration ssh would use, with `ssh -G`.
    func resolve() -> [String: String] {
        Self.parseConfig(SSHRunner.run(["-G"] + options + [destination]).output)
    }

    /// The keys and values `ssh -G` printed.
    static func parseConfig(_ output: String) -> [String: String] {
        var config: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            // Like ssh, the first value of a repeated key is the one that counts.
            if config[key] == nil { config[key] = String(line[line.index(after: space)...]) }
        }
        return config
    }
}

/// Runs the system ssh and waits for it.
enum SSHRunner {
    static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    static func run(_ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // A file rather than a pipe: a master this starts in the background keeps nothing
        // of ours open, but a file can't block either way.
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-ssh-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        guard let errorHandle = try? FileHandle(forWritingTo: errorURL) else { return (-1, "", "") }
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? errorHandle.close()
        let errorText = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus,
                String(decoding: data, as: UTF8.self),
                errorText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
