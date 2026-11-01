import Foundation

extension String {
    /// The string as a single shell word, in single quotes unless it only has characters
    /// that need none. Works in POSIX shells and fish.
    var shellQuoted: String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !isEmpty, unicodeScalars.allSatisfy(safe.contains) { return self }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The path with a leading `~` expanded to the home directory.
    var expandingTilde: String { (self as NSString).expandingTildeInPath }

    /// The path with the home directory shown as `~`.
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }
}
