import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../logic/pixel_ops.dart';
import '../../state/pixel_editor_providers.dart';

/// The pixel editor drawing surface: the document rendered 1 logical unit per
/// pixel inside an InteractiveViewer (zoom is lossless because the image is
/// drawn with FilterQuality.none), plus checkerboard, grids, selection
/// overlays, and the floating-selection handles.
class PixelCanvas extends ConsumerStatefulWidget {
  const PixelCanvas({super.key});

  @override
  ConsumerState<PixelCanvas> createState() => _PixelCanvasState();
}

class _PixelCanvasState extends ConsumerState<PixelCanvas> {
  final TransformationController _transform = TransformationController();
  (int, int)? _fittedFor;
  Offset? _hover;

  static const _minScale = 0.25;
  static const _maxScale = 64.0;

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

  void _onTransformChanged() => setState(() {});

  void _fitToViewport(BoxConstraints constraints, int w, int h) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scale = math.min(
              constraints.maxWidth / w, constraints.maxHeight / h) *
          0.85;
      final clamped = scale.clamp(_minScale, _maxScale);
      final matrix = Matrix4.identity()
        ..translateByDouble((constraints.maxWidth - w * clamped) / 2,
            (constraints.maxHeight - h * clamped) / 2, 0, 1)
        ..scaleByDouble(clamped, clamped, 1, 1);
      _transform.value = matrix;
    });
  }

  /// Corner index (0 TL, 1 TR, 2 BL, 3 BR) if the position grabs a scale
  /// handle of the floating selection, else null. Handle size tracks zoom so
  /// it is constant on screen.
  int? _handleAt(Offset pos, PixelEditorState state) {
    final f = state.floating;
    if (f == null) return null;
    final scale = _transform.value.getMaxScaleOnAxis();
    final r = 8.0 / scale;
    final corners = [
      Offset(f.offsetX.toDouble(), f.offsetY.toDouble()),
      Offset((f.offsetX + f.width).toDouble(), f.offsetY.toDouble()),
      Offset(f.offsetX.toDouble(), (f.offsetY + f.height).toDouble()),
      Offset((f.offsetX + f.width).toDouble(), (f.offsetY + f.height).toDouble()),
    ];
    for (var i = 0; i < corners.length; i++) {
      if ((pos - corners[i]).distance <= r) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pixelEditorProvider);
    final notifier = ref.read(pixelEditorProvider.notifier);
    final w = state.document.width;
    final h = state.document.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (_fittedFor != (w, h)) {
          _fittedFor = (w, h);
          _fitToViewport(constraints, w, h);
        }

        return InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: _minScale,
          maxScale: _maxScale,
          boundaryMargin: const EdgeInsets.all(2000),
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
              if (event is! PointerScrollEvent) return;
              final isZoomKey = HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed;
              if (isZoomKey) {
                final dy = event.scrollDelta.dy;
                if (dy == 0) return;
                final scaleDelta = dy > 0 ? 0.9 : 1.1;
                final matrix = _transform.value.clone();
                final tx = matrix.storage[12];
                final ty = matrix.storage[13];
                final currentScale = matrix.getMaxScaleOnAxis();
                final newScale =
                    (currentScale * scaleDelta).clamp(_minScale, _maxScale);
                final actualFactor = newScale / currentScale;
                if (actualFactor == 1.0) return;
                final px = event.localPosition.dx;
                final py = event.localPosition.dy;
                matrix.storage[0] *= actualFactor;
                matrix.storage[5] *= actualFactor;
                matrix.storage[10] *= actualFactor;
                matrix.storage[12] = px + (tx - px) * actualFactor;
                matrix.storage[13] = py + (ty - py) * actualFactor;
                _transform.value = matrix;
              } else {
                final matrix = _transform.value.clone();
                matrix.storage[12] -= event.scrollDelta.dx;
                matrix.storage[13] -= event.scrollDelta.dy;
                _transform.value = matrix;
              }
            },
            child: RawGestureDetector(
              gestures: {
                _LeftClickPanGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        _LeftClickPanGestureRecognizer>(
                  () => _LeftClickPanGestureRecognizer(
                    allowedButtonsFilter: (buttons) =>
                        buttons == kPrimaryButton,
                  ),
                  (instance) {
                    instance
                      ..onStart = (details) {
                        final pos = details.localPosition;
                        if (state.tool == PixelTool.move) {
                          final corner = _handleAt(pos, state);
                          if (corner != null) {
                            notifier.startHandleScale(corner);
                          }
                        }
                        notifier.strokeStart(pos.dx, pos.dy);
                      }
                      ..onUpdate = (details) {
                        notifier.strokeUpdate(details.localPosition.dx,
                            details.localPosition.dy);
                      }
                      ..onEnd = (_) {
                        notifier.strokeEnd();
                      };
                  },
                ),
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(
                    allowedButtonsFilter: (buttons) =>
                        buttons == kPrimaryButton,
                  ),
                  (instance) {
                    instance.onTapUp = (details) => notifier.tapAt(
                        details.localPosition.dx, details.localPosition.dy);
                  },
                ),
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.precise,
                onHover: (event) =>
                    setState(() => _hover = event.localPosition),
                onExit: (_) => setState(() => _hover = null),
                child: CustomPaint(
                  size: Size(w.toDouble(), h.toDouble()),
                  painter: _PixelCanvasPainter(
                    state: state,
                    scale: _transform.value.getMaxScaleOnAxis(),
                    hover: _hover,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PixelCanvasPainter extends CustomPainter {
  const _PixelCanvasPainter({
    required this.state,
    required this.scale,
    required this.hover,
  });

  final PixelEditorState state;
  final double scale;
  final Offset? hover;

  @override
  void paint(Canvas canvas, Size size) {
    final w = state.document.width;
    final h = state.document.height;
    canvas.clipRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));

    _paintCheckerboard(canvas, w, h);

    final image = state.canvasImage;
    if (image != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..filterQuality = FilterQuality.none,
      );
    }

    final floating = state.floating;
    final floatingImage = state.floatingImage;
    if (floating != null && floatingImage != null) {
      canvas.drawImageRect(
        floatingImage,
        Rect.fromLTWH(0, 0, floatingImage.width.toDouble(),
            floatingImage.height.toDouble()),
        Rect.fromLTWH(floating.offsetX.toDouble(), floating.offsetY.toDouble(),
            floating.width.toDouble(), floating.height.toDouble()),
        Paint()..filterQuality = FilterQuality.none,
      );
    }

    if (state.showPixelGrid && scale >= 8) _paintGrid(canvas, w, h, 1, 0.35);
    if (state.showCellGrid && scale * GridConstants.cellSize >= 24) {
      _paintGrid(canvas, w, h, GridConstants.cellSize.toInt(), 0.7);
    }
    if (state.symmetry != SymmetryMode.none) _paintSymmetryAxes(canvas, w, h);

    final selection = state.selection;
    if (selection != null) _paintSelection(canvas, selection, w, h);
    if (state.selectDraft != null) _paintSelectDraft(canvas);
    if (state.lassoDraft != null) _paintLassoDraft(canvas);
    if (floating != null) _paintFloatingChrome(canvas, floating);
    if (hover != null) _paintHover(canvas, w, h);
  }

  void _paintCheckerboard(Canvas canvas, int w, int h) {
    const tile = 8;
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = const Color(0xffb8b8b8));
    final dark = Paint()..color = const Color(0xff909090);
    for (var y = 0; y * tile < h; y++) {
      for (var x = y.isEven ? 1 : 0; x * tile < w; x += 2) {
        canvas.drawRect(
          Rect.fromLTWH((x * tile).toDouble(), (y * tile).toDouble(),
              tile.toDouble(), tile.toDouble()),
          dark,
        );
      }
    }
  }

  void _paintGrid(Canvas canvas, int w, int h, int step, double opacity) {
    final paint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, opacity * 0.5)
      ..strokeWidth = 1 / scale;
    for (var x = step; x < w; x += step) {
      canvas.drawLine(
          Offset(x.toDouble(), 0), Offset(x.toDouble(), h.toDouble()), paint);
    }
    for (var y = step; y < h; y += step) {
      canvas.drawLine(
          Offset(0, y.toDouble()), Offset(w.toDouble(), y.toDouble()), paint);
    }
  }

  void _paintSymmetryAxes(Canvas canvas, int w, int h) {
    final paint = Paint()
      ..color = const Color(0xccff5588)
      ..strokeWidth = 1.5 / scale;
    if (state.symmetry == SymmetryMode.horizontal ||
        state.symmetry == SymmetryMode.both) {
      canvas.drawLine(
          Offset(w / 2, 0), Offset(w / 2, h.toDouble()), paint);
    }
    if (state.symmetry == SymmetryMode.vertical ||
        state.symmetry == SymmetryMode.both) {
      canvas.drawLine(
          Offset(0, h / 2), Offset(w.toDouble(), h / 2), paint);
    }
  }

  /// Selected region: translucent fill plus a solid outline along the mask
  /// boundary, built from horizontal runs.
  void _paintSelection(Canvas canvas, Uint8List selection, int w, int h) {
    final path = Path();
    for (var y = 0; y < h; y++) {
      var x = 0;
      while (x < w) {
        if (selection[y * w + x] == 0) {
          x++;
          continue;
        }
        final start = x;
        while (x < w && selection[y * w + x] != 0) {
          x++;
        }
        path.addRect(Rect.fromLTRB(
            start.toDouble(), y.toDouble(), x.toDouble(), (y + 1).toDouble()));
      }
    }
    canvas.drawPath(path, Paint()..color = const Color(0x3342a5f5));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale
        ..color = const Color(0xff42a5f5),
    );
  }

  void _paintSelectDraft(Canvas canvas) {
    final d = state.selectDraft!;
    final rect = Rect.fromLTRB(
      math.min(d.x0, d.x1).toDouble(),
      math.min(d.y0, d.y1).toDouble(),
      math.max(d.x0, d.x1) + 1.0,
      math.max(d.y0, d.y1) + 1.0,
    );
    canvas.drawRect(rect, Paint()..color = const Color(0x2242a5f5));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale
        ..color = const Color(0xffffffff),
    );
  }

  void _paintLassoDraft(Canvas canvas) {
    final points = state.lassoDraft!;
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.$1, points.first.$2);
    for (final (x, y) in points.skip(1)) {
      path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale
        ..color = const Color(0xffffffff),
    );
  }

  void _paintFloatingChrome(Canvas canvas, FloatingSelection floating) {
    final rect = Rect.fromLTWH(
      floating.offsetX.toDouble(),
      floating.offsetY.toDouble(),
      floating.width.toDouble(),
      floating.height.toDouble(),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / scale
        ..color = const Color(0xffffc107),
    );
    final handle = Paint()..color = const Color(0xffffc107);
    final r = 4.0 / scale;
    for (final corner in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight
    ]) {
      canvas.drawRect(Rect.fromCircle(center: corner, radius: r), handle);
    }
  }

  void _paintHover(Canvas canvas, int w, int h) {
    final x = hover!.dx.floor();
    final y = hover!.dy.floor();
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final brush = state.brushSize;
    final start = -(brush - 1) ~/ 2;
    canvas.drawRect(
      Rect.fromLTWH((x + start).toDouble(), (y + start).toDouble(),
          brush.toDouble(), brush.toDouble()),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale
        ..color = const Color(0xeeffffff),
    );
  }

  @override
  bool shouldRepaint(_PixelCanvasPainter oldDelegate) =>
      oldDelegate.state.revision != state.revision ||
      oldDelegate.state.canvasImage != state.canvasImage ||
      oldDelegate.state.floatingImage != state.floatingImage ||
      oldDelegate.scale != scale ||
      oldDelegate.hover != hover ||
      oldDelegate.state.showPixelGrid != state.showPixelGrid ||
      oldDelegate.state.showCellGrid != state.showCellGrid ||
      oldDelegate.state.symmetry != state.symmetry ||
      oldDelegate.state.brushSize != state.brushSize;
}

/// Left-button drag recognizer that ignores trackpad pan-zoom pointers, same
/// as the Phase 1/2 canvases (two-finger scroll must pan the view, not draw).
class _LeftClickPanGestureRecognizer extends PanGestureRecognizer {
  _LeftClickPanGestureRecognizer({super.allowedButtonsFilter});

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {}
}
