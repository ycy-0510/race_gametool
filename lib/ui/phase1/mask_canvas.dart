import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../models/block_def.dart';
import '../../models/geometry.dart';
import '../../models/mask_draft.dart';
import '../../state/asset_definer_providers.dart';
import '../widgets/port_marker.dart';

/// The Phase 1 editing canvas: the raw draft image inside an
/// InteractiveViewer, overlaid with the 16 px grid, mask shapes, ports,
/// and drag previews. Gestures are interpreted according to the active
/// Phase1Tool.
class MaskCanvas extends ConsumerStatefulWidget {
  const MaskCanvas({super.key});

  // The physics-area tool is tap-only (append/undo/complete by clicking), so
  // it deliberately stays out of this set: no left-drag recognizer.
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
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    setState(() {});
  }

  Offset _getSnappedOffset(Offset raw, double cell, bool snapEnabled) {
    if (!snapEnabled) {
      return Offset(raw.dx.roundToDouble(), raw.dy.roundToDouble());
    }
    final double halfCell = cell / 2.0; // 8.0
    double snapX = raw.dx;
    double snapY = raw.dy;
    const double threshold = 4.0;

    double nearX = (raw.dx / halfCell).round() * halfCell;
    double nearY = (raw.dy / halfCell).round() * halfCell;

    if ((raw.dx - nearX).abs() < threshold) {
      snapX = nearX;
    } else {
      snapX = raw.dx.roundToDouble();
    }
    if ((raw.dy - nearY).abs() < threshold) {
      snapY = nearY;
    } else {
      snapY = raw.dy.roundToDouble();
    }

    return Offset(snapX, snapY);
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
          (local.dx / cell).floor().clamp(0, (image.width / cell).ceil() - 1).toInt(),
          (local.dy / cell).floor().clamp(0, (image.height / cell).ceil() - 1).toInt(),
        );

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (state.tool == Phase1Tool.drawPhysicsArea && state.physicsDrawing) {
            final isCmdZ = event.logicalKey == LogicalKeyboardKey.keyZ &&
                (HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed);
            if (isCmdZ) {
              notifier.undoPhysicsAreaVertex();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.enter) {
              notifier.closePhysicsArea();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.backspace ||
                event.logicalKey == LogicalKeyboardKey.delete) {
              notifier.undoPhysicsAreaVertex();
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.escape) {
              notifier.cancelPhysicsArea();
              return KeyEventResult.handled;
            }
          }
        }
        return KeyEventResult.ignored;
      },
      child: InteractiveViewer(
        transformationController: _transform,
        constrained: false,
        minScale: 0.15,
        maxScale: 12,
        boundaryMargin: const EdgeInsets.all(600),
        child: Listener(
          onPointerMove: (event) {
            if (event.buttons == kMiddleMouseButton) {
              final matrix = _transform.value.clone();
              matrix.storage[12] += event.delta.dx;
              matrix.storage[13] += event.delta.dy;
              _transform.value = matrix;
            }
          },
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              final isZoomKey = HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed;
              if (isZoomKey) {
                final double dy = event.scrollDelta.dy;
                if (dy != 0) {
                  final double scaleDelta = dy > 0 ? 0.9 : 1.1;
                  final matrix = _transform.value.clone();
                  final double tx = matrix.storage[12];
                  final double ty = matrix.storage[13];
                  final double currentScale = matrix.getMaxScaleOnAxis();
                  const minScale = 0.15;
                  const maxScale = 12.0;
                  final double newScale = (currentScale * scaleDelta).clamp(minScale, maxScale);
                  final double actualFactor = newScale / currentScale;
                  if (actualFactor != 1.0) {
                    final px = event.localPosition.dx;
                    final py = event.localPosition.dy;
                    matrix.storage[0] *= actualFactor;
                    matrix.storage[5] *= actualFactor;
                    matrix.storage[10] *= actualFactor;
                    matrix.storage[12] = px + (tx - px) * actualFactor;
                    matrix.storage[13] = py + (ty - py) * actualFactor;
                    _transform.value = matrix;
                  }
                }
              } else {
                final matrix = _transform.value.clone();
                matrix.storage[12] -= event.scrollDelta.dx;
                matrix.storage[13] -= event.scrollDelta.dy;
                _transform.value = matrix;
              }
            }
          },
          child: RawGestureDetector(
            gestures: {
              if (usesDrag)
                LeftClickPanGestureRecognizer: GestureRecognizerFactoryWithHandlers<LeftClickPanGestureRecognizer>(
                  () => LeftClickPanGestureRecognizer(
                    allowedButtonsFilter: (int buttons) => buttons == kPrimaryButton,
                  ),
                  (LeftClickPanGestureRecognizer instance) {
                    instance
                      ..onStart = (details) {
                        final (x, y) = toCell(details.localPosition);
                        notifier.dragStart(x, y);
                      }
                      ..onUpdate = (details) {
                        final (x, y) = toCell(details.localPosition);
                        notifier.dragUpdate(x, y);
                      }
                      ..onEnd = (_) {
                        notifier.dragEnd();
                      };
                  },
                ),
              TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(
                  allowedButtonsFilter: (int buttons) => buttons == kPrimaryButton,
                ),
                (TapGestureRecognizer instance) {
                  instance.onTapUp = (details) {
                    if (state.tool == Phase1Tool.drawPhysicsArea) {
                      final snapped = _getSnappedOffset(details.localPosition, cell, state.snapToGrid);
                      notifier.trackAreaTap(snapped);
                    } else {
                      final (x, y) = toCell(details.localPosition);
                      notifier.tapCell(x, y);
                    }
                  };
                },
              ),
            },
            child: MouseRegion(
              onHover: (event) {
                if (state.tool == Phase1Tool.drawPhysicsArea &&
                    state.physicsDrawing) {
                  final snapped = _getSnappedOffset(event.localPosition, cell, state.snapToGrid);
                  notifier.updatePhysicsAreaHover(snapped);
                }
              },
              onExit: (_) {
                if (state.tool == Phase1Tool.drawPhysicsArea) {
                  notifier.updatePhysicsAreaHover(null);
                }
              },
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
                  scale: _transform.value.getMaxScaleOnAxis(),
                  physicsDrawing: state.physicsDrawing,
                  physicsAreaHoverPos: state.physicsAreaHoverPos,
                  curveMode: state.curveMode,
                  curveDraftPoints: state.curveDraftPoints,
                ),
              ),
            ),
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
    required this.scale,
    required this.physicsDrawing,
    required this.physicsAreaHoverPos,
    required this.curveMode,
    required this.curveDraftPoints,
  });

  final ui.Image image;
  final List<MaskDraft> masks;
  final int? selectedIndex;
  final Phase1Tool tool;
  final DragPreview? dragPreview;
  final Set<Cell>? paintPreview;
  final MovePreview? movePreview;
  final double scale;
  final bool physicsDrawing;
  final ui.Offset? physicsAreaHoverPos;
  final bool curveMode;
  final List<Vec2> curveDraftPoints;

  static const _cell = GridConstants.cellSize;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImage(image, Offset.zero, Paint());
    _paintGrid(canvas, size);

    final move = movePreview;
    for (var i = 0; i < masks.length; i++) {
      if (move != null && move.index == i && (move.dx != 0 || move.dy != 0)) {
        continue;
      }
      _paintMask(canvas, masks[i], selected: i == selectedIndex);
    }

    _paintMovePreview(canvas);
    _paintDragPreview(canvas);
    _paintPaintPreview(canvas);
    _paintCrosshair(canvas, size);
  }

  void _paintCrosshair(Canvas canvas, Size size) {
    final hover = physicsAreaHoverPos;
    if (tool == Phase1Tool.drawPhysicsArea && physicsDrawing && hover != null) {
      final paint = Paint()
        ..color = Colors.purpleAccent.withValues(alpha: 0.3)
        ..strokeWidth = 1.0 / scale
        ..style = PaintingStyle.stroke;
      // Horizontal line
      canvas.drawLine(Offset(0, hover.dy), Offset(size.width, hover.dy), paint);
      // Vertical line
      canvas.drawLine(Offset(hover.dx, 0), Offset(hover.dx, size.height), paint);

      // Draw snap target dot
      canvas.drawCircle(
        hover,
        2.5 / scale,
        Paint()..color = Colors.purpleAccent,
      );
    }
  }

  void _paintMovePreview(Canvas canvas) {
    final move = movePreview;
    if (move == null || (move.dx == 0 && move.dy == 0)) return;
    final mask = masks[move.index];
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

  List<Vec2> _generateArc(Vec2 center, Vec2 start, Vec2 end, int widthCells, int heightCells) {
    final double r = math.sqrt((start.x - center.x) * (start.x - center.x) +
        (start.y - center.y) * (start.y - center.y));
    if (r == 0) return [start];

    final double thetaA = math.atan2(start.y - center.y, start.x - center.x);
    final double thetaB = math.atan2(end.y - center.y, end.x - center.x);

    const int steps = 12;
    final double w = widthCells * _cell;
    final double h = heightCells * _cell;

    double angleB1 = thetaB;
    if (angleB1 < thetaA) angleB1 += 2.0 * math.pi;
    final points1 = <Vec2>[];
    for (var i = 0; i <= steps; i++) {
      final t = thetaA + (angleB1 - thetaA) * (i / steps);
      points1.add(Vec2(
        (center.x + r * math.cos(t)).roundToDouble(),
        (center.y + r * math.sin(t)).roundToDouble(),
      ));
    }

    double angleB2 = thetaB;
    if (angleB2 > thetaA) angleB2 -= 2.0 * math.pi;
    final points2 = <Vec2>[];
    for (var i = 0; i <= steps; i++) {
      final t = thetaA + (angleB2 - thetaA) * (i / steps);
      points2.add(Vec2(
        (center.x + r * math.cos(t)).roundToDouble(),
        (center.y + r * math.sin(t)).roundToDouble(),
      ));
    }

    int countInside(List<Vec2> pts) {
      var count = 0;
      for (final p in pts) {
        if (p.x >= 0.0 && p.x <= w && p.y >= 0.0 && p.y <= h) {
          count++;
        }
      }
      return count;
    }

    if (countInside(points1) >= countInside(points2)) {
      return points1;
    } else {
      return points2;
    }
  }

  void _drawLabel(Canvas canvas, Offset offset, String text, Paint bgPaint, Paint fgPaint) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: fgPaint.color,
          fontSize: 9.0 / scale,
          fontWeight: FontWeight.bold,
          backgroundColor: bgPaint.color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, offset + Offset(6.0 / scale, -10.0 / scale));
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
      final fontSize = (12.0 / scale).clamp(4.0, 48.0);
      final textPainter = TextPainter(
        text: TextSpan(
          text: mask.id,
          style: TextStyle(
            color: borderColor,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            shadows: const [Shadow(blurRadius: 3, color: Colors.black)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, origin + Offset(2 / scale, -(fontSize + 4) / scale));
    }

    // Physics track area polygon.
    if (mask.physicsTrackArea.isNotEmpty) {
      final pts = mask.physicsTrackArea;
      final drawing =
          selected && tool == Phase1Tool.drawPhysicsArea && physicsDrawing;

      final path = Path()
        ..moveTo(origin.dx + pts.first.x, origin.dy + pts.first.y);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(origin.dx + pts[i].x, origin.dy + pts[i].y);
      }

      // While drawing the polyline stays open (no auto snap-back to the
      // origin); the finished area is a filled, closed polygon.
      if (!drawing) {
        path.close();
        canvas.drawPath(
          path,
          Paint()
            ..color =
                Colors.purpleAccent.withValues(alpha: selected ? 0.15 : 0.08)
            ..style = PaintingStyle.fill,
        );
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.purpleAccent.withValues(alpha: selected ? 1.0 : 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (selected ? 3.5 : 2.0) / scale
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );

      if (drawing) {
        for (var i = 0; i < pts.length; i++) {
          final center = origin + Offset(pts[i].x, pts[i].y);
          // The first vertex is the close target once the shape has 3+ points;
          // the last is the undo target.
          final canClose = i == 0 && pts.length >= 3;
          final isLast = i == pts.length - 1;
          final ringColor = canClose
              ? Colors.greenAccent
              : (isLast ? Colors.yellowAccent : Colors.purple);
          final big = canClose || isLast;
          canvas.drawCircle(
            center,
            (big ? 6.0 : 4.5) / scale,
            Paint()..color = ringColor,
          );
          canvas.drawCircle(
            center,
            (big ? 3.0 : 2.5) / scale,
            Paint()..color = Colors.white,
          );
        }

        // Rubber-band preview from the last point to the cursor (line mode).
        final hover = physicsAreaHoverPos;
        if (!curveMode && hover != null) {
          canvas.drawLine(
            origin + Offset(pts.last.x, pts.last.y),
            hover,
            Paint()
              ..color = Colors.purpleAccent.withValues(alpha: 0.7)
              ..strokeWidth = 3.0 / scale
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round,
          );
        }
      }
    }

    // Curve overlay: reconstruct the arc's start and center from the draft and
    // the current polyline. With an existing polyline the last vertex is the
    // start, so the draft only holds the center; otherwise the draft holds the
    // start then the center.
    if (selected &&
        tool == Phase1Tool.drawPhysicsArea &&
        physicsDrawing &&
        curveMode) {
      final bg = Paint()..color = Colors.black.withValues(alpha: 0.6);
      final fg = Paint()..color = Colors.purpleAccent;
      final draft = curveDraftPoints;
      final hover = physicsAreaHoverPos;
      final pts = mask.physicsTrackArea;

      final Vec2? start = pts.isNotEmpty
          ? pts.last
          : (draft.isNotEmpty ? draft[0] : null);
      final Vec2? center = pts.isNotEmpty
          ? (draft.isNotEmpty ? draft[0] : null)
          : (draft.length > 1 ? draft[1] : null);

      if (start != null) {
        final startPt = origin + Offset(start.x, start.y);
        canvas.drawCircle(startPt, 5.0 / scale, fg);
        _drawLabel(canvas, startPt, 'Start', bg, fg);
      }
      if (center != null) {
        final centerPt = origin + Offset(center.x, center.y);
        canvas.drawCircle(centerPt, 5.0 / scale, fg);
        _drawLabel(canvas, centerPt, 'Center', bg, fg);
      }

      // While choosing the center there is no connecting line; the arc preview
      // only appears once both start and center are set (choosing the end).
      if (start != null && center != null && hover != null) {
        // Choosing the end: show the radius guide and the preview arc.
        final centerPt = origin + Offset(center.x, center.y);
        final startPt = origin + Offset(start.x, start.y);
        final r = math.sqrt(
          (startPt.dx - centerPt.dx) * (startPt.dx - centerPt.dx) +
              (startPt.dy - centerPt.dy) * (startPt.dy - centerPt.dy),
        );
        canvas.drawCircle(
          centerPt,
          r,
          Paint()
            ..color = Colors.purpleAccent.withValues(alpha: 0.15)
            ..strokeWidth = 1.0 / scale
            ..style = PaintingStyle.stroke,
        );
        final hoverLocal = Vec2(hover.dx - origin.dx, hover.dy - origin.dy);
        final arcPts = _generateArc(
          center,
          start,
          hoverLocal,
          mask.widthCells,
          mask.heightCells,
        );
        if (arcPts.isNotEmpty) {
          final arcPath = Path()
            ..moveTo(origin.dx + arcPts.first.x, origin.dy + arcPts.first.y);
          for (var i = 1; i < arcPts.length; i++) {
            arcPath.lineTo(origin.dx + arcPts[i].x, origin.dy + arcPts[i].y);
          }
          canvas.drawPath(
            arcPath,
            Paint()
              ..color = Colors.purpleAccent.withValues(alpha: 0.85)
              ..strokeWidth = 3.5 / scale
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round,
          );
        }
      }
    }

    // Hide all port markers in drawPhysicsArea mode.
    if (tool != Phase1Tool.drawPhysicsArea) {
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
              stripRect.slate(1.5), const Radius.circular(4));
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
  }

  @override
  bool shouldRepaint(_MaskCanvasPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.masks != masks ||
      oldDelegate.selectedIndex != selectedIndex ||
      oldDelegate.tool != tool ||
      oldDelegate.dragPreview != dragPreview ||
      oldDelegate.paintPreview != paintPreview ||
      oldDelegate.movePreview != movePreview ||
      oldDelegate.scale != scale ||
      oldDelegate.physicsDrawing != physicsDrawing ||
      oldDelegate.physicsAreaHoverPos != physicsAreaHoverPos ||
      oldDelegate.curveMode != curveMode ||
      oldDelegate.curveDraftPoints != curveDraftPoints;
}

class LeftClickPanGestureRecognizer extends PanGestureRecognizer {
  LeftClickPanGestureRecognizer({
    super.allowedButtonsFilter,
  });

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
  }
}

extension on Rect {
  Rect slate(double delta) => Rect.fromLTRB(
        left + delta,
        top + delta,
        right - delta,
        bottom - delta,
      );
}
