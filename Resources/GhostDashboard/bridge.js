// cmux Ghost dashboard Swift↔JS bridge (Task #3).
//
// Injected into the dashboard WebView at .atDocumentStart by
// GhostDashboardWebViewHost so window.__ghostBridge is available before any
// dashboard renderer code runs.
//
// Protocol (matches GhostBridgeProtocol.swift):
//   Swift → JS:  window.__ghostBridge.onSnapshot(jsonString)
//                window.__ghostBridge.onDelta(jsonString)
//   JS → Swift:  window.__ghostBridge.sendAction({ action, projectID?, data? })
//
// Every envelope is shaped { v: 1, payload: ... }. Anything with v !== 1 is
// rejected with a console.error and dropped.
(function () {
  if (typeof window === "undefined") return;
  if (window.__ghostBridge && window.__ghostBridge.__cmuxInstalled) return;

  var SNAPSHOT = "ghost.snapshot.v1";
  var DELTA = "ghost.delta.v1";
  var ACTION = "ghost.action.v1";
  var METRICS = "ghost.bridge.metrics";

  var snapshotCount = 0;
  var deltaCount = 0;

  function safeParse(raw) {
    if (typeof raw !== "string") return raw;
    try {
      return JSON.parse(raw);
    } catch (e) {
      console.error("[bridge] JSON parse failed", e);
      return null;
    }
  }

  function postMetric(kind, count) {
    try {
      var handler =
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers[METRICS];
      if (!handler) return;
      handler.postMessage(
        JSON.stringify({ v: 1, kind: kind, count: count })
      );
    } catch (_) {
      // Metrics are best-effort.
    }
  }

  function dispatchTo(name, detail) {
    try {
      window.dispatchEvent(new CustomEvent(name, { detail: detail }));
    } catch (e) {
      console.error("[bridge] dispatch failed", name, e);
    }
  }

  window.__ghostBridge = {
    __cmuxInstalled: true,

    onSnapshot: function (raw) {
      var env = safeParse(raw);
      if (!env || env.v !== 1) {
        console.error(
          "[bridge] unsupported version",
          env && env.v
        );
        return;
      }
      snapshotCount += 1;
      // console.count drives the integration soak counter on the JS side.
      console.count("[bridge] snapshot");
      dispatchTo(SNAPSHOT, env.payload);
      postMetric("snapshot", snapshotCount);
    },

    onDelta: function (raw) {
      var env = safeParse(raw);
      if (!env || env.v !== 1) {
        console.error(
          "[bridge] unsupported version",
          env && env.v
        );
        return;
      }
      deltaCount += 1;
      console.count("[bridge] delta");
      dispatchTo(DELTA, env.payload);
      postMetric("delta", deltaCount);
    },

    sendAction: function (payload) {
      try {
        var handler =
          window.webkit &&
          window.webkit.messageHandlers &&
          window.webkit.messageHandlers[ACTION];
        if (!handler) {
          console.error("[bridge] action handler unavailable");
          return false;
        }
        handler.postMessage(
          JSON.stringify({ v: 1, payload: payload || {} })
        );
        return true;
      } catch (e) {
        console.error("[bridge] sendAction failed", e);
        return false;
      }
    },

    counters: function () {
      return { snapshot: snapshotCount, delta: deltaCount };
    },

    resetCountersForTesting: function () {
      snapshotCount = 0;
      deltaCount = 0;
    },
  };

  // Helpful no-op so the renderer can advertise readiness without crashing if
  // it loads before bridge.js (it shouldn't, but defense in depth).
  if (typeof window.__ghostBridgeReady === "function") {
    try {
      window.__ghostBridgeReady();
    } catch (e) {
      console.error("[bridge] ready hook threw", e);
    }
  }
})();
