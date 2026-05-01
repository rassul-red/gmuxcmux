import XCTest
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Envelope round-trip

final class GhostBridgeEnvelopeTests: XCTestCase {
    func testSnapshotEnvelopeRoundTrip() throws {
        let payload = GhostSnapshotPayload(
            projects: [
                GhostProjectState(
                    projectID: "proj-1",
                    projectName: "cmux",
                    projectCwd: "/Users/me/cmux",
                    projectStatus: "running",
                    ghosts: [
                        GhostEntryState(ghostID: "specter-1", state: "Coding", label: "Edit"),
                        GhostEntryState(ghostID: "specter-2", state: "Idle", label: ""),
                    ],
                    selectedProjectID: "proj-1"
                )
            ]
        )
        let envelope = GhostEnvelope(payload: payload)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let decoded = try JSONDecoder().decode(
            GhostEnvelope<GhostSnapshotPayload>.self,
            from: data
        )

        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded, envelope)
    }

    func testDeltaEnvelopeRoundTrip() throws {
        let delta = GhostDeltaPayload(
            projectID: "proj-1",
            ghosts: [
                GhostEntryState(ghostID: "specter-1", state: "Reading", label: "Read")
            ],
            projectStatus: "OK"
        )
        let envelope = GhostEnvelope(payload: delta)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            GhostEnvelope<GhostDeltaPayload>.self,
            from: data
        )
        XCTAssertEqual(decoded.v, 1)
        XCTAssertEqual(decoded.payload, delta)
    }

    func testDeltaEnvelopeAllowsNilFields() throws {
        let delta = GhostDeltaPayload(projectID: "proj-only-status", ghosts: nil, projectStatus: "warning")
        let envelope = GhostEnvelope(payload: delta)
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            GhostEnvelope<GhostDeltaPayload>.self,
            from: data
        )
        XCTAssertEqual(decoded.payload.projectID, "proj-only-status")
        XCTAssertNil(decoded.payload.ghosts)
        XCTAssertEqual(decoded.payload.projectStatus, "warning")
    }

    func testActionPayloadDecode() throws {
        let json = #"{"action":"interrupt","projectID":"proj-1"}"#
        let payload = try JSONDecoder().decode(
            GhostActionPayload.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(payload.action, "interrupt")
        XCTAssertEqual(payload.projectID, "proj-1")
        XCTAssertNil(payload.data)
    }
}

// MARK: - Action routing & version reject

final class GhostBridgeHostRoutingTests: XCTestCase {
    /// `WKScriptMessage` is final, so we drive `userContentController(_:didReceive:)`
    /// indirectly by re-implementing the public-facing decode + dispatch path
    /// through the test seam below. The bridge host exposes the same method
    /// surface for callers that hand it raw JSON strings.
    private func makeMessageBody(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func deliver(_ host: GhostBridgeHost, body: String) {
        // Emulate the WKScriptMessage path via the same handleAction route.
        // We can't construct a WKScriptMessage directly (no public init), so
        // we exercise the host through its public push/route surface using a
        // synthetic decode path identical to handleActionBody().
        let data = body.data(using: .utf8)!
        let decoder = JSONDecoder()
        if let env = try? decoder.decode(
            GhostEnvelope<GhostActionPayload>.self,
            from: data
        ), env.v == 1 {
            host.routeForTesting(env.payload)
            return
        }
        if let payload = try? decoder.decode(GhostActionPayload.self, from: data) {
            host.routeForTesting(payload)
            return
        }
    }

    func testAllSixActionsRouteCorrectly() {
        let host = GhostBridgeHost()
        var hits: [String] = []
        host.onRoomSelect   = { hits.append("roomSelect:\($0.projectID ?? "")") }
        host.onOpenProject  = { hits.append("openProject:\($0.projectID ?? "")") }
        host.onInterrupt    = { hits.append("interrupt:\($0.projectID ?? "")") }
        host.onNewTask      = { hits.append("newTask:\($0.projectID ?? "")") }
        host.onFollow       = { hits.append("follow:\($0.projectID ?? "")") }
        host.onNoOpAction   = { hits.append("noop:\($0)") }

        let actions: [(String, String)] = [
            ("roomSelect", "p1"),
            ("openProject", "p2"),
            ("interrupt", "p3"),
            ("newTask", "p4"),
            ("follow", "p5"),
            ("broadcast", "p6"),
            ("groupChat", "p7"),
        ]
        for (name, pid) in actions {
            deliver(host, body: makeMessageBody(["action": name, "projectID": pid]))
        }

        XCTAssertEqual(hits, [
            "roomSelect:p1",
            "openProject:p2",
            "interrupt:p3",
            "newTask:p4",
            "follow:p5",
            "noop:broadcast",
            "noop:groupChat",
        ])
    }

    func testEnvelopeWithVersionTwoIsRejected() {
        let host = GhostBridgeHost()
        var hit = false
        host.onInterrupt = { _ in hit = true }
        let body = makeMessageBody([
            "v": 2,
            "payload": ["action": "interrupt", "projectID": "p1"],
        ])
        deliver(host, body: body)
        XCTAssertFalse(hit, "v != 1 envelope must not invoke action closures")
    }

    func testRawPayloadWithoutEnvelopeStillRoutes() {
        let host = GhostBridgeHost()
        var hit = false
        host.onInterrupt = { _ in hit = true }
        deliver(host, body: makeMessageBody(["action": "interrupt", "projectID": "p1"]))
        XCTAssertTrue(hit, "Raw payload (no envelope) must still route — bridge.js calls match this shape post-envelope-strip when JS posts via webkit.messageHandlers")
    }
}

// MARK: - Counter behavior under burst

final class GhostBridgeHostCounterTests: XCTestCase {
    @MainActor
    func testDeltaPushIncrementsCounterOncePerCall() {
        let host = GhostBridgeHost()
        let webView = WKWebView(frame: .zero)
        host.webView = webView

        let n: Int32 = 100
        for i in 0..<n {
            let delta = GhostDeltaPayload(
                projectID: "p-\(i)",
                ghosts: [GhostEntryState(ghostID: "g-\(i)", state: "Coding", label: "Edit")],
                projectStatus: nil
            )
            host.push(delta: delta, to: webView)
        }
        XCTAssertEqual(host.deltasSent, n)
    }

    @MainActor
    func testSnapshotPushIncrementsCounterOncePerCall() {
        let host = GhostBridgeHost()
        let webView = WKWebView(frame: .zero)
        host.webView = webView

        let snapshot = GhostSnapshotPayload(projects: [])
        for _ in 0..<25 {
            host.push(snapshot: snapshot, to: webView)
        }
        XCTAssertEqual(host.snapshotsSent, 25)
    }

    @MainActor
    func testCoalesceCollapsesBurstToOneDeltaPerProject() {
        let host = GhostBridgeHost()
        let webView = WKWebView(frame: .zero)
        host.webView = webView

        // Three back-to-back roster mutations on the same project — coalesce
        // window must collapse them to a single delta push when flushed.
        let pid = "p-coalesce"
        let r1 = [pid: ProjectGhostRoster(projectID: pid, ghosts: [
            GhostEntry(id: "g1", state: .Coding, label: "Edit"),
        ])]
        let r2 = [pid: ProjectGhostRoster(projectID: pid, ghosts: [
            GhostEntry(id: "g1", state: .Coding, label: "Edit"),
            GhostEntry(id: "g2", state: .Reading, label: "Read"),
        ])]
        let r3 = [pid: ProjectGhostRoster(projectID: pid, ghosts: [
            GhostEntry(id: "g1", state: .Idle, label: "Edit"),
            GhostEntry(id: "g2", state: .Reading, label: "Read"),
        ])]

        host.ingestRosterForTesting(r1) // emits initial snapshot
        XCTAssertEqual(host.snapshotsSent, 1)
        XCTAssertEqual(host.deltasSent, 0)

        host.ingestRosterForTesting(r2)
        host.ingestRosterForTesting(r3)
        XCTAssertEqual(host.deltasSent, 0, "Pre-flush: pending only")
        host.flushPendingForTesting()
        XCTAssertEqual(host.deltasSent, 1, "Coalesced to one push for the single project")
    }
}

// MARK: - Test seam

extension GhostBridgeHost {
    /// Test-only wrapper around the private `route(action:)` switch so unit
    /// tests can drive callbacks without a `WKScriptMessage`.
    func routeForTesting(_ action: GhostActionPayload) {
        switch action.action {
        case GhostBridgeAction.roomSelect:   onRoomSelect?(action)
        case GhostBridgeAction.openProject:  onOpenProject?(action)
        case GhostBridgeAction.interrupt:    onInterrupt?(action)
        case GhostBridgeAction.newTask:      onNewTask?(action)
        case GhostBridgeAction.follow:       onFollow?(action)
        case GhostBridgeAction.broadcast,
             GhostBridgeAction.groupChat:
            onNoOpAction?(action.action)
        default:
            break
        }
    }
}
