/*
 * Snappet Mobile — Knowledge Graph engine.
 * A dependency-free, offline force-directed graph renderer (Canvas 2D).
 *
 * Features: force / hierarchical / grouped layouts, pan-zoom, node drag,
 * fuzzy search, type/category/platform filters, neighbour highlighting,
 * shortest-path workflow tracing, deep-linkable selection, PNG/JSON export,
 * light/dark themes and keyboard shortcuts.
 */
(function () {
  "use strict";

  const G = window.GRAPH;
  const { NODE_TYPES, EDGE_TYPES, GROUP_COLORS } = G;

  // ---- working copies (don't mutate source) ----
  const nodes = G.nodes.map((n) => ({ ...n }));
  const links = G.links.map((l) => ({ ...l }));
  const nodeById = new Map(nodes.map((n) => [n.id, n]));

  // resolve link endpoints to node objects + build adjacency
  const adj = new Map(nodes.map((n) => [n.id, []]));
  links.forEach((l) => {
    l.s = nodeById.get(l.source);
    l.t = nodeById.get(l.target);
    if (!l.s || !l.t) console.warn("dangling link", l);
    else {
      adj.get(l.source).push({ to: l.target, link: l, dir: "out" });
      adj.get(l.target).push({ to: l.source, link: l, dir: "in" });
    }
  });
  // degree drives node radius
  nodes.forEach((n) => { n.deg = (adj.get(n.id) || []).length; });

  // ---- canvas ----
  const canvas = document.getElementById("graph");
  const ctx = canvas.getContext("2d");
  let DPR = Math.min(window.devicePixelRatio || 1, 2);
  let W = 0, H = 0;

  // ---- view transform ----
  const view = { x: 0, y: 0, k: 1 };

  // ---- interaction state ----
  let hoverNode = null;
  let selectedNode = null;
  let dragNode = null;
  let dragging = false;       // panning
  let lastPointer = { x: 0, y: 0 };
  let pinNode = null;         // fixed via drag
  let pathSet = null;         // Set of node ids on the traced path
  let pathLinkSet = null;     // Set of link refs on path
  let pathAnchor = null;      // first node picked for path tracing
  let pathMode = false;

  // ---- filters ----
  const active = {
    type: new Set(Object.keys(NODE_TYPES)),
    category: new Set(),
    platform: new Set(),
  };
  nodes.forEach((n) => { active.category.add(n.category); active.platform.add(n.platform); });
  const allCategories = [...active.category];
  const allPlatforms = [...active.platform];

  let layout = "force"; // force | tree | group

  function visible(n) {
    return active.type.has(n.type) && active.category.has(n.category) && active.platform.has(n.platform);
  }
  function linkVisible(l) { return visible(l.s) && visible(l.t); }

  /* ───────────────────────── Layout ───────────────────────── */

  function resetVelocities() { nodes.forEach((n) => { n.vx = 0; n.vy = 0; }); }

  // seed positions in a ring so the sim unfolds nicely
  function seedPositions() {
    const R = 320;
    nodes.forEach((n, i) => {
      const a = (i / nodes.length) * Math.PI * 2;
      n.x = Math.cos(a) * R + (Math.random() - 0.5) * 40;
      n.y = Math.sin(a) * R + (Math.random() - 0.5) * 40;
      n.vx = 0; n.vy = 0;
    });
    const app = nodeById.get("app");
    if (app) { app.x = 0; app.y = -260; }
  }

  // BFS layers from the app root → hierarchical layout
  function computeTreeLayout() {
    const depth = new Map();
    const root = "app";
    const q = [root]; depth.set(root, 0);
    while (q.length) {
      const id = q.shift();
      for (const e of adj.get(id)) {
        if (!depth.has(e.to)) { depth.set(e.to, depth.get(id) + 1); q.push(e.to); }
      }
    }
    let maxD = 0; depth.forEach((d) => (maxD = Math.max(maxD, d)));
    const byLayer = new Map();
    nodes.forEach((n) => {
      const d = depth.has(n.id) ? depth.get(n.id) : maxD + 1;
      if (!byLayer.has(d)) byLayer.set(d, []);
      byLayer.get(d).push(n);
    });
    const ySpacing = 150, xSpacing = 110;
    byLayer.forEach((layerNodes, d) => {
      layerNodes.sort((a, b) => (a.group + a.label).localeCompare(b.group + b.label));
      const total = (layerNodes.length - 1) * xSpacing;
      layerNodes.forEach((n, i) => {
        n.tx = i * xSpacing - total / 2;
        n.ty = d * ySpacing - 260;
      });
    });
  }

  // cluster by group around group anchors → grouped layout
  function computeGroupLayout() {
    const groups = [...new Set(nodes.map((n) => n.group))];
    const gc = groups.length;
    const ringR = 520;
    const center = {};
    groups.forEach((g, i) => {
      const a = (i / gc) * Math.PI * 2 - Math.PI / 2;
      center[g] = { x: Math.cos(a) * ringR, y: Math.sin(a) * ringR };
    });
    const byGroup = new Map();
    nodes.forEach((n) => { if (!byGroup.has(n.group)) byGroup.set(n.group, []); byGroup.get(n.group).push(n); });
    byGroup.forEach((gn, g) => {
      const c = center[g];
      const inner = Math.max(60, gn.length * 13);
      gn.forEach((n, i) => {
        const a = (i / gn.length) * Math.PI * 2;
        n.gx = c.x + Math.cos(a) * inner * (0.5 + 0.5 * ((i % 3) / 2));
        n.gy = c.y + Math.sin(a) * inner * (0.5 + 0.5 * ((i % 3) / 2));
      });
    });
    window.__groupCenters = center;
  }

  // force tick
  let alpha = 1;
  function tick() {
    const vis = nodes.filter(visible);

    if (layout === "force") {
      // repulsion (O(n²), fine for this size)
      for (let i = 0; i < vis.length; i++) {
        const a = vis[i];
        for (let j = i + 1; j < vis.length; j++) {
          const b = vis[j];
          let dx = a.x - b.x, dy = a.y - b.y;
          let d2 = dx * dx + dy * dy || 0.01;
          const d = Math.sqrt(d2);
          const rep = 5200 / d2;
          const fx = (dx / d) * rep, fy = (dy / d) * rep;
          a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
        }
      }
      // spring along visible links
      links.forEach((l) => {
        if (!linkVisible(l)) return;
        const a = l.s, b = l.t;
        let dx = b.x - a.x, dy = b.y - a.y;
        const d = Math.sqrt(dx * dx + dy * dy) || 0.01;
        const rest = l.type === "contains" ? 95 : 140;
        const k = 0.02 * (d - rest);
        const fx = (dx / d) * k, fy = (dy / d) * k;
        a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
      });
      // gentle gravity toward center
      vis.forEach((n) => { n.vx += -n.x * 0.0016; n.vy += -n.y * 0.0016; });
      // integrate
      vis.forEach((n) => {
        if (n === pinNode || n === dragNode) return;
        n.vx *= 0.86; n.vy *= 0.86;
        n.x += n.vx * alpha; n.y += n.vy * alpha;
      });
      alpha *= 0.994;
      if (alpha < 0.02) alpha = 0.02;
    } else {
      // ease toward target positions (tree/group)
      const key = layout === "tree" ? ["tx", "ty"] : ["gx", "gy"];
      vis.forEach((n) => {
        if (n === dragNode) return;
        const targX = n[key[0]] ?? n.x, targY = n[key[1]] ?? n.y;
        n.x += (targX - n.x) * 0.12;
        n.y += (targY - n.y) * 0.12;
      });
    }
  }

  function reheat(a = 0.9) { if (layout === "force") alpha = a; }

  /* ───────────────────────── Rendering ───────────────────────── */

  function radius(n) { return 9 + Math.min(n.deg, 10) * 1.5 + (n.type === "module" || n.type === "root" || n.type === "engine" ? 4 : 0); }

  function nodeColor(n) {
    // modules + their screens take the group accent; infra takes type colour
    if (n.type === "module") return GROUP_COLORS[n.group] || NODE_TYPES[n.type].color;
    return NODE_TYPES[n.type].color;
  }

  function isDimmed(n) {
    if (pathSet) return !pathSet.has(n.id);
    const focus = hoverNode || selectedNode;
    if (!focus) return false;
    if (n === focus) return false;
    return !neighbors(focus.id).has(n.id);
  }

  const neighborCache = new Map();
  function neighbors(id) {
    if (neighborCache.has(id)) return neighborCache.get(id);
    const s = new Set([id]);
    for (const e of adj.get(id)) s.add(e.to);
    neighborCache.set(id, s);
    return s;
  }

  function drawShape(x, y, r, shape) {
    ctx.beginPath();
    switch (shape) {
      case "diamond":
        ctx.moveTo(x, y - r); ctx.lineTo(x + r, y); ctx.lineTo(x, y + r); ctx.lineTo(x - r, y); ctx.closePath();
        break;
      case "hexagon":
        for (let i = 0; i < 6; i++) { const a = (Math.PI / 3) * i - Math.PI / 6; const px = x + Math.cos(a) * r, py = y + Math.sin(a) * r; i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); }
        ctx.closePath();
        break;
      case "rect": {
        const w = r * 1.7, h = r * 1.25; roundRect(x - w / 2, y - h / 2, w, h, 4); break;
      }
      case "roundrect": {
        const w = r * 1.8, h = r * 1.4; roundRect(x - w / 2, y - h / 2, w, h, h / 2); break;
      }
      case "cylinder": {
        const w = r * 1.5, h = r * 1.6, ry = r * 0.35;
        ctx.ellipse(x, y - h / 2 + ry, w / 2, ry, 0, Math.PI, 0);
        ctx.lineTo(x + w / 2, y + h / 2 - ry);
        ctx.ellipse(x, y + h / 2 - ry, w / 2, ry, 0, 0, Math.PI);
        ctx.lineTo(x - w / 2, y - h / 2 + ry);
        ctx.closePath();
        break;
      }
      default:
        ctx.arc(x, y, r, 0, Math.PI * 2);
    }
  }
  function roundRect(x, y, w, h, r) {
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function render() {
    ctx.save();
    ctx.clearRect(0, 0, W, H);
    ctx.translate(view.x, view.y);
    ctx.scale(view.k, view.k);

    // group hulls in grouped layout
    if (layout === "group" && window.__groupCenters) {
      drawGroupBubbles();
    }

    const focus = hoverNode || selectedNode;
    const focusNbrs = focus ? neighbors(focus.id) : null;

    // edges
    links.forEach((l) => {
      if (!linkVisible(l)) return;
      const onPath = pathLinkSet && pathLinkSet.has(l);
      let dim = false;
      if (pathSet) dim = !onPath;
      else if (focus) dim = !(focusNbrs.has(l.source) && focusNbrs.has(l.target) && (l.source === focus.id || l.target === focus.id));
      drawEdge(l, dim, onPath, focus);
    });

    // nodes
    nodes.forEach((n) => { if (visible(n)) drawNode(n); });

    ctx.restore();
  }

  function drawGroupBubbles() {
    const centers = window.__groupCenters;
    const byGroup = new Map();
    nodes.forEach((n) => { if (!visible(n)) return; if (!byGroup.has(n.group)) byGroup.set(n.group, []); byGroup.get(n.group).push(n); });
    byGroup.forEach((gn, g) => {
      let minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
      gn.forEach((n) => { minx = Math.min(minx, n.x); miny = Math.min(miny, n.y); maxx = Math.max(maxx, n.x); maxy = Math.max(maxy, n.y); });
      const pad = 34;
      ctx.beginPath();
      roundRect(minx - pad, miny - pad, maxx - minx + pad * 2, maxy - miny + pad * 2, 26);
      const col = GROUP_COLORS[g] || "#888";
      ctx.fillStyle = hexA(col, 0.07); ctx.fill();
      ctx.strokeStyle = hexA(col, 0.25); ctx.lineWidth = 1.2; ctx.stroke();
      ctx.fillStyle = hexA(col, 0.9); ctx.font = "600 12px " + FONT;
      ctx.fillText(groupLabel(g), minx - pad + 8, miny - pad + 16);
    });
  }

  function drawEdge(l, dim, onPath, focus) {
    const a = l.s, b = l.t;
    const et = EDGE_TYPES[l.type];
    const r = radius(b);
    // shorten to node edge for arrowhead
    let dx = b.x - a.x, dy = b.y - a.y;
    const dist = Math.sqrt(dx * dx + dy * dy) || 1;
    const ux = dx / dist, uy = dy / dist;
    const ex = b.x - ux * (r + 3), ey = b.y - uy * (r + 3);
    const sx = a.x + ux * (radius(a) + 1), sy = a.y + uy * (radius(a) + 1);

    ctx.save();
    ctx.globalAlpha = dim ? 0.06 : onPath ? 1 : 0.55;
    ctx.strokeStyle = et.color;
    ctx.lineWidth = (onPath ? 3 : 1.4) / 1;
    if (et.dash) ctx.setLineDash(Array.isArray(et.dash) ? et.dash : [5, 5]); else ctx.setLineDash([]);

    // slight curve so reciprocal edges don't overlap
    const mx = (sx + ex) / 2 + uy * 14, my = (sy + ey) / 2 - ux * 14;
    ctx.beginPath();
    ctx.moveTo(sx, sy);
    ctx.quadraticCurveTo(mx, my, ex, ey);
    ctx.stroke();
    ctx.setLineDash([]);

    if (et.arrow && !dim) {
      const ang = Math.atan2(ey - my, ex - mx);
      const ah = onPath ? 9 : 7;
      ctx.beginPath();
      ctx.moveTo(ex, ey);
      ctx.lineTo(ex - ah * Math.cos(ang - 0.4), ey - ah * Math.sin(ang - 0.4));
      ctx.lineTo(ex - ah * Math.cos(ang + 0.4), ey - ah * Math.sin(ang + 0.4));
      ctx.closePath();
      ctx.fillStyle = et.color; ctx.fill();
    }

    // edge label when focused/path and zoomed in enough
    const showLabel = (onPath || (focus && (l.source === focus.id || l.target === focus.id))) && l.label && view.k > 0.55;
    if (showLabel && !dim) {
      ctx.globalAlpha = 1;
      ctx.font = "10px " + FONT;
      const tw = ctx.measureText(l.label).width;
      ctx.fillStyle = CSS("--bg-elev");
      ctx.fillRect(mx - tw / 2 - 3, my - 7, tw + 6, 13);
      ctx.fillStyle = CSS("--text-dim");
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.fillText(l.label, mx, my);
      ctx.textAlign = "start";
    }
    ctx.restore();
  }

  function drawNode(n) {
    const r = radius(n);
    const dim = isDimmed(n);
    const col = nodeColor(n);
    const isFocus = n === selectedNode || n === hoverNode;
    const onPath = pathSet && pathSet.has(n.id);

    ctx.save();
    ctx.globalAlpha = dim ? 0.16 : 1;

    // glow for focus/path
    if (isFocus || onPath) {
      ctx.shadowColor = col; ctx.shadowBlur = 18;
    }
    drawShape(n.x, n.y, r, NODE_TYPES[n.type].shape);
    ctx.fillStyle = col; ctx.fill();
    ctx.shadowBlur = 0;

    // ring
    ctx.lineWidth = isFocus ? 3 : onPath ? 2.5 : 1.5;
    ctx.strokeStyle = isFocus ? CSS("--text") : hexA("#000000", 0.35);
    drawShape(n.x, n.y, r, NODE_TYPES[n.type].shape);
    ctx.stroke();

    // pin marker
    if (n === pinNode) {
      ctx.beginPath(); ctx.arc(n.x + r * 0.75, n.y - r * 0.75, 3, 0, Math.PI * 2);
      ctx.fillStyle = CSS("--text"); ctx.fill();
    }

    // label
    if (!dim && (view.k > 0.5 || isFocus || n.type === "module" || onPath)) {
      ctx.globalAlpha = dim ? 0.2 : 1;
      ctx.font = (isFocus ? "600 " : "") + (n.type === "module" ? "12px " : "11px ") + FONT;
      ctx.textAlign = "center"; ctx.textBaseline = "top";
      const ly = n.y + r + 3;
      const text = n.label;
      const tw = ctx.measureText(text).width;
      // label backplate
      ctx.fillStyle = hexA(CSS("--bg"), 0.7);
      ctx.fillRect(n.x - tw / 2 - 2, ly - 1, tw + 4, 14);
      ctx.fillStyle = CSS("--text");
      ctx.fillText(text, n.x, ly);
      ctx.textAlign = "start";
    }
    ctx.restore();
  }

  /* ───────────────────────── helpers ───────────────────────── */
  const FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';
  // getComputedStyle is slow to call every frame — cache the theme vars and
  // refresh the cache only when the theme actually changes.
  let cssCache = {};
  function refreshCSSCache() {
    const cs = getComputedStyle(document.documentElement);
    ["--bg", "--bg-elev", "--bg-elev2", "--text", "--text-dim", "--border"].forEach((v) => {
      cssCache[v] = cs.getPropertyValue(v).trim() || "#fff";
    });
  }
  function CSS(v) { return cssCache[v] || "#fff"; }
  function hexA(hex, a) {
    hex = hex.replace("#", "");
    if (hex.length === 3) hex = hex.split("").map((c) => c + c).join("");
    const n = parseInt(hex, 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
  }
  function groupLabel(g) {
    const map = { shell: "Shell", "workout-log": "Workout", workout: "Workout Reels", core: "Core", engine: "HighlightEngine", watch: "watchOS", platform: "OS frameworks" };
    return map[g] || g.charAt(0).toUpperCase() + g.slice(1);
  }

  function worldToScreen(x, y) { return { x: x * view.k + view.x, y: y * view.k + view.y }; }
  function screenToWorld(x, y) { return { x: (x - view.x) / view.k, y: (y - view.y) / view.k }; }

  function nodeAt(sx, sy) {
    const w = screenToWorld(sx, sy);
    let best = null, bestD = Infinity;
    for (const n of nodes) {
      if (!visible(n)) continue;
      const r = radius(n) + 4;
      const dx = n.x - w.x, dy = n.y - w.y;
      const d = dx * dx + dy * dy;
      if (d < r * r && d < bestD) { best = n; bestD = d; }
    }
    return best;
  }

  /* ───────────────────────── Animation loop ───────────────────────── */
  function loop() {
    tick();
    render();
    requestAnimationFrame(loop);
  }

  /* ───────────────────────── Resize ───────────────────────── */
  function resize() {
    const stage = canvas.parentElement;
    W = stage.clientWidth; H = stage.clientHeight;
    DPR = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = W * DPR; canvas.height = H * DPR;
    canvas.style.width = W + "px"; canvas.style.height = H + "px";
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  }
  window.addEventListener("resize", resize);

  function fitView(animate = true) {
    const vis = nodes.filter(visible);
    if (!vis.length) return;
    let minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
    vis.forEach((n) => { minx = Math.min(minx, n.x); miny = Math.min(miny, n.y); maxx = Math.max(maxx, n.x); maxy = Math.max(maxy, n.y); });
    const pad = 80;
    const w = maxx - minx + pad * 2, h = maxy - miny + pad * 2;
    const k = Math.min(W / w, H / h, 1.6);
    const target = { k, x: W / 2 - ((minx + maxx) / 2) * k, y: H / 2 - ((miny + maxy) / 2) * k };
    if (animate) animateView(target); else Object.assign(view, target);
  }
  let viewAnim = null;
  function animateView(target, dur = 420) {
    const start = { ...view }, t0 = performance.now();
    cancelAnimationFrame(viewAnim);
    function step(now) {
      const p = Math.min(1, (now - t0) / dur);
      const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
      view.x = start.x + (target.x - start.x) * e;
      view.y = start.y + (target.y - start.y) * e;
      view.k = start.k + (target.k - start.k) * e;
      if (p < 1) viewAnim = requestAnimationFrame(step);
    }
    viewAnim = requestAnimationFrame(step);
  }
  function centerOn(n, k = 1.3) {
    animateView({ k, x: W / 2 - n.x * k, y: H / 2 - n.y * k });
  }

  /* ───────────────────────── Pointer interaction ───────────────────────── */
  let downPoint = null, didDrag = false;
  canvas.addEventListener("pointerdown", (e) => {
    canvas.setPointerCapture(e.pointerId);
    const n = nodeAt(e.offsetX, e.offsetY);
    lastPointer = { x: e.offsetX, y: e.offsetY };
    downPoint = { x: e.offsetX, y: e.offsetY };
    didDrag = false;
    if (n) {
      if (pathMode) { tracePathTo(n); return; }
      dragNode = n;
      canvas.classList.add("grabbing-node");
    } else {
      dragging = true; hideTooltip(); canvas.classList.add("dragging");
    }
  });
  canvas.addEventListener("pointermove", (e) => {
    const dx = e.offsetX - lastPointer.x, dy = e.offsetY - lastPointer.y;
    if (downPoint && Math.hypot(e.offsetX - downPoint.x, e.offsetY - downPoint.y) > 4) didDrag = true;
    if (dragNode) {
      const w = screenToWorld(e.offsetX, e.offsetY);
      dragNode.x = w.x; dragNode.y = w.y; dragNode.vx = 0; dragNode.vy = 0;
      if (didDrag) pinNode = dragNode; // a real drag pins the node where you drop it
      reheat(0.5);
    } else if (dragging) {
      view.x += dx; view.y += dy;
    } else {
      const n = nodeAt(e.offsetX, e.offsetY);
      if (n !== hoverNode) { hoverNode = n; updateTooltip(n, e); canvas.style.cursor = n ? "pointer" : "grab"; }
      else if (n) moveTooltip(e);
    }
    lastPointer = { x: e.offsetX, y: e.offsetY };
  });
  canvas.addEventListener("pointerup", (e) => {
    if (dragNode) {
      if (!didDrag) selectNode(dragNode); // a clean click selects (doesn't pin)
      dragNode = null;
    } else if (dragging && !didDrag) {
      if (!pathMode) selectNode(null); // click on empty space clears selection
    }
    dragging = false; downPoint = null;
    canvas.classList.remove("dragging", "grabbing-node");
  });
  canvas.addEventListener("pointerleave", () => { hoverNode = null; hideTooltip(); });

  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const factor = Math.pow(1.0015, -e.deltaY);
    const mx = e.offsetX, my = e.offsetY;
    const w = screenToWorld(mx, my);
    view.k = Math.max(0.2, Math.min(4, view.k * factor));
    view.x = mx - w.x * view.k;
    view.y = my - w.y * view.k;
  }, { passive: false });

  // double-click to pin/unpin
  canvas.addEventListener("dblclick", (e) => {
    const n = nodeAt(e.offsetX, e.offsetY);
    if (n) { pinNode = pinNode === n ? null : n; }
  });

  /* ───────────────────────── Tooltip ───────────────────────── */
  const tooltip = document.getElementById("tooltip");
  function updateTooltip(n, e) {
    if (!n) { hideTooltip(); return; }
    tooltip.innerHTML = `<div class="tt-type">${NODE_TYPES[n.type].label} · ${groupLabel(n.group)}</div><div class="tt-title">${n.label}</div><div>${n.desc.length > 110 ? n.desc.slice(0, 110) + "…" : n.desc}</div>`;
    tooltip.style.display = "block";
    moveTooltip(e);
  }
  function moveTooltip(e) {
    const pad = 14;
    let x = e.offsetX + pad, y = e.offsetY + pad;
    const rect = tooltip.getBoundingClientRect();
    if (x + rect.width > W) x = e.offsetX - rect.width - pad;
    if (y + rect.height > H) y = e.offsetY - rect.height - pad;
    tooltip.style.left = x + "px"; tooltip.style.top = y + "px";
  }
  function hideTooltip() { tooltip.style.display = "none"; }

  /* ───────────────────────── Selection + detail panel ───────────────────────── */
  function selectNode(n, { center = false, push = true } = {}) {
    selectedNode = n;
    renderDetail(n);
    if (n) {
      document.querySelector(".detail").classList.remove("collapsed");
      if (center) centerOn(n);
      if (push) history.replaceState(null, "", "#node=" + encodeURIComponent(n.id));
    } else {
      history.replaceState(null, "", location.pathname + location.search);
    }
  }

  function renderDetail(n) {
    const el = document.getElementById("detailContent");
    if (!n) {
      el.innerHTML = `<div class="detail-placeholder"><div class="big">◎</div>Select any node to inspect its screen, file, and connections.<br><br>Tip: press <kbd>/</kbd> to search, or use <b>Trace path</b> to map a user flow between two screens.</div>`;
      return;
    }
    const col = nodeColor(n);
    const outs = adj.get(n.id).filter((e) => e.dir === "out" && visible(e.link.t));
    const ins = adj.get(n.id).filter((e) => e.dir === "in" && visible(e.link.s));
    const connRow = (e) => {
      const other = nodeById.get(e.to);
      const oc = nodeColor(other);
      const arrow = e.dir === "out" ? "→" : "←";
      const et = EDGE_TYPES[e.link.type];
      return `<div class="conn" data-go="${other.id}"><span class="arrow">${arrow} ${et.label}</span><span class="dot" style="background:${oc}"></span><span class="nm">${other.label}</span></div>`;
    };
    el.innerHTML = `
      <div class="head">
        <button class="close" id="detailClose" title="Close">×</button>
        <div class="typebadge"><span class="dot" style="background:${col}"></span>${NODE_TYPES[n.type].label} · ${groupLabel(n.group)}</div>
        <h2>${n.label}</h2>
      </div>
      <div class="body">
        ${n.shot ? `<div class="shots"><figure class="shotfig"><img class="shot" src="${n.shot}" alt="${n.label} light screenshot" loading="lazy"><figcaption>Light</figcaption></figure><figure class="shotfig"><img class="shot" src="${n.shot.replace(/\.png$/, "-dark.png")}" alt="${n.label} dark screenshot" loading="lazy"><figcaption>Dark</figcaption></figure></div>` : ""}
        ${n.video ? `<video class="shot-video" controls preload="metadata" playsinline><source src="${n.video}" type="video/mp4">Your browser can't play this video — <a href="${n.video}">open it directly</a>.</video>` : ""}
        <div class="desc">${n.desc}</div>
        <div class="kv"><span class="k">Category</span><span class="v">${cap(n.category)}</span></div>
        <div class="kv"><span class="k">Platform</span><span class="v">${platLabel(n.platform)}</span></div>
        <div class="kv"><span class="k">Source</span><span class="v file">${n.file}</span></div>
        ${n.tags && n.tags.length ? `<div class="kv"><span class="k">Tags</span><span class="v"><span class="tags">${n.tags.map((t) => `<span class="tag">${t}</span>`).join("")}</span></span></div>` : ""}
        ${outs.length ? `<div class="section-t">Leads to · ${outs.length}</div>${outs.map(connRow).join("")}` : ""}
        ${ins.length ? `<div class="section-t">Reached from · ${ins.length}</div>${ins.map(connRow).join("")}` : ""}
        <button class="btn pathbtn" id="tracePathFrom"><span class="ic">⤳</span> Trace a path from here…</button>
      </div>`;
    el.querySelectorAll(".conn").forEach((c) => c.addEventListener("click", () => {
      const target = nodeById.get(c.dataset.go); selectNode(target, { center: true });
    }));
    document.getElementById("detailClose").addEventListener("click", () => selectNode(null));
    document.getElementById("tracePathFrom").addEventListener("click", () => startPathMode(n));
  }
  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }
  function platLabel(p) { return { ios: "iOS", "ios+android": "iOS + Android", watchos: "watchOS", engine: "HighlightEngine (pure Swift)", external: "OS framework" }[p] || p; }

  /* ───────────────────────── Path tracing (BFS) ───────────────────────── */
  function startPathMode(fromNode) {
    pathMode = true; pathAnchor = fromNode || selectedNode;
    clearPath();
    document.getElementById("pathBanner").classList.add("show");
    document.getElementById("pathFrom").textContent = pathAnchor ? pathAnchor.label : "—";
    document.getElementById("pathTo").textContent = "pick a target…";
    document.getElementById("btnPath").classList.add("active");
  }
  function tracePathTo(toNode) {
    if (!pathAnchor || toNode === pathAnchor) return;
    const path = bfsPath(pathAnchor.id, toNode.id);
    if (!path) {
      document.getElementById("pathTo").textContent = "no path ✕";
      pathSet = null; pathLinkSet = null;
      return;
    }
    pathSet = new Set(path.nodes);
    pathLinkSet = new Set(path.links);
    document.getElementById("pathTo").textContent = toNode.label;
    selectedNode = null;
    fitToSet(pathSet);
  }
  function bfsPath(a, b) {
    const prev = new Map(), prevLink = new Map();
    const q = [a]; const seen = new Set([a]);
    while (q.length) {
      const id = q.shift();
      if (id === b) break;
      for (const e of adj.get(id)) {
        if (!visible(e.link.s) || !visible(e.link.t)) continue;
        if (!seen.has(e.to)) { seen.add(e.to); prev.set(e.to, id); prevLink.set(e.to, e.link); q.push(e.to); }
      }
    }
    if (!seen.has(b)) return null;
    const ns = [b], ls = [];
    let cur = b;
    while (cur !== a) { ls.push(prevLink.get(cur)); cur = prev.get(cur); ns.push(cur); }
    return { nodes: ns, links: ls };
  }
  function fitToSet(set) {
    const vis = nodes.filter((n) => set.has(n.id));
    if (!vis.length) return;
    let minx = 1e9, miny = 1e9, maxx = -1e9, maxy = -1e9;
    vis.forEach((n) => { minx = Math.min(minx, n.x); miny = Math.min(miny, n.y); maxx = Math.max(maxx, n.x); maxy = Math.max(maxy, n.y); });
    const pad = 120, w = maxx - minx + pad * 2, h = maxy - miny + pad * 2;
    const k = Math.min(W / w, H / h, 1.5);
    animateView({ k, x: W / 2 - ((minx + maxx) / 2) * k, y: H / 2 - ((miny + maxy) / 2) * k });
  }
  function clearPath() {
    pathSet = null; pathLinkSet = null;
  }
  function exitPathMode() {
    pathMode = false; pathAnchor = null; clearPath();
    document.getElementById("pathBanner").classList.remove("show");
    document.getElementById("btnPath").classList.remove("active");
  }

  /* ───────────────────────── Search ───────────────────────── */
  const searchInput = document.getElementById("search");
  const searchResults = document.getElementById("searchResults");
  const searchWrap = document.getElementById("searchWrap");
  let searchIdx = -1, searchHits = [];

  function fuzzy(q, n) {
    q = q.toLowerCase();
    const hay = (n.label + " " + n.desc + " " + (n.tags || []).join(" ") + " " + n.type + " " + n.group + " " + n.file).toLowerCase();
    if (hay.includes(q)) {
      // score: label hit > tag/type > desc
      let score = 0;
      if (n.label.toLowerCase().includes(q)) score += 100;
      if (n.label.toLowerCase().startsWith(q)) score += 50;
      if ((n.tags || []).some((t) => t.includes(q))) score += 30;
      if (n.type.includes(q) || n.group.includes(q)) score += 20;
      return score + 1;
    }
    return 0;
  }
  function runSearch(q) {
    if (!q.trim()) { searchResults.classList.remove("open"); searchHits = []; return; }
    searchHits = nodes.map((n) => ({ n, s: fuzzy(q, n) })).filter((x) => x.s > 0).sort((a, b) => b.s - a.s).slice(0, 12);
    searchIdx = -1;
    if (!searchHits.length) {
      searchResults.innerHTML = `<div class="item"><span class="label" style="color:var(--text-faint)">No matches</span></div>`;
      searchResults.classList.add("open");
      return;
    }
    searchResults.innerHTML = searchHits.map((h, i) => {
      const n = h.n;
      return `<div class="item" data-i="${i}" data-id="${n.id}"><span class="dot" style="background:${nodeColor(n)}"></span><span class="label">${n.label}</span><span class="meta">${NODE_TYPES[n.type].label}</span></div>`;
    }).join("");
    searchResults.classList.add("open");
    searchResults.querySelectorAll(".item").forEach((it) => it.addEventListener("click", () => {
      const n = nodeById.get(it.dataset.id); if (n) pickSearch(n);
    }));
  }
  function pickSearch(n) {
    searchResults.classList.remove("open");
    searchInput.value = n.label;
    searchWrap.classList.add("has-value");
    ensureVisible(n);
    selectNode(n, { center: true });
  }
  function ensureVisible(n) {
    // if filters hide the node's type/cat/plat, re-enable them
    if (!active.type.has(n.type)) { active.type.add(n.type); }
    if (!active.category.has(n.category)) active.category.add(n.category);
    if (!active.platform.has(n.platform)) active.platform.add(n.platform);
    buildFilters();
  }
  searchInput.addEventListener("input", (e) => {
    searchWrap.classList.toggle("has-value", !!e.target.value);
    runSearch(e.target.value);
  });
  searchInput.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); searchIdx = Math.min(searchHits.length - 1, searchIdx + 1); hiliteSearch(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); searchIdx = Math.max(0, searchIdx - 1); hiliteSearch(); }
    else if (e.key === "Enter") { if (searchHits[searchIdx]) pickSearch(searchHits[searchIdx].n); else if (searchHits[0]) pickSearch(searchHits[0].n); }
    else if (e.key === "Escape") { searchResults.classList.remove("open"); searchInput.blur(); }
  });
  function hiliteSearch() {
    searchResults.querySelectorAll(".item").forEach((it, i) => it.classList.toggle("active", i === searchIdx));
  }
  document.getElementById("searchClear").addEventListener("click", () => {
    searchInput.value = ""; searchWrap.classList.remove("has-value"); searchResults.classList.remove("open"); searchInput.focus();
  });
  document.addEventListener("click", (e) => { if (!searchWrap.contains(e.target)) searchResults.classList.remove("open"); });

  /* ───────────────────────── Sidebar: filters + legend ───────────────────────── */
  function countByType(t) { return nodes.filter((n) => n.type === t).length; }
  function countByCat(c) { return nodes.filter((n) => n.category === c).length; }
  function countByPlat(p) { return nodes.filter((n) => n.platform === p).length; }

  function buildFilters() {
    // type legend
    const tl = document.getElementById("typeFilters");
    tl.innerHTML = Object.entries(NODE_TYPES).map(([k, v]) => {
      const on = active.type.has(k);
      return `<div class="filter-row ${on ? "" : "off"}" data-type="${k}"><span class="swatch ${["root","external"].includes(k) ? "" : "dot"}" style="background:${v.color}"></span><span class="name">${v.label}</span><span class="count">${countByType(k)}</span></div>`;
    }).join("");
    tl.querySelectorAll(".filter-row").forEach((r) => r.addEventListener("click", () => toggle(active.type, r.dataset.type, buildFilters)));

    // category filter
    const cl = document.getElementById("catFilters");
    cl.innerHTML = allCategories.map((c) => {
      const on = active.category.has(c);
      return `<div class="filter-row ${on ? "" : "off"}" data-cat="${c}"><span class="swatch dot" style="background:${catColor(c)}"></span><span class="name">${cap(c)}</span><span class="count">${countByCat(c)}</span></div>`;
    }).join("");
    cl.querySelectorAll(".filter-row").forEach((r) => r.addEventListener("click", () => toggle(active.category, r.dataset.cat, buildFilters)));

    // platform filter
    const pl = document.getElementById("platFilters");
    pl.innerHTML = allPlatforms.map((p) => {
      const on = active.platform.has(p);
      return `<div class="filter-row ${on ? "" : "off"}" data-plat="${p}"><span class="swatch" style="background:${platColor(p)}"></span><span class="name">${platLabel(p)}</span><span class="count">${countByPlat(p)}</span></div>`;
    }).join("");
    pl.querySelectorAll(".filter-row").forEach((r) => r.addEventListener("click", () => toggle(active.platform, r.dataset.plat, buildFilters)));

    updateStats();
  }
  function toggle(set, key, after) {
    if (set.has(key)) set.delete(key); else set.add(key);
    if (after) after();
    reheat(0.4);
  }
  function catColor(c) { return { fitness: "#ff2d92", productivity: "#30d158", finance: "#0a84ff", core: "#5e5ce6", platform: "#98989d" }[c] || "#888"; }
  function platColor(p) { return { ios: "#0a84ff", "ios+android": "#30d158", watchos: "#66d4cf", engine: "#ff453a", external: "#98989d" }[p] || "#888"; }

  function buildEdgeLegend() {
    const el = document.getElementById("edgeLegend");
    el.innerHTML = Object.entries(EDGE_TYPES).map(([k, v]) => {
      const dash = v.dash ? "border-top-style:dashed" : "";
      return `<div class="er"><span class="line" style="border-top-color:${v.color};${dash}"></span>${v.label}</div>`;
    }).join("");
  }

  function updateStats() {
    const vn = nodes.filter(visible).length;
    const vl = links.filter(linkVisible).length;
    document.getElementById("stats").textContent = `${vn} nodes · ${vl} edges · ${layout} layout`;
  }

  /* ───────────────────────── Layout switching ───────────────────────── */
  function setLayout(l) {
    layout = l;
    document.querySelectorAll("#layoutSeg button").forEach((b) => b.classList.toggle("active", b.dataset.layout === l));
    if (l === "tree") computeTreeLayout();
    else if (l === "group") computeGroupLayout();
    reheat(1);
    updateStats();
    setTimeout(() => fitView(true), 60);
  }

  /* ───────────────────────── Theme ───────────────────────── */
  function toggleTheme() {
    document.documentElement.classList.toggle("light");
    const light = document.documentElement.classList.contains("light");
    document.getElementById("btnTheme").innerHTML = light ? "<span class='ic'>☾</span>" : "<span class='ic'>☀</span>";
    refreshCSSCache();
    try { localStorage.setItem("kg-theme", light ? "light" : "dark"); } catch (e) {}
  }

  /* ───────────────────────── Export ───────────────────────── */
  function exportPNG() {
    // render at higher res onto offscreen
    const scale = 2;
    const off = document.createElement("canvas");
    off.width = W * scale; off.height = H * scale;
    const octx = off.getContext("2d");
    octx.fillStyle = CSS("--bg"); octx.fillRect(0, 0, off.width, off.height);
    octx.drawImage(canvas, 0, 0, off.width, off.height);
    off.toBlob((blob) => {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob); a.download = "snappet-knowledge-graph.png"; a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    });
  }

  /* ───────────────────────── Wiring up toolbar ───────────────────────── */
  document.getElementById("btnFit").addEventListener("click", () => fitView(true));
  function zoomAtCenter(factor) {
    const cx = W / 2, cy = H / 2;
    const w = screenToWorld(cx, cy);
    view.k = Math.max(0.2, Math.min(4, view.k * factor));
    view.x = cx - w.x * view.k;
    view.y = cy - w.y * view.k;
  }
  document.getElementById("btnZoomIn").addEventListener("click", () => zoomAtCenter(1.25));
  document.getElementById("btnZoomOut").addEventListener("click", () => zoomAtCenter(1 / 1.25));
  document.getElementById("btnTheme").addEventListener("click", toggleTheme);
  document.getElementById("btnExport").addEventListener("click", exportPNG);
  document.getElementById("btnHelp").addEventListener("click", () => document.getElementById("helpModal").classList.add("open"));
  document.getElementById("helpClose").addEventListener("click", () => document.getElementById("helpModal").classList.remove("open"));
  document.getElementById("helpModal").addEventListener("click", (e) => { if (e.target.id === "helpModal") e.currentTarget.classList.remove("open"); });
  document.getElementById("btnSidebar").addEventListener("click", () => document.querySelector(".sidebar").classList.toggle("collapsed"));
  document.getElementById("btnPath").addEventListener("click", () => { if (pathMode) exitPathMode(); else startPathMode(selectedNode); });
  document.getElementById("pathClose").addEventListener("click", exitPathMode);
  document.querySelectorAll("#layoutSeg button").forEach((b) => b.addEventListener("click", () => setLayout(b.dataset.layout)));
  document.getElementById("btnReset").addEventListener("click", () => {
    active.type = new Set(Object.keys(NODE_TYPES));
    active.category = new Set(allCategories);
    active.platform = new Set(allPlatforms);
    pinNode = null; exitPathMode(); buildFilters(); seedPositions(); setLayout("force");
  });

  /* keyboard */
  document.addEventListener("keydown", (e) => {
    if (e.target.tagName === "INPUT") return;
    if (e.key === "/") { e.preventDefault(); searchInput.focus(); }
    else if (e.key === "Escape") { if (pathMode) exitPathMode(); else if (selectedNode) selectNode(null); document.getElementById("helpModal").classList.remove("open"); }
    else if (e.key === "f") fitView(true);
    else if (e.key === "1") setLayout("force");
    else if (e.key === "2") setLayout("tree");
    else if (e.key === "3") setLayout("group");
    else if (e.key === "t") toggleTheme();
    else if (e.key === "p") { if (pathMode) exitPathMode(); else startPathMode(selectedNode); }
    else if (e.key === "?") document.getElementById("helpModal").classList.toggle("open");
  });

  /* ───────────────────────── Deep link ───────────────────────── */
  function applyHash() {
    const m = location.hash.match(/node=([^&]+)/);
    if (m) {
      const n = nodeById.get(decodeURIComponent(m[1]));
      if (n) setTimeout(() => { ensureVisible(n); selectNode(n, { center: true, push: false }); }, 700);
    }
  }

  /* ───────────────────────── Boot ───────────────────────── */
  function boot() {
    try { if (localStorage.getItem("kg-theme") === "light") { document.documentElement.classList.add("light"); document.getElementById("btnTheme").innerHTML = "<span class='ic'>☾</span>"; } } catch (e) {}
    refreshCSSCache();
    resize();
    seedPositions();
    buildFilters();
    buildEdgeLegend();
    renderDetail(null);
    updateStats();
    // warm up the sim before fitting
    for (let i = 0; i < 120; i++) tick();
    fitView(false);
    loop();
    applyHash();
  }
  boot();

  // expose a tiny API for debugging
  window.__KG = { nodes, links, view, selectNode, setLayout };
})();
