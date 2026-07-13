# Pixel Editor (feat/pixel-editor) — work plan and task backup

A built-in pixel drawing tool for authoring all Phase 1 source images.
Scope agreed on 2026-07-13: the "advanced" tier — core editor plus
selection/transform tools, symmetry, color replace, canvas operations, and
.pal palette I/O. Layers/animation/blend modes are deferred, but the file
format already carries a layer stack so those can land without breaking
old files.

## Feature scope (first release)

Core:
- Canvas with lossless zoom (FilterQuality.none), checkerboard transparency,
  1 px pixel grid and 16 px cell grid overlays
- Tools: pencil, eraser, line, rectangle, ellipse (outline via drag box),
  bucket fill with tolerance + contiguous toggle, eyedropper
- Brush sizes 1-8 (UI exposes 1-4)
- Indexed palette panel (default DawnBringer 32), visual HSV sliders +
  hex/AARRGGBB entry, add/remove palette entries
- Unlimited undo/redo (history stack, capped at 256 snapshots)
- Fixed keyboard shortcuts for tool switching
- `.rgpix` project save/open (JSON: dimensions, layer stack, palette,
  grid/symmetry settings)
- PNG export
- Auto-import into Phase 1 ("Send to Phase 1": track / island / decoration)

Advanced (same release):
- Selection: rectangle, lasso (polygon), magic wand (tolerance + contiguous)
- Move/transform: floating selection with drag move, nearest-neighbor corner
  scaling (resampled from the lifted original, no compounding loss),
  rotate 90 CW/CCW, flip H/V; Esc cancels, click outside commits
- Every drawing tool respects the active selection mask
- Symmetry drawing: X mirror, Y mirror, XY
- Color replace = fill tool with contiguous off (recolors all matching)
- Canvas: resize with 9-way anchor, crop to selection, rotate/flip whole
  canvas
- Palette import/export as JASC `.pal`

Deferred (format-ready, not in this release): layer UI + blend modes,
animation frames + sprite sheet export, isometric grid, dithered gradient,
custom shortcut editing.

## Architecture

- `lib/models/pixel_document.dart` — PixelLayer / PixelDocument (ARGB
  Uint32List buffers), source-over compositing, RgpixFile encode/decode.
  No dart:ui (CLI-safe, same rule as the other models).
- `lib/logic/pixel_ops.dart` — pure buffer ops: Bresenham line, rect,
  Zingl midpoint ellipse, flood fill (tolerance/contiguous/selection mask),
  magic wand, rect/polygon selection masks, lift/blit for floating
  selections, nearest-neighbor scale, rotate90, flips, canvas resize
  (anchored) and crop, symmetry point expansion.
- `lib/logic/pal_file.dart` — JASC-PAL text format encode/decode.
- `lib/state/pixel_editor_providers.dart` — Riverpod Notifier: tool state,
  stroke lifecycle (preview by repainting from a stroke-base copy so
  preview and commit share one code path), undo/redo snapshots, composited
  ui.Image cache (generation-guarded async decode), floating selection,
  file I/O, Send-to-Phase-1.
- `lib/ui/pixel_editor/pixel_canvas.dart` — InteractiveViewer canvas
  (same zoom/pan conventions as the Phase 1/2 canvases), painter for
  checkerboard/image/grids/selection/floating chrome/hover.
- `lib/ui/pixel_editor/color_panel.dart` — color + palette panel.
- `lib/ui/pixel_editor/pixel_editor_page.dart` — page layout, toolbar,
  dialogs (new/resize/send), keyboard shortcuts.
- Shell: a pinned "Pixel Editor" tab next to Phase 1
  (`WorkspaceState.pixelEditorActive`, `AppMode.pixelEditor`); Save /
  Save As / Undo menu routing; quit prompt covers dirty pixel art.
  Phase 1 gains one additive method
  (`AssetDefinerNotifier.importImageBytes`) and Phase 2 is untouched
  (explicit constraint: keep impact on existing phases minimal).

## File formats

`.rgpix` (JSON):
```json
{
  "format": "rgpix", "version": 1,
  "width": 128, "height": 128,
  "layers": [
    {"name": "Layer 1", "visible": true, "opacity": 1.0,
     "pixels": "<base64 of row-major RGBA bytes>"}
  ],
  "palette": ["#ff000000", "..."],
  "settings": {"showPixelGrid": true, "showCellGrid": true, "symmetry": "none"}
}
```

`.pal`: JASC-PAL ("JASC-PAL" / "0100" / count / "r g b" lines).

## Task list (backup of the session tracker)

| # | Task | Status |
|---|------|--------|
| 1 | Core: pixel document model + pure drawing ops + .rgpix format (`pixel_document.dart`, `pixel_ops.dart`, `pal_file.dart`) | completed |
| 2 | Core: pixel editor state notifier (tools, stroke lifecycle, undo/redo, image cache, file I/O, Send to Phase 1; `pixel_editor_providers.dart`, `importImageBytes` in Phase 1 notifier, workspace pixel tab state) | completed |
| 3 | Core: pixel editor UI (`pixel_canvas.dart`, `color_panel.dart`, `pixel_editor_page.dart`) + app_shell integration (tab chip, page routing, save/undo routing, quit prompt, status bar) | completed |
| 4 | Core: tests + verification loop | completed |
| 5 | Advanced: selection tools (rect/lasso/wand) + move/transform | completed (built with core, proven by notifier tests) |
| 6 | Advanced: symmetry, color replace, canvas resize/crop/rotate/flip, .pal I/O | completed (built with core) |
| 7 | Advanced: tests + verification loop + commit | completed |

Progress notes:
- The advanced state machinery was designed together with the core
  notifier, so the whole feature landed as a single commit instead of the
  originally suggested two.
- 58 new tests: `test/pixel_ops_test.dart` + `test/pixel_document_test.dart`
  (35, pure layer) and `test/pixel_editor_test.dart` (23, notifier behavior
  including selection masking, floating moves, symmetry, canvas ops, and
  the Send-to-Phase-1 hand-off).
- Verification loop green: `flutter analyze` clean, full `flutter test`
  suite (169) passing, `flutter build macos --debug` succeeds.
