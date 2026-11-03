import AppKit
import SwiftUI
import GhosttyKit

/// Reads and edits the settings in Ghostty's config file that the quick settings popover
/// offers, and reloads the configuration so they take effect right away.
///
/// Edits keep the rest of the file, comments included: a key's first line is rewritten in
/// place and its other lines removed, or the key is appended when the file doesn't set it.
@MainActor
final class QuickSettingsStore: ObservableObject {
    static let shared = QuickSettingsStore()

    /// Whether the tab bar is shown while a window has a single tab. Kept in the user
    /// defaults since it is this app's, not a Ghostty config option.
    static let alwaysShowTabBarKey = "AlwaysShowTabBar"

    static var alwaysShowsTabBar: Bool {
        UserDefaults.standard.object(forKey: alwaysShowTabBarKey) as? Bool ?? true
    }

    /// The file Ghostty opens for editing. On macOS it is loaded last, so what it sets wins.
    let path: String

    /// The values the file sets, by key. For repeatable keys such as `font-family`, the first.
    @Published private(set) var values: [String: String] = [:]
    @Published private(set) var error: String?

    /// Edits not yet written, nil to remove the key; written together shortly after the
    /// last one so dragging a slider doesn't reload the config for every step.
    private var pending: [String: String?] = [:]
    private var flushWork: DispatchWorkItem?

    private init() {
        path = Ghostty.AllocatedString(ghostty_config_open_path()).string
        load()
    }

    func load() {
        flush()
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let (key, value) = Self.parse(line) else { continue }
            if Self.repeatable.contains(key), values[key] != nil { continue }
            values[key] = value
        }
        self.values = values
    }

    func value(_ key: String) -> String? {
        values[key]
    }

    /// Sets the key, or removes it from the file when `value` is nil so Ghostty's default
    /// (or the theme's) applies again.
    func set(_ key: String, _ value: String?) {
        values[key] = value
        pending[key] = .some(value)
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func openFile() {
        flush()
        (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
    }

    /// A color the current configuration resolves to, e.g. for `background` when the file
    /// leaves it to the theme. Only for the keys whose type is a plain color.
    func effectiveColor(_ key: String) -> Color? {
        guard key == "background" || key == "foreground",
              let config = (NSApp.delegate as? AppDelegate)?.ghostty.config.config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }

    // MARK: Writing

    private func flush() {
        flushWork?.cancel()
        flushWork = nil
        guard !pending.isEmpty else { return }
        let edits = pending
        pending = [:]

        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
            text = Self.apply(key, value, to: text)
        }

        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            error = nil
        } catch {
            self.error = "无法写入配置文件：\(error.localizedDescription)"
            return
        }

        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
    }

    /// Keys that may appear on several lines, each adding to a list.
    private static let repeatable: Set<String> = ["font-family"]

    /// Values that need quoting to keep their spaces or `#`.
    private static let quoted: Set<String> = ["font-family", "theme"]

    static func apply(_ key: String, _ value: String?, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let indices = lines.indices.filter { parse(lines[$0])?.key == key }

        if let value {
            let formatted = quoted.contains(key) ? "\"\(value)\"" : value
            let line = "\(key) = \(formatted)"
            if let first = indices.first {
                lines[first] = line
                for index in indices.dropFirst().reversed() { lines.remove(at: index) }
            } else {
                // Before the trailing empty line a final newline leaves, if any.
                if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines.append(line) }
            }
        } else {
            for index in indices.reversed() { lines.remove(at: index) }
        }

        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// The key and value of a `key = value` line, nil for comments and blank lines.
    static func parse(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    // MARK: Choices

    /// The themes bundled with the app and the user's own, sorted by name.
    static let themes: [String] = {
        var names = Set<String>()
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("ghostty/themes"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".config/ghostty/themes"))
        directories.append(home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/themes"))
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            names.formUnion(files.filter { !$0.hasPrefix(".") })
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    /// The families of the installed fixed-pitch fonts.
    static let monospacedFamilies: [String] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
            .filter { !$0.hasPrefix(".") }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()
}

extension Color {
    /// `#rrggbb` in sRGB, as Ghostty's config writes colors.
    var configHex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /// A color written as `#rrggbb` or `rrggbb`; nil for names and other forms.
    init?(configHex: String) {
        var hex = configHex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
