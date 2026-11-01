import AppKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", category: "files-tab")

/// What to do with a file or folder whose name is taken where it is being copied.
enum TransferConflict {
    /// Replace the file; for a folder, copy into it, replacing files with the same names
    case replace
    /// Copy under a new name, like Finder's "Keep Both"
    case keepBoth
    case skip
}

/// The bytes a transfer has copied, counted by its tasks and read by the queue.
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var total: UInt64 = 0
    private var done: UInt64 = 0

    func setTotal(_ bytes: UInt64) { lock.withLock { total = bytes } }
    func add(_ bytes: Int) { lock.withLock { done += UInt64(max(bytes, 0)) } }
    var snapshot: (total: UInt64, done: UInt64) { lock.withLock { (total, done) } }
}

/// Copies files and folders between this Mac and a host over SFTP.
///
/// A file is copied in chunks with several requests in flight, which is what makes SFTP
/// fast over a slow link. It goes to a hidden temporary name next to its destination and
/// is renamed into place once complete, so a failed or cancelled copy never leaves a
/// partial file behind or destroys the file it was replacing. Modification times and
/// permissions are kept.
enum SFTPTransfer {
    static let chunkSize = 32 * 1024
    /// Requests in flight per file
    static let window = 32

    // MARK: Upload

    static func upload(_ local: String, to remote: String, client: SFTPClient, progress: TransferProgress) async throws {
        guard let type = fileType(local, followingLinks: true) else { throw posixError(ENOENT) }
        guard type == S_IFDIR else {
            progress.setTotal(fileSize(local))
            return try await uploadFile(local, to: remote, client: client, progress: progress)
        }

        // Folders come before what is in them. Links are copied as what they point to,
        // except links to folders, which could loop.
        var directories: [String] = []
        var files: [String] = []
        var total: UInt64 = 0
        let relatives = FileManager.default.enumerator(atPath: local)?.allObjects as? [String] ?? []
        for relative in relatives {
            let path = FileEntry.join(local, relative)
            switch fileType(path, followingLinks: false) {
            case S_IFDIR:
                directories.append(relative)
            case S_IFREG:
                files.append(relative)
                total += fileSize(path)
            case S_IFLNK where fileType(path, followingLinks: true) == S_IFREG:
                files.append(relative)
                total += fileSize(path)
            default:
                break
            }
        }
        progress.setTotal(total)

        try await makeRemoteDirectory(remote, client: client)
        for relative in directories {
            try Task.checkCancellation()
            try await makeRemoteDirectory(FileEntry.join(remote, relative), client: client)
        }
        for relative in files {
            try Task.checkCancellation()
            try await uploadFile(FileEntry.join(local, relative), to: FileEntry.join(remote, relative),
                                 client: client, progress: progress)
        }
    }

    private static func uploadFile(_ local: String, to remote: String, client: SFTPClient, progress: TransferProgress) async throws {
        let fd = open(local, O_RDONLY)
        guard fd >= 0 else { throw posixError(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError(errno) }
        let size = UInt64(max(info.st_size, 0))
        let permissions = UInt32(info.st_mode) & 0o7777

        let temporary = temporaryPath(for: remote, suffix: "upload")
        let handle = try await client.open(temporary, flags: [.write, .create, .truncate], permissions: permissions & 0o777)
        do {
            try await pipelined(chunkCount(size)) { index in
                let offset = UInt64(index) * UInt64(chunkSize)
                let data = try readLocal(fd, offset: offset, length: Int(min(UInt64(chunkSize), size - offset)))
                try await client.write(handle, offset: offset, data: data)
                progress.add(data.count)
            }
            try await client.closeHandle(handle)
            try? await client.setAttributes(temporary, SFTPAttributes(
                permissions: permissions,
                modified: UInt32(clamping: info.st_mtimespec.tv_sec),
                accessed: UInt32(clamping: info.st_atimespec.tv_sec)))
            try await client.replace(temporary, with: remote)
        } catch {
            try? await client.closeHandle(handle)
            try? await client.remove(temporary)
            throw error
        }
    }

    private static func makeRemoteDirectory(_ path: String, client: SFTPClient) async throws {
        if let existing = try? await client.stat(path) {
            guard existing.isDirectory else { throw TransferError.notADirectory(path) }
            return
        }
        try await client.mkdir(path, permissions: 0o755)
    }

    // MARK: Download

    static func download(_ remote: String, to local: String, client: SFTPClient, progress: TransferProgress) async throws {
        let attributes = try await client.stat(remote)
        guard attributes.isDirectory else {
            progress.setTotal(attributes.size ?? 0)
            return try await downloadFile(remote, attributes, to: local, client: client, progress: progress)
        }

        // Folders come before what is in them; links are handled as for uploads.
        var directories: [String] = []
        var files: [(String, SFTPAttributes)] = []
        var queue = [""]
        var next = 0
        while next < queue.count {
            try Task.checkCancellation()
            let relative = queue[next]
            next += 1
            let directory = relative.isEmpty ? remote : FileEntry.join(remote, relative)
            for item in try await client.listDirectory(directory) {
                let child = relative.isEmpty ? item.name : relative + "/" + item.name
                var attributes = item.attributes
                if attributes.isSymlink {
                    guard let target = try? await client.stat(FileEntry.join(directory, item.name)),
                          !target.isDirectory else { continue }
                    attributes = target
                }
                if attributes.isDirectory {
                    directories.append(child)
                    queue.append(child)
                } else if attributes.permissions.map({ $0 & 0o170000 == 0o100000 }) ?? true {
                    files.append((child, attributes))
                }
            }
        }
        progress.setTotal(files.reduce(0) { $0 + ($1.1.size ?? 0) })

        try makeLocalDirectory(local)
        for relative in directories { try makeLocalDirectory(FileEntry.join(local, relative)) }
        for (relative, attributes) in files {
            try Task.checkCancellation()
            try await downloadFile(FileEntry.join(remote, relative), attributes, to: FileEntry.join(local, relative),
                                   client: client, progress: progress)
        }
    }

    private static func downloadFile(
        _ remote: String,
        _ attributes: SFTPAttributes,
        to local: String,
        client: SFTPClient,
        progress: TransferProgress
    ) async throws {
        let temporary = temporaryPath(for: local, suffix: "download")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw posixError(errno) }
        var isOpen = true
        defer { if isOpen { close(fd) } }

        do {
            let handle = try await client.open(remote, flags: [.read])
            do {
                let size = attributes.size ?? 0
                try await pipelined(chunkCount(size)) { index in
                    var position = UInt64(index) * UInt64(chunkSize)
                    let end = min(position + UInt64(chunkSize), size)
                    // A server may answer with less than asked; ask again for the rest.
                    while position < end {
                        guard let data = try await client.read(handle, offset: position, length: UInt32(end - position)) else { break }
                        try writeLocal(fd, data, offset: position)
                        position += UInt64(data.count)
                        progress.add(data.count)
                    }
                }
                // The file may have grown since it was listed.
                var position = size
                while let data = try await client.read(handle, offset: position, length: UInt32(chunkSize)) {
                    try writeLocal(fd, data, offset: position)
                    position += UInt64(data.count)
                    progress.add(data.count)
                }
                try? await client.closeHandle(handle)
            } catch {
                try? await client.closeHandle(handle)
                throw error
            }

            fchmod(fd, mode_t((attributes.permissions ?? 0o644) & 0o777))
            if let modified = attributes.modified {
                let accessed = attributes.accessed ?? modified
                var times = [timespec(tv_sec: Int(accessed), tv_nsec: 0), timespec(tv_sec: Int(modified), tv_nsec: 0)]
                futimens(fd, &times)
            }
            close(fd)
            isOpen = false
            guard rename(temporary, local) == 0 else { throw posixError(errno) }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    private static func makeLocalDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw TransferError.notADirectory(path) }
            return
        }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    // MARK: Remote changes

    /// Removes a file, or a folder with everything in it. Links are removed, not followed.
    static func removeRecursively(_ path: String, client: SFTPClient) async throws {
        let attributes = try await client.lstat(path)
        guard attributes.isDirectory else { return try await client.remove(path) }
        for item in try await client.listDirectory(path) {
            try Task.checkCancellation()
            let child = FileEntry.join(path, item.name)
            if item.attributes.isDirectory {
                try await removeRecursively(child, client: client)
            } else {
                try await client.remove(child)
            }
        }
        try await client.rmdir(path)
    }

    // MARK: Helpers

    private static func chunkCount(_ size: UInt64) -> Int {
        Int((size + UInt64(chunkSize) - 1) / UInt64(chunkSize))
    }

    /// Runs `body` for each index with up to `window` running at once.
    private static func pipelined(_ count: Int, _ body: @escaping @Sendable (Int) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(window, count) {
                let index = next
                group.addTask { try await body(index) }
                next += 1
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if next < count {
                    let index = next
                    group.addTask { try await body(index) }
                    next += 1
                }
            }
        }
    }

    private static func temporaryPath(for path: String, suffix: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return FileEntry.join(directory.isEmpty ? "." : directory,
                              ".\((path as NSString).lastPathComponent).ghostty-\(suffix)")
    }

    private static func fileType(_ path: String, followingLinks: Bool) -> mode_t? {
        var info = stat()
        let result = followingLinks ? stat(path, &info) : lstat(path, &info)
        return result == 0 ? info.st_mode & S_IFMT : nil
    }

    private static func fileSize(_ path: String) -> UInt64 {
        var info = stat()
        return stat(path, &info) == 0 ? UInt64(max(info.st_size, 0)) : 0
    }

    private static func readLocal(_ fd: Int32, offset: UInt64, length: Int) throws -> Data {
        var data = Data(count: length)
        var read = 0
        try data.withUnsafeMutableBytes { buffer in
            while read < length {
                let count = pread(fd, buffer.baseAddress! + read, length - read, off_t(offset) + off_t(read))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                if count == 0 { break }
                read += count
            }
        }
        return data.prefix(read)
    }

    private static func writeLocal(_ fd: Int32, _ data: Data, offset: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = pwrite(fd, buffer.baseAddress! + written, buffer.count - written, off_t(offset) + off_t(written))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                written += count
            }
        }
    }

    private static func posixError(_ code: Int32) -> Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

enum TransferError: LocalizedError {
    case notADirectory(String)

    var errorDescription: String? {
        switch self {
        case .notADirectory(let path): return "“\((path as NSString).lastPathComponent)”已存在且不是文件夹"
        }
    }
}

/// A window's file transfers, run one at a time in the order they were added.
@MainActor
final class FileTransfers: ObservableObject {
    enum Direction {
        case upload
        case download
    }

    enum Status: Equatable {
        case queued
        case running
        case done
        case failed(String)
        case cancelled

        var isFinished: Bool { self != .queued && self != .running }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let direction: Direction
        let name: String
        /// The other side, e.g. `user@host`
        let host: String
        /// The folder it is copied to, as shown
        let destination: String
        var total: UInt64 = 0
        var done: UInt64 = 0
        /// Bytes per second, smoothed
        var speed: Double = 0
        var status: Status = .queued
    }

    @Published private(set) var items: [Item] = []

    /// Called when an item finishes, to refresh what shows its destination.
    var didFinish: ((Item) -> Void)?

    private struct Job {
        let id: UUID
        let run: @Sendable (TransferProgress) async throws -> Void
        let completion: (@MainActor () -> Void)?
    }

    private var jobs: [Job] = []
    private var current: (id: UUID, task: Task<Void, Never>, progress: TransferProgress)?
    private var timer: Timer?
    private var lastSample: (date: Date, done: UInt64)?

    /// Uploads local files and folders into a remote folder, asking what to do with
    /// names that are taken.
    func upload(_ paths: [String], to directory: String, client: SFTPClient, host: String, displayDirectory: String) {
        Task {
            var conflicts = ConflictResolver(count: paths.count)
            for path in paths {
                let name = (path as NSString).lastPathComponent
                var destination = FileEntry.join(directory, name)
                if let existing = try? await client.lstat(destination) {
                    switch conflicts.resolve(name: name, isDirectory: existing.isDirectory, place: "\(host):\(displayDirectory)") {
                    case .skip: continue
                    case .replace: break
                    case .keepBoth:
                        destination = await Self.availableName(in: directory, for: name) { candidate in
                            (try? await client.lstat(candidate)) != nil
                        }
                    }
                }
                let target = destination
                enqueue(Item(direction: .upload, name: name, host: host, destination: displayDirectory)) { progress in
                    try await SFTPTransfer.upload(path, to: target, client: client, progress: progress)
                }
            }
        }
    }

    /// Downloads remote files and folders into a local folder, asking what to do with
    /// names that are taken.
    func download(_ paths: [String], to directory: String, client: SFTPClient, host: String) {
        var conflicts = ConflictResolver(count: paths.count)
        for path in paths {
            let name = (path as NSString).lastPathComponent
            var destination = FileEntry.join(directory, name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory) {
                switch conflicts.resolve(name: name, isDirectory: isDirectory.boolValue, place: directory.abbreviatingHome) {
                case .skip: continue
                case .replace: break
                case .keepBoth:
                    destination = Self.availableName(in: directory, for: name) {
                        FileManager.default.fileExists(atPath: $0)
                    }
                }
            }
            let target = destination
            enqueue(Item(direction: .download, name: name, host: host, destination: directory.abbreviatingHome)) { progress in
                try await SFTPTransfer.download(path, to: target, client: client, progress: progress)
            }
        }
    }

    /// Downloads a remote file to a temporary folder and opens it with its default app,
    /// or hands the copy to `handler` when one is given.
    func open(_ path: String, client: SFTPClient, host: String, with handler: (@MainActor (URL) -> Void)? = nil) {
        let name = (path as NSString).lastPathComponent
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ghostty Remote Files", isDirectory: true)
            .appendingPathComponent(host.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        let local = directory.appendingPathComponent(name)
        enqueue(Item(direction: .download, name: name, host: host, destination: "临时文件夹"),
                completion: {
                    if let handler { handler(local) } else { NSWorkspace.shared.open(local) }
                }) { progress in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await SFTPTransfer.download(path, to: local.path, client: client, progress: progress)
        }
    }

    func cancel(_ id: UUID) {
        if let current, current.id == id {
            current.task.cancel()
        } else if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs.remove(at: index)
            update(id) { $0.status = .cancelled }
        }
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    private func enqueue(
        _ item: Item,
        completion: (@MainActor () -> Void)? = nil,
        run: @escaping @Sendable (TransferProgress) async throws -> Void
    ) {
        logger.notice("transfer queued: \(item.direction == .upload ? "upload" : "download") \(item.name, privacy: .public)")
        items.append(item)
        jobs.append(Job(id: item.id, run: run, completion: completion))
        startNext()
    }

    private func startNext() {
        guard current == nil else { return }
        guard !jobs.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }

        let job = jobs.removeFirst()
        let progress = TransferProgress()
        update(job.id) { $0.status = .running }
        lastSample = nil
        let task = Task { [weak self] in
            let status: Status
            do {
                try await job.run(progress)
                status = .done
            } catch {
                status = error is CancellationError || Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            if case .failed(let message) = status { logger.error("transfer failed: \(message, privacy: .public)") }
            guard let self else { return }
            self.sample()
            self.update(job.id) {
                $0.status = status
                $0.speed = 0
            }
            self.current = nil
            if status == .done { job.completion?() }
            if let item = self.items.first(where: { $0.id == job.id }) { self.didFinish?(item) }
            self.startNext()
        }
        current = (job.id, task, progress)

        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            }
        }
    }

    /// Copies the running transfer's progress into its item.
    private func sample() {
        guard let current else { return }
        let (total, done) = current.progress.snapshot
        let now = Date()
        var speed: Double?
        if let lastSample, now.timeIntervalSince(lastSample.date) > 0 {
            speed = Double(done - min(done, lastSample.done)) / now.timeIntervalSince(lastSample.date)
        }
        lastSample = (now, done)
        update(current.id) { item in
            item.total = total
            item.done = done
            if let speed { item.speed = item.speed == 0 ? speed : item.speed * 0.7 + speed * 0.3 }
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        if item != items[index] { items[index] = item }
    }

    /// `name` in the folder, or "name 2", "name 3"… before its extension if taken.
    private static func availableName(in directory: String, for name: String, taken: (String) async -> Bool) async -> String {
        var candidate = FileEntry.join(directory, name)
        var number = 2
        while await taken(candidate), number < 10_000 {
            candidate = FileEntry.join(directory, numbered(name, number))
            number += 1
        }
        return candidate
    }

    private static func availableName(in directory: String, for name: String, taken: (String) -> Bool) -> String {
        var candidate = FileEntry.join(directory, name)
        var number = 2
        while taken(candidate), number < 10_000 {
            candidate = FileEntry.join(directory, numbered(name, number))
            number += 1
        }
        return candidate
    }

    private static func numbered(_ name: String, _ number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(name) \(number)" : "\(base) \(number).\(ext)"
    }
}

/// Asks what to do when names are taken, remembering "apply to all".
@MainActor
private struct ConflictResolver {
    let count: Int
    private var always: TransferConflict?

    init(count: Int) { self.count = count }

    mutating func resolve(name: String, isDirectory: Bool, place: String) -> TransferConflict {
        if let always { return always }

        let alert = NSAlert()
        alert.messageText = "“\(name)”已存在"
        alert.informativeText = isDirectory
            ? "\(place) 中已有同名文件夹。合并会把内容复制进去，并替换其中的同名文件。"
            : "\(place) 中已有同名文件。"
        alert.addButton(withTitle: isDirectory ? "合并" : "替换")
        alert.addButton(withTitle: "保留两者")
        alert.addButton(withTitle: "跳过")
        if count > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "应用到全部"
        }

        let choice: TransferConflict
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .replace
        case .alertSecondButtonReturn: choice = .keepBoth
        default: choice = .skip
        }
        if alert.suppressionButton?.state == .on { always = choice }
        return choice
    }
}
