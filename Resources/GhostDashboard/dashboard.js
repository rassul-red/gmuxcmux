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

  // GhostState rawValue → tile-mode bucket for *assigned* ghosts (those with
  // a `tableID`). Assigned ghosts are bound to their desk for the lifetime of
  // the terminal instance — even when the session is Idle ("Idle at desk").
  // Free ghosts (`tableID == null`) always wander regardless of state.
  var STATE_TO_MODE = {
    idle:       "seated",
    walking:    "seated",
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

  function modeFor(rawState, hasTable) {
    // Free ghosts (no desk assigned) always wander, regardless of state.
    if (!hasTable) return "wander";
    if (typeof rawState !== "string") return "seated";
    return STATE_TO_MODE[rawState.toLowerCase()] || "seated";
  }

  function poseFor(mode, rawState) {
    if (mode === "attention") return "Attention";
    if (mode === "wander") return "Idle";
    // Seated: use the Idle sprite when the session has collapsed to Idle so
    // the ghost reads as "at desk but not currently working". Otherwise use
    // the Working pose.
    if (typeof rawState === "string" && rawState.toLowerCase() === "idle") {
      return "Idle";
    }
    return "Working";
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

    // Header overlay: a single capsule that displays the cmux workspace
    // name for this slot. The label is supplied by the host via
    // `applyWorkspaceLabels` (driven by the first four cmux workspace
    // titles) and stays hidden until cmux supplies one.
    var header = el("div", "room-header");
    var workspacePill = el("span", "workspace-pill", "");
    workspacePill.hidden = true;
    header.appendChild(workspacePill);
    scene.appendChild(header);

    room.appendChild(scene);

    return {
      idx: idx,
      root: room,
      sceneEl: scene,
      workspacePillEl: workspacePill,
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
    // Speech bubble badge — displayed only when `needsAttention` is true.
    // Anchored to the worker's position via the same left/top transform so
    // it follows the ghost as it walks.
    var badge = el("div", "ghost-attention-badge", "?");
    badge.style.left = startX + "%";
    badge.style.top = startY + "%";
    badge.hidden = true;
    tile.sceneEl.appendChild(badge);
    return {
      ghostID: ghostID,
      role: role,
      slotIdx: slotIdx,
      mode: "wander",
      pose: "Idle",
      pos: { x: startX, y: startY },
      dom: dom,
      badge: badge,
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
    if (worker.badge) {
      worker.badge.style.left = x + "%";
      worker.badge.style.top = y + "%";
    }
  }

  function setWorkerAttention(worker, on) {
    if (!worker.badge) return;
    worker.badge.hidden = !on;
    setClass(worker.dom, "needs-attention", !!on);
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
      tile.workers.forEach(function (w) {
        if (w.walkTimer) clearTimeout(w.walkTimer);
        w.dom.remove();
        if (w.badge) w.badge.remove();
      });
      tile.workers.clear();
      return;
    }

    tile.projectID = project.projectID;
    var info = projectBucket(project);
    tile.root.className = "ghost-room state-" + info.bucket;

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
        if (w.badge) w.badge.remove();
      }
      tile.workers["delete"](id);
    });

    // Add or update.
    for (var i = 0; i < ghosts.length; i += 1) {
      var g = ghosts[i];
      var hasTable = (g.tableID !== null && g.tableID !== undefined);
      // Slot the ghost into its assigned desk if it has one; otherwise the
      // free ghost gets `slotIdx = -1` and roams freely.
      var slotIdx = hasTable ? (g.tableID | 0) : -1;
      var worker = tile.workers.get(g.ghostID);
      if (!worker) {
        worker = spawnWorker(tile, g.ghostID, slotIdx);
        tile.workers.set(g.ghostID, worker);
      }
      worker.slotIdx = slotIdx;
      var needsAttention = !!g.needsAttention;
      var newMode = needsAttention ? "attention" : modeFor(g.state, hasTable);
      var newPose = poseFor(newMode, g.state);

      // Tooltip + click metadata — refreshed every snapshot so hover/click
      // always reflect current status. Stash on the dom node so the global
      // hover/click handlers can read it without keeping a Worker reference.
      worker.dom.dataset.projectId = project.projectID || "";
      worker.dom.dataset.projectName = project.projectName || project.projectID || "";
      worker.dom.dataset.ghostId = g.ghostID || "";
      worker.dom.dataset.ghostState = g.state || "Idle";
      worker.dom.dataset.ghostLabel = g.label || "";
      worker.dom.dataset.ghostFree = hasTable ? "0" : "1";
      worker.dom.dataset.ghostAttention = needsAttention ? "1" : "0";
      worker.dom.dataset.lastActivityAt = (g.lastActivityAt != null) ? String(g.lastActivityAt) : "";
      worker.dom.dataset.panelId = g.panelID || "";

      if (worker.mode !== newMode || worker.pose !== newPose) {
        transitionToMode(worker, newMode, newPose);
      }
      setWorkerAttention(worker, needsAttention);
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
    // Render in the order the host emitted them. The host (Swift bridge)
    // emits in cmux workspace order, which matches the sidebar ordering.
    // Alphabetical sort would be unstable when projectIDs are workspace
    // UUIDs.
    for (var i = 0; i < TILE_COUNT; i += 1) {
      syncTile(tiles[i], projects[i] || null);
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

  // Per-tile workspace name capsule. Labels are the first four cmux
  // workspace titles, in workspace order. Slots without a label hide the
  // capsule entirely.
  var currentLabels = [];
  function applyWorkspaceLabels(labels) {
    currentLabels = Array.isArray(labels) ? labels.slice(0, TILE_COUNT) : [];
    for (var i = 0; i < TILE_COUNT; i += 1) {
      var tile = tiles[i];
      if (!tile || !tile.workspacePillEl) continue;
      var label = currentLabels[i];
      if (typeof label === "string" && label.length > 0) {
        tile.workspacePillEl.textContent = label;
        tile.workspacePillEl.hidden = false;
      } else {
        tile.workspacePillEl.textContent = "";
        tile.workspacePillEl.hidden = true;
      }
    }
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

  // ---------- hover tooltip -----------------------------------------------

  var tooltipEl = null;

  function ensureTooltip() {
    if (tooltipEl) return tooltipEl;
    tooltipEl = el("div", "ghost-tooltip");
    tooltipEl.style.display = "none";
    document.body.appendChild(tooltipEl);
    return tooltipEl;
  }

  function escapeHtml(s) {
    if (s == null) return "";
    return String(s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function formatLastActivity(msStr) {
    if (!msStr) return null;
    var ms = Number(msStr);
    if (!isFinite(ms) || ms <= 0) return null;
    var delta = Math.max(0, Date.now() - ms);
    if (delta < 5000) return "just now";
    if (delta < 60000) return Math.floor(delta / 1000) + "s ago";
    if (delta < 3600000) return Math.floor(delta / 60000) + "m ago";
    return Math.floor(delta / 3600000) + "h ago";
  }

  function showTooltip(ev) {
    var target = ev.target;
    if (!target || target.nodeName !== "IMG") return;
    if (!target.classList.contains("worker")) return;
    var t = ensureTooltip();
    var d = target.dataset || {};
    var isFree = d.ghostFree === "1";
    var needsAttention = d.ghostAttention === "1";
    var stateText = isFree
      ? "Idle - waiting for task"
      : (d.ghostState || "Idle") + (d.ghostLabel ? " - " + d.ghostLabel : "");
    var lines = [];
    if (d.projectName) {
      lines.push('<div class="ghost-tooltip-title">' + escapeHtml(d.projectName) + '</div>');
    }
    lines.push('<div class="ghost-tooltip-state">' + escapeHtml(stateText) + '</div>');
    if (needsAttention) {
      lines.push('<div class="ghost-tooltip-attention">Needs attention</div>');
    }
    var when = formatLastActivity(d.lastActivityAt);
    if (when) lines.push('<div class="ghost-tooltip-time">' + escapeHtml(when) + '</div>');
    t.innerHTML = lines.join("");
    t.style.display = "block";
    moveTooltip(ev);
  }

  function moveTooltip(ev) {
    if (!tooltipEl || tooltipEl.style.display === "none") return;
    var pad = 14;
    tooltipEl.style.left = (ev.clientX + pad) + "px";
    tooltipEl.style.top = (ev.clientY + pad) + "px";
  }

  function hideTooltip(ev) {
    var target = ev.target;
    if (!target || !target.classList || !target.classList.contains("worker")) return;
    if (tooltipEl) tooltipEl.style.display = "none";
  }

  // ---------- click → focus session ---------------------------------------

  // Click on a ghost: send `focusGhost` to the host so cmux jumps to that
  // workspace (and, eventually, the specific Claude Code session inside it).
  // No-op when the bridge isn't attached (pure demo mode).
  function handleWorkerClick(ev) {
    var target = ev.target;
    if (!target || target.nodeName !== "IMG") return;
    if (!target.classList.contains("worker")) return;
    var d = target.dataset || {};
    var projectID = d.projectId || "";
    var ghostID = d.ghostId || "";
    if (!projectID && !ghostID) return;
    ev.preventDefault();
    ev.stopPropagation();
    var bridge = window.__ghostBridge;
    if (!bridge || typeof bridge.sendAction !== "function") return;
    var panelID = d.panelId || "";
    bridge.sendAction({
      action: "focusGhost",
      projectID: projectID,
      data: { ghostID: ghostID, panelID: panelID },
    });
  }

  // ---------- boot ---------------------------------------------------------

  function init() {
    buildGrid();
    render();

    // If the host pushed labels before this script booted, replay them.
    if (Array.isArray(window.__cmuxWorkspaceLabels)) {
      applyWorkspaceLabels(window.__cmuxWorkspaceLabels);
    }

    window.addEventListener(SNAPSHOT_EVENT,  function (ev) { applySnapshot(ev.detail); });
    window.addEventListener(DELTA_EVENT,     function (ev) { applyDelta(ev.detail); });
    window.addEventListener(LIFECYCLE_EVENT, function (ev) { applyLifecycle(ev.detail); });

    document.addEventListener("mouseover", showTooltip, true);
    document.addEventListener("mousemove", moveTooltip, true);
    document.addEventListener("mouseout", hideTooltip, true);
    document.addEventListener("click", handleWorkerClick, true);

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
    applyWorkspaceLabels: applyWorkspaceLabels,
  };
})();
