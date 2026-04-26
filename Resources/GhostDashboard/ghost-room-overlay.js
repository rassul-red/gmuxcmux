// cmux Ghost dashboard demo seeder + legacy overlay (issue #17).
//
// Two responsibilities, in priority order:
//
//   1. **Demo seeder** — when the dashboard mounts and no real Swift→JS
//      bridge snapshot has arrived after a short grace period, dispatch
//      synthetic `ghost.snapshot.v1` / `ghost.delta.v1` CustomEvents that
//      populate the four rooms with cute ghosts walking, sitting, and
//      cycling between Idle/Coding/Reading/Checking. dashboard.js renders
//      them with the existing isometric office sprites — no extra layer.
//
//   2. **Legacy SVG overlay** — fixed-position SVG figures with their own
//      wander/walk/settle animation, used when no native renderer is
//      present (e.g. the original bundled index.html, or a stripped-down
//      embedding). Auto-disables itself when dashboard.js is detected so
//      the two don't double-render the same room.
//
// Both live in this single file so the WebView host injects only one
// user script and the demo path stays simple to reason about.
(function () {
  if (typeof window === "undefined") return;
  if (window.__ghostRoomOverlayInstalled) return;
  window.__ghostRoomOverlayInstalled = true;

  // ---------- shared state ----------------------------------------------
  var SNAPSHOT_EVENT = "ghost.snapshot.v1";
  var DELTA_EVENT = "ghost.delta.v1";

  // Real Swift→JS snapshots increment `__ghostBridge.counters().snapshot`
  // because they go through `window.__ghostBridge.onSnapshot`. Synthetic
  // events dispatched directly via `window.dispatchEvent(new CustomEvent...)`
  // do NOT touch that counter, so we can still tell real data from demo
  // data even after the demo starts emitting.
  function bridgeSnapshotCount() {
    try {
      var c = window.__ghostBridge && window.__ghostBridge.counters
        ? window.__ghostBridge.counters()
        : null;
      return c && typeof c.snapshot === "number" ? c.snapshot : 0;
    } catch (_) {
      return 0;
    }
  }

  function dispatchSnapshot(payload) {
    try {
      window.dispatchEvent(new CustomEvent(SNAPSHOT_EVENT, { detail: payload }));
    } catch (e) { /* ignore */ }
  }
  function dispatchDelta(payload) {
    try {
      window.dispatchEvent(new CustomEvent(DELTA_EVENT, { detail: payload }));
    } catch (e) { /* ignore */ }
  }

  // ===================================================================
  //                            DEMO SEEDER
  // ===================================================================
  //
  // Demo data: four cute throwaway projects (`web`/`api`/`infra`/`docs`),
  // each with 3 ghosts cycling through states. The room renderer maps:
  //
  //   Idle   → wander (free roam in the tile)
  //   Coding → seated (Builder/Debugger/Orchestrator/Reviewer pose)
  //   Reading→ seated (different sprite per role)
  //   Checking→ seated (Bash bucket)
  //
  // Cycling between Idle and active states every few seconds gives
  // visible "walking to desk" → "seated" → "got up and wandered" beats.

  var DEMO_PROJECTS = [
    { projectID: "demo-web",   projectName: "web",   projectCwd: "/tmp/gmux-demo/web",   projectStatus: "running" },
    { projectID: "demo-api",   projectName: "api",   projectCwd: "/tmp/gmux-demo/api",   projectStatus: "running" },
    { projectID: "demo-infra", projectName: "infra", projectCwd: "/tmp/gmux-demo/infra", projectStatus: "running" },
    { projectID: "demo-docs",  projectName: "docs",  projectCwd: "/tmp/gmux-demo/docs",  projectStatus: "running" },
  ];

  // Per-project ghost roster. Each ghost: [suffix, startState, label].
  // After the new "1 ghost per workspace + free wanderer" model, each demo
  // project shows N assigned ghosts (one per simulated terminal instance) and
  // dashboard.js will render them as seated. The free wandering ghost is
  // appended below so the demo always shows the "waiting for next task"
  // ghost roaming around.
  var DEMO_ROSTER = {
    "demo-web":   [["alpha", "Coding",    "Edit"],     ["beta",  "Reading",   "Read"]],
    "demo-api":   [["alpha", "Reading",   "Read"],     ["beta",  "Coding",    "Edit"]],
    "demo-infra": [["alpha", "Checking",  "Bash"]],
    "demo-docs":  [["alpha", "Reading",   "Glob"],     ["beta",  "Reviewing", "WebFetch"]],
  };

  // Synthetic free-ghost id matches the Swift constant
  // `GhostRosterManager.freeGhostSuffix` so JS and Swift agree on the shape.
  var FREE_GHOST_SUFFIX = "__free__";

  // Active states the demo rotates through. Idle is added separately so
  // wander beats are common enough to be visible.
  var ACTIVE_POOL = ["Coding", "Reading", "Checking", "Reviewing", "Monitoring"];
  var LABEL_POOL = {
    Coding: ["Edit", "Write"],
    Reading: ["Read", "Glob", "Grep"],
    Checking: ["Bash"],
    Reviewing: ["WebFetch", "WebSearch", "Skill"],
    Monitoring: ["Task"],
  };

  function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }
  function nowIso() { return new Date().toISOString(); }

  function buildAssignedEntry(suffix, projectID, state, label, tableID) {
    return {
      ghostID: projectID + "#" + suffix,
      state: state,
      label: label,
      lastActivityAt: state === "Idle" ? null : Date.now(),
      lifecycle: state === "Idle" ? "idle" : "working",
      motion: (Math.random() < 0.3) ? "walking" : "settled",
      tableID: tableID,
      motionStartedAt: nowIso(),
    };
  }

  function buildFreeEntry(projectID) {
    return {
      ghostID: projectID + "#" + FREE_GHOST_SUFFIX,
      state: "Idle",
      label: "",
      lastActivityAt: null,
      lifecycle: "idle",
      motion: "wandering",
      tableID: null,
      motionStartedAt: null,
    };
  }

  function buildDemoSnapshot() {
    var projects = DEMO_PROJECTS.map(function (p) {
      var roster = DEMO_ROSTER[p.projectID] || [];
      var ghosts = roster.map(function (entry, idx) {
        return buildAssignedEntry(entry[0], p.projectID, entry[1], entry[2] || "", idx);
      });
      // Append the per-workspace free wandering ghost. The Swift roster
      // omits it once all 4 desks are assigned; the demo uses ≤ 2 assigned
      // ghosts so the free ghost is always present.
      ghosts.push(buildFreeEntry(p.projectID));
      return {
        projectID: p.projectID,
        projectName: p.projectName,
        projectCwd: p.projectCwd,
        projectStatus: p.projectStatus,
        ghosts: ghosts,
        selectedProjectID: null,
      };
    });
    return { projects: projects };
  }

  // Mutable demo state — drives the rotation deltas.
  var demoState = null;
  var demoTimer = 0;
  var demoStarted = false;

  function rotateOne() {
    if (!demoState) return;
    // Pick a random project then a random *assigned* ghost (those with a
    // tableID — the free wanderer is never rotated; it just keeps roaming).
    var project = pick(demoState.projects);
    if (!project || !project.ghosts || !project.ghosts.length) return;
    var assigned = project.ghosts.filter(function (g) {
      return g.tableID !== null && g.tableID !== undefined;
    });
    if (!assigned.length) return;
    var ghost = pick(assigned);

    if (ghost.state === "Idle") {
      // Wake back up at the desk: pick a new active state. The ghost stays
      // seated the whole time (assigned ghosts never get up under the new
      // "1 ghost per terminal instance" model).
      var newState = pick(ACTIVE_POOL);
      var labels = LABEL_POOL[newState] || [""];
      ghost.state = newState;
      ghost.label = pick(labels);
      ghost.motion = "settled";
      ghost.motionStartedAt = nowIso();
      ghost.lastActivityAt = Date.now();
      ghost.lifecycle = "working";
    } else {
      // Stop working: collapse to "Idle at desk". Stays seated; only the
      // pose flips from Working → Idle.
      ghost.state = "Idle";
      ghost.label = "";
      ghost.motion = "settled";
      ghost.lifecycle = "idle";
    }
    emitProjectDelta(project);
  }

  function emitProjectDelta(project) {
    dispatchDelta({
      projectID: project.projectID,
      ghosts: project.ghosts.slice(),
      projectStatus: project.projectStatus,
    });
  }

  function startDemo() {
    if (demoStarted) return;
    demoStarted = true;
    demoState = buildDemoSnapshot();
    dispatchSnapshot(demoState);
    // Stagger the first rotation by ~1.5 s so the initial spawn-walk
    // animation lands first, then keep beats coming every 1.5–3.5 s for
    // a lively-but-not-frantic feel.
    demoTimer = window.setInterval(rotateOne, 1800);
    // Expose for E2E hooks.
    window.__ghostRoomDemo = {
      stop: stopDemo,
      restart: function () { stopDemo(); demoStarted = false; startDemo(); },
      isActive: function () { return demoStarted; },
    };
  }

  function stopDemo() {
    if (demoTimer) window.clearInterval(demoTimer);
    demoTimer = 0;
    demoState = null;
    demoStarted = false;
  }

  // Watch for real Swift→JS data after the demo started — if real data
  // arrives, hand the rooms over by stopping the demo.
  var realWatchdog = 0;
  function startRealWatchdog() {
    if (realWatchdog) return;
    realWatchdog = window.setInterval(function () {
      if (demoStarted && bridgeSnapshotCount() > 0) {
        stopDemo();
        if (realWatchdog) {
          window.clearInterval(realWatchdog);
          realWatchdog = 0;
        }
      }
    }, 1500);
  }

  function maybeStartDemo() {
    // Give the host a 1.5 s grace window to push real data first.
    window.setTimeout(function () {
      if (bridgeSnapshotCount() > 0) {
        // Real data arrived — host owns the rooms.
        return;
      }
      startDemo();
      startRealWatchdog();
    }, 1500);
  }

  // Kick the demo seeder on document ready.
  if (document.readyState === "complete" || document.readyState === "interactive") {
    maybeStartDemo();
  } else {
    document.addEventListener("DOMContentLoaded", maybeStartDemo);
  }

  // Honor the dashboard activity gate so the demo sleeps when the
  // window is hidden (saves battery during the demo recording).
  var origLifecycle = window.__ghostLifecycle;
  window.__ghostLifecycle = function (msg) {
    try {
      if (msg && msg.active === false && demoTimer) {
        window.clearInterval(demoTimer);
        demoTimer = 0;
      } else if (msg && msg.active === true && demoStarted && !demoTimer) {
        demoTimer = window.setInterval(rotateOne, 1800);
      }
    } catch (_) { /* ignore */ }
    if (typeof origLifecycle === "function") {
      try { origLifecycle(msg); } catch (_) { /* ignore */ }
    }
  };
})();
