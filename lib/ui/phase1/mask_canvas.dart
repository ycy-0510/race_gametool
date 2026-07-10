import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../models/block_def.dart';
import '../../models/mask_draft.dart';
import '../../state/asset_definer_providers.dart';
import '../widgets/port_marker.dart';

/// The Phase 1 editing canvas: the raw draft image inside an
/// InteractiveViewer, overlaid with the 16 px grid, mask shapes, ports,
/// and drag previews. Gestures are interpreted according to the active
/// Phase1Tool.
class MaskCanvas extends ConsumerStatefulWidget {
  const MaskCanvas({super.key});

  static const _dragTools = {
    Phase1Tool.drawBox,
    Phase1Tool.paintMask,
    Phase1Tool.addPort,
    Phase1Tool.move,
  };

  @override
  ConsumerState<MaskCanvas> createState() => _MaskCanvasState();
}

class _MaskCanvasState extends ConsumerState<MaskCanvas> {
  final TransformationController _transform = TransformationController();
  ui.Image? _lastImage;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(assetDefinerProvider);
    final image = state.image;
    if (image == null) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(assetDefinerProvider.notifier);
    const cell = GridConstants.cellSize;
    final usesDrag = MaskCanvas._dragTools.contains(state.tool);

    if (_lastImage != image) {
      _lastImage = image;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;

        final imageW = image.width.toDouble();
        final imageH = image.height.toDouble();
        final viewportW = box.size.width;
        final viewportH = box.size.height;

        final scale = math.min(viewportW / imageW, viewportH / imageH).clamp(0.15, 12.0);
        final tx = (viewportW - imageW * scale) / 2;
        final ty = (viewportH - imageH * scale) / 2;

        final matrix = Matrix4.identity();
        matrix.setEntry(0, 0, scale);
        matrix.setEntry(1, 1, scale);
        matrix.setEntry(0, 3, tx);
        matrix.setEntry(1, 3, ty);
        _transform.value = matrix;
      });
    }

    (int, int) toCell(Offset local) => (
          (local.dx / cell).floor().clamp(0, (image.width / cell).ceil() - 1),
          (local.dy / cell).floor().clamp(0, (image.height / cell).ceil() - 1),
        );

    return InteractiveViewer(
      transformationController: _transform,
      constrained: false,
      minScale: 0.15,
      maxScale: 12,
      boundaryMargin: const EdgeInsets.all(600),
      // Pan handlers are registered only for the drawing tools; in Select
      // mode single-pointer drags fall through to InteractiveViewer so the
      // canvas can be panned with the mouse.
      child: GestureDetector(
        onTapUp: (details) {
          final (x, y) = toCell(details.localPosition);
          notifier.tapCell(x, y);
        },
        onPanStart: !usesDrag
            ? null
            : (details) {
                final (x, y) = toCell(details.localPosition);
                notifier.dragStart(x, y);
              },
        onPanUpdate: !usesDrag
            ? null
            : (details) {
                final (x, y) = toCell(details.localPosition);
                notifier.dragUpdate(x, y);
              },
        onPanEnd: !usesDrag ? null : (_) => notifier.dragEnd(),
        child: CustomPaint(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          painter: _MaskCanvasPainter(
            image: image,
            masks: state.masks,
            selectedIndex: state.selectedIndex,
            tool: state.tool,
            dragPreview: state.dragPreview,
            paintPreview: state.paintPreview,
            movePreview: state.movePreview,
          ),
        ),
      ),
    );
  }
}

class _MaskCanvasPainter extends CustomPainter {
  const _MaskCanvasPainter({
    required this.image,
    required this.masks,
    required this.selectedIndex,
    required this.tool,
    required this.dragPreview,
    required this.paintPreview,
    required this.movePreview,
  });

  final ui.Image image;
  final List<MaskDraft> masks;
  final int? selectedIndex;
  final Phase1Tool tool;
  final DragPreview? dragPreview;
  final Set<Cell>? paintPreview;
  final MovePreview? movePreview;

  static const _cell = GridConstants.cellSize;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImage(image, Offset.zero, Paint());
    _paintGrid(canvas, size);

    final move = movePreview;
    for (var i = 0; i < masks.length; i++) {
      // The block being moved is drawn separately at its previewed spot.
      if (move != null && move.index == i && (move.dx != 0 || move.dy != 0)) {
        continue;
      }
      _paintMask(canvas, masks[i], selected: i == selectedIndex);
    }

    _paintMovePreview(canvas);
    _paintDragPreview(canvas);
    _paintPaintPreview(canvas);
  }

  void _paintMovePreview(Canvas canvas) {
    final move = movePreview;
    if (move == null || (move.dx == 0 && move.dy == 0)) return;
    final mask = masks[move.index];
    // Ghost outline at the original position.
    final origin = Rect.fromLTWH(mask.gridX * _cell, mask.gridY * _cell,
        mask.widthCells * _cell, mask.heightCells * _cell);
    canvas.drawRect(
      origin,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.3),
    );
    canvas.save();
    canvas.translate(move.dx * _cell, move.dy * _cell);
    _paintMask(canvas, mask, selected: true);
    canvas.restore();
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeWidth = 0.5
      ..color = Colors.white.withValues(alpha: 0.12);
    for (var x = 0.0; x <= size.width; x += _cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += _cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _paintDragPreview(Canvas canvas) {
    final preview = dragPreview;
    if (preview == null) return;
    final isPort = tool == Phase1Tool.addPort;
    final color = isPort ? Colors.orangeAccent : Colors.tealAccent;
    final rect = Rect.fromLTWH(
      preview.gridX * _cell,
      preview.gridY * _cell,
      preview.widthCells * _cell,
      preview.heightCells * _cell,
    );
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color,
    );
  }

  void _paintPaintPreview(Canvas canvas) {
    final cells = paintPreview;
    if (cells == null) return;
    final fill = Paint()..color = Colors.tealAccent.withValues(alpha: 0.35);
    for (final (x, y) in cells) {
      canvas.drawRect(
          Rect.fromLTWH(x * _cell, y * _cell, _cell, _cell), fill);
    }
  }

  void _paintMask(Canvas canvas, MaskDraft mask, {required bool selected}) {
    final borderColor = selected ? Colors.yellowAccent : Colors.lightGreen;
    final fillPaint = Paint()
      ..color = borderColor.withValues(alpha: selected ? 0.14 : 0.07);
    final strokeWidth = mask.category == BlockCategory.islandTile
        ? (selected ? 1.5 : 0.8)
        : (selected ? 2.5 : 1.5);
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = borderColor;

    final origin = Offset(mask.gridX * _cell, mask.gridY * _cell);
    final cells = mask.cells;
    if (cells == null) {
      final rect = origin &
          Size(mask.widthCells * _cell, mask.heightCells * _cell);
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, strokePaint);
    } else {
      // Freeform: fill each occupied cell and stroke only boundary edges
      // (edges whose neighbor cell is not part of the shape).
      for (final (x, y) in cells) {
        final rect = Rect.fromLTWH(origin.dx + x * _cell,
            origin.dy + y * _cell, _cell, _cell);
        canvas.drawRect(rect, fillPaint);
        if (!cells.contains((x, y - 1))) {
          canvas.drawLine(rect.topLeft, rect.topRight, strokePaint);
        }
        if (!cells.contains((x, y + 1))) {
          canvas.drawLine(rect.bottomLeft, rect.bottomRight, strokePaint);
        }
        if (!cells.contains((x - 1, y))) {
          canvas.drawLine(rect.topLeft, rect.bottomLeft, strokePaint);
        }
        if (!cells.contains((x + 1, y))) {
          canvas.drawLine(rect.topRight, rect.bottomRight, strokePaint);
        }
      }
    }

    if (mask.category != BlockCategory.islandTile) {
      // Block ID label above the box.
      final textPainter = TextPainter(
        text: TextSpan(
          text: mask.id,
          style: TextStyle(
            color: borderColor,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, origin + const Offset(2, -16));
    }

      for (final port in mask.ports) {
        final (extentW, extentH) = port.cellExtent;
        final stripRect = Rect.fromLTWH(
          origin.dx + port.localGridX * _cell,
          origin.dy + port.localGridY * _cell,
          extentW * _cell,
          extentH * _cell,
        );
        final portColor = defaultPortColor(port.direction);
        if (port.span > 1) {
          final rrect = RRect.fromRectAndRadius(
              stripRect.deflate(1.5), const Radius.circular(4));
          canvas.drawRRect(
              rrect, Paint()..color = portColor.withValues(alpha: 0.25));
          canvas.drawRRect(
            rrect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..color = portColor,
          );
        }

        var center = stripRect.center;
        var radius = _cell * 0.6;

        if (mask.category == BlockCategory.islandTile) {
          // Push the small arrows out toward their corresponding edges/corners
          // so they don't all overlap at the center of the 1x1 cell.
          final angle = port.direction.angle;
          center += Offset(math.cos(angle), math.sin(angle)) * (_cell * 0.35);
          radius = _cell * 0.2;
        }

        paintPort(
          canvas,
          center,
          radius,
          port.direction,
          bidirectional: port.bidirectional,
        );
      }
    }

  @override
  bool shouldRepaint(_MaskCanvasPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.masks != masks ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.tool != tool ||
      oldDelegate.dragPreview != dragPreview ||
      oldDelegate.paintPreview != paintPreview ||
      oldDelegate.movePreview != movePreview;
}
