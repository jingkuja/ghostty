import Foundation

/// Where a remote shell is, as read from the terminal title many shells set at each prompt:
/// `user@host: ~/dir`. Debian and Ubuntu's default bashrc, RHEL, CentOS and Fedora's
/// /etc/bashrc, and oh-my-zsh all set it, for TERM=xterm* (which Ghostty's is).
struct ShellTitle: Equatable {
    let user: String
    let host: String
    /// As shown: absolute, or starting with `~` for the user's home
    let path: String

    /// `user@host:path` or `user@host: path`, optionally after Debian's `(chroot)` prefix.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(?:\([^)]*\)\s*)?([A-Za-z0-9._][A-Za-z0-9._-]*)@([A-Za-z0-9][A-Za-z0-9._-]*):\s*(~|~/.*|/.*)$"#)

    static func parse(_ title: String) -> ShellTitle? {
        let title = title.trimmingCharacters(in: .whitespaces)
        let range = NSRange(title.startIndex..., in: title)
        guard let match = pattern.firstMatch(in: title, range: range),
              let user = Range(match.range(at: 1), in: title),
              let host = Range(match.range(at: 2), in: title),
              let path = Range(match.range(at: 3), in: title) else { return nil }
        return ShellTitle(
            user: String(title[user]),
            host: String(title[host]),
            path: String(title[path]).trimmingCharacters(in: .whitespaces))
    }

    /// The absolute path, given the logged in user and their home directory, or nil if the
    /// title doesn't say exactly where (a shortened path, or another user's `~`).
    func absolutePath(loginUser: String?, home: String?) -> String? {
        // bash's PROMPT_DIRTRIM and similar shorten the middle of the path.
        guard !path.contains("/.../") && !path.hasPrefix(".../") else { return nil }
        guard path.hasPrefix("~") else { return path }

        let homeDirectory: String
        if user == loginUser, let home {
            homeDirectory = home
        } else if user == "root" {
            homeDirectory = "/root"
        } else {
            return nil
        }
        if path == "~" { return homeDirectory }
        return FileEntry.join(homeDirectory, String(path.dropFirst(2)))
    }

    /// Whether the title's host, a short host name as shells show it, is the host
    /// `hostname` (as `uname -n` gives it) names.
    func isHost(_ hostname: String) -> Bool {
        let title = host.lowercased()
        let name = hostname.lowercased()
        return title == name
            || title == name.split(separator: ".").first.map(String.init)
            || name == title.split(separator: ".").first.map(String.init)
    }
}
