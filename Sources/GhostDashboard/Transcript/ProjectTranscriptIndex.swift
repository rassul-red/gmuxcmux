import Foundation

/// Resolves a workspace cwd to its `~/.claude/projects/<encoded-cwd>/*.jsonl` set.
///
/// Encoding rule (matches the Claude Code on-disk layout):
///   `/Users/jh0927/cmux` → `-Users-jh0927-cmux`
/// (i.e. an absolute path with every `/` replaced by `-`. The leading `/` thus
/// becomes a leading `-`.)
public final class ProjectTranscriptIndex: @unchecked Sendable {
    public init(rootDirectoryURL: URL? = nil) {
        if let rootDirectoryURL {
            self.rootDirectoryURL = rootDirectoryURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.rootDirectoryURL = home
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
    }

    public let rootDirectoryURL: URL

    /// Encodes a cwd to its on-disk directory name.
    /// `/Users/jh0927/cmux` → `-Users-jh0927-cmux`
    public static func encode(cwd: String) -> String {
        let normalized = (cwd as NSString).standardizingPath
        var encoded = ""
        encoded.reserveCapacity(normalized.count)
        for ch in normalized {
            encoded.append(ch == "/" ? "-" : ch)
        }
        return encoded
    }

    /// Round-trips an encoded directory name back to an absolute path.
    /// Used by tests and snapshot bookkeeping; returns nil if the name does
    /// not start with the leading `-` produced by `encode(cwd:)`.
    public static func decode(directoryName: String) -> String? {
        guard directoryName.hasPrefix("-") else { return nil }
        var decoded = ""
        decoded.reserveCapacity(directoryName.count)
        for ch in directoryName {
            decoded.append(ch == "-" ? "/" : ch)
        }
        return decoded
    }

    /// Project-specific transcript directory. May not exist on disk yet.
    public func projectDirectoryURL(for cwd: String) -> URL {
        rootDirectoryURL.appendingPathComponent(Self.encode(cwd: cwd), isDirectory: true)
    }

    /// All `*.jsonl` URLs under `<root>/<encoded-cwd>/`. Returns `[]` if the
    /// directory is missing. Sorted by lastPathComponent for deterministic
    /// iteration (mostly for tests; watchers don't depend on order).
    public func sessionURLs(for cwd: String) -> [URL] {
        let dir = projectDirectoryURL(for: cwd)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
