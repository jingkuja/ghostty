import Foundation

/// A failed SFTP request or connection.
enum SFTPError: LocalizedError, Equatable {
    /// A STATUS reply other than OK
    case status(code: UInt32, message: String)
    /// The connection closed, with what ssh reported on its way out
    case disconnected(String)
    case badMessage

    static let eof: UInt32 = 1
    static let noSuchFile: UInt32 = 2
    static let permissionDenied: UInt32 = 3

    var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            switch code {
            case Self.noSuchFile: return "文件不存在"
            case Self.permissionDenied: return "没有权限"
            default: return message.isEmpty ? "SFTP 错误 \(code)" : message
            }
        case .disconnected(let message):
            return message.isEmpty ? "连接已断开" : message
        case .badMessage:
            return "无法识别的 SFTP 响应"
        }
    }
}

/// File attributes as SFTP v3 sends them.
struct SFTPAttributes: Sendable {
    var size: UInt64?
    var permissions: UInt32?
    var modified: UInt32?
    var accessed: UInt32?

    var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    var isSymlink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }

    fileprivate static let sizeFlag: UInt32 = 0x1
    fileprivate static let uidGIDFlag: UInt32 = 0x2
    fileprivate static let permissionsFlag: UInt32 = 0x4
    fileprivate static let timesFlag: UInt32 = 0x8
    fileprivate static let extendedFlag: UInt32 = 0x8000_0000
}

/// A client of the SFTP v3 protocol (draft-ietf-secsh-filexfer-02, which OpenSSH speaks),
/// talking to an `ssh -s … sftp` process over its stdin and stdout.
///
/// Using the system ssh for the transport keeps the user's ssh config, agent, jump hosts,
/// known hosts and multiplexed connections. Requests can be sent from any thread and are
/// answered as their replies arrive, so several can be in flight at once.
final class SFTPClient: @unchecked Sendable {
    private enum PacketType {
        static let initialize: UInt8 = 1
        static let version: UInt8 = 2
        static let open: UInt8 = 3
        static let close: UInt8 = 4
        static let read: UInt8 = 5
        static let write: UInt8 = 6
        static let lstat: UInt8 = 7
        static let setstat: UInt8 = 9
        static let opendir: UInt8 = 11
        static let readdir: UInt8 = 12
        static let remove: UInt8 = 13
        static let mkdir: UInt8 = 14
        static let rmdir: UInt8 = 15
        static let realpath: UInt8 = 16
        static let stat: UInt8 = 17
        static let rename: UInt8 = 18
        static let status: UInt8 = 101
        static let handle: UInt8 = 102
        static let data: UInt8 = 103
        static let name: UInt8 = 104
        static let attrs: UInt8 = 105
    }

    /// Flags for `open`
    struct OpenFlags: OptionSet {
        let rawValue: UInt32
        static let read = OpenFlags(rawValue: 0x01)
        static let write = OpenFlags(rawValue: 0x02)
        static let append = OpenFlags(rawValue: 0x04)
        static let create = OpenFlags(rawValue: 0x08)
        static let truncate = OpenFlags(rawValue: 0x10)
        static let exclusive = OpenFlags(rawValue: 0x20)
    }

    private struct Reply {
        let type: UInt8
        var reader: SFTPReader
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorURL: URL

    private let lock = NSLock()
    /// Keeps packets sent from different threads from interleaving in the pipe.
    private let sendLock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Reply, Error>] = [:]
    private var versionContinuation: CheckedContinuation<Void, Error>?
    private var received = Data()
    private var closedError: SFTPError?
    private var outputEnded = false
    private var terminated = false
    private var closeHandlers: [@Sendable (SFTPError) -> Void] = []

    /// Starts `ssh` with the arguments, which must run the sftp subsystem, and waits for
    /// the server to answer the protocol's greeting.
    /// `executable` is replaceable for tests, which can talk to `sftp-server` directly.
    static func connect(
        sshArguments: [String],
        environment: [String: String],
        executable: URL = SSHRunner.executable
    ) async throws -> SFTPClient {
        let client = SFTPClient(executable: executable, arguments: sshArguments, environment: environment)
        try await client.start()
        return client
    }

    private init(executable: URL, arguments: [String], environment: [String: String]) {
        errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-sftp-\(UUID().uuidString).log")
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
    }

    deinit {
        close()
        try? FileManager.default.removeItem(at: errorURL)
    }

    private func start() async throws {
        // ssh's errors go to a file: a master it leaves in the background could otherwise
        // keep a pipe open.
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        process.standardError = errorHandle

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.lock.withLock { self.outputEnded = true }
                self.finishIfDone()
            } else {
                self.receive(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.terminated = true }
            // Give the last replies time to be read before failing what is left.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.finish() }
            self.finishIfDone()
        }

        try process.run()
        try? errorHandle.close()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { versionContinuation = continuation }
            var packet = SFTPWriter()
            packet.u8(PacketType.initialize)
            packet.u32(3)
            send(packet)
        }
    }

    /// Calls `handler` once when the connection closes, right away if it has.
    func onClose(_ handler: @escaping @Sendable (SFTPError) -> Void) {
        let closed: SFTPError? = lock.withLock {
            if closedError == nil { closeHandlers.append(handler) }
            return closedError
        }
        if let closed { handler(closed) }
    }

    var isClosed: Bool { lock.withLock { closedError != nil } }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: Requests

    /// The absolute form of the path, e.g. the home directory for ".".
    func realpath(_ path: String) async throws -> String {
        var reply = try await request(PacketType.realpath) { $0.string(path) }
        try expect(reply, PacketType.name)
        guard try reply.reader.u32() >= 1 else { throw SFTPError.badMessage }
        return try reply.reader.string()
    }

    func stat(_ path: String) async throws -> SFTPAttributes {
        var reply = try await request(PacketType.stat) { $0.string(path) }
        try expect(reply, PacketType.attrs)
        return try reply.reader.attributes()
    }

    func lstat(_ path: String) async throws -> SFTPAttributes {
        var reply = try await request(PacketType.lstat) { $0.string(path) }
        try expect(reply, PacketType.attrs)
        return try reply.reader.attributes()
    }

    /// The names in the directory, without `.` and `..`, with the attributes of each
    /// name itself (a link's own, not its target's).
    func listDirectory(_ path: String) async throws -> [(name: String, attributes: SFTPAttributes)] {
        let handle = try await handleRequest(PacketType.opendir) { $0.string(path) }
        var entries: [(String, SFTPAttributes)] = []
        do {
            while true {
                var reply = try await request(PacketType.readdir) { $0.string(handle) }
                if Self.isEOF(reply) { break }
                try expect(reply, PacketType.name)
                let count = try reply.reader.u32()
                for _ in 0..<count {
                    let name = try reply.reader.string()
                    _ = try reply.reader.bytes() // the `ls -l` style line
                    let attributes = try reply.reader.attributes()
                    if name != "." && name != ".." { entries.append((name, attributes)) }
                }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
        return entries
    }

    func open(_ path: String, flags: OpenFlags, permissions: UInt32? = nil) async throws -> Data {
        try await handleRequest(PacketType.open) {
            $0.string(path)
            $0.u32(flags.rawValue)
            $0.attributes(SFTPAttributes(permissions: permissions))
        }
    }

    /// Reads up to `length` bytes at `offset`; nil at the end of the file.
    func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        var reply = try await request(PacketType.read) {
            $0.string(handle)
            $0.u64(offset)
            $0.u32(length)
        }
        if Self.isEOF(reply) { return nil }
        try expect(reply, PacketType.data)
        return try reply.reader.bytes()
    }

    func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        try await statusRequest(PacketType.write) {
            $0.string(handle)
            $0.u64(offset)
            $0.string(data)
        }
    }

    func closeHandle(_ handle: Data) async throws {
        try await statusRequest(PacketType.close) { $0.string(handle) }
    }

    func mkdir(_ path: String, permissions: UInt32? = nil) async throws {
        try await statusRequest(PacketType.mkdir) {
            $0.string(path)
            $0.attributes(SFTPAttributes(permissions: permissions))
        }
    }

    func rmdir(_ path: String) async throws {
        try await statusRequest(PacketType.rmdir) { $0.string(path) }
    }

    func remove(_ path: String) async throws {
        try await statusRequest(PacketType.remove) { $0.string(path) }
    }

    func rename(_ from: String, to: String) async throws {
        try await statusRequest(PacketType.rename) {
            $0.string(from)
            $0.string(to)
        }
    }

    func setAttributes(_ path: String, _ attributes: SFTPAttributes) async throws {
        try await statusRequest(PacketType.setstat) {
            $0.string(path)
            $0.attributes(attributes)
        }
    }

    // MARK: Plumbing

    private func handleRequest(_ type: UInt8, _ body: (inout SFTPWriter) -> Void) async throws -> Data {
        var reply = try await request(type, body)
        try expect(reply, PacketType.handle)
        return try reply.reader.bytes()
    }

    private func statusRequest(_ type: UInt8, _ body: (inout SFTPWriter) -> Void) async throws {
        let reply = try await request(type, body)
        try expect(reply, PacketType.status)
    }

    /// Throws the STATUS reply's error unless it is the expected reply or an OK status.
    private func expect(_ reply: Reply, _ type: UInt8) throws {
        if reply.type == type && type != PacketType.status { return }
        guard reply.type == PacketType.status else { throw SFTPError.badMessage }
        var reply = reply
        let code = try reply.reader.u32()
        guard code == 0 else {
            let message = (try? reply.reader.string()) ?? ""
            throw SFTPError.status(code: code, message: message)
        }
        if type != PacketType.status { throw SFTPError.badMessage }
    }

    private static func isEOF(_ reply: Reply) -> Bool {
        guard reply.type == PacketType.status else { return false }
        var reader = reply.reader
        return (try? reader.u32()) == SFTPError.eof
    }

    private func request(_ type: UInt8, _ body: (inout SFTPWriter) -> Void) async throws -> Reply {
        var packet = SFTPWriter()
        packet.u8(type)
        let id: UInt32 = lock.withLock {
            defer { nextID &+= 1 }
            return nextID
        }
        packet.u32(id)
        body(&packet)

        return try await withCheckedThrowingContinuation { continuation in
            let closed: SFTPError? = lock.withLock {
                if closedError == nil { pending[id] = continuation }
                return closedError
            }
            if let closed { return continuation.resume(throwing: closed) }
            send(packet)
        }
    }

    private func send(_ packet: SFTPWriter) {
        var framed = Data()
        framed.reserveCapacity(packet.data.count + 4)
        withUnsafeBytes(of: UInt32(packet.data.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(packet.data)
        // A write to a process that exited fails rather than raising SIGPIPE, which the
        // app ignores; the termination handler then fails the request.
        sendLock.withLock { try? input.fileHandleForWriting.write(contentsOf: framed) }
    }

    private func receive(_ data: Data) {
        var replies: [(CheckedContinuation<Reply, Error>, Reply)] = []
        var version: CheckedContinuation<Void, Error>?
        lock.withLock {
            received.append(data)
            while received.count >= 4 {
                let length = received.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard received.count >= 4 + length else { break }
                let start = received.startIndex + 4
                var reader = SFTPReader(data: Data(received[start..<start + length]))
                received.removeFirst(4 + length)
                guard let type = try? reader.u8() else { continue }
                if type == PacketType.version {
                    version = versionContinuation
                    versionContinuation = nil
                } else if let id = try? reader.u32(), let continuation = pending.removeValue(forKey: id) {
                    replies.append((continuation, Reply(type: type, reader: reader)))
                }
            }
        }
        version?.resume()
        for (continuation, reply) in replies { continuation.resume(returning: reply) }
    }

    private func finishIfDone() {
        let done = lock.withLock { outputEnded && terminated }
        if done { finish() }
    }

    /// Fails what is still waiting for a reply, once the process has exited.
    private func finish() {
        let message = ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = SFTPError.disconnected(message)
        let (continuations, version, handlers): ([CheckedContinuation<Reply, Error>], CheckedContinuation<Void, Error>?, [@Sendable (SFTPError) -> Void]) = lock.withLock {
            guard closedError == nil else { return ([], nil, []) }
            closedError = error
            defer {
                pending = [:]
                versionContinuation = nil
                closeHandlers = []
            }
            return (Array(pending.values), versionContinuation, closeHandlers)
        }
        version?.resume(throwing: error)
        for continuation in continuations { continuation.resume(throwing: error) }
        for handler in handlers { handler(error) }
    }
}

/// Builds an SFTP packet's payload.
struct SFTPWriter {
    var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) { string(Data(value.utf8)) }

    mutating func attributes(_ attributes: SFTPAttributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTPAttributes.sizeFlag }
        if attributes.permissions != nil { flags |= SFTPAttributes.permissionsFlag }
        if attributes.modified != nil { flags |= SFTPAttributes.timesFlag }
        u32(flags)
        if let size = attributes.size { u64(size) }
        if let permissions = attributes.permissions { u32(permissions) }
        if let modified = attributes.modified {
            u32(attributes.accessed ?? modified)
            u32(modified)
        }
    }
}

/// Reads an SFTP packet's payload.
struct SFTPReader {
    let data: Data
    private var offset = 0

    init(data: Data) { self.data = data }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.count - offset >= count else { throw SFTPError.badMessage }
        let start = data.startIndex + offset
        offset += count
        return data[start..<start + count]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bytes() throws -> Data { Data(try take(Int(try u32()))) }

    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

    mutating func attributes() throws -> SFTPAttributes {
        var attributes = SFTPAttributes()
        let flags = try u32()
        if flags & SFTPAttributes.sizeFlag != 0 { attributes.size = try u64() }
        if flags & SFTPAttributes.uidGIDFlag != 0 {
            _ = try u32()
            _ = try u32()
        }
        if flags & SFTPAttributes.permissionsFlag != 0 { attributes.permissions = try u32() }
        if flags & SFTPAttributes.timesFlag != 0 {
            attributes.accessed = try u32()
            attributes.modified = try u32()
        }
        if flags & SFTPAttributes.extendedFlag != 0 {
            for _ in 0..<(try u32()) {
                _ = try bytes()
                _ = try bytes()
            }
        }
        return attributes
    }
}
