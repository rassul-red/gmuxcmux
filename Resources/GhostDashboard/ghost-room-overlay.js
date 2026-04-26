// cmux Ghost dashboard "room scene" overlay (issue #17).
//
// Injected into the dashboard WebView at .atDocumentEnd by
// GhostDashboardWebViewHost. Renders a fixed-position SVG layer on top of
// the bundled dashboard with one ghost per roster entry. Ghosts:
//
//   * "spawning"  — fade in at the entry point, then drift slowly while
//                   waiting for a seat assignment.
//   * "wandering" — slow random drift around the room (idle).
//   * "walking"   — animate from current position toward the assigned table
//                   over WALK_DURATION_SECONDS seconds.
//   * "settled"   — parked next to the table.
//
// Listens to the existing bridge events from bridge.js:
//   - ghost.snapshot.v1 (full roster)
//   - ghost.delta.v1    (per-project delta)
//
// Pure presentational layer. No bridge protocol changes here — it only
// consumes the optional motion/tableID fields added by GhostBridgeProtocol
// and gracefully falls back when they are absent (older host).
(function () {
  if (typeof window === "undefined") return;
  if (window.__ghostRoomOverlayInstalled) return;
  window.__ghostRoomOverlayInstalled = true;

  // Must match GhostMotion.walkDuration in GhostRosterManager.swift.
  var WALK_DURATION_SECONDS = 2.0;

  // Up to 5 seats per project (mirrors GhostRosterManager.maxGhostsPerProject).
  // Coordinates are unit-square (0..1); the overlay scales them to the actual
  // viewport in render(). Lay tables out in a row at the bottom third of the
  // room with a little staggering so they don't visually overlap.
  var TABLE_LAYOUT = [
    { x: 0.18, y: 0.62 },
    { x: 0.34, y: 0.70 },
    { x: 0.50, y: 0.62 },
    { x: 0.66, y: 0.70 },
    { x: 0.82, y: 0.62 },
  ];

  // Where ghosts park relative to a table (slightly above so the ghost sits
  // "at" the desk).
  var SEAT_OFFSET = { x: 0.0, y: -0.05 };

  // Where new ghosts enter the room (off-screen left, mid-height).
  var SPAWN_POINT = { x: -0.05, y: 0.30 };

  // Visible inset so wandering ghosts don't clip into the dashboard chrome.
  var ROOM_BOUNDS = { minX: 0.05, maxX: 0.95, minY: 0.10, maxY: 0.55 };

  // ---- Internal state ----------------------------------------------------

  // ghostID -> { x, y, motion, tableID, walkStart, walkFromX, walkFromY,
  //              wanderTargetX, wanderTargetY, wanderRetargetAt }
  var ghosts = Object.create(null);

  // Removed-ghost ids get cleaned up on the next render.
  var alive = Object.create(null);

  var rafHandle = 0;
  var paused = false;
  var rootEl = null;
  var lastFrameAt = 0;

  function clamp(v, lo, hi) {
    return v < lo ? lo : (v > hi ? hi : v);
  }

  function ensureRoot() {
    if (rootEl && rootEl.isConnected) return rootEl;
    var existing = document.getElementById("__ghost_room_overlay");
    if (existing) {
      rootEl = existing;
      return rootEl;
    }
    var div = document.createElement("div");
    div.id = "__ghost_room_overlay";
    div.style.cssText =
      "position:fixed;inset:0;pointer-events:none;z-index:50;" +
      "overflow:hidden;contain:strict;";

    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("id", "__ghost_room_svg");
    svg.setAttribute("preserveAspectRatio", "none");
    svg.style.cssText = "position:absolute;inset:0;width:100%;height:100%;";
    div.appendChild(svg);

    // Append to body when it exists. atDocumentEnd injection guarantees body
    // is present.
    (document.body || document.documentElement).appendChild(div);
    rootEl = div;
    return rootEl;
  }

  function removeNode(node) {
    if (node && node.parentNode) node.parentNode.removeChild(node);
  }

  function nodeForGhost(id) {
    var svg = document.getElementById("__ghost_room_svg");
    if (!svg) return null;
    var existing = svg.querySelector('g[data-ghost-id="' + cssEscape(id) + '"]');
    if (existing) return existing;

    var g = document.createElementNS("http://www.w3.org/2000/svg", "g");
    g.setAttribute("data-ghost-id", id);
    g.setAttribute("class", "cmux-ghost-room-figure");
    g.style.transition = "opacity 0.4s ease-in-out";
    g.style.opacity = "0";

    // Body: rounded ghost silhouette in lavender.
    var body = document.createElementNS("http://www.w3.org/2000/svg", "path");
    body.setAttribute(
      "d",
      "M -14 12 Q -14 -18 0 -18 Q 14 -18 14 12 L 14 18 L 10 14 L 6 18 L 2 14 L -2 18 L -6 14 L -10 18 L -14 14 Z"
    );
    body.setAttribute("fill", "#fff8ec");
    body.setAttribute("stroke", "#b89ad9");
    body.setAttribute("stroke-width", "1.5");
    body.setAttribute("opacity", "0.92");
    g.appendChild(body);

    // Eyes.
    var eyeL = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    eyeL.setAttribute("cx", "-4");
    eyeL.setAttribute("cy", "-4");
    eyeL.setAttribute("r", "1.6");
    eyeL.setAttribute("fill", "#1a0a04");
    g.appendChild(eyeL);
    var eyeR = document.createElementNS("http://www.w3.org/2000/svg", "circle");
    eyeR.setAttribute("cx", "4");
    eyeR.setAttribute("cy", "-4");
    eyeR.setAttribute("r", "1.6");
    eyeR.setAttribute("fill", "#1a0a04");
    g.appendChild(eyeR);

    svg.appendChild(g);
    // Defer fade-in to next frame so the transition triggers.
    window.requestAnimationFrame(function () {
      g.style.opacity = "1";
    });
    return g;
  }

  // Lightweight CSS.escape fallback for attribute selectors.
  function cssEscape(value) {
    if (window.CSS && typeof window.CSS.escape === "function") {
      return window.CSS.escape(value);
    }
    return String(value).replace(/[^a-zA-Z0-9_-]/g, function (ch) {
      return "\\" + ch;
    });
  }

  function tablePoint(tableID) {
    if (tableID == null || tableID < 0 || tableID >= TABLE_LAYOUT.length) {
      return null;
    }
    var t = TABLE_LAYOUT[tableID];
    return { x: t.x + SEAT_OFFSET.x, y: t.y + SEAT_OFFSET.y };
  }

  function pickWanderTarget() {
    var x = ROOM_BOUNDS.minX +
      Math.random() * (ROOM_BOUNDS.maxX - ROOM_BOUNDS.minX);
    var y = ROOM_BOUNDS.minY +
      Math.random() * (ROOM_BOUNDS.maxY - ROOM_BOUNDS.minY);
    return { x: x, y: y };
  }

  function ensureGhostState(id, motion, tableID, motionStartedAt) {
    var st = ghosts[id];
    if (!st) {
      st = {
        x: SPAWN_POINT.x,
        y: SPAWN_POINT.y,
        motion: motion || "spawning",
        tableID: tableID == null ? null : tableID,
        walkStart: 0,
        walkFromX: SPAWN_POINT.x,
        walkFromY: SPAWN_POINT.y,
        wanderTargetX: 0,
        wanderTargetY: 0,
        wanderRetargetAt: 0,
      };
      ghosts[id] = st;
    }
    return st;
  }

  function applyEntry(entry) {
    if (!entry || !entry.ghostID) return;
    alive[entry.ghostID] = true;

    var motion = typeof entry.motion === "string" ? entry.motion : "spawning";
    var tableID = (typeof entry.tableID === "number") ? entry.tableID : null;
    var startedAt = entry.motionStartedAt
      ? Date.parse(entry.motionStartedAt)
      : 0;

    var st = ensureGhostState(entry.ghostID, motion, tableID, startedAt);

    // If motion phase changed, freeze the current position as the new
    // animation origin so transitions look continuous.
    if (st.motion !== motion) {
      st.walkFromX = st.x;
      st.walkFromY = st.y;
      st.walkStart = isFinite(startedAt) && startedAt > 0
        ? startedAt
        : Date.now();
      st.motion = motion;
    }
    st.tableID = tableID;
  }

  function applyDelta(payload) {
    if (!payload || !Array.isArray(payload.ghosts)) return;
    payload.ghosts.forEach(applyEntry);
  }

  function applySnapshot(payload) {
    if (!payload || !Array.isArray(payload.projects)) return;
    // Reset alive markers — anything not in the snapshot fades out.
    alive = Object.create(null);
    payload.projects.forEach(function (project) {
      if (!project || !Array.isArray(project.ghosts)) return;
      project.ghosts.forEach(applyEntry);
    });
  }

  function reapDead() {
    var ids = Object.keys(ghosts);
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i];
      if (alive[id]) continue;
      // Fade and remove the node, then drop our state.
      var svg = document.getElementById("__ghost_room_svg");
      if (svg) {
        var node = svg.querySelector(
          'g[data-ghost-id="' + cssEscape(id) + '"]'
        );
        if (node) {
          node.style.opacity = "0";
          (function (n) {
            window.setTimeout(function () { removeNode(n); }, 450);
          })(node);
        }
      }
      delete ghosts[id];
    }
  }

  function tick(now) {
    if (paused) {
      rafHandle = 0;
      return;
    }
    var root = ensureRoot();
    if (!root) {
      rafHandle = window.requestAnimationFrame(tick);
      return;
    }

    // Frame-rate-independent dt for wander drift. Clamp the first frame and
    // any tab-suspend hiccups so a long pause doesn't teleport the ghost to
    // its target. ~0.5s cap matches the lifecycle gate's resume cadence.
    var dt = lastFrameAt ? Math.min(0.5, (now - lastFrameAt) / 1000) : 1 / 60;
    lastFrameAt = now;

    var rect = root.getBoundingClientRect();
    var width = rect.width || window.innerWidth || 800;
    var height = rect.height || window.innerHeight || 600;

    var ids = Object.keys(ghosts);
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i];
      var st = ghosts[id];

      if (st.motion === "walking") {
        // Linear interpolation toward seat over WALK_DURATION_SECONDS.
        var seat = tablePoint(st.tableID) || { x: st.x, y: st.y };
        var elapsed = Math.max(0, (now - st.walkStart) / 1000);
        var t = clamp(elapsed / WALK_DURATION_SECONDS, 0, 1);
        st.x = st.walkFromX + (seat.x - st.walkFromX) * t;
        st.y = st.walkFromY + (seat.y - st.walkFromY) * t;
      } else if (st.motion === "settled") {
        var s = tablePoint(st.tableID);
        if (s) { st.x = s.x; st.y = s.y; }
      } else {
        // wandering OR spawning — slow drift toward a random target,
        // re-pick when close or every few seconds.
        if (
          !st.wanderRetargetAt ||
          now > st.wanderRetargetAt ||
          Math.hypot(st.wanderTargetX - st.x, st.wanderTargetY - st.y) < 0.02
        ) {
          var target = pickWanderTarget();
          // For "spawning" ghosts (no seat yet) bias them toward room center
          // so they don't pile up at the spawn point.
          if (st.motion === "spawning") {
            target.x = (target.x + 0.5) / 2;
          }
          st.wanderTargetX = target.x;
          st.wanderTargetY = target.y;
          st.wanderRetargetAt = now + 4000 + Math.random() * 3000;
        }
        var dx = st.wanderTargetX - st.x;
        var dy = st.wanderTargetY - st.y;
        // Time-based exponential approach: ~0.72 unit-square per second
        // toward the target (matches the original 0.012/frame at 60fps).
        // dt is clamped above so a tab-resume hiccup can't snap the ghost.
        var step = Math.min(1, 0.72 * dt);
        st.x += dx * step;
        st.y += dy * step;
      }

      var px = clamp(st.x, -0.1, 1.1) * width;
      var py = clamp(st.y, -0.1, 1.1) * height;
      var node = nodeForGhost(id);
      if (node) {
        node.setAttribute("transform", "translate(" + px + "," + py + ")");
      }
    }

    reapDead();
    rafHandle = window.requestAnimationFrame(tick);
  }

  function start() {
    if (rafHandle) return;
    paused = false;
    // Reset the dt baseline — otherwise a long suspend (e.g. dashboard
    // hidden for minutes) would deliver a huge first-frame dt; the cap in
    // tick() already protects against that, but resetting keeps the
    // animation perfectly continuous on resume.
    lastFrameAt = 0;
    ensureRoot();
    rafHandle = window.requestAnimationFrame(tick);
  }

  function stop() {
    paused = true;
    if (rafHandle) {
      window.cancelAnimationFrame(rafHandle);
      rafHandle = 0;
    }
  }

  // Bridge listeners — bridge.js dispatches CustomEvents whose `detail` is
  // the decoded payload (see bridge.js#dispatchTo).
  window.addEventListener("ghost.snapshot.v1", function (e) {
    applySnapshot(e && e.detail);
    start();
  });
  window.addEventListener("ghost.delta.v1", function (e) {
    applyDelta(e && e.detail);
    start();
  });

  // Honor the existing dashboard-active gate so the overlay sleeps when the
  // window is hidden.
  var origLifecycle = window.__ghostLifecycle;
  window.__ghostLifecycle = function (msg) {
    try {
      if (msg && msg.active === false) stop();
      else if (msg && msg.active === true) start();
    } catch (_) { /* ignore */ }
    if (typeof origLifecycle === "function") {
      try { origLifecycle(msg); } catch (_) { /* ignore */ }
    }
  };

  // Expose tiny test/debug surface for E2E hooks.
  window.__ghostRoomOverlay = {
    debugState: function () {
      return {
        ghosts: Object.keys(ghosts).map(function (id) {
          var s = ghosts[id];
          return {
            id: id, x: s.x, y: s.y, motion: s.motion, tableID: s.tableID,
          };
        }),
      };
    },
  };

  // Kick the loop in case the bridge already received a snapshot before this
  // script ran.
  start();
})();
