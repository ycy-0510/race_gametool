import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../logic/pal_file.dart';
import '../logic/pixel_ops.dart';
import '../models/block_def.dart';
import '../models/pixel_document.dart';
import 'app_providers.dart';
import 'asset_definer_providers.dart';

/// Tools of the pixel editor toolbar.
enum PixelTool {
  pencil('Pencil'),
  eraser('Eraser'),
  line('Line'),
  rect('Rectangle'),
  ellipse('Ellipse'),
  fill('Fill / Replace'),
  eyedropper('Eyedropper'),
  selectRect('Select Rectangle'),
  lasso('Lasso'),
  wand('Magic Wand'),
  move('Move / Transform');

  const PixelTool(this.label);
  final String label;
}

const _minCanvasSide = 1;
const _maxCanvasSide = 1024;

/// DawnBringer 32, a common general-purpose pixel-art palette; the default
/// palette for new sessions.
const defaultPixelPalette = <int>[
  0xff000000, 0xff222034, 0xff45283c, 0xff663931,
  0xff8f563b, 0xffdf7126, 0xffd9a066, 0xffeec39a,
  0xfffbf236, 0xff99e550, 0xff6abe30, 0xff37946e,
  0xff4b692f, 0xff524b24, 0xff323c39, 0xff3f3f74,
  0xff306082, 0xff5b6ee1, 0xff639bff, 0xff5fcde4,
  0xffcbdbfc, 0xffffffff, 0xff9badb7, 0xff847e87,
  0xff696a6a, 0xff595652, 0xff76428a, 0xffac3232,
  0xffd95763, 0xffd77bba, 0xff8f974a, 0xff8a6f30,
];

/// Selection pixels lifted off the layer, movable and scalable before being
/// stamped back down. [original] keeps the pixels as lifted so repeated
/// nearest-neighbor scaling always resamples from the source (no compounding
/// loss).
class FloatingSelection {
  const FloatingSelection({
    required this.pixels,
    required this.width,
    required this.height,
    required this.offsetX,
    required this.offsetY,
    required this.original,
    required this.originalWidth,
    required this.originalHeight,
  });

  final Uint32List pixels;
  final int width;
  final int height;
  final int offsetX;
  final int offsetY;
  final Uint32List original;
  final int originalWidth;
  final int originalHeight;

  FloatingSelection copyWith({
    Uint32List? pixels,
    int? width,
    int? height,
    int? offsetX,
    int? offsetY,
    Uint32List? original,
    int? originalWidth,
    int? originalHeight,
  }) =>
      FloatingSelection(
        pixels: pixels ?? this.pixels,
        width: width ?? this.width,
        height: height ?? this.height,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
        original: original ?? this.original,
        originalWidth: originalWidth ?? this.originalWidth,
        originalHeight: originalHeight ?? this.originalHeight,
      );
}

/// The in-progress rectangle of a Select Rectangle drag, in pixel coords.
class SelectDraft {
  const SelectDraft(this.x0, this.y0, this.x1, this.y1);
  final int x0, y0, x1, y1;
}

class _Snapshot {
  _Snapshot(this.document, this.selection);
  final PixelDocument document;
  final Uint8List? selection;
}

class PixelEditorState {
  const PixelEditorState({
    required this.document,
    this.tool = PixelTool.pencil,
    this.color = 0xff000000,
    this.palette = defaultPixelPalette,
    this.brushSize = 1,
    this.fillTolerance = 0,
    this.fillContiguous = true,
    this.symmetry = SymmetryMode.none,
    this.showPixelGrid = true,
    this.showCellGrid = true,
    this.canvasImage,
    this.floatingImage,
    this.revision = 0,
    this.selection,
    this.floating,
    this.selectDraft,
    this.lassoDraft,
    this.isDirty = false,
    this.filePath,
    this.statusMessage,
    this.canUndo = false,
    this.canRedo = false,
  });

  final PixelDocument document;
  final PixelTool tool;

  /// Active drawing color, ARGB.
  final int color;

  /// The indexed palette, ARGB entries.
  final List<int> palette;

  final int brushSize;

  /// Fill tool matching tolerance, 0..255 per channel.
  final int fillTolerance;

  /// Fill tool: true flood-fills the connected region, false recolors every
  /// matching pixel (color replace).
  final bool fillContiguous;

  final SymmetryMode symmetry;
  final bool showPixelGrid;
  final bool showCellGrid;

  /// Composited document, rebuilt after every change; what the canvas draws.
  final ui.Image? canvasImage;

  /// The floating selection's pixels as an image, drawn above [canvasImage].
  final ui.Image? floatingImage;

  /// Bumped on every visual change so the painter always repaints, even when
  /// the image object arrives asynchronously.
  final int revision;

  /// Active selection mask (document-sized, non-zero = selected), or null
  /// when nothing is selected.
  final Uint8List? selection;

  final FloatingSelection? floating;
  final SelectDraft? selectDraft;

  /// Lasso polygon vertices collected during the drag, in pixel coords.
  final List<(double, double)>? lassoDraft;

  final bool isDirty;
  final String? filePath;
  final String? statusMessage;
  final bool canUndo;
  final bool canRedo;

  PixelEditorState copyWith({
    PixelDocument? document,
    PixelTool? tool,
    int? color,
    List<int>? palette,
    int? brushSize,
    int? fillTolerance,
    bool? fillContiguous,
    SymmetryMode? symmetry,
    bool? showPixelGrid,
    bool? showCellGrid,
    ui.Image? Function()? canvasImage,
    ui.Image? Function()? floatingImage,
    int? revision,
    Uint8List? Function()? selection,
    FloatingSelection? Function()? floating,
    SelectDraft? Function()? selectDraft,
    List<(double, double)>? Function()? lassoDraft,
    bool? isDirty,
    String? Function()? filePath,
    String? Function()? statusMessage,
    bool? canUndo,
    bool? canRedo,
  }) =>
      PixelEditorState(
        document: document ?? this.document,
        tool: tool ?? this.tool,
        color: color ?? this.color,
        palette: palette ?? this.palette,
        brushSize: brushSize ?? this.brushSize,
        fillTolerance: fillTolerance ?? this.fillTolerance,
        fillContiguous: fillContiguous ?? this.fillContiguous,
        symmetry: symmetry ?? this.symmetry,
        showPixelGrid: showPixelGrid ?? this.showPixelGrid,
        showCellGrid: showCellGrid ?? this.showCellGrid,
        canvasImage: canvasImage != null ? canvasImage() : this.canvasImage,
        floatingImage:
            floatingImage != null ? floatingImage() : this.floatingImage,
        revision: revision ?? this.revision,
        selection: selection != null ? selection() : this.selection,
        floating: floating != null ? floating() : this.floating,
        selectDraft: selectDraft != null ? selectDraft() : this.selectDraft,
        lassoDraft: lassoDraft != null ? lassoDraft() : this.lassoDraft,
        isDirty: isDirty ?? this.isDirty,
        filePath: filePath != null ? filePath() : this.filePath,
        statusMessage:
            statusMessage != null ? statusMessage() : this.statusMessage,
        canUndo: canUndo ?? this.canUndo,
        canRedo: canRedo ?? this.canRedo,
      );
}

class PixelEditorNotifier extends Notifier<PixelEditorState> {
  // Undo history. Snapshots are full document clones; at the tool's canvas
  // sizes (<= 1024 square) this is simple and fast. Capped so marathon
  // sessions cannot exhaust memory.
  static const _historyCap = 256;
  final List<_Snapshot> _undoStack = [];
  final List<_Snapshot> _redoStack = [];

  // Stroke-in-progress bookkeeping.
  Uint32List? _strokeBase;
  (int, int)? _shapeAnchor;
  (int, int)? _lastStrokePoint;

  // Move-tool drag bookkeeping.
  (int, int)? _moveGrabOffset;
  int? _scaleCorner; // 0 TL, 1 TR, 2 BL, 3 BR

  int _imageGeneration = 0;
  int _floatingGeneration = 0;
  bool _disposed = false;

  @override
  PixelEditorState build() {
    ref.onDispose(() => _disposed = true);
    final state = PixelEditorState(document: PixelDocument.blank(128, 128));
    _scheduleRebuild(state.document);
    return state;
  }

  PixelLayer get _layer => state.document.layers.first;
  int get _w => state.document.width;
  int get _h => state.document.height;

  // --- Image cache ----------------------------------------------------------

  /// Rebuilds the composited canvas image asynchronously. A generation
  /// counter drops stale results when edits outpace decoding.
  void _scheduleRebuild(PixelDocument document) {
    final generation = ++_imageGeneration;
    final bytes = pixelsToRgbaBytes(document.composite());
    ui.decodeImageFromPixels(
      bytes,
      document.width,
      document.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (_disposed || generation != _imageGeneration) {
          image.dispose();
          return;
        }
        state.canvasImage?.dispose();
        state = state.copyWith(
          canvasImage: () => image,
          revision: state.revision + 1,
        );
      },
    );
  }

  void _scheduleFloatingRebuild(FloatingSelection? floating) {
    final generation = ++_floatingGeneration;
    if (floating == null) {
      state.floatingImage?.dispose();
      state = state.copyWith(
        floatingImage: () => null,
        revision: state.revision + 1,
      );
      return;
    }
    ui.decodeImageFromPixels(
      pixelsToRgbaBytes(floating.pixels),
      floating.width,
      floating.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (_disposed || generation != _floatingGeneration) {
          image.dispose();
          return;
        }
        state.floatingImage?.dispose();
        state = state.copyWith(
          floatingImage: () => image,
          revision: state.revision + 1,
        );
      },
    );
  }

  void _touch({bool dirty = true, String? status}) {
    state = state.copyWith(
      revision: state.revision + 1,
      isDirty: dirty ? true : null,
      statusMessage: status == null ? null : () => status,
    );
    _scheduleRebuild(state.document);
  }

  // --- History --------------------------------------------------------------

  void _pushUndo() {
    _undoStack.add(_Snapshot(
      state.document.clone(),
      state.selection == null ? null : Uint8List.fromList(state.selection!),
    ));
    if (_undoStack.length > _historyCap) _undoStack.removeAt(0);
    _redoStack.clear();
    state = state.copyWith(canUndo: true, canRedo: false);
  }

  void undo() {
    if (_strokeBase != null || state.lassoDraft != null) return;
    if (_undoStack.isEmpty) return;
    _commitFloating(silent: true);
    // _commitFloating may itself have pushed nothing; the floating case is
    // committed as part of the state being undone.
    if (_undoStack.isEmpty) return;
    _redoStack.add(_Snapshot(
      state.document.clone(),
      state.selection == null ? null : Uint8List.fromList(state.selection!),
    ));
    final snapshot = _undoStack.removeLast();
    state = state.copyWith(
      document: snapshot.document,
      selection: () => snapshot.selection,
      canUndo: _undoStack.isNotEmpty,
      canRedo: true,
      statusMessage: () => 'Undo',
    );
    _touch(dirty: true);
  }

  void redo() {
    if (_strokeBase != null || state.lassoDraft != null) return;
    if (_redoStack.isEmpty) return;
    _undoStack.add(_Snapshot(
      state.document.clone(),
      state.selection == null ? null : Uint8List.fromList(state.selection!),
    ));
    final snapshot = _redoStack.removeLast();
    state = state.copyWith(
      document: snapshot.document,
      selection: () => snapshot.selection,
      canUndo: true,
      canRedo: _redoStack.isNotEmpty,
      statusMessage: () => 'Redo',
    );
    _touch(dirty: true);
  }

  // --- Settings -------------------------------------------------------------

  void setTool(PixelTool tool) {
    if (tool != PixelTool.move) _commitFloating();
    state = state.copyWith(
      tool: tool,
      selectDraft: () => null,
      lassoDraft: () => null,
      statusMessage: () => tool.label,
    );
  }

  void setColor(int argb) => state = state.copyWith(color: argb);

  void setBrushSize(int size) =>
      state = state.copyWith(brushSize: size.clamp(1, 8));

  void setFillTolerance(int tolerance) =>
      state = state.copyWith(fillTolerance: tolerance.clamp(0, 255));

  void setFillContiguous(bool contiguous) =>
      state = state.copyWith(fillContiguous: contiguous);

  void setSymmetry(SymmetryMode mode) => state = state.copyWith(
        symmetry: mode,
        statusMessage: () => 'Symmetry: ${mode.jsonValue}',
      );

  void togglePixelGrid() =>
      state = state.copyWith(showPixelGrid: !state.showPixelGrid);

  void toggleCellGrid() =>
      state = state.copyWith(showCellGrid: !state.showCellGrid);

  // --- Palette --------------------------------------------------------------

  void addCurrentColorToPalette() {
    if (state.palette.contains(state.color)) {
      state = state.copyWith(
          statusMessage: () => 'Color already in the palette');
      return;
    }
    state = state.copyWith(
      palette: [...state.palette, state.color],
      isDirty: true,
    );
  }

  void removePaletteColor(int index) {
    if (index < 0 || index >= state.palette.length) return;
    state = state.copyWith(
      palette: [...state.palette]..removeAt(index),
      isDirty: true,
    );
  }

  Future<void> importPalette() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import palette (.pal)',
      type: FileType.custom,
      allowedExtensions: ['pal'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    try {
      final palette = decodeJascPal(utf8.decode(bytes, allowMalformed: true));
      state = state.copyWith(
        palette: palette,
        isDirty: true,
        statusMessage: () =>
            'Imported ${palette.length} colors from ${result!.files.single.name}',
      );
    } on FormatException catch (e) {
      state = state.copyWith(
          statusMessage: () => 'Palette import failed: ${e.message}');
    }
  }

  Future<void> exportPalette() async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export palette (.pal)',
      fileName: 'palette.pal',
      type: FileType.custom,
      allowedExtensions: ['pal'],
      bytes: Uint8List.fromList(utf8.encode(encodeJascPal(state.palette))),
    );
    if (path != null) {
      state = state.copyWith(statusMessage: () => 'Palette saved to $path');
    }
  }

  // --- Selection ------------------------------------------------------------

  void selectAll() {
    _commitFloating();
    state = state.copyWith(
      selection: () => Uint8List(_w * _h)..fillRange(0, _w * _h, 1),
      statusMessage: () => 'All selected',
    );
  }

  void clearSelection() {
    _commitFloating();
    state = state.copyWith(selection: () => null);
  }

  /// Esc: drop a floating selection back where it was lifted from, else
  /// deselect.
  void cancelFloatingOrSelection() {
    if (state.floating != null) {
      // The lift pushed an undo snapshot; restoring it is the cancel.
      final snapshot = _undoStack.removeLast();
      state = state.copyWith(
        document: snapshot.document,
        selection: () => snapshot.selection,
        floating: () => null,
        canUndo: _undoStack.isNotEmpty,
        statusMessage: () => 'Move cancelled',
      );
      _scheduleFloatingRebuild(null);
      _touch();
      return;
    }
    if (state.selection != null) clearSelection();
  }

  /// Deletes the selected pixels (or drops the floating selection).
  void deleteSelectionContents() {
    if (state.floating != null) {
      // Pixels were already lifted off the layer; dropping the float deletes
      // them. The lift's undo snapshot restores everything.
      state = state.copyWith(
        floating: () => null,
        selection: () => null,
        statusMessage: () => 'Selection deleted',
      );
      _scheduleFloatingRebuild(null);
      _touch();
      return;
    }
    final selection = state.selection;
    if (selection == null) return;
    _pushUndo();
    final pixels = _layer.pixels;
    for (var i = 0; i < pixels.length; i++) {
      if (selection[i] != 0) pixels[i] = 0;
    }
    state = state.copyWith(selection: () => null);
    _touch(status: 'Selection deleted');
  }

  // --- Floating selection (move/transform) -----------------------------------

  void _liftSelection() {
    final selection = state.selection;
    if (selection == null) return;
    final bounds = maskBounds(selection, _w, _h);
    if (bounds == null) return;
    _pushUndo();
    final lifted = liftMaskedPixels(_layer.pixels, _w, _h, selection, bounds);
    final (left, top, right, bottom) = bounds;
    final fw = right - left + 1, fh = bottom - top + 1;
    final floating = FloatingSelection(
      pixels: lifted,
      width: fw,
      height: fh,
      offsetX: left,
      offsetY: top,
      original: Uint32List.fromList(lifted),
      originalWidth: fw,
      originalHeight: fh,
    );
    state = state.copyWith(
      floating: () => floating,
      selection: () => null,
    );
    _scheduleFloatingRebuild(floating);
    _touch();
  }

  /// Stamps the floating pixels down and re-derives the selection from their
  /// footprint, so the moved region stays selected.
  void _commitFloating({bool silent = false}) {
    final floating = state.floating;
    if (floating == null) return;
    blit(_layer.pixels, _w, _h, floating.pixels, floating.width,
        floating.height, floating.offsetX, floating.offsetY);
    final selection = Uint8List(_w * _h);
    for (var y = 0; y < floating.height; y++) {
      final ty = floating.offsetY + y;
      if (ty < 0 || ty >= _h) continue;
      for (var x = 0; x < floating.width; x++) {
        final tx = floating.offsetX + x;
        if (tx < 0 || tx >= _w) continue;
        if ((floating.pixels[y * floating.width + x] >>> 24) != 0) {
          selection[ty * _w + tx] = 1;
        }
      }
    }
    state = state.copyWith(
      floating: () => null,
      selection: () => selection,
      statusMessage: silent ? null : () => 'Selection placed',
    );
    _scheduleFloatingRebuild(null);
    _touch();
  }

  /// The canvas widget hit-tests scale handles (their size is zoom
  /// dependent) and reports the grabbed corner here before the drag.
  void startHandleScale(int corner) {
    if (state.floating == null) return;
    _scaleCorner = corner;
  }

  void _transformFloating(
      FloatingSelection Function(FloatingSelection) transform) {
    var floating = state.floating;
    if (floating == null) {
      if (state.selection == null) return;
      _liftSelection();
      floating = state.floating;
      if (floating == null) return;
    }
    final next = transform(floating);
    state = state.copyWith(floating: () => next, isDirty: true);
    _scheduleFloatingRebuild(next);
    state = state.copyWith(revision: state.revision + 1);
  }

  /// Rotates the floating selection (lifting the selection if needed), or
  /// with no selection the whole canvas.
  void rotate90Action({required bool clockwise}) {
    if (state.floating != null || state.selection != null) {
      _transformFloating((f) {
        final pixels =
            rotate90(f.pixels, f.width, f.height, clockwise: clockwise);
        final original = rotate90(f.original, f.originalWidth, f.originalHeight,
            clockwise: clockwise);
        return f.copyWith(
          pixels: pixels,
          width: f.height,
          height: f.width,
          original: original,
          originalWidth: f.originalHeight,
          originalHeight: f.originalWidth,
        );
      });
      return;
    }
    _pushUndo();
    final doc = state.document;
    final layers = [
      for (final layer in doc.layers)
        layer.copyWith(
            pixels:
                rotate90(layer.pixels, doc.width, doc.height, clockwise: clockwise)),
    ];
    state = state.copyWith(
      document: PixelDocument(
          width: doc.height, height: doc.width, layers: layers),
    );
    _touch(status: 'Canvas rotated');
  }

  /// Flips the floating selection (lifting if needed), or the whole canvas.
  void flipAction({required bool horizontal}) {
    if (state.floating != null || state.selection != null) {
      _transformFloating((f) {
        final pixels = Uint32List.fromList(f.pixels);
        final original = Uint32List.fromList(f.original);
        if (horizontal) {
          flipHorizontal(pixels, f.width, f.height);
          flipHorizontal(original, f.originalWidth, f.originalHeight);
        } else {
          flipVertical(pixels, f.width, f.height);
          flipVertical(original, f.originalWidth, f.originalHeight);
        }
        return f.copyWith(pixels: pixels, original: original);
      });
      return;
    }
    _pushUndo();
    for (final layer in state.document.layers) {
      if (horizontal) {
        flipHorizontal(layer.pixels, _w, _h);
      } else {
        flipVertical(layer.pixels, _w, _h);
      }
    }
    _touch(status: 'Canvas flipped');
  }

  // --- Canvas size ----------------------------------------------------------

  /// Anchor components are -1 (keep start edge), 0 (center), 1 (keep end).
  void resizeCanvasTo(int width, int height, {int anchorX = -1, int anchorY = -1}) {
    final w = width.clamp(_minCanvasSide, _maxCanvasSide);
    final h = height.clamp(_minCanvasSide, _maxCanvasSide);
    if (w == _w && h == _h) return;
    _commitFloating(silent: true);
    _pushUndo();
    final doc = state.document;
    final layers = [
      for (final layer in doc.layers)
        layer.copyWith(
            pixels: resizeCanvas(layer.pixels, doc.width, doc.height, w, h,
                anchorX: anchorX, anchorY: anchorY)),
    ];
    state = state.copyWith(
      document: PixelDocument(width: w, height: h, layers: layers),
      selection: () => null,
    );
    _touch(status: 'Canvas resized to $w x $h');
  }

  void cropToSelection() {
    final selection = state.selection;
    if (selection == null) return;
    final bounds = maskBounds(selection, _w, _h);
    if (bounds == null) return;
    _commitFloating(silent: true);
    _pushUndo();
    final doc = state.document;
    final (left, top, right, bottom) = bounds;
    final layers = [
      for (final layer in doc.layers)
        layer.copyWith(
            pixels: cropCanvas(layer.pixels, doc.width, doc.height, bounds)),
    ];
    state = state.copyWith(
      document: PixelDocument(
          width: right - left + 1, height: bottom - top + 1, layers: layers),
      selection: () => null,
    );
    _touch(status: 'Cropped to selection');
  }

  // --- Drawing gestures -------------------------------------------------------

  (int, int) _clampPoint(double x, double y) =>
      (x.floor().clamp(0, _w - 1), y.floor().clamp(0, _h - 1));

  bool _insideSelection(int x, int y) {
    final selection = state.selection;
    if (selection == null) return false;
    if (x < 0 || y < 0 || x >= _w || y >= _h) return false;
    return selection[y * _w + x] != 0;
  }

  bool _insideFloating(int x, int y) {
    final f = state.floating;
    if (f == null) return false;
    return x >= f.offsetX &&
        y >= f.offsetY &&
        x < f.offsetX + f.width &&
        y < f.offsetY + f.height;
  }

  /// Draws one brush segment (with symmetry) from [from] to [to] on the live
  /// layer buffer.
  void _paintSegment((int, int) from, (int, int) to, int color) {
    final fromPts = symmetryPoints(from.$1, from.$2, _w, _h, state.symmetry);
    final toPts = symmetryPoints(to.$1, to.$2, _w, _h, state.symmetry);
    for (var i = 0; i < fromPts.length; i++) {
      drawLine(_layer.pixels, _w, _h, fromPts[i].$1, fromPts[i].$2,
          toPts[i].$1, toPts[i].$2, color,
          brushSize: state.brushSize, mask: state.selection);
    }
  }

  void _paintShape((int, int) from, (int, int) to) {
    final fromPts = symmetryPoints(from.$1, from.$2, _w, _h, state.symmetry);
    final toPts = symmetryPoints(to.$1, to.$2, _w, _h, state.symmetry);
    for (var i = 0; i < fromPts.length; i++) {
      final (x0, y0) = fromPts[i];
      final (x1, y1) = toPts[i];
      switch (state.tool) {
        case PixelTool.line:
          drawLine(_layer.pixels, _w, _h, x0, y0, x1, y1, state.color,
              brushSize: state.brushSize, mask: state.selection);
        case PixelTool.rect:
          drawRectShape(_layer.pixels, _w, _h, x0, y0, x1, y1, state.color,
              brushSize: state.brushSize, mask: state.selection);
        case PixelTool.ellipse:
          drawEllipseShape(_layer.pixels, _w, _h, x0, y0, x1, y1, state.color,
              brushSize: state.brushSize, mask: state.selection);
        default:
          break;
      }
    }
  }

  void strokeStart(double px, double py) {
    final (x, y) = _clampPoint(px, py);
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
        _strokeBase = Uint32List.fromList(_layer.pixels);
        _lastStrokePoint = (x, y);
        final color = state.tool == PixelTool.eraser ? 0 : state.color;
        _paintSegment((x, y), (x, y), color);
        _touch();
      case PixelTool.line:
      case PixelTool.rect:
      case PixelTool.ellipse:
        _strokeBase = Uint32List.fromList(_layer.pixels);
        _shapeAnchor = (x, y);
        _paintShape((x, y), (x, y));
        _touch();
      case PixelTool.selectRect:
        _commitFloating(silent: true);
        _shapeAnchor = (x, y);
        state = state.copyWith(
          selectDraft: () => SelectDraft(x, y, x, y),
          revision: state.revision + 1,
        );
      case PixelTool.lasso:
        _commitFloating(silent: true);
        state = state.copyWith(
          lassoDraft: () => [(px, py)],
          revision: state.revision + 1,
        );
      case PixelTool.move:
        if (_scaleCorner != null) return; // handle grab set by the widget
        if (_insideFloating(x, y)) {
          final f = state.floating!;
          _moveGrabOffset = (x - f.offsetX, y - f.offsetY);
        } else if (_insideSelection(x, y)) {
          _liftSelection();
          final f = state.floating;
          if (f != null) _moveGrabOffset = (x - f.offsetX, y - f.offsetY);
        } else {
          _commitFloating();
        }
      case PixelTool.fill:
      case PixelTool.eyedropper:
      case PixelTool.wand:
        break; // tap-only tools
    }
  }

  void strokeUpdate(double px, double py) {
    final (x, y) = _clampPoint(px, py);
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
        if (_strokeBase == null) return;
        final last = _lastStrokePoint ?? (x, y);
        if (last == (x, y)) return;
        final color = state.tool == PixelTool.eraser ? 0 : state.color;
        _paintSegment(last, (x, y), color);
        _lastStrokePoint = (x, y);
        _touch();
      case PixelTool.line:
      case PixelTool.rect:
      case PixelTool.ellipse:
        final base = _strokeBase;
        final anchor = _shapeAnchor;
        if (base == null || anchor == null) return;
        _layer.pixels.setAll(0, base);
        _paintShape(anchor, (x, y));
        _touch();
      case PixelTool.selectRect:
        final anchor = _shapeAnchor;
        if (anchor == null) return;
        state = state.copyWith(
          selectDraft: () => SelectDraft(anchor.$1, anchor.$2, x, y),
          revision: state.revision + 1,
        );
      case PixelTool.lasso:
        final draft = state.lassoDraft;
        if (draft == null) return;
        state = state.copyWith(
          lassoDraft: () => [...draft, (px, py)],
          revision: state.revision + 1,
        );
      case PixelTool.move:
        final corner = _scaleCorner;
        if (corner != null) {
          _scaleFloatingTo(corner, x, y);
          return;
        }
        final grab = _moveGrabOffset;
        final f = state.floating;
        if (grab == null || f == null) return;
        final next = f.copyWith(offsetX: x - grab.$1, offsetY: y - grab.$2);
        state = state.copyWith(
          floating: () => next,
          isDirty: true,
          revision: state.revision + 1,
        );
      case PixelTool.fill:
      case PixelTool.eyedropper:
      case PixelTool.wand:
        break;
    }
  }

  void strokeEnd() {
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
      case PixelTool.line:
      case PixelTool.rect:
      case PixelTool.ellipse:
        final base = _strokeBase;
        if (base == null) return;
        _strokeBase = null;
        _shapeAnchor = null;
        _lastStrokePoint = null;
        // History records the pre-stroke buffer; the live buffer already
        // holds the result.
        final result = Uint32List.fromList(_layer.pixels);
        _layer.pixels.setAll(0, base);
        _pushUndo();
        _layer.pixels.setAll(0, result);
        _touch();
      case PixelTool.selectRect:
        final draft = state.selectDraft;
        _shapeAnchor = null;
        if (draft == null) return;
        final mask = rectMask(_w, _h, draft.x0, draft.y0, draft.x1, draft.y1);
        state = state.copyWith(
          selection: () => mask,
          selectDraft: () => null,
          revision: state.revision + 1,
          statusMessage: () => 'Selected',
        );
      case PixelTool.lasso:
        final draft = state.lassoDraft;
        if (draft == null) return;
        final mask = draft.length >= 3 ? polygonMask(_w, _h, draft) : null;
        final hasAny = mask != null && mask.any((v) => v != 0);
        state = state.copyWith(
          selection: () => hasAny ? mask : null,
          lassoDraft: () => null,
          revision: state.revision + 1,
          statusMessage: () => hasAny ? 'Selected' : 'Empty selection',
        );
      case PixelTool.move:
        _moveGrabOffset = null;
        _scaleCorner = null;
      case PixelTool.fill:
      case PixelTool.eyedropper:
      case PixelTool.wand:
        break;
    }
  }

  void _scaleFloatingTo(int corner, int x, int y) {
    final f = state.floating;
    if (f == null) return;
    // The corner opposite the grabbed one stays fixed.
    final fixedX = corner == 0 || corner == 2 ? f.offsetX + f.width - 1 : f.offsetX;
    final fixedY = corner == 0 || corner == 1 ? f.offsetY + f.height - 1 : f.offsetY;
    final left = x < fixedX ? x : fixedX;
    final right = x < fixedX ? fixedX : x;
    final top = y < fixedY ? y : fixedY;
    final bottom = y < fixedY ? fixedY : y;
    final w = right - left + 1;
    final h = bottom - top + 1;
    final next = f.copyWith(
      pixels: scaleNearest(f.original, f.originalWidth, f.originalHeight, w, h),
      width: w,
      height: h,
      offsetX: left,
      offsetY: top,
    );
    state = state.copyWith(
      floating: () => next,
      isDirty: true,
      revision: state.revision + 1,
    );
    _scheduleFloatingRebuild(next);
  }

  void tapAt(double px, double py) {
    final (x, y) = _clampPoint(px, py);
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
        _strokeBase = Uint32List.fromList(_layer.pixels);
        final color = state.tool == PixelTool.eraser ? 0 : state.color;
        _paintSegment((x, y), (x, y), color);
        strokeEnd();
      case PixelTool.fill:
        _pushUndo();
        for (final (sx, sy) in symmetryPoints(x, y, _w, _h, state.symmetry)) {
          floodFill(_layer.pixels, _w, _h, sx, sy, state.color,
              tolerance: state.fillTolerance,
              contiguous: state.fillContiguous,
              mask: state.selection);
        }
        _touch(status: state.fillContiguous ? 'Filled' : 'Color replaced');
      case PixelTool.eyedropper:
        final composite = state.document.composite();
        final picked = composite[y * _w + x];
        if ((picked >>> 24) == 0) {
          state = state.copyWith(
              statusMessage: () => 'Transparent pixel: color kept');
        } else {
          state = state.copyWith(
            color: picked,
            statusMessage: () => 'Picked color',
          );
        }
      case PixelTool.wand:
        _commitFloating(silent: true);
        final mask = magicWandMask(_layer.pixels, _w, _h, x, y,
            tolerance: state.fillTolerance, contiguous: state.fillContiguous);
        final hasAny = mask.any((v) => v != 0);
        state = state.copyWith(
          selection: () => hasAny ? mask : null,
          revision: state.revision + 1,
          statusMessage: () => hasAny ? 'Selected' : 'Nothing selected',
        );
      case PixelTool.selectRect:
      case PixelTool.lasso:
        _commitFloating(silent: true);
        state = state.copyWith(
          selection: () => null,
          revision: state.revision + 1,
        );
      case PixelTool.move:
        _scaleCorner = null;
        if (state.floating != null && !_insideFloating(x, y)) {
          _commitFloating();
        }
      case PixelTool.line:
      case PixelTool.rect:
      case PixelTool.ellipse:
        break;
    }
  }

  // --- Files ------------------------------------------------------------------

  void newDocument(int width, int height) {
    final w = width.clamp(_minCanvasSide, _maxCanvasSide);
    final h = height.clamp(_minCanvasSide, _maxCanvasSide);
    _undoStack.clear();
    _redoStack.clear();
    _strokeBase = null;
    state = state.copyWith(
      document: PixelDocument.blank(w, h),
      selection: () => null,
      floating: () => null,
      selectDraft: () => null,
      lassoDraft: () => null,
      isDirty: false,
      filePath: () => null,
      canUndo: false,
      canRedo: false,
      statusMessage: () => 'New $w x $h canvas',
    );
    _scheduleFloatingRebuild(null);
    _scheduleRebuild(state.document);
  }

  RgpixFile _currentFile() {
    // Serialize with the floating selection stamped down, without disturbing
    // the live editing state.
    final doc = state.document.clone();
    final floating = state.floating;
    if (floating != null) {
      blit(doc.layers.first.pixels, doc.width, doc.height, floating.pixels,
          floating.width, floating.height, floating.offsetX, floating.offsetY);
    }
    return RgpixFile(
      document: doc,
      palette: state.palette,
      showPixelGrid: state.showPixelGrid,
      showCellGrid: state.showCellGrid,
      symmetry: state.symmetry.jsonValue,
    );
  }

  Future<void> save() async {
    final path = state.filePath;
    if (path == null) {
      await saveAs();
      return;
    }
    try {
      await File(path).writeAsString(_currentFile().encode());
    } catch (e) {
      state = state.copyWith(statusMessage: () => 'Save failed: $e');
      return;
    }
    state = state.copyWith(
      isDirty: false,
      statusMessage: () => 'Saved to $path',
    );
  }

  Future<void> saveAs() async {
    final encoded = _currentFile().encode();
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save pixel project',
      fileName: state.filePath?.split('/').last ?? 'pixel-art.rgpix',
      type: FileType.custom,
      allowedExtensions: ['rgpix'],
      bytes: Uint8List.fromList(utf8.encode(encoded)),
    );
    if (path == null) {
      state = state.copyWith(statusMessage: () => 'Save cancelled');
      return;
    }
    state = state.copyWith(
      isDirty: false,
      filePath: () => path,
      statusMessage: () => 'Saved to $path',
    );
  }

  Future<void> openFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open pixel project',
      type: FileType.custom,
      allowedExtensions: ['rgpix'],
      withData: true,
    );
    final file = result?.files.single;
    if (file?.bytes == null) return;
    final RgpixFile decoded;
    try {
      decoded = RgpixFile.decode(utf8.decode(file!.bytes!));
    } on FormatException catch (e) {
      state = state.copyWith(statusMessage: () => 'Open failed: ${e.message}');
      return;
    }
    _undoStack.clear();
    _redoStack.clear();
    _strokeBase = null;
    state = state.copyWith(
      document: decoded.document,
      palette: decoded.palette.isEmpty ? null : decoded.palette,
      showPixelGrid: decoded.showPixelGrid,
      showCellGrid: decoded.showCellGrid,
      symmetry: SymmetryMode.fromJson(decoded.symmetry),
      selection: () => null,
      floating: () => null,
      isDirty: false,
      filePath: () => file.path,
      canUndo: false,
      canRedo: false,
      statusMessage: () => 'Opened ${file.name}',
    );
    _scheduleFloatingRebuild(null);
    _scheduleRebuild(state.document);
  }

  Uint8List _encodePng() {
    final file = _currentFile();
    final rgba = pixelsToRgbaBytes(file.document.composite());
    final image = img.Image.fromBytes(
      width: file.document.width,
      height: file.document.height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  String get _pngName {
    final base = state.filePath?.split('/').last.replaceAll('.rgpix', '');
    return '${base ?? 'pixel-art'}.png';
  }

  Future<void> exportPng() async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export PNG',
      fileName: _pngName,
      type: FileType.custom,
      allowedExtensions: ['png'],
      bytes: _encodePng(),
    );
    if (path != null) {
      state = state.copyWith(statusMessage: () => 'Exported PNG to $path');
    }
  }

  /// Hands the flattened image straight to Phase 1 as the given category's
  /// source image (decoration: added as a new image) and switches to the
  /// Asset Definer tab.
  Future<void> sendToPhase1(BlockCategory category) async {
    final error = await ref
        .read(assetDefinerProvider.notifier)
        .importImageBytes(_encodePng(), _pngName, category);
    if (error != null) {
      state = state.copyWith(statusMessage: () => error);
      return;
    }
    ref.read(workspaceProvider.notifier).activatePhase1();
    state = state.copyWith(
      statusMessage: () =>
          'Sent to Phase 1 as ${category.jsonValue} image',
    );
  }
}

final pixelEditorProvider =
    NotifierProvider<PixelEditorNotifier, PixelEditorState>(
        PixelEditorNotifier.new);
