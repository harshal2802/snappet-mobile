# Snappet Mobile — App Knowledge Graph

A **searchable, interactive knowledge graph** of the Snappet Mobile app's wireframe and
workflows. Every screen, sheet, mini-app, service, engine component and data model is a node;
the navigation pushes, modal presentations, service usage and data flows that connect them are
the edges.

It's a single static site — **no build step, no backend, fully offline**. Open it and explore.

**Live:** [harshal2802.github.io/snappet-mobile/knowledge-graph](https://harshal2802.github.io/snappet-mobile/knowledge-graph/)
(once GitHub Pages is enabled — see below).

## Open it

```sh
# Easiest: just open the file
open docs/knowledge-graph/index.html        # macOS
xdg-open docs/knowledge-graph/index.html    # Linux

# Or serve it (recommended — clean deep-links, no file:// quirks)
cd docs/knowledge-graph && python3 -m http.server 8000
# → http://localhost:8000
```

### GitHub Pages

The site is plain static HTML/JS, so Pages serves it with no build:

1. Repo **Settings → Pages → Source: "Deploy from a branch" → `main` / `/docs`**.
2. Visit `https://<owner>.github.io/snappet-mobile/knowledge-graph/`.

The repo includes an empty `docs/.nojekyll` so Pages serves the files verbatim instead of
running them through Jekyll.

## What you can do

| Capability | How |
|---|---|
| **Search** anything | Press <kbd>/</kbd> (or click the search box). Fuzzy-matches labels, tags, types, files. Arrow-keys + Enter to jump. |
| **Inspect a node** | Click it — the right panel shows its type, category, platform, source file, tags and every in/out connection (each connection is clickable). |
| **Highlight a flow** | Hover or select a node to dim everything except its direct neighbours. |
| **Trace a workflow** | Click **Trace path**, then click a target node — the shortest navigation/data path lights up (e.g. *App Library → Workout Reels → Reel → Share*). |
| **Switch layout** | **Force** (organic), **Hierarchy** (BFS layers from the app root), **Clusters** (grouped by mini-app). Keys <kbd>1</kbd>/<kbd>2</kbd>/<kbd>3</kbd>. |
| **Filter** | Toggle by node **type**, **category** (fitness / productivity / finance / core / platform) or **platform** (iOS / iOS+Android / watchOS / engine / OS framework). |
| **Pan / zoom / drag** | Drag the canvas to pan, scroll to zoom, drag a node to reposition (drop pins it), double-click to pin/unpin. |
| **Deep-link** | Selecting a node updates the URL (`#node=reel`) so you can share a link to any screen. |
| **Export** | Download the current view as a PNG. |
| **Theme** | Light / dark toggle (<kbd>T</kbd>), remembered across visits. |

Press <kbd>?</kbd> in-app for the full legend and shortcut list.

## Files

```
index.html   UI shell (toolbar, sidebar filters, detail panel, help modal)
styles.css   theme + layout
data.js      the graph model — nodes + edges (the single source of truth)
graph.js     the engine — force sim, layouts, search, filters, path tracing, export
```

## Extending the graph

The graph is **data-driven**: everything (search, filters, layouts, legend, the detail panel)
is derived from [`data.js`](data.js). To add a screen or wire a new flow, you only touch that file.

**Add a node** to the `nodes` array:

```js
{ id: "my-screen", label: "MyNewView", type: "screen", group: "journal",
  category: "productivity", platform: "ios",
  file: "ios/App/Snappet/Features/Journal/MyNewView.swift",
  desc: "What this screen does.", tags: ["detail"] },
```

**Connect it** in the `links` array with an edge of the right semantic type:

```js
{ source: "journal-root", target: "my-screen", type: "navigate", label: "tap row" },
```

Node `type`s (drive colour/shape): `root · shell · module · screen · section · sheet · cover ·
service · engine · core · model · watch · widget · external`.

Edge `type`s (drive colour/style): `contains · navigate · present · cover · uses · persists ·
feeds · streams`.

Reload the page — no rebuild needed.

## How it was built

The model was reconstructed from the iOS source tree (`ios/App/Snappet/`): the `TabView` shell
and `SuiteRouter`, `ModuleRegistry`'s eight `AppModule`s, every `navigationDestination` / `.sheet`
/ `.fullScreenCover`, the flagship Workout-Reels pipeline (`AppModel` → `HighlightEngine` →
`ReelExporter`), and the SwiftData `@Model`s behind Snappet Core. It also covers the **Live Workout
Capture + Video Studio** initiative — the watchOS companion, the pluggable `MetricsSource` layer (Apple
Watch / BLE band), the Live Activity, and the video studio (session media tagging → enriched HR summary →
CapCut-style clip editor → engine-driven highlight reel → share / save). Many screen/section nodes carry a
**screenshot** (`shot`), and the **Live Workout Studio** overview node embeds the **walkthrough video**.
Android mirrors the same screens 1:1 (nodes are tagged `iOS + Android` where parity exists).
