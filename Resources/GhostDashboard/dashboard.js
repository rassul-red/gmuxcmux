// cmux Ghost Projects dashboard renderer.
//
// Owns the 2x2 tile DOM and consumes envelopes from `bridge.js`:
//   - ghost.snapshot.v1   { projects: [GhostProjectState] }   — full reset
//   - ghost.delta.v1      { projectID, ghosts?, projectStatus? } — single project
//   - ghost.lifecycle.v1  { active }                          — animation gate
//
// The renderer is a plain DOM script (no bundler) to mirror the existing
// bridge.js style. It keeps a simple `state.projects[]` array sorted by
// projectID so the 4 tile slots are stable across snapshots.
(function () {
  "use strict";

  var SNAPSHOT_EVENT = "ghost.snapshot.v1";
  var DELTA_EVENT = "ghost.delta.v1";
  var LIFECYCLE_EVENT = "ghost.lifecycle.v1";
  var TILE_COUNT = 4;

  // Lower-cased GhostState.rawValue → CSS class suffix.
  // GhostState today is one of: Coding, Reviewing, Reading, Idle,
  // Checking, Deploying, Monitoring, Testing. We collapse them into the four
  // visual buckets the CSS knows about: idle, coding, warning, walking.
  var STATE_BUCKETS = {
    idle: "idle",
    coding: "coding",
    reviewing: "coding",
    reading: "coding",
    checking: "coding",
    deploying: "coding",
    monitoring: "coding",
    testing: "coding",
    warning: "warning",
    walking: "walking",
  };

  // Inline ghost glyph: chubby Pac-Man-style silhouette with a wavy hem and
  // two eyes. Uses currentColor so the surrounding `.ghost-room.state-*`
  // class drives the fill. Eyes are white circles.
  var GHOST_SVG = [
    '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg" ',
    'aria-hidden="true" focusable="false">',
      '<path d="',
        'M 12 50 ',
        'C 12 24, 30 12, 50 12 ',
        'C 70 12, 88 24, 88 50 ',
        'L 88 86 ',
        'L 78 76 ',
        'L 68 86 ',
        'L 58 76 ',
        'L 50 86 ',
        'L 42 76 ',
        'L 32 86 ',
        'L 22 76 ',
        'L 12 86 ',
        'Z" fill="currentColor"/>',
      '<circle cx="38" cy="46" r="7" fill="#ffffff"/>',
      '<circle cx="62" cy="46" r="7" fill="#ffffff"/>',
      '<circle cx="38" cy="48" r="3" fill="#0a090e"/>',
      '<circle cx="62" cy="48" r="3" fill="#0a090e"/>',
    "</svg>",
  ].join("");

  var state = {
    projects: [], // sorted by projectID, capped to TILE_COUNT for render
  };

  var tiles = []; // DOM nodes, length = TILE_COUNT, set by buildGrid()

  function buildGrid() {
    var grid = document.getElementById("ghost-grid");
    if (!grid) return;
    grid.innerHTML = "";
    tiles = [];
    for (var i = 0; i < TILE_COUNT; i += 1) {
      var room = document.createElement("div");
      room.className = "ghost-room placeholder state-idle";
      room.setAttribute("data-slot", String(i));

      var glyph = document.createElement("div");
      glyph.className = "ghost-glyph";
      glyph.innerHTML = GHOST_SVG;
      room.appendChild(glyph);

      var name = document.createElement("div");
      name.className = "room-name";
      name.textContent = "No project";
      room.appendChild(name);

      var meta = document.createElement("div");
      meta.className = "room-meta";
      var pill = document.createElement("span");
      pill.className = "status-pill";
      pill.textContent = "idle";
      meta.appendChild(pill);
      room.appendChild(meta);

      var activity = document.createElement("div");
      activity.className = "last-activity";
      activity.textContent = "";
      room.appendChild(activity);

      grid.appendChild(room);
      tiles.push({
        root: room,
        name: name,
        pill: pill,
        activity: activity,
      });
    }
  }

  function bucketFor(stateValue) {
    if (typeof stateValue !== "string") return "idle";
    var key = stateValue.toLowerCase();
    return STATE_BUCKETS[key] || "idle";
  }

  // Pick a representative state for the tile from a project's ghost roster.
  // We surface the most "active" ghost (anything non-idle wins) so the tile
  // pulses while any session in the project is alive.
  function projectTileState(project) {
    var ghosts = (project && project.ghosts) || [];
    if (!ghosts.length) return { bucket: "idle", raw: "Idle", lastActivityAt: null };
    for (var i = 0; i < ghosts.length; i += 1) {
      var g = ghosts[i];
      var bucket = bucketFor(g && g.state);
      if (bucket !== "idle") {
        return { bucket: bucket, raw: g.state, lastActivityAt: g.lastActivityAt || null };
      }
    }
    var first = ghosts[0];
    return { bucket: "idle", raw: first.state || "Idle", lastActivityAt: first.lastActivityAt || null };
  }

  function formatActivity(ts) {
    if (!ts) return "";
    var n = (typeof ts === "number") ? ts : Number(ts);
    if (!isFinite(n) || n <= 0) return "";
    try {
      return new Date(n).toLocaleTimeString();
    } catch (_) {
      return "";
    }
  }

  function applyTile(tile, project) {
    if (!tile) return;
    if (!project) {
      tile.root.className = "ghost-room placeholder state-idle";
      tile.name.textContent = "No project";
      tile.pill.textContent = "idle";
      tile.activity.textContent = "";
      return;
    }
    var info = projectTileState(project);
    tile.root.className = "ghost-room state-" + info.bucket;
    tile.name.textContent = project.projectName || project.projectID || "(unnamed)";
    tile.pill.textContent = (info.raw || "idle").toLowerCase();
    tile.activity.textContent = formatActivity(info.lastActivityAt);
  }

  function render() {
    var sorted = state.projects.slice().sort(function (a, b) {
      var ai = (a && a.projectID) || "";
      var bi = (b && b.projectID) || "";
      return ai < bi ? -1 : ai > bi ? 1 : 0;
    });
    for (var i = 0; i < TILE_COUNT; i += 1) {
      applyTile(tiles[i], sorted[i]);
    }
  }

  function applySnapshot(payload) {
    var projects = (payload && payload.projects) || [];
    state.projects = projects.slice();
    render();
  }

  function applyDelta(payload) {
    if (!payload || !payload.projectID) return;
    var pid = payload.projectID;
    var existing = null;
    for (var i = 0; i < state.projects.length; i += 1) {
      if (state.projects[i].projectID === pid) {
        existing = state.projects[i];
        break;
      }
    }
    // Empty ghosts array signals "project removed" per #3 contract.
    if (Array.isArray(payload.ghosts) && payload.ghosts.length === 0) {
      state.projects = state.projects.filter(function (p) { return p.projectID !== pid; });
      render();
      return;
    }
    if (!existing) {
      // Best-effort upsert: synthesize a project record. The bridge usually
      // pushes a snapshot first so this branch is mostly defensive.
      state.projects.push({
        projectID: pid,
        projectName: pid,
        projectCwd: "",
        projectStatus: payload.projectStatus || "",
        ghosts: payload.ghosts || [],
      });
    } else {
      if (Array.isArray(payload.ghosts)) {
        existing.ghosts = payload.ghosts;
      }
      if (typeof payload.projectStatus === "string") {
        existing.projectStatus = payload.projectStatus;
      }
    }
    render();
  }

  function applyLifecycle(payload) {
    var active = !!(payload && payload.active);
    document.body.classList.toggle("lifecycle-inactive", !active);
  }

  function init() {
    buildGrid();
    render();
    window.addEventListener(SNAPSHOT_EVENT, function (ev) { applySnapshot(ev.detail); });
    window.addEventListener(DELTA_EVENT,    function (ev) { applyDelta(ev.detail); });
    window.addEventListener(LIFECYCLE_EVENT, function (ev) { applyLifecycle(ev.detail); });

    // The WebViewHost's lifecycle shim posts to window.__ghostLifecycle
    // (the #5 RAF gate). Wrap it so the dashboard's CSS animations also
    // suspend/resume in lockstep with the gate, without changing the gate's
    // own RAF semantics.
    var prior = (typeof window.__ghostLifecycle === "function")
      ? window.__ghostLifecycle
      : null;
    window.__ghostLifecycle = function (msg) {
      try { applyLifecycle(msg); } catch (_) { /* noop */ }
      if (prior) {
        try { prior(msg); } catch (_) { /* noop */ }
      }
    };
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  // Public hook for tests / direct injection.
  window.cmuxGhostDashboard = {
    applySnapshot: applySnapshot,
    applyDelta: applyDelta,
    applyLifecycle: applyLifecycle,
  };
})();
