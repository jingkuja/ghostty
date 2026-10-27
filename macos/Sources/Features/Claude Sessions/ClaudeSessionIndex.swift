import Foundation

// Claude Code's on-disk session format is not a public API. Everything here reads it
// leniently: unknown records are skipped and every field has a fallback.

/// A Claude Code session recorded under `~/.claude/projects`.
struct ClaudeSession: Identifiable, Equatable {
    let id: String
    let path: String
    let title: String
    /// Working directory recorded with the first prompt
    let cwd: String?
    let gitBranch: String?
    /// The newest prompt or reply
    let lastActivity: Date
}

enum ClaudeSessionGroup: CaseIterable {
    case today
    case yesterday
    case week
    case earlier

    var label: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .week: return "本周"
        case .earlier: return "更早"
        }
    }

    /// Groups sessions by their last activity, newest first. Weeks start on Monday.
    static func group(_ sessions: [ClaudeSession], now: Date = Date()) -> [(Self, [ClaudeSession])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = Calendar(identifier: .iso8601).dateInterval(of: .weekOfYear, for: now)?.start ?? today

        var groups: [Self: [ClaudeSession]] = [:]
        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let t = session.lastActivity
            let key: Self = t >= today ? .today : t >= yesterday ? .yesterday : t >= week ? .week : .earlier
            groups[key, default: []].append(session)
        }
        return allCases.compactMap { key in groups[key].map { (key, $0) } }
    }
}

/// Lists the Claude Code sessions recorded for a directory.
///
/// Session files are append-only, so each one is parsed incrementally: only lines appended
/// since the last read are scanned. This class is not thread-safe; use it from one queue.
final class ClaudeSessionIndex {
    /// Claude Code shortens longer project directory names and appends a hash
    private static let maxProjectDirName = 200

    let claudeDir: URL

    private var cache: [String: CacheEntry] = [:]

    init(claudeDir: URL? = nil) {
        if let claudeDir {
            self.claudeDir = claudeDir
        } else if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            self.claudeDir = URL(fileURLWithPath: dir)
        } else {
            self.claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
    }

    var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    var liveSessionsDir: URL { claudeDir.appendingPathComponent("sessions") }

    /// The sessions recorded for `cwd`, newest first. SDK sessions are left out.
    func list(cwd: String) -> [ClaudeSession] {
        let cwds = Self.directoryCandidates(cwd)
        let fm = FileManager.default
        let dirs = projectDirs(for: cwds)
        var files: [String] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            files += entries.filter { $0.hasSuffix(".jsonl") }.map { (dir as NSString).appendingPathComponent($0) }
        }

        // Forget files that are gone so the cache doesn't grow forever.
        let listed = Set(files)
        cache = cache.filter { listed.contains($0.key) || !dirs.contains(($0.key as NSString).deletingLastPathComponent) }

        return files
            .compactMap { read($0) }
            // The directory name encoding is lossy (`/a-b` and `/a/b` collide)
            .filter { $0.info.cwd.map { cwds.contains(Self.standardize($0)) } ?? true }
            .filter { !($0.entrypoint?.hasPrefix("sdk") ?? false) }
            .map(\.info)
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The session a running `claude` process currently has open. Claude Code registers each
    /// running instance in `sessions/<pid>.json`, which also follows `/resume` and `/clear`.
    func liveSessionID(pid: Int) -> String? {
        let url = liveSessionsDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["pid"] as? Int == pid else { return nil }
        return json["sessionId"] as? String
    }

    // MARK: Project directories

    static func encodeProjectPath(_ path: String) -> String {
        // Claude Code replaces every UTF-16 code unit that isn't ASCII alphanumeric.
        String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(Unicode.Scalar(unit)!)
            default: return "-"
            }
        })
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The directory as given and with symlinks resolved.
    private static func directoryCandidates(_ cwd: String) -> [String] {
        let standardized = standardize(cwd)
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return resolved == standardized ? [standardized] : [standardized, resolved]
    }

    private func projectDirs(for cwds: [String]) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else { return [] }
        var result: [String] = []
        for cwd in cwds {
            let encoded = Self.encodeProjectPath(cwd)
            let prefix = encoded.count > Self.maxProjectDirName ? String(encoded.prefix(Self.maxProjectDirName)) : nil
            for entry in entries where entry == encoded || prefix.map({ entry.hasPrefix($0) }) == true {
                let dir = projectsDir.appendingPathComponent(entry).path
                if !result.contains(dir) { result.append(dir) }
            }
        }
        return result
    }

    // MARK: Session files

    private struct CacheEntry {
        var scanner = SessionScanner()
        /// Bytes consumed so far, always at a line boundary
        var offset: UInt64 = 0
        var fileNumber: Int?
        var size: UInt64 = 0
        var modified: Date?
        var session: ClaudeSession?
    }

    private struct ReadResult {
        let info: ClaudeSession
        let entrypoint: String?
    }

    private func read(_ path: String) -> ReadResult? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            cache[path] = nil
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attrs[.modificationDate] as? Date
        let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.intValue

        var entry = cache[path] ?? CacheEntry()
        if entry.fileNumber != fileNumber || size < entry.offset {
            // Replaced or truncated: start over.
            entry = CacheEntry()
        }

        if entry.size != size || entry.modified != modified || entry.fileNumber == nil {
            if !consume(path, into: &entry) {
                cache[path] = nil
                return nil
            }
            entry.fileNumber = fileNumber
            entry.size = size
            entry.modified = modified
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            entry.session = entry.scanner.session(id: id, path: path, fallbackDate: modified ?? Date())
            cache[path] = entry
        }

        guard let session = entry.session else { return nil }
        return ReadResult(info: session, entrypoint: entry.scanner.entrypoint)
    }

    /// Scans the complete lines appended since `entry.offset`.
    private func consume(_ path: String, into entry: inout CacheEntry) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: entry.offset)
            var pending = Data()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                pending.append(chunk)
                var start = pending.startIndex
                while let newline = pending[start...].firstIndex(of: 0x0A) {
                    entry.scanner.consume(pending[start..<newline])
                    start = pending.index(after: newline)
                }
                entry.offset += UInt64(start - pending.startIndex)
                pending = Data(pending[start...])
            }
            return true
        } catch {
            return false
        }
    }
}

/// Accumulates what the sidebar shows from the records of one session file.
private struct SessionScanner {
    private static let maxTitleLength = 200

    /// Bulky records the sidebar never needs; anything unknown is still parsed
    private static let skippedRecords: Set<String> = [
        "api-request", "api-request-blob", "api-request-shape", "attachment", "atis-latch", "cost-state",
        "file-history-delta", "file-history-snapshot", "mode", "permission-mode", "queue-operation", "system", "tools-used",
    ]

    private static let typeMarker = Data("\"type\":\"".utf8)

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackDateFormatter = ISO8601DateFormatter()

    private var customTitle: String?
    private var aiTitle: String?
    private var summary: String?
    private var lastPrompt: String?
    private var firstPrompt: String?
    private var cwd: String?
    private var gitBranch: String?
    private(set) var entrypoint: String?
    private var lastActivity: Date?
    /// False for sessions without a single real exchange (e.g. only `/config` was run)
    private var hasExchange = false

    func session(id: String, path: String, fallbackDate: Date) -> ClaudeSession? {
        guard hasExchange else { return nil }
        return ClaudeSession(
            id: id,
            path: path,
            title: customTitle ?? aiTitle ?? summary ?? lastPrompt ?? firstPrompt ?? id,
            cwd: cwd,
            gitBranch: gitBranch,
            lastActivity: lastActivity ?? fallbackDate)
    }

    mutating func consume(_ line: Data) {
        // Most of a large session is API payloads; skip them without parsing.
        if let type = Self.recordType(line), Self.skippedRecords.contains(type) { return }
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        switch record["type"] as? String {
        case "custom-title":
            customTitle = Self.normalizeTitle(record["customTitle"]) ?? customTitle
        case "ai-title":
            aiTitle = Self.normalizeTitle(record["aiTitle"]) ?? aiTitle
        case "summary":
            summary = Self.normalizeTitle(record["summary"]) ?? summary
        case "last-prompt":
            lastPrompt = Self.normalizeTitle(record["lastPrompt"]) ?? lastPrompt
        case "user", "assistant":
            consumeMessage(record)
        default:
            break
        }
    }

    private mutating func consumeMessage(_ record: [String: Any]) {
        if record["isSidechain"] as? Bool == true { return }
        if let timestamp = record["timestamp"] as? String,
           let date = Self.dateFormatter.date(from: timestamp) ?? Self.fallbackDateFormatter.date(from: timestamp) {
            lastActivity = max(lastActivity ?? date, date)
        }
        if let branch = record["gitBranch"] as? String, !branch.isEmpty {
            gitBranch = branch
        }
        if record["type"] as? String == "assistant" {
            hasExchange = true
            return
        }
        if record["isMeta"] as? Bool == true { return }

        if cwd == nil { cwd = record["cwd"] as? String }
        if entrypoint == nil { entrypoint = record["entrypoint"] as? String }
        let message = record["message"] as? [String: Any]
        if let text = Self.promptText(message?["content"]) {
            hasExchange = true
            if firstPrompt == nil { firstPrompt = text }
        }
    }

    /// The `type` of a record, if it appears near the start of the line.
    private static func recordType(_ line: Data) -> String? {
        let head = line.prefix(512)
        guard let marker = head.range(of: typeMarker) else { return nil }
        let rest = head[marker.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<end], as: UTF8.self)
    }

    private static func normalizeTitle(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let title = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return title.count > maxTitleLength ? String(title.prefix(maxTitleLength)) + "…" : title
    }

    /// Text the user typed, or nil for tool results, slash commands and their output.
    private static func promptText(_ content: Any?) -> String? {
        var text: String?
        if let content = content as? String {
            text = content
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" && $0["text"] is String }?["text"] as? String
        }
        guard let text else { return nil }
        let trimmed = text.drop(while: { $0.isWhitespace })
        for prefix in ["<command-", "<local-command", "<bash-", "<system-reminder"] where trimmed.hasPrefix(prefix) {
            return nil
        }
        return normalizeTitle(text)
    }
}
