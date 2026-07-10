import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../models/block_def.dart';
import '../../models/map_scene.dart';
import '../../state/app_providers.dart';
import '../../state/level_editor_providers.dart';
import '../widgets/block_thumbnail.dart';
import '../widgets/port_marker.dart';

/// The Phase 2 grid canvas: an InteractiveViewer holding a fixed grid onto
/// which palette blocks are stamped. Renders placed sprites from the packed
/// sheet, their ports, the selection highlight, and a stamp ghost preview.
class LevelCanvas extends ConsumerStatefulWidget {
  const LevelCanvas({super.key});

  /// Canvas size in grid cells. Large enough to lay out a full track;
  /// InteractiveViewer pans and zooms within it.
  static const int cols = GridConstants.levelGridCols;
  static const int rows = GridConstants.levelGridRows;

  @override
  ConsumerState<LevelCanvas> createState() => _LevelCanvasState();
}

class _LevelCanvasState extends ConsumerState<LevelCanvas> {
  static const _cell = GridConstants.cellSize;

  final TransformationController _transform = TransformationController();
  bool _centered = false;

  @override
  void initState() {
    super.initState();
    // Start the view centred on the large canvas so a track can grow in
    // every direction before reaching an edge.
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnce());
  }

  void _centerOnce() {
    if (_centered || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    const canvasW = LevelCanvas.cols * _cell;
    const canvasH = LevelCanvas.rows * _cell;
    _transform.value = Matrix4.translationValues(
      box.size.width / 2 - canvasW / 2,
      box.size.height / 2 - canvasH / 2,
      0,
    );
    _centered = true;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  (int, int) _toCell(Offset local) => (
        (local.dx / _cell).floor().clamp(0, LevelCanvas.cols - 1),
        (local.dy / _cell).floor().clamp(0, LevelCanvas.rows - 1),
      );

  /// Connect mode: tapping a free port opens a menu of blocks that can
  /// snap onto it (matching opposite direction and span). Choosing one
  /// places it snapped to the port.
  Future<void> _handleConnectTap(
    BuildContext context,
    LevelEditorNotifier notifier,
    int cellX,
    int cellY,
    Offset globalPosition,
  ) async {
    final hit = notifier.connectPortAt(cellX, cellY);
    if (hit == null) {
      notifier.setStatus('Tap a port (the + markers) to connect a block');
      return;
    }
    final candidates = notifier.connectCandidates(hit);
    if (candidates.isEmpty) {
      notifier.setStatus('No compatible block fits this port');
      return;
    }
    final library = ref.read(assetLibraryProvider);
    final chosen = await showMenu<ConnectCandidate>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      items: [
        for (final c in candidates)
          PopupMenuItem<ConnectCandidate>(
            value: c,
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: library.sheetImage == null
                      ? const Icon(Icons.widgets_outlined, size: 20)
                      : BlockThumbnail(
                          image: library.sheetImage!,
                          rect: c.def.spriteSheetRect,
                        ),
                ),
                const SizedBox(width: 10),
                Text(c.def.id),
              ],
            ),
          ),
      ],
    );
    if (chosen != null) {
      notifier.chooseConnection(
        hit,
        chosen,
        cols: LevelCanvas.cols,
        rows: LevelCanvas.rows,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(levelEditorProvider);
    final library = ref.watch(assetLibraryProvider);
    final notifier = ref.read(levelEditorProvider.notifier);
    // Stamp/erase paint on drag; Multi drags to marquee-select or move the
    // selection. Select and Connect leave drags to InteractiveViewer to pan.
    final usesDrag = state.tool == LevelTool.stamp ||
        state.tool == LevelTool.erase ||
        state.tool == LevelTool.multi;

    // Occupancy for drawing "+" on free ports in Connect mode.
    final occupied =
        state.tool == LevelTool.connect ? notifier.occupiedCells() : null;

    // Seam markers for the Insert tool.
    final insertMarkers = state.tool == LevelTool.insert
        ? notifier.insertSeamBoundaryCells()
        : null;

    void handleTap(Offset local, Offset global) {
      final (x, y) = _toCell(local);
      switch (state.tool) {
        case LevelTool.stamp:
          notifier.stampAt(x, y);
        case LevelTool.erase:
          notifier.eraseAt(x, y);
        case LevelTool.select:
          notifier.selectAt(x, y);
        case LevelTool.multi:
          notifier.selectSingleAt(x, y);
        case LevelTool.insert:
          final seam = notifier.insertSeamAt(x, y);
          if (seam != null) {
            notifier.insertStraightAtSeam(seam);
          } else {
            notifier.setStatus('Tap a + on a seam to insert a straight');
          }
        case LevelTool.spawn:
          notifier.setSpawnAt(x, y);
        case LevelTool.connect:
          // While a straight-extension preview is active, a tap picks how
          // many tiles to place (ghost N -> place N), or cancels.
          if (state.extendPreview != null) {
            final count = notifier.extendCountAt(x, y);
            if (count != null) {
              notifier.commitExtend(count);
            } else {
              notifier.cancelExtend();
            }
          } else {
            _handleConnectTap(context, notifier, x, y, global);
          }
      }
    }

    void handleDrag(Offset local) {
      final (x, y) = _toCell(local);
      if (state.tool == LevelTool.stamp) {
        notifier.stampAt(x, y);
      } else if (state.tool == LevelTool.erase) {
        notifier.eraseAt(x, y);
      } else if (state.tool == LevelTool.multi) {
        notifier.multiDragUpdate(x, y);
      }
    }

    // The MouseRegion sits INSIDE the InteractiveViewer so hover positions
    // are in the same scene coordinate space as taps; otherwise a panned or
    // zoomed view makes the stamp preview land on a different cell than the
    // actual placement.
    return InteractiveViewer(
      transformationController: _transform,
      constrained: false,
      minScale: 0.2,
      maxScale: 10,
      boundaryMargin: const EdgeInsets.all(400),
      child: MouseRegion(
        onHover: state.tool == LevelTool.stamp
            ? (event) => notifier.setHover(_toCell(event.localPosition))
            : null,
        onExit: (_) => notifier.setHover(null),
        child: GestureDetector(
          onTapUp: (d) => handleTap(d.localPosition, d.globalPosition),
          // Stamp/erase paint on drag; Multi marquee-selects or moves the
          // selection; select and connect leave drags to InteractiveViewer.
          onPanStart: !usesDrag
              ? null
              : (d) {
                  final (x, y) = _toCell(d.localPosition);
                  if (state.tool == LevelTool.multi) {
                    notifier.multiDragStart(x, y);
                  } else {
                    handleDrag(d.localPosition);
                  }
                },
          onPanUpdate: !usesDrag ? null : (d) => handleDrag(d.localPosition),
          onPanEnd: state.tool != LevelTool.multi
              ? null
              : (_) => notifier.multiDragEnd(
                  cols: LevelCanvas.cols, rows: LevelCanvas.rows),
          child: CustomPaint(
            size: const Size(
                LevelCanvas.cols * _cell, LevelCanvas.rows * _cell),
            painter: _LevelPainter(
              blocks: library,
              placements: state.placements,
              tool: state.tool,
              hoverCell: state.hoverCell,
              stampId: state.selectedPaletteId,
              rectOf: notifier.rectOf,
              occupied: occupied,
              extendPreview: state.extendPreview,
              selection: state.highlighted,
              marquee: state.marquee,
              groupDelta: state.groupDelta,
              insertMarkers: insertMarkers,
              spawn: state.spawn,
              activeLayer: state.activeLayer,
            ),
          ),
        ),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  _LevelPainter({
    required this.blocks,
    required this.placements,
    required this.tool,
    required this.hoverCell,
    required this.stampId,
    required this.rectOf,
    required this.occupied,
    required this.extendPreview,
    required this.selection,
    required this.marquee,
    required this.groupDelta,
    required this.insertMarkers,
    required this.spawn,
    required this.activeLayer,
  });

  final AssetLibrary blocks;
  final List<BlockPlacement> placements;
  final LevelTool tool;
  final (int, int)? hoverCell;
  final String? stampId;
  final CellRect? Function(BlockPlacement) rectOf;
  final Set<(int, int)>? occupied;
  final ExtendPreview? extendPreview;
  final Set<int> selection;
  final (int, int, int, int)? marquee;
  final (int, int)? groupDelta;
  final List<(int, int)>? insertMarkers;
  final SpawnPoint? spawn;
  final MapLayer activeLayer;

  static const _cell = GridConstants.cellSize;

  MapLayer? _layerOf(BlockPlacement p) {
    final def = blocks.blockById(p.blockId);
    return def == null ? null : MapLayer.forCategory(def.category);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);

    // Other layers first, dimmed for context; the active layer on top.
    for (var i = 0; i < placements.length; i++) {
      if (_layerOf(placements[i]) != activeLayer) {
        _paintPlacement(canvas, placements[i], selected: false, dim: true);
      }
    }
    for (var i = 0; i < placements.length; i++) {
      if (_layerOf(placements[i]) == activeLayer) {
        _paintPlacement(canvas, placements[i],
            selected: selection.contains(i));
      }
    }

    _paintStampGhost(canvas);
    _paintExtendPreview(canvas);
    _paintGroupMove(canvas);
    _paintMarquee(canvas);
    _paintInsertMarkers(canvas);
    _paintSpawn(canvas);
  }

  void _paintSpawn(Canvas canvas) {
    final s = spawn;
    if (s == null) return;
    final center = Offset((s.gridX + 0.5) * _cell, (s.gridY + 0.5) * _cell);
    final r = _cell * 0.6;
    canvas.drawCircle(
        center, r, Paint()..color = Colors.purpleAccent.withValues(alpha: 0.85));
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    // Facing arrow.
    final a = s.facingAngle;
    final tip = center + Offset(math.cos(a), math.sin(a)) * r;
    final tail = center - Offset(math.cos(a), math.sin(a)) * r * 0.4;
    final arrow = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(tail, tip, arrow);
    for (final side in [2.5, -2.5]) {
      final wing =
          tip + Offset(math.cos(a + side), math.sin(a + side)) * r * 0.5;
      canvas.drawLine(tip, wing, arrow);
    }
  }

  void _paintInsertMarkers(Canvas canvas) {
    final markers = insertMarkers;
    if (markers == null) return;
    for (final (cx, cy) in markers) {
      _paintPlus(canvas, Offset((cx + 0.5) * _cell, (cy + 0.5) * _cell),
          _cell * 0.45);
    }
  }

  void _paintGroupMove(Canvas canvas) {
    final delta = groupDelta;
    if (delta == null || (delta.$1 == 0 && delta.$2 == 0)) return;
    final ox = delta.$1 * _cell;
    final oy = delta.$2 * _cell;
    for (final i in selection) {
      final r = rectOf(placements[i]);
      if (r == null) continue;
      final dst = Rect.fromLTWH(
          r.x * _cell + ox, r.y * _cell + oy, r.w * _cell, r.h * _cell);
      canvas.drawRect(
          dst, Paint()..color = Colors.cyanAccent.withValues(alpha: 0.18));
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.cyanAccent,
      );
    }
  }

  void _paintMarquee(Canvas canvas) {
    final m = marquee;
    if (m == null) return;
    final rect =
        Rect.fromLTWH(m.$1 * _cell, m.$2 * _cell, m.$3 * _cell, m.$4 * _cell);
    canvas.drawRect(
        rect, Paint()..color = Colors.lightBlueAccent.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.lightBlueAccent,
    );
  }

  void _paintExtendPreview(Canvas canvas) {
    final preview = extendPreview;
    if (preview == null) return;
    final def = blocks.blockById(preview.blockId);
    if (def == null) return;
    final image = blocks.sheetImage;
    final r = def.spriteSheetRect;
    for (var i = 0; i < preview.positions.length; i++) {
      final (px, py) = preview.positions[i];
      final dst = Rect.fromLTWH(px * _cell, py * _cell,
          def.boundingBox.width * _cell, def.boundingBox.height * _cell);
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(
              r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble()),
          dst,
          Paint()
            ..filterQuality = FilterQuality.none
            ..color = const Color(0x66FFFFFF)
            ..colorFilter = const ColorFilter.mode(
                Color(0x66FFFFFF), BlendMode.modulate),
        );
      }
      canvas.drawRect(
          dst, Paint()..color = Colors.cyanAccent.withValues(alpha: 0.12));
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.cyanAccent.withValues(alpha: 0.7),
      );
      // A "+" at each step; clicking step i places i+1 tiles.
      _paintPlus(canvas, dst.center, _cell * 0.42);
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF0E1B24));
    final minor = Paint()
      ..strokeWidth = 0.5
      ..color = Colors.white.withValues(alpha: 0.06);
    final major = Paint()
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.14);
    for (var c = 0; c <= LevelCanvas.cols; c++) {
      final x = c * _cell;
      canvas.drawLine(
          Offset(x, 0), Offset(x, size.height), c % 5 == 0 ? major : minor);
    }
    for (var r = 0; r <= LevelCanvas.rows; r++) {
      final y = r * _cell;
      canvas.drawLine(
          Offset(0, y), Offset(size.width, y), r % 5 == 0 ? major : minor);
    }
  }

  void _paintPlacement(Canvas canvas, BlockPlacement p,
      {required bool selected, bool dim = false}) {
    final def = blocks.blockById(p.blockId);
    if (def == null) {
      // Unknown block: draw a red placeholder so it is visible.
      final rect = Rect.fromLTWH(p.gridX * _cell, p.gridY * _cell, _cell, _cell);
      canvas.drawRect(rect, Paint()..color = Colors.red.withValues(alpha: 0.4));
      return;
    }
    final dst = Rect.fromLTWH(
      p.gridX * _cell,
      p.gridY * _cell,
      def.boundingBox.width * _cell,
      def.boundingBox.height * _cell,
    );
    final image = blocks.sheetImage;
    if (image != null) {
      final r = def.spriteSheetRect;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(
            r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble()),
        dst,
        Paint()
          ..filterQuality = FilterQuality.none
          // Fade blocks that are not on the active layer.
          ..color = Colors.white.withValues(alpha: dim ? 0.28 : 1.0),
      );
    } else {
      canvas.drawRect(
          dst,
          Paint()
            ..color = Colors.blueGrey.withValues(alpha: dim ? 0.18 : 0.5));
    }

    // Dimmed (inactive-layer) blocks are context only: no selection ring,
    // no port glyphs.
    if (dim) return;

    if (selected) {
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.yellowAccent,
      );
    }

    _paintPorts(canvas, def, p.gridX, p.gridY);
  }

  void _paintPorts(
      Canvas canvas, BlockDef def, int originX, int originY) {
    final connectMode = tool == LevelTool.connect;
    final occ = occupied;
    for (var j = 0; j < def.ports.length; j++) {
      final port = def.ports[j];
      final passThrough = portIsPassThrough(def, port);
      final (extentW, extentH) = port.cellExtent;
      final center = Offset(
        (originX + port.localGridX + extentW / 2) * _cell,
        (originY + port.localGridY + extentH / 2) * _cell,
      );
      paintPort(canvas, center, _cell * 0.55, port.direction,
          bidirectional: passThrough);

      // In Connect mode, mark each free side with a "+" just outside the
      // strip. A pass-through port gets a "+" on both ends.
      if (connectMode && occ != null) {
        for (final dir in portOutwardDirections(def, port)) {
          final sideOccupied = portOutwardCells(originX, originY, port, dir)
              .any(occ.contains);
          if (sideOccupied) continue;
          final (dx, dy) = dir.gridDelta;
          final plus = Offset(
            center.dx + dx * _cell * 0.9,
            center.dy + dy * _cell * 0.9,
          );
          _paintPlus(canvas, plus, _cell * 0.42);
        }
      }
    }
  }

  void _paintPlus(Canvas canvas, Offset center, double radius) {
    canvas.drawCircle(
        center, radius, Paint()..color = Colors.green.withValues(alpha: 0.9));
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white,
    );
    final arm = radius * 0.55;
    final bar = Paint()
      ..strokeWidth = radius * 0.28
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    canvas.drawLine(
        center - Offset(arm, 0), center + Offset(arm, 0), bar);
    canvas.drawLine(
        center - Offset(0, arm), center + Offset(0, arm), bar);
  }

  void _paintStampGhost(Canvas canvas) {
    if (tool != LevelTool.stamp) return;
    final hover = hoverCell;
    final id = stampId;
    if (hover == null || id == null) return;
    final def = blocks.blockById(id);
    if (def == null) return;
    // Clamp the origin so the ghost stays fully inside the grid, exactly
    // as stampAt does, so the preview matches where the block will land.
    final maxX = LevelCanvas.cols - def.boundingBox.width;
    final maxY = LevelCanvas.rows - def.boundingBox.height;
    if (maxX < 0 || maxY < 0) return;
    final hx = hover.$1.clamp(0, maxX);
    final hy = hover.$2.clamp(0, maxY);
    final dst = Rect.fromLTWH(
      hx * _cell,
      hy * _cell,
      def.boundingBox.width * _cell,
      def.boundingBox.height * _cell,
    );

    // Red when the drop would overlap, green otherwise.
    final candidate =
        CellRect(hx, hy, def.boundingBox.width, def.boundingBox.height);
    var blocked = false;
    for (final p in placements) {
      final r = rectOf(p);
      if (r != null && candidate.overlaps(r)) {
        blocked = true;
        break;
      }
    }
    final tint = blocked ? Colors.redAccent : Colors.greenAccent;

    final image = blocks.sheetImage;
    if (image != null) {
      final r = def.spriteSheetRect;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(
            r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble()),
        dst,
        Paint()
          ..filterQuality = FilterQuality.none
          ..color = const Color(0x88FFFFFF)
          ..colorFilter =
              const ColorFilter.mode(Color(0x88FFFFFF), BlendMode.modulate),
      );
    }
    canvas.drawRect(dst, Paint()..color = tint.withValues(alpha: 0.18));
    canvas.drawRect(
      dst,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = tint,
    );
  }

  @override
  bool shouldRepaint(_LevelPainter old) =>
      old.blocks != blocks ||
      old.placements != placements ||
      old.tool != tool ||
      old.hoverCell != hoverCell ||
      old.stampId != stampId ||
      old.occupied != occupied ||
      old.extendPreview != extendPreview ||
      old.selection != selection ||
      old.marquee != marquee ||
      old.groupDelta != groupDelta ||
      old.insertMarkers != insertMarkers ||
      old.spawn != spawn ||
      old.activeLayer != activeLayer;
}
