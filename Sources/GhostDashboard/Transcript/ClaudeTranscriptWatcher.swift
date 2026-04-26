import Darwin
import Foundation

/// Minimal projection of a Claude Code transcript JSONL line. Only the fields
/// the ghost state engine cares about are decoded.
public struct TranscriptEvent: Decodable, Sendable, Equatable {
    public let type: String
    public let timestamp: String
    public let cwd: String?
    public let sessionId: String?
    public let uuid: String?
    public let message: TranscriptMessage?

    public struct TranscriptMessage: Decodable, Sendable, Equatable {
        public let content: [ContentItem]
    }

    public struct ContentItem: Decodable, Sendable, Equatable {
        public let type: String
        public let name: String?
    }

    /// Convenience: every `tool_use.name` carried by `message.content`.
    public var toolUseNames: [String] {
        guard let content = message?.content else { return [] }
        return content.compactMap { item in
            item.type == "tool_use" ? item.name : nil
        }
    }

    /// Parsed timestamp (ISO 8601 with fractional seconds, as Claude Code emits).
    /// Falls back to `Date()` so a malformed timestamp never drops the event.
    public func parsedTimestamp(now: Date = Date()) -> Date {
        ClaudeTranscriptWatcher.iso8601.date(from: timestamp) ?? now
    }
}

/// Watches one project's transcript directory and every `*.jsonl` inside it,
/// streaming parsed `TranscriptEvent`s off-main.
///
/// Threading contract:
///   - All file I/O and JSON parsing run on the watcher's private serial queue.
///   - The `onEvents` callback fires on that same queue.
///   - The directory and file watchers are `DispatchSource.makeFileSystemObjectSource`
///     bound to the same private queue.
///   - Callers are responsible for hopping to main before mutating UI state.
public final class ClaudeTranscriptWatcher: @unchecked Sendable {
    public typealias EventCallback = (_ projectID: String, _ events: [TranscriptEvent]) -> Void

    public let projectID: String
    public let cwd: String
    public let projectDirectoryURL: URL

    private let index: ProjectTranscriptIndex
    private let onEvents: EventCallback
    private let queue: DispatchQueue

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1

    private struct FileWatch {
        var source: DispatchSourceFileSystemObject
        var fd: Int32
        var offset: UInt64
        var leftover: Data
    }

    private var fileWatches: [URL: FileWatch] = [:]
    private var stopped: Bool = false

    /// ISO 8601 with fractional seconds, matches Claude Code's emitter.
    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(
        projectID: String,
        cwd: String,
        index: ProjectTranscriptIndex = ProjectTranscriptIndex(),
        queue: DispatchQueue? = nil,
        onEvents: @escaping EventCallback
    ) {
        self.projectID = projectID
        self.cwd = cwd
        self.index = index
        self.projectDirectoryURL = index.projectDirectoryURL(for: cwd)
        self.queue = queue ?? DispatchQueue(
            label: "cmux.ghost-dashboard.transcript.\(projectID)",
            qos: .utility
        )
        self.onEvents = onEvents
    }

    deinit {
        // deinit is not isolated; cancel synchronously without touching `self`
        // through the queue (no captures needed).
        for (_, watch) in fileWatches {
            watch.source.cancel()
        }
        if let directorySource {
            directorySource.cancel()
        }
    }

    // MARK: - Lifecycle

    /// Begin watching. If `coldStart` is true, existing files are seeked to
    /// EOF and only newly appended bytes drive events (the cold-start AC).
    /// If false, the entire current contents are replayed first.
    public func start(coldStart: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.installDirectoryWatcher()
            self.refreshFileWatches(coldStart: coldStart)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            for (_, watch) in self.fileWatches {
                watch.source.cancel()
            }
            self.fileWatches.removeAll()
            if let src = self.directorySource {
                src.cancel()
                self.directorySource = nil
            }
        }
    }

    // MARK: - Directory watcher

    private func installDirectoryWatcher() {
        dispatchPrecondition(condition: .onQueue(queue))

        // Best-effort: if the directory doesn't exist yet (no Claude Code run
        // for this project), watch the parent `~/.claude/projects/` so we
        // can attach as soon as it appears.
        let path: String
        if FileManager.default.fileExists(atPath: projectDirectoryURL.path) {
            path = projectDirectoryURL.path
        } else {
            path = index.rootDirectoryURL.path
            try? FileManager.default.createDirectory(
                at: index.rootDirectoryURL,
                withIntermediateDirectories: true
            )
        }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .link, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.refreshFileWatches(coldStart: true)
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        source.resume()
        directorySource = source
    }

    /// Scans the project directory and installs a per-file watcher for any
    /// new `.jsonl`. Called on directory writes and from `start()`.
    private func refreshFileWatches(coldStart: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }

        let urls = index.sessionURLs(for: cwd)
        let known = Set(fileWatches.keys)
        let current = Set(urls)

        for url in current.subtracting(known) {
            installFileWatcher(for: url, coldStart: coldStart)
        }
        for url in known.subtracting(current) {
            if var watch = fileWatches.removeValue(forKey: url) {
                watch.source.cancel()
                watch.leftover.removeAll()
            }
        }
    }

    private func installFileWatcher(for url: URL, coldStart: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let initialSize: UInt64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let initialOffset: UInt64 = coldStart ? initialSize : 0

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )

        var watch = FileWatch(source: source, fd: fd, offset: initialOffset, leftover: Data())
        fileWatches[url] = watch

        source.setEventHandler { [weak self, url] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                if var existing = self.fileWatches.removeValue(forKey: url) {
                    existing.source.cancel()
                    existing.leftover.removeAll()
                }
                return
            }
            self.drain(url: url)
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        source.resume()

        // For cold-start we still need to make sure the most recent state is
        // visible — but per the AC we do NOT replay already-consumed bytes.
        // For non-cold-start (replay mode, used by tests/integration), drain
        // the file once now.
        if !coldStart {
            watch.offset = 0
            fileWatches[url] = watch
            drain(url: url)
        }
    }

    /// Reads bytes appended since the last known offset, splits on `\n`,
    /// decodes well-formed JSON lines, and emits a single batch.
    private func drain(url: URL) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var watch = fileWatches[url] else { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: watch.offset)
        } catch {
            // File shrank under us (rotation/rewrite). Re-anchor to start.
            watch.offset = 0
            watch.leftover.removeAll()
            try? handle.seek(toOffset: 0)
        }

        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }

        watch.offset += UInt64(chunk.count)
        watch.leftover.append(chunk)

        var events: [TranscriptEvent] = []
        events.reserveCapacity(8)

        // Iterate complete lines; keep any tail without a newline as leftover.
        var consumed = 0
        var cursor = 0
        let bytes = watch.leftover
        let newline: UInt8 = 0x0A
        while cursor < bytes.count {
            if bytes[cursor] == newline {
                let lineRange = consumed..<cursor
                if let event = decodeLine(bytes.subdata(in: lineRange)) {
                    events.append(event)
                }
                consumed = cursor + 1
            }
            cursor += 1
        }
        if consumed > 0 {
            watch.leftover.removeSubrange(0..<consumed)
        }
        // Cap leftover so a runaway line can't pin unbounded memory.
        if watch.leftover.count > 1_048_576 {
            watch.leftover.removeAll(keepingCapacity: false)
        }
        fileWatches[url] = watch

        if !events.isEmpty {
            onEvents(projectID, events)
        }
    }

    private func decodeLine(_ data: Data) -> TranscriptEvent? {
        // Trim trailing whitespace / \r and require the payload to end with `}`
        // — that's the partial-write guard from the spec.
        var trimmed = data
        while let last = trimmed.last, last == 0x20 || last == 0x0D || last == 0x09 {
            trimmed.removeLast()
        }
        guard trimmed.last == 0x7D /* `}` */ else { return nil }
        guard let first = trimmed.first, first == 0x7B /* `{` */ else { return nil }

        let decoder = JSONDecoder()
        return try? decoder.decode(TranscriptEvent.self, from: trimmed)
    }

    // MARK: - Test seam

    /// Synchronously feed bytes into the watcher's parser without touching
    /// the file system. Used by unit tests.
    public func feedForTesting(url: URL, bytes: Data) {
        queue.sync { [self] in
            if fileWatches[url] == nil {
                let placeholder = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: -1,
                    eventMask: .write,
                    queue: queue
                )
                fileWatches[url] = FileWatch(source: placeholder, fd: -1, offset: 0, leftover: Data())
            }
            guard var watch = fileWatches[url] else { return }
            watch.leftover.append(bytes)

            var events: [TranscriptEvent] = []
            var consumed = 0
            var cursor = 0
            let buf = watch.leftover
            let newline: UInt8 = 0x0A
            while cursor < buf.count {
                if buf[cursor] == newline {
                    if let evt = decodeLine(buf.subdata(in: consumed..<cursor)) {
                        events.append(evt)
                    }
                    consumed = cursor + 1
                }
                cursor += 1
            }
            if consumed > 0 {
                watch.leftover.removeSubrange(0..<consumed)
            }
            fileWatches[url] = watch

            if !events.isEmpty {
                onEvents(projectID, events)
            }
        }
    }
}
