import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - ProjectTranscriptIndex

final class ProjectTranscriptIndexTests: XCTestCase {
    func testEncodeMatchesClaudeCodeOnDiskRule() {
        XCTAssertEqual(
            ProjectTranscriptIndex.encode(cwd: "/Users/jh0927/cmux"),
            "-Users-jh0927-cmux"
        )
        XCTAssertEqual(
            ProjectTranscriptIndex.encode(cwd: "/Users/jh0927/sessions/gmux-t2/repo"),
            "-Users-jh0927-sessions-gmux-t2-repo"
        )
    }

    func testEncodeRoundTrip() {
        let original = "/Users/jh0927/Code Projects/sub"
        let encoded = ProjectTranscriptIndex.encode(cwd: original)
        let decoded = ProjectTranscriptIndex.decode(directoryName: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testSessionURLsReturnsEmptyWhenDirectoryAbsent() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghost-index-missing-\(UUID().uuidString)", isDirectory: true)
        let index = ProjectTranscriptIndex(rootDirectoryURL: temp)
        XCTAssertEqual(index.sessionURLs(for: "/Users/whoever/no-such-cwd"), [])
    }

    func testSessionURLsListsJsonlFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghost-index-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/Users/test/cmux-fixture"
        let projectDir = root.appendingPathComponent(
            ProjectTranscriptIndex.encode(cwd: cwd),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let aURL = projectDir.appendingPathComponent("a.jsonl")
        let bURL = projectDir.appendingPathComponent("b.jsonl")
        let txtURL = projectDir.appendingPathComponent("ignored.txt")
        try Data().write(to: aURL)
        try Data().write(to: bURL)
        try Data().write(to: txtURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let index = ProjectTranscriptIndex(rootDirectoryURL: root)
        let urls = index.sessionURLs(for: cwd)
        let names = Set(urls.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["a.jsonl", "b.jsonl"])
    }
}

// MARK: - GhostStateMachine

final class GhostStateMachineTests: XCTestCase {
    func testMapToolNameTable() {
        XCTAssertEqual(GhostStateMachine.mapToolName("Read"), .Reading)
        XCTAssertEqual(GhostStateMachine.mapToolName("Glob"), .Reading)
        XCTAssertEqual(GhostStateMachine.mapToolName("Grep"), .Reading)
        XCTAssertEqual(GhostStateMachine.mapToolName("Edit"), .Coding)
        XCTAssertEqual(GhostStateMachine.mapToolName("Write"), .Coding)
        XCTAssertEqual(GhostStateMachine.mapToolName("Bash"), .Checking)
        XCTAssertEqual(GhostStateMachine.mapToolName("WebFetch"), .Reviewing)
        XCTAssertEqual(GhostStateMachine.mapToolName("WebSearch"), .Reviewing)
        XCTAssertEqual(GhostStateMachine.mapToolName("Task"), .Monitoring)
        XCTAssertEqual(GhostStateMachine.mapToolName("Skill"), .Reviewing)
        XCTAssertEqual(GhostStateMachine.mapToolName("mcp__github__list_prs"), .Monitoring)
        XCTAssertEqual(GhostStateMachine.mapToolName("Anything"), .Coding)
    }

    func testApplyRecordsLastState() {
        var sm = GhostStateMachine()
        let now = Date()
        sm.apply(toolName: "Read", at: now)
        XCTAssertEqual(sm.rawState, .Reading)
        XCTAssertEqual(sm.currentState(now: now), .Reading)
    }

    func testCollapsesToIdleAfterThreshold() {
        var sm = GhostStateMachine()
        let stale = Date(timeIntervalSinceNow: -61)
        sm.apply(toolName: "Edit", at: stale)
        XCTAssertEqual(sm.currentState(now: Date()), .Idle)
    }

    func testStaysActiveJustBelowThreshold() {
        var sm = GhostStateMachine()
        let recent = Date(timeIntervalSinceNow: -30)
        sm.apply(toolName: "Edit", at: recent)
        XCTAssertEqual(sm.currentState(now: Date()), .Coding)
    }
}

// MARK: - ClaudeTranscriptWatcher (parser)

final class ClaudeTranscriptParserTests: XCTestCase {
    private func makeWatcher(
        onEvents: @escaping (String, [TranscriptEvent]) -> Void
    ) -> ClaudeTranscriptWatcher {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghost-watch-\(UUID().uuidString)", isDirectory: true)
        let index = ProjectTranscriptIndex(rootDirectoryURL: temp)
        return ClaudeTranscriptWatcher(
            projectID: "p1",
            cwd: "/Users/test/x",
            index: index,
            onEvents: onEvents
        )
    }

    func testPartialLineSuppressedThenEmittedAfterCompletion() {
        var batches: [[TranscriptEvent]] = []
        let watcher = makeWatcher { _, evts in batches.append(evts) }
        let url = URL(fileURLWithPath: "/tmp/ghost-test-fixture.jsonl")

        // Truncated mid-line — must produce zero events.
        let partial = #"{"type":"assistant","timestamp":"2026-04-26T10:00:00.000Z","message":{"content":[{"type":"tool"#
        watcher.feedForTesting(url: url, bytes: Data(partial.utf8))
        XCTAssertTrue(batches.isEmpty, "Truncated line must not emit events")

        // Append the rest of that JSON line followed by a newline.
        let rest = #"_use","name":"Read"}]}}"# + "\n"
        watcher.feedForTesting(url: url, bytes: Data(rest.utf8))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 1)
        XCTAssertEqual(batches.first?.first?.toolUseNames, ["Read"])
    }

    func testIgnoresLineWithoutClosingBrace() {
        var batches: [[TranscriptEvent]] = []
        let watcher = makeWatcher { _, evts in batches.append(evts) }
        let url = URL(fileURLWithPath: "/tmp/ghost-test-fixture-2.jsonl")
        // Garbage line that doesn't end with `}` — guarded out.
        watcher.feedForTesting(url: url, bytes: Data("not-json-at-all\n".utf8))
        XCTAssertTrue(batches.isEmpty)
    }

    func testTrimsTrailingWhitespaceBeforeBraceCheck() {
        var batches: [[TranscriptEvent]] = []
        let watcher = makeWatcher { _, evts in batches.append(evts) }
        let url = URL(fileURLWithPath: "/tmp/ghost-test-fixture-3.jsonl")
        let line = #"{"type":"assistant","timestamp":"2026-04-26T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash"}]}}  "# + "\n"
        watcher.feedForTesting(url: url, bytes: Data(line.utf8))
        XCTAssertEqual(batches.first?.first?.toolUseNames, ["Bash"])
    }
}

// MARK: - GhostRosterManager

final class GhostRosterManagerTests: XCTestCase {
    func testRosterUpdatesViaIngestForTesting() {
        let manager = GhostRosterManager()
        manager.register(projectID: "p1", cwd: "/Users/test/no-such-cwd")
        // register is async on stateQueue; ingestForTesting is sync, so wait
        // briefly for the registration to install the project context.
        let registered = expectation(description: "registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { registered.fulfill() }
        wait(for: [registered], timeout: 1.0)

        let event = TranscriptEvent(
            type: "assistant",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            cwd: "/Users/test/no-such-cwd",
            sessionId: "session-A",
            uuid: nil,
            message: TranscriptEvent.TranscriptMessage(content: [
                TranscriptEvent.ContentItem(type: "tool_use", name: "Edit"),
            ])
        )
        manager.ingestForTesting(projectID: "p1", events: [event])

        let committed = expectation(description: "main hop")
        DispatchQueue.main.async { committed.fulfill() }
        wait(for: [committed], timeout: 1.0)

        let snapshot = manager.roster["p1"]
        XCTAssertEqual(snapshot?.ghosts.count, 1)
        XCTAssertEqual(snapshot?.ghosts.first?.state, .Coding)
        XCTAssertEqual(snapshot?.ghosts.first?.label, "Edit")
    }

    func testRosterCapsAtFiveGhosts() {
        let manager = GhostRosterManager()
        manager.register(projectID: "p2", cwd: "/Users/test/no-such-cwd-2")
        let registered = expectation(description: "registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { registered.fulfill() }
        wait(for: [registered], timeout: 1.0)

        let now = ISO8601DateFormatter().string(from: Date())
        let events: [TranscriptEvent] = (0..<8).map { i in
            TranscriptEvent(
                type: "assistant",
                timestamp: now,
                cwd: "/Users/test/no-such-cwd-2",
                sessionId: "session-\(i)",
                uuid: nil,
                message: TranscriptEvent.TranscriptMessage(content: [
                    TranscriptEvent.ContentItem(type: "tool_use", name: "Read"),
                ])
            )
        }
        manager.ingestForTesting(projectID: "p2", events: events)

        let committed = expectation(description: "main hop")
        DispatchQueue.main.async { committed.fulfill() }
        wait(for: [committed], timeout: 1.0)

        XCTAssertEqual(manager.roster["p2"]?.ghosts.count, 5)
    }

    func testIdleSweepCollapsesStaleGhostWithoutNewEvents() {
        let manager = GhostRosterManager()
        manager.register(projectID: "p3", cwd: "/Users/test/no-such-cwd-3")
        let registered = expectation(description: "registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { registered.fulfill() }
        wait(for: [registered], timeout: 1.0)

        let activeAt = Date()
        let event = TranscriptEvent(
            type: "assistant",
            timestamp: ISO8601DateFormatter().string(from: activeAt),
            cwd: "/Users/test/no-such-cwd-3",
            sessionId: "session-X",
            uuid: nil,
            message: TranscriptEvent.TranscriptMessage(content: [
                TranscriptEvent.ContentItem(type: "tool_use", name: "Bash"),
            ])
        )
        manager.ingestForTesting(projectID: "p3", events: [event])

        let firstHop = expectation(description: "first main hop")
        DispatchQueue.main.async { firstHop.fulfill() }
        wait(for: [firstHop], timeout: 1.0)
        XCTAssertEqual(manager.roster["p3"]?.ghosts.first?.state, .Checking)

        // No further tool_use events. Sweep at +120s — well past the 60s
        // idle threshold — and assert the ghost flips to .Idle even though
        // the watcher never delivered another callback.
        manager.refreshIdleStatesForTesting(now: activeAt.addingTimeInterval(120))

        let idleHop = expectation(description: "idle main hop")
        DispatchQueue.main.async { idleHop.fulfill() }
        wait(for: [idleHop], timeout: 1.0)
        XCTAssertEqual(manager.roster["p3"]?.ghosts.first?.state, .Idle)
    }
}

// MARK: - Issue #17: agent-launch detection + table assignment

final class GhostMotionTests: XCTestCase {
    /// First `tool_use` lifts the session out of the initial Idle state.
    /// That transition is the "agent launched in this terminal tab" signal.
    func testApplyReportsLaunchOnFirstActivation() {
        var sm = GhostStateMachine()
        let result = sm.apply(toolName: "Edit", at: Date())
        XCTAssertEqual(result.state, .Coding)
        XCTAssertTrue(result.didLaunch, "Initial Idle → Coding must report didLaunch")
    }

    /// Once the agent is active, subsequent tool_use events do NOT re-fire
    /// the launch signal — otherwise the ghost would re-walk to its desk on
    /// every keystroke.
    func testApplyDoesNotReportLaunchWhileAlreadyActive() {
        var sm = GhostStateMachine()
        let t0 = Date()
        _ = sm.apply(toolName: "Edit", at: t0)
        let result = sm.apply(toolName: "Bash", at: t0.addingTimeInterval(1))
        XCTAssertEqual(result.state, .Checking)
        XCTAssertFalse(result.didLaunch, "Active → Active is not a launch")
    }

    /// After 60 seconds of inactivity the state machine collapses to Idle.
    /// The next tool_use therefore counts as a fresh launch and the ghost
    /// walks back to its (sticky) desk.
    func testApplyReportsLaunchAfterIdleCollapse() {
        var sm = GhostStateMachine()
        let t0 = Date()
        _ = sm.apply(toolName: "Edit", at: t0)
        // Past the 60s idle threshold.
        let t1 = t0.addingTimeInterval(120)
        let result = sm.apply(toolName: "Read", at: t1)
        XCTAssertTrue(result.didLaunch, "Idle (collapsed) → Reading must re-fire didLaunch")
    }

    /// Roster manager assigns a deterministic seat (lowest free index) on
    /// the first tool_use for a session, then renders motion = walking.
    func testRosterAssignsTableOnFirstToolUse() {
        let manager = GhostRosterManager()
        manager.register(projectID: "p-motion", cwd: "/Users/test/no-such-cwd-motion")
        let registered = expectation(description: "registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { registered.fulfill() }
        wait(for: [registered], timeout: 1.0)

        let event = TranscriptEvent(
            type: "assistant",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            cwd: "/Users/test/no-such-cwd-motion",
            sessionId: "session-launch-1",
            uuid: nil,
            message: TranscriptEvent.TranscriptMessage(content: [
                TranscriptEvent.ContentItem(type: "tool_use", name: "Edit"),
            ])
        )
        manager.ingestForTesting(projectID: "p-motion", events: [event])

        let hop = expectation(description: "main hop")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 1.0)

        let ghost = manager.roster["p-motion"]?.ghosts.first
        XCTAssertNotNil(ghost)
        XCTAssertEqual(ghost?.tableID, 0, "First launched ghost gets seat #0")
        XCTAssertEqual(ghost?.motion, .walking, "Just-launched ghost is walking to its desk")
        XCTAssertNotNil(ghost?.motionStartedAt, "Motion clock must start on launch")
    }

    /// Two distinct sessions launching in the same project occupy seats
    /// 0 and 1 — the lowest-free-index policy guarantees no collision.
    func testRosterAssignsDistinctTablesPerSession() {
        let manager = GhostRosterManager()
        manager.register(projectID: "p-motion-2", cwd: "/Users/test/no-such-cwd-motion-2")
        let registered = expectation(description: "registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { registered.fulfill() }
        wait(for: [registered], timeout: 1.0)

        let now = ISO8601DateFormatter().string(from: Date())
        let events: [TranscriptEvent] = ["session-A", "session-B"].map { sid in
            TranscriptEvent(
                type: "assistant",
                timestamp: now,
                cwd: "/Users/test/no-such-cwd-motion-2",
                sessionId: sid,
                uuid: nil,
                message: TranscriptEvent.TranscriptMessage(content: [
                    TranscriptEvent.ContentItem(type: "tool_use", name: "Read"),
                ])
            )
        }
        manager.ingestForTesting(projectID: "p-motion-2", events: events)

        let hop = expectation(description: "main hop")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 1.0)

        let seats = manager.roster["p-motion-2"]?.ghosts.compactMap { $0.tableID } ?? []
        XCTAssertEqual(Set(seats), Set([0, 1]), "Distinct sessions take distinct seats")
        XCTAssertEqual(seats.count, 2, "Both ghosts have a seat (no nils)")
    }

    /// Ghost without a launch-derived seat (initial registration with no
    /// activity) renders as `spawning`, not `walking`. We don't have a
    /// pre-launch entry in the public model today, but verify the derivation
    /// rule by checking the post-collapse pathway: idle → wandering, seat
    /// stays sticky.
    func testIdleCollapseFlipsMotionToWanderingButKeepsTable() {
        let manager = GhostRosterManager()
        manager.register(projectID: "p-motion-3", cwd: "/Users/test/no-such-cwd-motion-3")
        let registered = expectation(description: "registered")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { registered.fulfill() }
        wait(for: [registered], timeout: 1.0)

        let activeAt = Date()
        let event = TranscriptEvent(
            type: "assistant",
            timestamp: ISO8601DateFormatter().string(from: activeAt),
            cwd: "/Users/test/no-such-cwd-motion-3",
            sessionId: "session-collapse",
            uuid: nil,
            message: TranscriptEvent.TranscriptMessage(content: [
                TranscriptEvent.ContentItem(type: "tool_use", name: "Bash"),
            ])
        )
        manager.ingestForTesting(projectID: "p-motion-3", events: [event])

        let firstHop = expectation(description: "first main hop")
        DispatchQueue.main.async { firstHop.fulfill() }
        wait(for: [firstHop], timeout: 1.0)
        XCTAssertEqual(manager.roster["p-motion-3"]?.ghosts.first?.tableID, 0)

        // Sweep idle past the 60s threshold.
        manager.refreshIdleStatesForTesting(now: activeAt.addingTimeInterval(120))
        let idleHop = expectation(description: "idle main hop")
        DispatchQueue.main.async { idleHop.fulfill() }
        wait(for: [idleHop], timeout: 1.0)

        let collapsed = manager.roster["p-motion-3"]?.ghosts.first
        XCTAssertEqual(collapsed?.state, .Idle)
        XCTAssertEqual(collapsed?.motion, .wandering, "Idle ghost wanders again")
        XCTAssertEqual(collapsed?.tableID, 0, "Seat is sticky across idle collapse")
    }
}

// MARK: - Issue #17: bridge protocol round-trip + backward compat

final class GhostMotionBridgeProtocolTests: XCTestCase {
    func testEntryStateRoundTripsMotionFields() throws {
        let entry = GhostEntryState(
            ghostID: "specter-1",
            state: "Coding",
            label: "Edit",
            motion: "walking",
            tableID: 2,
            motionStartedAt: "2026-04-26T12:00:00.000Z"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(GhostEntryState.self, from: data)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.motion, "walking")
        XCTAssertEqual(decoded.tableID, 2)
        XCTAssertEqual(decoded.motionStartedAt, "2026-04-26T12:00:00.000Z")
    }

    /// Backward compat: pre-#17 JSON has no motion/tableID/motionStartedAt
    /// keys. Decoding must succeed and leave the new fields nil so older
    /// snapshot fixtures keep working and snapshot consumers that haven't
    /// been updated still get a complete payload.
    func testEntryStateDecodesWithoutMotionFields() throws {
        let json = #"{"ghostID":"g-1","label":"Edit","state":"Coding"}"#
        let decoded = try JSONDecoder().decode(
            GhostEntryState.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.ghostID, "g-1")
        XCTAssertEqual(decoded.state, "Coding")
        XCTAssertEqual(decoded.label, "Edit")
        XCTAssertNil(decoded.motion)
        XCTAssertNil(decoded.tableID)
        XCTAssertNil(decoded.motionStartedAt)
    }
}

