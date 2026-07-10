import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../logic/island_generator.dart';
import '../logic/island_tiles.dart';
import '../logic/track_topology.dart';
import '../models/block_def.dart';
import '../models/map_scene.dart';
import '../models/port.dart';
import 'app_providers.dart';

/// Interaction tools for the Phase 2 level canvas.
enum LevelTool {
  select('Select'),
  multi('Multi'),
  stamp('Stamp'),
  connect('Connect'),
  insert('Insert'),
  spawn('Spawn'),
  erase('Erase');

  const LevelTool(this.label);
  final String label;
}

/// Reference to a specific port on a placed block.
class PortRef {
  const PortRef(this.placementIndex, this.portIndex);
  final int placementIndex;
  final int portIndex;
}

/// A port hit resolved to a specific outward side. A pass-through port has
/// two sides; [outward] is the one the user actually reached for, so the
/// connected block lands on that side.
class ConnectHit {
  const ConnectHit(this.ref, this.outward);
  final PortRef ref;
  final PortDirection outward;
}

/// A port is a pass-through when flagged bidirectional, or when the block
/// is one cell thick along the port's travel axis: a length-1 straight
/// tile connects straight through, so it should read (and behave) as
/// two-sided even if it was authored with a single-direction port.
bool portIsPassThrough(BlockDef def, Port port) {
  if (port.bidirectional) return true;
  switch (port.direction) {
    case PortDirection.up:
    case PortDirection.down:
      return def.boundingBox.height == 1;
    case PortDirection.left:
    case PortDirection.right:
      return def.boundingBox.width == 1;
    default:
      return false; // diagonal ports are single-sided
  }
}

/// Outward directions a port can connect toward: both sides for a
/// pass-through, otherwise just its facing direction.
List<PortDirection> portOutwardDirections(BlockDef def, Port port) =>
    portIsPassThrough(def, port)
        ? [port.direction, port.direction.opposite]
        : [port.direction];

/// The cells immediately outside a port's strip along [dir], given the
/// owning block's placed origin in grid cells.
List<(int, int)> portOutwardCells(
    int originX, int originY, Port port, PortDirection dir) {
  final (dx, dy) = dir.gridDelta;
  final (ew, eh) = port.cellExtent;
  final sx = originX + port.localGridX;
  final sy = originY + port.localGridY;
  return [
    for (var k = 0; k < ew * eh; k++)
      (sx + (ew > 1 ? k : 0) + dx, sy + (eh > 1 ? k : 0) + dy),
  ];
}

/// The cells a port's strip itself occupies, given the block's placed
/// origin in grid cells.
Set<(int, int)> portStripCells(int originX, int originY, Port port) {
  final (ew, eh) = port.cellExtent;
  final sx = originX + port.localGridX;
  final sy = originY + port.localGridY;
  return {
    for (var k = 0; k < ew * eh; k++)
      (sx + (ew > 1 ? k : 0), sy + (eh > 1 ? k : 0)),
  };
}

/// A block that can snap onto a given source port: which block, via which
/// of its ports, and the resulting placement origin in grid cells.
class ConnectCandidate {
  const ConnectCandidate({
    required this.def,
    required this.bPortIndex,
    required this.gridX,
    required this.gridY,
  });

  final BlockDef def;
  final int bPortIndex;
  final int gridX;
  final int gridY;
}

/// A rectangle in grid cells (used for overlap tests and hit testing).
class CellRect {
  const CellRect(this.x, this.y, this.w, this.h);
  final int x;
  final int y;
  final int w;
  final int h;

  bool contains(int cx, int cy) =>
      cx >= x && cx < x + w && cy >= y && cy < y + h;

  bool overlaps(CellRect o) =>
      x < o.x + o.w && x + w > o.x && y < o.y + o.h && y + h > o.y;
}

/// A pending straight-extension: choosing a straight block in Connect mode
/// previews a run of identical tiles reaching as far as they fit. Each
/// entry in [positions] is a candidate tile origin; clicking the Nth one
/// places the first N.
class ExtendPreview {
  const ExtendPreview({required this.blockId, required this.positions});
  final String blockId;
  final List<(int, int)> positions;
}

/// Editing layers for Phase 2. Only the active layer's blocks are shown
/// solid and are editable; other layers render dimmed for context. Layers
/// are independent planes, so blocks on different layers may overlap.
enum MapLayer {
  island('Island', {BlockCategory.islandTile}),
  track('Track', {BlockCategory.track}),
  decoration('Decoration', {BlockCategory.finishLine}),
  function('Function', <BlockCategory>{});

  const MapLayer(this.label, this.categories);
  final String label;

  /// Block categories that belong to this layer.
  final Set<BlockCategory> categories;

  bool accepts(BlockCategory c) => categories.contains(c);

  /// The layer a category belongs to (track as the safe default).
  static MapLayer forCategory(BlockCategory c) =>
      MapLayer.values.firstWhere((l) => l.accepts(c), orElse: () => track);
}

class LevelEditorState {
  const LevelEditorState({
    this.mapName = 'map_01',
    this.placements = const [],
    this.activeLayer = MapLayer.track,
    this.tool = LevelTool.stamp,
    this.selectedPaletteId,
    this.selectedPlacementIndex,
    this.hoverCell,
    this.extendPreview,
    this.selection = const {},
    this.marquee,
    this.groupDelta,
    this.spawn,
    this.spawnFacing = PortDirection.right,
    this.statusMessage,
  });

  final String mapName;
  final List<BlockPlacement> placements;

  /// The layer currently being edited.
  final MapLayer activeLayer;

  final LevelTool tool;

  /// Palette block chosen for stamping.
  final String? selectedPaletteId;

  /// Index into [placements] of the selected placed block.
  final int? selectedPlacementIndex;

  /// Grid cell under the cursor, for the stamp ghost preview.
  final (int, int)? hoverCell;

  /// Active straight-extension preview, if any.
  final ExtendPreview? extendPreview;

  /// Placements selected for group operations (Multi tool).
  final Set<int> selection;

  /// Live rubber-band rectangle in grid cells (x, y, w, h) while dragging.
  final (int, int, int, int)? marquee;

  /// Live offset applied to the selection during a group drag.
  final (int, int)? groupDelta;

  /// The player start, if placed.
  final SpawnPoint? spawn;

  /// Facing chosen for the next spawn placement / the current spawn.
  final PortDirection spawnFacing;

  final String? statusMessage;

  /// All highlighted placements: the multi-selection plus any single
  /// selection from the other tools.
  Set<int> get highlighted =>
      {...selection, ?selectedPlacementIndex};

  LevelEditorState copyWith({
    String? mapName,
    List<BlockPlacement>? placements,
    MapLayer? activeLayer,
    LevelTool? tool,
    String? Function()? selectedPaletteId,
    int? Function()? selectedPlacementIndex,
    (int, int)? Function()? hoverCell,
    ExtendPreview? Function()? extendPreview,
    Set<int>? selection,
    (int, int, int, int)? Function()? marquee,
    (int, int)? Function()? groupDelta,
    SpawnPoint? Function()? spawn,
    PortDirection? spawnFacing,
    String? Function()? statusMessage,
  }) =>
      LevelEditorState(
        mapName: mapName ?? this.mapName,
        placements: placements ?? this.placements,
        activeLayer: activeLayer ?? this.activeLayer,
        tool: tool ?? this.tool,
        selectedPaletteId: selectedPaletteId != null
            ? selectedPaletteId()
            : this.selectedPaletteId,
        selectedPlacementIndex: selectedPlacementIndex != null
            ? selectedPlacementIndex()
            : this.selectedPlacementIndex,
        hoverCell: hoverCell != null ? hoverCell() : this.hoverCell,
        extendPreview:
            extendPreview != null ? extendPreview() : this.extendPreview,
        selection: selection ?? this.selection,
        marquee: marquee != null ? marquee() : this.marquee,
        groupDelta: groupDelta != null ? groupDelta() : this.groupDelta,
        spawn: spawn != null ? spawn() : this.spawn,
        spawnFacing: spawnFacing ?? this.spawnFacing,
        statusMessage:
            statusMessage != null ? statusMessage() : this.statusMessage,
      );
}

class LevelEditorNotifier extends Notifier<LevelEditorState> {
  @override
  LevelEditorState build() => const LevelEditorState();

  List<BlockDef> get _blocks => ref.read(assetLibraryProvider).blocks;

  BlockDef? _def(String id) => ref.read(assetLibraryProvider).blockById(id);

  /// Bounding rectangle a placement occupies, in grid cells.
  CellRect? rectOf(BlockPlacement p) {
    final def = _def(p.blockId);
    if (def == null) return null;
    return CellRect(
        p.gridX, p.gridY, def.boundingBox.width, def.boundingBox.height);
  }

  /// The layer a placement lives on (from its block's category).
  MapLayer? layerOf(BlockPlacement p) {
    final def = _def(p.blockId);
    return def == null ? null : MapLayer.forCategory(def.category);
  }

  /// Whether a placement belongs to the layer currently being edited.
  bool onActiveLayer(BlockPlacement p) => layerOf(p) == state.activeLayer;

  void setLayer(MapLayer layer) => state = state.copyWith(
        activeLayer: layer,
        selectedPlacementIndex: () => null,
        selection: const {},
        selectedPaletteId: () => null,
        statusMessage: () => 'Editing ${layer.label} layer',
      );

  void setTool(LevelTool tool) => state = state.copyWith(tool: tool);

  void setStatus(String message) =>
      state = state.copyWith(statusMessage: () => message);

  void selectPalette(String id) => state = state.copyWith(
        selectedPaletteId: () => id,
        tool: LevelTool.stamp,
        statusMessage: () => 'Stamp: $id',
      );

  void setHover((int, int)? cell) =>
      state = state.copyWith(hoverCell: () => cell);

  /// Whether a block of [id] placed at (gridX, gridY) would overlap another
  /// placement ON THE SAME LAYER. Layers are independent planes, so an
  /// island tile and a track piece may share cells. Uses bounding boxes.
  bool _wouldOverlap(String id, int gridX, int gridY, {int? ignoreIndex}) {
    final def = _def(id);
    if (def == null) return false;
    final layer = MapLayer.forCategory(def.category);
    final candidate = CellRect(
        gridX, gridY, def.boundingBox.width, def.boundingBox.height);
    for (var i = 0; i < state.placements.length; i++) {
      if (i == ignoreIndex) continue;
      if (layerOf(state.placements[i]) != layer) continue;
      final other = rectOf(state.placements[i]);
      if (other != null && candidate.overlaps(other)) return true;
    }
    return false;
  }

  /// Whether a block of [id] at (gridX, gridY) lies fully inside the level
  /// grid.
  bool _inBounds(String id, int gridX, int gridY) {
    final def = _def(id);
    if (def == null) return false;
    return gridX >= 0 &&
        gridY >= 0 &&
        gridX + def.boundingBox.width <= GridConstants.levelGridCols &&
        gridY + def.boundingBox.height <= GridConstants.levelGridRows;
  }

  /// A block fits if it is in bounds and does not overlap anything.
  bool _fits(String id, int gridX, int gridY) =>
      _inBounds(id, gridX, gridY) && !_wouldOverlap(id, gridX, gridY);

  // --- Port-driven connection -----------------------------------------------

  /// World strip origin (top-left cell) of a placement's port.
  (int, int) _portWorldOrigin(BlockPlacement p, Port port) =>
      (p.gridX + port.localGridX, p.gridY + port.localGridY);

  /// Set of cells covered by placements on the active layer (for occupancy
  /// and free-port tests, which operate within the current layer).
  Set<(int, int)> occupiedCells() {
    final cells = <(int, int)>{};
    for (final p in state.placements) {
      if (!onActiveLayer(p)) continue;
      final r = rectOf(p);
      if (r == null) continue;
      for (var y = r.y; y < r.y + r.h; y++) {
        for (var x = r.x; x < r.x + r.w; x++) {
          cells.add((x, y));
        }
      }
    }
    return cells;
  }

  /// Whether a specific outward side of a port is already occupied (so no
  /// "+" is shown and no connection is offered on that side).
  bool isSideConnected(
      BlockPlacement p, Port port, PortDirection dir, Set<(int, int)> occ) {
    for (final cell in portOutwardCells(p.gridX, p.gridY, port, dir)) {
      if (occ.contains(cell)) return true;
    }
    return false;
  }

  /// Free outward sides of a port (0, 1, or 2 sides for a pass-through).
  List<PortDirection> freeSides(
      int placementIndex, int portIndex, Set<(int, int)> occ) {
    final p = state.placements[placementIndex];
    final def = _def(p.blockId);
    if (def == null) return const [];
    final port = def.ports[portIndex];
    return [
      for (final dir in portOutwardDirections(def, port))
        if (!isSideConnected(p, port, dir, occ)) dir,
    ];
  }

  /// Hit test for Connect mode, resolved to a specific outward side.
  /// Matches a tap on the outward "+" cell of a free side first (so each
  /// side of a pass-through is independently clickable), then a tap on the
  /// port strip itself (picking a free side).
  ConnectHit? connectPortAt(int cellX, int cellY) {
    final occ = occupiedCells();
    // Priority 1: the outward "+" cell of a specific free side.
    for (var i = state.placements.length - 1; i >= 0; i--) {
      final p = state.placements[i];
      final def = _def(p.blockId);
      if (def == null) continue;
      for (var j = 0; j < def.ports.length; j++) {
        final port = def.ports[j];
        for (final dir in portOutwardDirections(def, port)) {
          if (isSideConnected(p, port, dir, occ)) continue;
          for (final (ox, oy)
              in portOutwardCells(p.gridX, p.gridY, port, dir)) {
            if (ox == cellX && oy == cellY) {
              return ConnectHit(PortRef(i, j), dir);
            }
          }
        }
      }
    }
    // Priority 2: the port strip cell itself -> pick a free side.
    final ref = portAt(cellX, cellY);
    if (ref != null) {
      final sides = freeSides(ref.placementIndex, ref.portIndex, occ);
      if (sides.isNotEmpty) return ConnectHit(ref, sides.first);
    }
    return null;
  }

  /// The port (if any) whose strip covers the given cell, searched
  /// top-most placement first.
  PortRef? portAt(int cellX, int cellY) {
    for (var i = state.placements.length - 1; i >= 0; i--) {
      final p = state.placements[i];
      if (!onActiveLayer(p)) continue;
      final def = _def(p.blockId);
      if (def == null) continue;
      for (var j = 0; j < def.ports.length; j++) {
        final port = def.ports[j];
        final (sx, sy) = _portWorldOrigin(p, port);
        final (ew, eh) = port.cellExtent;
        if (cellX >= sx &&
            cellX < sx + ew &&
            cellY >= sy &&
            cellY < sy + eh) {
          return PortRef(i, j);
        }
      }
    }
    return null;
  }

  /// Blocks from the library that can snap onto the given [hit]: they must
  /// have a port able to face back toward the hit's outward direction with
  /// the same span, and the resulting placement must not overlap anything.
  /// One candidate per block (its first fitting port).
  List<ConnectCandidate> connectCandidates(ConnectHit hit) {
    final p = state.placements[hit.ref.placementIndex];
    final sourceDef = _def(p.blockId);
    if (sourceDef == null) return const [];
    final sourcePort = sourceDef.ports[hit.ref.portIndex];
    final (dx, dy) = hit.outward.gridDelta;
    final (sx, sy) = _portWorldOrigin(p, sourcePort);
    final needed = hit.outward.opposite;

    final candidates = <ConnectCandidate>[];
    for (final def in _blocks) {
      // Ports are isolated per layer: only offer blocks of the layer being
      // edited, so a track port never connects to an island tile.
      if (MapLayer.forCategory(def.category) != state.activeLayer) continue;
      for (var j = 0; j < def.ports.length; j++) {
        final bPort = def.ports[j];
        final canFace = portOutwardDirections(def, bPort).contains(needed);
        if (!canFace || bPort.span != sourcePort.span) continue;
        // Place B so its port strip aligns just outside the source strip
        // on the chosen side.
        final bx = sx + dx - bPort.localGridX;
        final by = sy + dy - bPort.localGridY;
        if (!_fits(def.id, bx, by)) continue;
        candidates.add(ConnectCandidate(
            def: def, bPortIndex: j, gridX: bx, gridY: by));
        break; // first fitting port per block
      }
    }
    return candidates;
  }

  /// Places the chosen candidate, snapping it onto the source port.
  void placeConnected(ConnectCandidate candidate) {
    if (!_fits(candidate.def.id, candidate.gridX, candidate.gridY)) {
      state = state.copyWith(
          statusMessage: () =>
              'Cannot connect ${candidate.def.id}: no room here');
      return;
    }
    final placement = BlockPlacement(
        blockId: candidate.def.id,
        gridX: candidate.gridX,
        gridY: candidate.gridY);
    state = state.copyWith(
      placements: [...state.placements, placement],
      selectedPlacementIndex: () => state.placements.length,
      statusMessage: () =>
          'Connected ${candidate.def.id} at (${candidate.gridX}, ${candidate.gridY})',
    );
  }

  /// A block is a straight tile if it is a plain two-way segment: either a
  /// single bidirectional (pass-through) port, or exactly two ports that
  /// are symmetric -- opposite directions with the same span. Corners,
  /// forks and junctions are excluded, so only straights auto-extend.
  bool _isStraightTile(BlockDef def) {
    if (def.ports.length == 1) {
      return portIsPassThrough(def, def.ports.first);
    }
    if (def.ports.length == 2) {
      final a = def.ports[0];
      final b = def.ports[1];
      return a.span == b.span && a.direction == b.direction.opposite;
    }
    return false;
  }

  /// Whether [def] is a straight tile that can continue a run toward
  /// [hit.outward] with the same span as the source port. Only true
  /// straights (see [_isStraightTile]) place many at once.
  bool _isStraightExtender(BlockDef def, ConnectHit hit) {
    if (!_isStraightTile(def)) return false;
    final sourceDef = _def(state.placements[hit.ref.placementIndex].blockId);
    if (sourceDef == null) return false;
    final span = sourceDef.ports[hit.ref.portIndex].span;
    for (final port in def.ports) {
      if (port.span == span &&
          portOutwardDirections(def, port).contains(hit.outward)) {
        return true;
      }
    }
    return false;
  }

  /// Origins of a straight run of [blockId] starting from the first snapped
  /// position and stepping one tile-length along [hit.outward] until a tile
  /// no longer fits (obstacle or canvas edge). Bounds are supplied by the
  /// caller so this logic stays UI-independent.
  List<(int, int)> straightRunPositions(
    ConnectHit hit,
    ConnectCandidate first, {
    required int cols,
    required int rows,
    int maxSteps = 200,
  }) {
    final def = first.def;
    final (dx, dy) = hit.outward.gridDelta;
    // Tile length along the run axis.
    final step = (dx != 0) ? def.boundingBox.width : def.boundingBox.height;
    final positions = <(int, int)>[];
    var x = first.gridX;
    var y = first.gridY;
    for (var k = 0; k < maxSteps; k++) {
      final inBounds = x >= 0 &&
          y >= 0 &&
          x + def.boundingBox.width <= cols &&
          y + def.boundingBox.height <= rows;
      if (!inBounds || _wouldOverlap(def.id, x, y)) break;
      positions.add((x, y));
      x += dx * step;
      y += dy * step;
    }
    return positions;
  }

  /// Handles a chosen connection candidate. Straight extenders enter an
  /// extension preview (place many at once); anything else places one tile.
  void chooseConnection(
    ConnectHit hit,
    ConnectCandidate candidate, {
    required int cols,
    required int rows,
  }) {
    if (_isStraightExtender(candidate.def, hit)) {
      final positions = straightRunPositions(hit, candidate,
          cols: cols, rows: rows);
      if (positions.isEmpty) {
        placeConnected(candidate);
        return;
      }
      state = state.copyWith(
        extendPreview: () =>
            ExtendPreview(blockId: candidate.def.id, positions: positions),
        statusMessage: () => 'Click a + to place up to ${positions.length} '
            '${candidate.def.id} tiles',
      );
    } else {
      placeConnected(candidate);
    }
  }

  /// Places the first [count] tiles of the active extension preview.
  void commitExtend(int count) {
    final preview = state.extendPreview;
    if (preview == null) return;
    final n = count.clamp(1, preview.positions.length);
    final additions = [
      for (var i = 0; i < n; i++)
        BlockPlacement(
            blockId: preview.blockId,
            gridX: preview.positions[i].$1,
            gridY: preview.positions[i].$2),
    ];
    state = state.copyWith(
      placements: [...state.placements, ...additions],
      extendPreview: () => null,
      selectedPlacementIndex: () => state.placements.length + n - 1,
      statusMessage: () => 'Placed $n ${preview.blockId} tiles',
    );
  }

  /// Index (1-based count) of the extension ghost covering the cell, or
  /// null. Clicking ghost K means "place K tiles".
  int? extendCountAt(int cellX, int cellY) {
    final preview = state.extendPreview;
    if (preview == null) return null;
    final def = _def(preview.blockId);
    if (def == null) return null;
    for (var i = 0; i < preview.positions.length; i++) {
      final (px, py) = preview.positions[i];
      if (cellX >= px &&
          cellX < px + def.boundingBox.width &&
          cellY >= py &&
          cellY < py + def.boundingBox.height) {
        return i + 1;
      }
    }
    return null;
  }

  void cancelExtend() {
    if (state.extendPreview != null) {
      state = state.copyWith(
          extendPreview: () => null, statusMessage: () => 'Cancelled');
    }
  }

  void stampAt(int gridX, int gridY) {
    final id = state.selectedPaletteId;
    if (id == null) {
      state = state.copyWith(
          statusMessage: () => 'Select a palette block first');
      return;
    }
    final (x, y) = stampOrigin(id, gridX, gridY);
    if (x == null || y == null) return;
    if (_wouldOverlap(id, x, y)) {
      state = state.copyWith(
          statusMessage: () => 'Cannot place $id here: overlaps another block');
      return;
    }
    final placement = BlockPlacement(blockId: id, gridX: x, gridY: y);
    state = state.copyWith(
      placements: [...state.placements, placement],
      selectedPlacementIndex: () => state.placements.length,
      statusMessage: () => 'Placed $id at ($x, $y)',
    );
  }

  /// The clamped top-left origin for stamping [id] near a hovered/clicked
  /// cell, so the whole block stays inside the grid. Returns (null, null)
  /// when the block is larger than the grid. Shared by the stamp ghost and
  /// stampAt so the preview always matches the actual placement.
  (int?, int?) stampOrigin(String id, int gridX, int gridY) {
    final def = _def(id);
    if (def == null) return (null, null);
    final maxX = GridConstants.levelGridCols - def.boundingBox.width;
    final maxY = GridConstants.levelGridRows - def.boundingBox.height;
    if (maxX < 0 || maxY < 0) return (null, null);
    return (gridX.clamp(0, maxX), gridY.clamp(0, maxY));
  }

  /// Topmost placement on the active layer whose bounding box contains the
  /// cell, or null. Other layers are not selectable/erasable while hidden
  /// behind the active one.
  int? _placementAt(int gridX, int gridY) {
    for (var i = state.placements.length - 1; i >= 0; i--) {
      if (!onActiveLayer(state.placements[i])) continue;
      final r = rectOf(state.placements[i]);
      if (r != null && r.contains(gridX, gridY)) return i;
    }
    return null;
  }

  /// Selects a placement directly (used by the diagnostics panel).
  void selectPlacement(int index) => state = state.copyWith(
        selectedPlacementIndex: () => index,
        statusMessage: () => index >= 0 && index < state.placements.length
            ? 'Selected ${state.placements[index].blockId}'
            : null,
      );

  void selectAt(int gridX, int gridY) {
    final index = _placementAt(gridX, gridY);
    state = state.copyWith(
      selectedPlacementIndex: () => index,
      statusMessage: () => index == null
          ? null
          : 'Selected ${state.placements[index].blockId}',
    );
  }

  void eraseAt(int gridX, int gridY) {
    final index = _placementAt(gridX, gridY);
    if (index == null) return;
    _removeAt(index);
  }

  void deleteSelected() {
    if (state.selection.isNotEmpty) {
      _removeIndices(state.selection);
      return;
    }
    final index = state.selectedPlacementIndex;
    if (index != null) _removeAt(index);
  }

  void _removeAt(int index) {
    final removed = state.placements[index].blockId;
    final placements = [...state.placements]..removeAt(index);
    state = state.copyWith(
      placements: placements,
      selectedPlacementIndex: () => null,
      selection: const {},
      statusMessage: () => 'Removed $removed',
    );
  }

  void _removeIndices(Set<int> indices) {
    final placements = [
      for (var i = 0; i < state.placements.length; i++)
        if (!indices.contains(i)) state.placements[i],
    ];
    state = state.copyWith(
      placements: placements,
      selection: const {},
      selectedPlacementIndex: () => null,
      statusMessage: () => 'Removed ${indices.length} blocks',
    );
  }

  void clearAll() => state = state.copyWith(
        placements: const [],
        selectedPlacementIndex: () => null,
        selection: const {},
        statusMessage: () => 'Cleared all placements',
      );

  // --- Multi-select (marquee) and group drag --------------------------------

  (int, int)? _multiAnchor;
  bool _multiMoving = false;

  /// Placements whose bounding box intersects the cell rectangle.
  Set<int> _placementsInRect(CellRect area) {
    final hit = <int>{};
    for (var i = 0; i < state.placements.length; i++) {
      final r = rectOf(state.placements[i]);
      if (r != null && r.overlaps(area)) hit.add(i);
    }
    return hit;
  }

  /// Selects a single placement (Multi-tool tap), or clears if empty.
  void selectSingleAt(int cellX, int cellY) {
    final index = _placementAt(cellX, cellY);
    state = state.copyWith(
      selection: index == null ? const {} : {index},
      selectedPlacementIndex: () => index,
    );
  }

  void multiDragStart(int cellX, int cellY) {
    _multiAnchor = (cellX, cellY);
    final onSelected = state.selection.any((i) {
      final r = rectOf(state.placements[i]);
      return r != null && r.contains(cellX, cellY);
    });
    if (onSelected) {
      _multiMoving = true;
      state = state.copyWith(groupDelta: () => (0, 0));
    } else {
      _multiMoving = false;
      state = state.copyWith(
        selection: const {},
        marquee: () => (cellX, cellY, 1, 1),
      );
    }
  }

  void multiDragUpdate(int cellX, int cellY) {
    final anchor = _multiAnchor;
    if (anchor == null) return;
    if (_multiMoving) {
      state = state.copyWith(
          groupDelta: () => (cellX - anchor.$1, cellY - anchor.$2));
    } else {
      final x0 = anchor.$1 < cellX ? anchor.$1 : cellX;
      final y0 = anchor.$2 < cellY ? anchor.$2 : cellY;
      final w = (cellX - anchor.$1).abs() + 1;
      final h = (cellY - anchor.$2).abs() + 1;
      state = state.copyWith(
        marquee: () => (x0, y0, w, h),
        selection: _placementsInRect(CellRect(x0, y0, w, h)),
      );
    }
  }

  void multiDragEnd({required int cols, required int rows}) {
    final wasMoving = _multiMoving;
    final delta = state.groupDelta;
    _multiAnchor = null;
    _multiMoving = false;
    if (wasMoving && delta != null) {
      _applyGroupMove(delta.$1, delta.$2, cols: cols, rows: rows);
      state = state.copyWith(groupDelta: () => null);
    } else {
      state = state.copyWith(marquee: () => null);
    }
  }

  void _applyGroupMove(int dx, int dy,
      {required int cols, required int rows}) {
    final sel = state.selection;
    if (sel.isEmpty || (dx == 0 && dy == 0)) return;

    final movedRects = <int, CellRect>{};
    for (final i in sel) {
      final p = state.placements[i];
      final def = _def(p.blockId);
      if (def == null) continue;
      final nx = p.gridX + dx;
      final ny = p.gridY + dy;
      if (nx < 0 ||
          ny < 0 ||
          nx + def.boundingBox.width > cols ||
          ny + def.boundingBox.height > rows) {
        state = state.copyWith(
            statusMessage: () => 'Move would leave the canvas');
        return;
      }
      movedRects[i] =
          CellRect(nx, ny, def.boundingBox.width, def.boundingBox.height);
    }
    // Reject if any moved block lands on a non-selected block.
    for (final entry in movedRects.entries) {
      for (var j = 0; j < state.placements.length; j++) {
        if (sel.contains(j)) continue;
        final other = rectOf(state.placements[j]);
        if (other != null && entry.value.overlaps(other)) {
          state = state.copyWith(
              statusMessage: () => 'Move would overlap another block');
          return;
        }
      }
    }
    final placements = [
      for (var i = 0; i < state.placements.length; i++)
        if (sel.contains(i))
          state.placements[i].copyWith(
              gridX: state.placements[i].gridX + dx,
              gridY: state.placements[i].gridY + dy)
        else
          state.placements[i],
    ];
    state = state.copyWith(
      placements: placements,
      statusMessage: () => 'Moved ${sel.length} blocks',
    );
  }

  // --- Insert / delete straight at a seam (auto-shift downstream) -----------

  List<Seam> _seams() => findSeams(state.placements, _def);

  /// A direction is "forward" if it points right or down; inserting/removing
  /// keeps the near (up/left) side fixed and shifts the far side.
  static bool _isForward(PortDirection d) {
    final (dx, dy) = d.gridDelta;
    return dy > 0 || (dy == 0 && dx > 0);
  }

  /// Seams eligible for an insert marker: one per boundary (the forward
  /// direction), whose near side has a same-span straight to insert.
  List<Seam> insertSeams() => _seams()
      .where((s) =>
          _isForward(s.dir) && onActiveLayer(state.placements[s.nearIndex]))
      .toList();

  /// Pixel-centre of each insert seam's boundary, for drawing "+" markers.
  List<(int, int)> insertSeamBoundaryCells() {
    final cells = <(int, int)>[];
    for (final s in insertSeams()) {
      final near = state.placements[s.nearIndex];
      final def = _def(near.blockId);
      if (def == null) continue;
      final outward = portOutwardCells(
          near.gridX, near.gridY, def.ports[s.nearPortIndex], s.dir);
      cells.add(outward[outward.length ~/ 2]);
    }
    return cells;
  }

  /// The forward seam whose boundary contains the tapped cell, if any.
  Seam? insertSeamAt(int cellX, int cellY) {
    for (final s in insertSeams()) {
      final near = state.placements[s.nearIndex];
      final def = _def(near.blockId);
      if (def == null) continue;
      final outward = portOutwardCells(
          near.gridX, near.gridY, def.ports[s.nearPortIndex], s.dir);
      if (outward.contains((cellX, cellY))) return s;
    }
    return null;
  }

  /// First library block that can bridge a gap along [dir] with the given
  /// [span]: it needs a port facing back (dir.opposite) and one facing on
  /// (dir), both of matching span. Returns the block and its near-port index.
  (BlockDef, int)? _straightConnector(PortDirection dir, int span) {
    for (final def in _blocks) {
      // Same-layer isolation: only bridge with blocks of the active layer.
      if (MapLayer.forCategory(def.category) != state.activeLayer) continue;
      if (!_isStraightTile(def)) continue;
      final nearIdx = def.ports.indexWhere((p) =>
          p.span == span &&
          portOutwardDirections(def, p).contains(dir.opposite));
      if (nearIdx == -1) continue;
      final hasFar = def.ports.any((p) =>
          p.span == span && portOutwardDirections(def, p).contains(dir));
      if (!hasFar) continue;
      return (def, nearIdx);
    }
    return null;
  }

  String? _validateLayout(List<BlockPlacement> list) {
    final rects = <CellRect>[];
    for (final p in list) {
      final def = _def(p.blockId);
      if (def == null) continue;
      if (p.gridX < 0 ||
          p.gridY < 0 ||
          p.gridX + def.boundingBox.width > GridConstants.levelGridCols ||
          p.gridY + def.boundingBox.height > GridConstants.levelGridRows) {
        return 'Shift would leave the grid';
      }
      rects.add(CellRect(
          p.gridX, p.gridY, def.boundingBox.width, def.boundingBox.height));
    }
    for (var a = 0; a < rects.length; a++) {
      for (var b = a + 1; b < rects.length; b++) {
        if (rects[a].overlaps(rects[b])) return 'Shift would overlap blocks';
      }
    }
    return null;
  }

  /// Inserts a straight at [seam], pushing the far-side connected component
  /// outward by one tile-length and dropping the straight into the gap.
  void insertStraightAtSeam(Seam seam) {
    final placements = state.placements;
    final adj = buildAdjacency(placements.length, _seams());
    final far = reachable(adj, seam.farIndex,
        edgeA: seam.nearIndex, edgeB: seam.farIndex);
    if (far.contains(seam.nearIndex)) {
      state = state.copyWith(
          statusMessage: () => 'Cannot insert into a closed loop');
      return;
    }
    final conn = _straightConnector(seam.dir, seam.span);
    if (conn == null) {
      state = state.copyWith(
          statusMessage: () =>
              'No straight tile of span ${seam.span} to insert');
      return;
    }
    final (sdef, straightNearPort) = conn;
    final (dx, dy) = seam.dir.gridDelta;
    final length =
        dx != 0 ? sdef.boundingBox.width : sdef.boundingBox.height;

    final near = state.placements[seam.nearIndex];
    final ndef = _def(near.blockId)!;
    final outward = portOutwardCells(
        near.gridX, near.gridY, ndef.ports[seam.nearPortIndex], seam.dir);
    final (ox, oy) = outward.first; // min corner of the gap
    final straightX = ox - sdef.ports[straightNearPort].localGridX;
    final straightY = oy - sdef.ports[straightNearPort].localGridY;

    final newList = <BlockPlacement>[
      for (var i = 0; i < placements.length; i++)
        if (far.contains(i))
          placements[i].copyWith(
              gridX: placements[i].gridX + dx * length,
              gridY: placements[i].gridY + dy * length)
        else
          placements[i],
      BlockPlacement(blockId: sdef.id, gridX: straightX, gridY: straightY),
    ];

    final err = _validateLayout(newList);
    if (err != null) {
      state = state.copyWith(statusMessage: () => err);
      return;
    }
    state = state.copyWith(
      placements: newList,
      selectedPlacementIndex: () => newList.length - 1,
      selection: const {},
      statusMessage: () => 'Inserted ${sdef.id} at the seam',
    );
  }

  /// Deletes the block at [index]; if it is a straight connected on two
  /// opposite sides, the far-side component slides back to close the gap.
  void deleteStraightAndClose(int index) {
    final def = _def(state.placements[index].blockId);
    if (def == null) {
      _removeAt(index);
      return;
    }
    final allSeams = _seams();
    Seam? forward;
    for (final s in allSeams) {
      if (s.nearIndex == index && _isForward(s.dir)) {
        forward = s;
        break;
      }
    }
    Seam? back;
    if (forward != null) {
      for (final s in allSeams) {
        if (s.nearIndex == index && s.dir == forward.dir.opposite) {
          back = s;
          break;
        }
      }
    }
    // Not a through-straight (dangling or unconnected): plain remove.
    if (forward == null || back == null) {
      _removeAt(index);
      return;
    }

    final (dx, dy) = forward.dir.gridDelta;
    final length = dx != 0 ? def.boundingBox.width : def.boundingBox.height;
    final adjNoIndex = buildAdjacency(
        state.placements.length,
        allSeams
            .where((s) => s.nearIndex != index && s.farIndex != index)
            .toList());
    final far = reachable(adjNoIndex, forward.farIndex);
    if (far.contains(back.farIndex)) {
      // Removing would leave a loop; cannot close cleanly, just remove.
      _removeAt(index);
      state = state.copyWith(
          statusMessage: () => 'Removed straight (loop: gap left open)');
      return;
    }

    final newList = <BlockPlacement>[
      for (var i = 0; i < state.placements.length; i++)
        if (i != index)
          if (far.contains(i))
            state.placements[i].copyWith(
                gridX: state.placements[i].gridX - dx * length,
                gridY: state.placements[i].gridY - dy * length)
          else
            state.placements[i],
    ];
    final err = _validateLayout(newList);
    if (err != null) {
      state = state.copyWith(statusMessage: () => err);
      return;
    }
    state = state.copyWith(
      placements: newList,
      selectedPlacementIndex: () => null,
      selection: const {},
      statusMessage: () => 'Removed straight and closed the gap',
    );
  }

  // --- Spawn point and export -----------------------------------------------

  void setSpawnFacing(PortDirection dir) {
    final current = state.spawn;
    state = state.copyWith(
      spawnFacing: dir,
      spawn: current == null
          ? null
          : () => SpawnPoint(
              gridX: current.gridX,
              gridY: current.gridY,
              facingAngle: dir.angle),
    );
  }

  void setSpawnAt(int gridX, int gridY) {
    state = state.copyWith(
      spawn: () => SpawnPoint(
          gridX: gridX, gridY: gridY, facingAngle: state.spawnFacing.angle),
      statusMessage: () =>
          'Spawn at ($gridX, $gridY) facing ${state.spawnFacing.jsonValue}',
    );
  }

  void clearSpawn() =>
      state = state.copyWith(spawn: () => null, statusMessage: () => 'Spawn cleared');

  // --- Auto island generation ------------------------------------------------

  /// Island tile ids grouped by their 8-direction signature key.
  Map<String, List<String>> _islandTilesBySignature() {
    final map = <String, List<String>>{};
    for (final def in ref.read(assetLibraryProvider).blocks) {
      if (def.category != BlockCategory.islandTile) continue;
      final key = sigKey(def.ports.map((p) => p.direction).toSet());
      map.putIfAbsent(key, () => []).add(def.id);
    }
    return map;
  }

  /// Grows an island around the track and autotiles it onto the island
  /// layer, replacing any existing island placements. Requires the full
  /// convex tile set (concave corners unlock inward notches).
  void generateIsland() {
    final tiles = _islandTilesBySignature();
    final missingConvex = [
      for (final s in convexSetSignatures)
        if (!tiles.containsKey(sigKey(s))) islandKindLabel(s),
    ];
    if (missingConvex.isNotEmpty) {
      state = state.copyWith(
          statusMessage: () =>
              'Cannot generate: missing ${missingConvex.toSet().join(", ")} tile(s)');
      return;
    }

    // Track footprint (only the track layer defines the island shape).
    final footprint = <(int, int)>{};
    for (final p in state.placements) {
      if (layerOf(p) != MapLayer.track) continue;
      final r = rectOf(p);
      if (r == null) continue;
      for (var y = r.y; y < r.y + r.h; y++) {
        for (var x = r.x; x < r.x + r.w; x++) {
          footprint.add((x, y));
        }
      }
    }
    if (footprint.isEmpty) {
      state = state.copyWith(
          statusMessage: () => 'Place some track first, then generate');
      return;
    }

    final grid = dilateRegion(
      footprint,
      cols: GridConstants.levelGridCols,
      rows: GridConstants.levelGridRows,
      padding: GridConstants.islandPaddingCells,
    );
    final result = autotileIsland(grid: grid, tileIdsBySignature: tiles);

    // Replace island-layer placements, keep everything else.
    final kept = [
      for (final p in state.placements)
        if (layerOf(p) != MapLayer.island) p,
    ];
    state = state.copyWith(
      placements: [...kept, ...result.placements],
      selection: const {},
      selectedPlacementIndex: () => null,
      statusMessage: () => result.unmatched == 0
          ? 'Generated ${result.placements.length} island tiles'
          : 'Generated ${result.placements.length} tiles; ${result.unmatched} '
              'cell(s) unmatched (add concave corners for notches)',
    );
  }

  void setMapName(String name) => state = state.copyWith(mapName: name);

  /// Builds the exportable scene from the current editor state. Island
  /// terrain is empty until the island generator is added.
  MapScene buildScene() => MapScene(
        mapName: state.mapName,
        spawnPoint: state.spawn ??
            const SpawnPoint(gridX: 0, gridY: 0, facingAngle: 0),
        placements: state.placements,
        islandTerrain: const [],
      );

  /// Exports the scene to a map_NN.json file chosen by the user.
  Future<void> exportMap() async {
    if (state.placements.isEmpty) {
      state = state.copyWith(statusMessage: () => 'Nothing to export');
      return;
    }
    if (state.spawn == null) {
      state = state.copyWith(
          statusMessage: () => 'Set a spawn point before exporting');
      return;
    }
    final jsonText =
        const JsonEncoder.withIndent('  ').convert(buildScene().toJson());
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export map scene',
      fileName: '${state.mapName}.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: Uint8List.fromList(utf8.encode(jsonText)),
    );
    state = state.copyWith(
        statusMessage: () =>
            path == null ? 'Export cancelled' : 'Exported to $path');
  }
}

final levelEditorProvider =
    NotifierProvider<LevelEditorNotifier, LevelEditorState>(
        LevelEditorNotifier.new);
