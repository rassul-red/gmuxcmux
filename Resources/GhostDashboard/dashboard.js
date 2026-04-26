// cmux Ghost Projects dashboard — isometric office scene renderer.
//
// Consumes envelopes from `bridge.js`:
//   - ghost.snapshot.v1   payload = { projects: [GhostProjectState] }   — full reset
//   - ghost.delta.v1      payload = { projectID, ghosts?, projectStatus? } — single project
//   - ghost.lifecycle.v1  payload = { active }                          — animation gate
//
// For each tile we maintain a small scene graph:
//   tile -> { sceneEl, projectID, workers: Map<ghostID, Worker> }
//   Worker = { ghostID, role, slotIdx, mode, pose, pos, dom, lastWanderTick, walkTimer }
//
// State → mode mapping collapses 8 GhostState raw values into:
//   wander  — standing, free-roaming
//   seated  — at the worker's assigned desk, "Working" pose
//   attention — standing, red glow, "Attention" pose

(function () {
  "use strict";

  // ---------- constants ----------------------------------------------------

  var SNAPSHOT_EVENT  = "ghost.snapshot.v1";
  var DELTA_EVENT     = "ghost.delta.v1";
  var LIFECYCLE_EVENT = "ghost.lifecycle.v1";

  var TILE_COUNT = 4;
  var ROLES = ["Builder", "Debugger", "Orchestrator", "Reviewer"];

  // 4 fixed desk slots per tile, in % of tile area (isometric layout tuned
  // to AgentOfficeBackground.png — back row up, front row down).
  var DESK_SLOTS = [
    { x: 28, y: 42 }, // back-left
    { x: 68, y: 42 }, // back-right
    { x: 24, y: 70 }, // front-left
    { x: 72, y: 70 }, // front-right
  ];

  // Free-roam bounding box (% within the tile).
  var ROAM = { xMin: 18, xMax: 78, yMin: 50, yMax: 82 };

  // GhostState rawValue → tile-mode bucket. Mirrors the lower-cased keys used
  // in the previous dashboard.js so the input contract is preserved.
  var STATE_TO_MODE = {
    idle:       "wander",
    walking:    "wander",
    coding:     "seated",
    reading:    "seated",
    reviewing:  "seated",
    checking:   "seated",
    deploying:  "seated",
    monitoring: "seated",
    testing:    "seated",
    warning:    "attention",
  };

  // GhostState rawValue → tile color bucket (drives the status-pill color).
  var STATE_BUCKETS = {
    idle:       "idle",
    walking:    "walking",
    coding:     "coding",
    reading:    "coding",
    reviewing:  "coding",
    checking:   "coding",
    deploying:  "coding",
    monitoring: "coding",
    testing:    "coding",
    warning:    "warning",
  };

  // Static prop layout — same for all 4 tiles. Coordinates in % of tile.
  // [name, leftPct, topPct, scale].
  var PROP_LAYOUT = [
    ["ServerRack",    10, 28, 0.30],
    ["Bookshelf",     90, 28, 0.34],
    ["TaskBoard",     50, 16, 0.26],
    ["FloorLamp",      8, 64, 0.26],
    ["PottedPlant",   92, 76, 0.20],
    ["FloorRug",      50, 88, 0.55],
    ["StorageCabinet", 92, 50, 0.24],
    ["Router",         8, 86, 0.18],
  ];

  // ---------- helpers ------------------------------------------------------

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (typeof text === "string") e.textContent = text;
    return e;
  }

  function roleFor(ghostID) {
    if (typeof ghostID !== "string" || !ghostID.length) return ROLES[0];
    var h = 0;
    for (var i = 0; i < ghostID.length; i += 1) {
      h = ((h * 31) + ghostID.charCodeAt(i)) | 0;
    }
    return ROLES[Math.abs(h) % ROLES.length];
  }

  function modeFor(rawState) {
    if (typeof rawState !== "string") return "wander";
    return STATE_TO_MODE[rawState.toLowerCase()] || "wander";
  }

  function bucketFor(rawState) {
    if (typeof rawState !== "string") return "idle";
    return STATE_BUCKETS[rawState.toLowerCase()] || "idle";
  }

  function workerSrc(role, pose, seated) {
    if (seated) {
      return "sprites/seated/AgentWorkerSeated" + role + pose + ".png";
    }
    return "sprites/workers/AgentWorker" + role + pose + ".png";
  }

  // Project-level rollup: pick the most "active" ghost so the pill shows it.
  function projectBucket(project) {
    var ghosts = (project && project.ghosts) || [];
    if (!ghosts.length) return { bucket: "idle", raw: "Idle" };
    var fallback = { bucket: "idle", raw: ghosts[0].state || "Idle" };
    for (var i = 0; i < ghosts.length; i += 1) {
      var b = bucketFor(ghosts[i].state);
      if (b === "warning") return { bucket: "warning", raw: ghosts[i].state };
      if (b !== "idle") fallback = { bucket: b, raw: ghosts[i].state };
    }
    return fallback;
  }

  // ---------- tile scaffold ------------------------------------------------

  function buildTile(idx) {
    var room = el("div", "ghost-room placeholder state-idle");
    room.setAttribute("data-slot", String(idx));
    var scene = el("div", "scene");

    // Static props.
    for (var i = 0; i < PROP_LAYOUT.length; i += 1) {
      var entry = PROP_LAYOUT[i];
      var p = el("img", "prop");
      p.alt = "";
      p.src = "sprites/props/OfficeProp" + entry[0] + ".png";
      p.style.left = entry[1] + "%";
      p.style.top = entry[2] + "%";
      p.style.width = (entry[3] * 60) + "%"; // scale is a multiplier
      p.style.transform = "translate(-50%, -50%)";
      scene.appendChild(p);
    }

    // 4 desks at fixed slots, role-keyed Idle PNGs.
    for (var j = 0; j < DESK_SLOTS.length; j += 1) {
      var slot = DESK_SLOTS[j];
      var role = ROLES[j];
      var d = el("img", "desk");
      d.alt = "";
      d.src = "sprites/desks/AgentDesk" + role + "Idle.png";
      d.style.left = slot.x + "%";
      d.style.top = slot.y + "%";
      d.style.width = "26%";
      d.style.transform = "translate(-50%, -50%)";
      d.dataset.slot = String(j);
      scene.appendChild(d);
    }

    // Header overlay (project name + status pill).
    var header = el("div", "room-header");
    var name = el("span", "room-name", "—");
    var pill = el("span", "status-pill", "no project");
    header.appendChild(name);
    header.appendChild(pill);
    scene.appendChild(header);

    room.appendChild(scene);

    return {
      idx: idx,
      root: room,
      sceneEl: scene,
      nameEl: name,
      pillEl: pill,
      projectID: null,
      workers: new Map(),
    };
  }

  // ---------- worker render ------------------------------------------------

  function spawnWorker(tile, ghostID, slotIdx) {
    var role = roleFor(ghostID);
    var dom = el("img", "worker bobbing");
    dom.alt = "";
    dom.src = workerSrc(role, "Idle", false);
    var startX = ROAM.xMin + Math.random() * (ROAM.xMax - ROAM.xMin);
    var startY = ROAM.yMin + Math.random() * (ROAM.yMax - ROAM.yMin);
    dom.style.left = startX + "%";
    dom.style.top = startY + "%";
    dom.dataset.role = role;
    tile.sceneEl.appendChild(dom);
    return {
      ghostID: ghostID,
      role: role,
      slotIdx: slotIdx,
      mode: "wander",
      pose: "Idle",
      pos: { x: startX, y: startY },
      dom: dom,
      lastWanderTick: 0,
      walkTimer: 0,
    };
  }

  function applyWorkerVisual(worker) {
    var dom = worker.dom;
    var seated = (worker.mode === "seated");
    dom.src = workerSrc(worker.role, worker.pose, seated);
    setClass(dom, "bobbing", worker.mode === "wander");
    setClass(dom, "attention", worker.mode === "attention");
    setClass(dom, "seated", seated);
  }

  function setClass(dom, cls, on) {
    if (on) dom.classList.add(cls);
    else dom.classList.remove(cls);
  }

  function moveWorker(worker, x, y) {
    worker.pos.x = x;
    worker.pos.y = y;
    worker.dom.style.left = x + "%";
    worker.dom.style.top = y + "%";
  }

  function deskPos(slotIdx) {
    var s = DESK_SLOTS[slotIdx % DESK_SLOTS.length];
    // Sit slightly in front of the desk so the seated sprite reads on top.
    return { x: s.x, y: Math.min(92, s.y + 10) };
  }

  function transitionToMode(worker, newMode, newPose) {
    var prevMode = worker.mode;
    worker.mode = newMode;
    worker.pose = newPose;

    // Cancel any in-flight walk timer; we're committing to a new state.
    if (worker.walkTimer) {
      clearTimeout(worker.walkTimer);
      worker.walkTimer = 0;
    }

    if (newMode === "seated") {
      // Walk to desk first, then swap to the seated sprite.
      var dp = deskPos(worker.slotIdx);
      // Stay standing while traveling.
      worker.dom.src = workerSrc(worker.role, "Idle", false);
      setClass(worker.dom, "bobbing", true);
      setClass(worker.dom, "attention", false);
      setClass(worker.dom, "seated", false);
      moveWorker(worker, dp.x, dp.y);
      worker.walkTimer = setTimeout(function () {
        worker.walkTimer = 0;
        applyWorkerVisual(worker);
      }, 2400);
    } else if (prevMode === "seated") {
      // Leave desk: standing pose, then enter wander/attention behavior.
      applyWorkerVisual(worker);
      // Pick a random wander target so it visibly walks away.
      if (newMode === "wander") {
        var x = ROAM.xMin + Math.random() * (ROAM.xMax - ROAM.xMin);
        var y = ROAM.yMin + Math.random() * (ROAM.yMax - ROAM.yMin);
        moveWorker(worker, x, y);
      }
    } else {
      applyWorkerVisual(worker);
    }
  }

  // ---------- per-tile sync ------------------------------------------------

  function syncTile(tile, project) {
    if (!project) {
      tile.projectID = null;
      tile.root.className = "ghost-room placeholder state-idle";
      tile.nameEl.textContent = "—";
      tile.pillEl.textContent = "no project";
      tile.workers.forEach(function (w) {
        if (w.walkTimer) clearTimeout(w.walkTimer);
        w.dom.remove();
      });
      tile.workers.clear();
      return;
    }

    tile.projectID = project.projectID;
    var info = projectBucket(project);
    tile.root.className = "ghost-room state-" + info.bucket;
    tile.nameEl.textContent = project.projectName || project.projectID || "(unnamed)";
    tile.pillEl.textContent = (info.raw || "idle").toLowerCase();

    var ghosts = (project.ghosts || []).slice(0, DESK_SLOTS.length);

    // Remove workers no longer present.
    var liveIds = new Set();
    for (var k = 0; k < ghosts.length; k += 1) liveIds.add(ghosts[k].ghostID);
    var stale = [];
    tile.workers.forEach(function (w, id) { if (!liveIds.has(id)) stale.push(id); });
    stale.forEach(function (id) {
      var w = tile.workers.get(id);
      if (w) {
        if (w.walkTimer) clearTimeout(w.walkTimer);
        w.dom.remove();
      }
      tile.workers["delete"](id);
    });

    // Add or update.
    for (var i = 0; i < ghosts.length; i += 1) {
      var g = ghosts[i];
      var worker = tile.workers.get(g.ghostID);
      if (!worker) {
        worker = spawnWorker(tile, g.ghostID, i);
        tile.workers.set(g.ghostID, worker);
      }
      worker.slotIdx = i;
      var newMode = modeFor(g.state);
      var newPose;
      if (newMode === "seated") newPose = "Working";
      else if (newMode === "attention") newPose = "Attention";
      else newPose = "Idle";

      if (worker.mode !== newMode || worker.pose !== newPose) {
        transitionToMode(worker, newMode, newPose);
      }
    }
  }

  // ---------- top-level state ---------------------------------------------

  var tiles = [];
  var projects = []; // sorted by projectID, capped to TILE_COUNT for render.

  function buildGrid() {
    var grid = document.getElementById("ghost-grid");
    if (!grid) return;
    grid.innerHTML = "";
    tiles = [];
    for (var i = 0; i < TILE_COUNT; i += 1) {
      var tile = buildTile(i);
      grid.appendChild(tile.root);
      tiles.push(tile);
    }
  }

  function render() {
    var sorted = projects.slice().sort(function (a, b) {
      var ai = (a && a.projectID) || "";
      var bi = (b && b.projectID) || "";
      return ai < bi ? -1 : ai > bi ? 1 : 0;
    });
    for (var i = 0; i < TILE_COUNT; i += 1) {
      syncTile(tiles[i], sorted[i] || null);
    }
  }

  // ---------- event handlers ----------------------------------------------

  function applySnapshot(payload) {
    var nextProjects = (payload && payload.projects) || [];
    projects = nextProjects.slice();
    render();
  }

  function applyDelta(payload) {
    if (!payload || !payload.projectID) return;
    var pid = payload.projectID;
    var existing = null;
    for (var i = 0; i < projects.length; i += 1) {
      if (projects[i].projectID === pid) {
        existing = projects[i];
        break;
      }
    }
    // Empty ghosts array signals "project removed" per #3 contract.
    if (Array.isArray(payload.ghosts) && payload.ghosts.length === 0) {
      projects = projects.filter(function (p) { return p.projectID !== pid; });
      render();
      return;
    }
    if (!existing) {
      projects.push({
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

  // ---------- free-roam loop ----------------------------------------------

  var lastTick = 0;
  function loop(now) {
    if (!document.body.classList.contains("lifecycle-inactive")) {
      if (now - lastTick > 800) {
        lastTick = now;
        for (var i = 0; i < tiles.length; i += 1) {
          var t = tiles[i];
          t.workers.forEach(function (w) {
            if (w.mode !== "wander") return;
            if (w.walkTimer) return;
            var due = 6000 + Math.random() * 6000;
            if (now - w.lastWanderTick > due) {
              w.lastWanderTick = now;
              var x = ROAM.xMin + Math.random() * (ROAM.xMax - ROAM.xMin);
              var y = ROAM.yMin + Math.random() * (ROAM.yMax - ROAM.yMin);
              moveWorker(w, x, y);
            }
          });
        }
      }
    }
    requestAnimationFrame(loop);
  }

  // ---------- boot ---------------------------------------------------------

  function init() {
    buildGrid();
    render();

    window.addEventListener(SNAPSHOT_EVENT,  function (ev) { applySnapshot(ev.detail); });
    window.addEventListener(DELTA_EVENT,     function (ev) { applyDelta(ev.detail); });
    window.addEventListener(LIFECYCLE_EVENT, function (ev) { applyLifecycle(ev.detail); });

    // The WebViewHost's lifecycle shim posts to window.__ghostLifecycle (the
    // #5 RAF gate). Wrap it so the dashboard's CSS animations also suspend
    // /resume in lockstep with the gate, without changing the gate's own
    // RAF semantics.
    var prior = (typeof window.__ghostLifecycle === "function")
      ? window.__ghostLifecycle
      : null;
    window.__ghostLifecycle = function (msg) {
      try { applyLifecycle(msg); } catch (_) { /* noop */ }
      if (prior) {
        try { prior(msg); } catch (_) { /* noop */ }
      }
    };

    requestAnimationFrame(loop);
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
