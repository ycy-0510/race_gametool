import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../logic/asset_bundle.dart';
import '../logic/port_placement.dart';
import '../models/block_def.dart';
import '../models/mask_draft.dart';
import '../models/port.dart';
import 'app_providers.dart';

/// Interaction tools available in the Phase 1 canvas.
enum Phase1Tool {
  select('Select'),
  move('Move'),
  drawBox('Draw Box'),
  paintMask('Paint Mask'),
  addPort('Add Port');

  const Phase1Tool(this.label);
  final String label;
}

/// A block move in progress, in grid cells. [index] is the mask being
/// moved; [dx]/[dy] is its offset from the original position (already
/// clamped so the block stays within the image).
class MovePreview {
  const MovePreview({required this.index, required this.dx, required this.dy});
  final int index;
  final int dx;
  final int dy;
}

/// A drag-in-progress rectangle, in grid cells. Purely visual feedback;
/// committed on release (a mask box in Draw Box mode, a port strip in
/// Add Port mode).
class DragPreview {
  const DragPreview({
    required this.gridX,
    required this.gridY,
    required this.widthCells,
    required this.heightCells,
  });

  final int gridX;
  final int gridY;
  final int widthCells;
  final int heightCells;
}

/// A loaded source image for one asset category.
class CategoryImage {
  const CategoryImage({
    required this.bytes,
    required this.image,
    required this.name,
  });

  final Uint8List bytes;
  final ui.Image image;
  final String name;
}

class AssetDefinerState {
  const AssetDefinerState({
    this.images = const {},
    this.masksByCategory = const {},
    this.activeCategory = BlockCategory.track,
    this.selectedIndex,
    this.tool = Phase1Tool.drawBox,
    this.dragPreview,
    this.paintPreview,
    this.movePreview,
    this.statusMessage,
  });

  /// One source image per category (only those that have been loaded).
  final Map<BlockCategory, CategoryImage> images;

  /// Masks per category. Each category is authored on its own image.
  final Map<BlockCategory, List<MaskDraft>> masksByCategory;

  /// The category currently being edited (drives the visible image + masks).
  final BlockCategory activeCategory;

  final int? selectedIndex;
  final Phase1Tool tool;

  /// Rectangle preview for Draw Box and Add Port drags.
  final DragPreview? dragPreview;

  /// Absolute cells painted so far during a Paint Mask drag.
  final Set<Cell>? paintPreview;

  /// Block reposition in progress (Move tool).
  final MovePreview? movePreview;

  /// One-shot feedback line shown in the toolbar.
  final String? statusMessage;

  // --- Active-category views (keep the rest of the editor unchanged) --------

  CategoryImage? get activeImage => images[activeCategory];
  Uint8List? get imageBytes => activeImage?.bytes;
  ui.Image? get image => activeImage?.image;
  String? get imageName => activeImage?.name;

  /// Masks of the active category (what the canvas edits).
  List<MaskDraft> get masks => masksByCategory[activeCategory] ?? const [];

  MaskDraft? get selectedMask =>
      selectedIndex == null ? null : masks[selectedIndex!];

  /// All masks across every category, for export.
  List<MaskDraft> get allMasks =>
      [for (final c in BlockCategory.values) ...?masksByCategory[c]];

  bool get canExport => BlockCategory.values.any((c) =>
      images[c] != null && (masksByCategory[c]?.isNotEmpty ?? false));

  AssetDefinerState copyWith({
    Map<BlockCategory, CategoryImage>? images,
    Map<BlockCategory, List<MaskDraft>>? masksByCategory,
    List<MaskDraft>? masks,
    BlockCategory? activeCategory,
    int? Function()? selectedIndex,
    Phase1Tool? tool,
    DragPreview? Function()? dragPreview,
    Set<Cell>? Function()? paintPreview,
    MovePreview? Function()? movePreview,
    String? Function()? statusMessage,
  }) {
    final category = activeCategory ?? this.activeCategory;
    var nextMasks = masksByCategory ?? this.masksByCategory;
    // The `masks` convenience param writes to the active category's list.
    if (masks != null) {
      nextMasks = {...nextMasks, category: masks};
    }
    return AssetDefinerState(
      images: images ?? this.images,
      masksByCategory: nextMasks,
      activeCategory: category,
      selectedIndex:
          selectedIndex != null ? selectedIndex() : this.selectedIndex,
      tool: tool ?? this.tool,
      dragPreview: dragPreview != null ? dragPreview() : this.dragPreview,
      paintPreview: paintPreview != null ? paintPreview() : this.paintPreview,
      movePreview: movePreview != null ? movePreview() : this.movePreview,
      statusMessage:
          statusMessage != null ? statusMessage() : this.statusMessage,
    );
  }
}

class AssetDefinerNotifier extends Notifier<AssetDefinerState> {
  int _nextBlockNumber = 1;
  ({int x, int y})? _dragAnchor;
  Cell? _lastPaintCell;

  @override
  AssetDefinerState build() => const AssetDefinerState();

  void setActiveCategory(BlockCategory category) {
    state = state.copyWith(
      activeCategory: category,
      selectedIndex: () => null,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
      tool: category == BlockCategory.islandTile ? Phase1Tool.drawBox : state.tool,
      statusMessage: () => 'Editing ${category.jsonValue}',
    );
  }

  /// Loads (or replaces) the image for the active category, keeping that
  /// category's existing masks. Replaces the old separate Load + Swap: a
  /// category with no image yet just gets one; re-loading updates the art
  /// and reports any masks that fall outside a smaller image.
  Future<void> loadImage() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Load image for ${state.activeCategory.jsonValue}',
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final image = await completer.future;
    final name = result!.files.single.name;

    final hadImage = state.activeImage != null;
    final cols = (image.width / GridConstants.cellSize).ceil();
    final rows = (image.height / GridConstants.cellSize).ceil();
    final outOfBounds = state.masks
        .where((m) =>
            m.gridX + m.widthCells > cols || m.gridY + m.heightCells > rows)
        .map((m) => m.id)
        .toList();

    state = state.copyWith(
      images: {
        ...state.images,
        state.activeCategory:
            CategoryImage(bytes: bytes, image: image, name: name),
      },
      tool: Phase1Tool.drawBox,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
      statusMessage: () => !hadImage
          ? 'Loaded $name (${image.width} x ${image.height} px)'
          : outOfBounds.isEmpty
              ? 'Replaced image with $name, kept ${state.masks.length} blocks'
              : 'Replaced image; ${outOfBounds.length} block(s) now out of '
                  'bounds: ${outOfBounds.join(', ')}',
    );
  }

  void setTool(Phase1Tool tool) {
    state = state.copyWith(
      tool: tool,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
    );
    _dragAnchor = null;
  }

  /// Grid dimensions of the current image in whole cells.
  (int cols, int rows) get _gridSize {
    final image = state.image;
    if (image == null) return (0, 0);
    return (
      (image.width / GridConstants.cellSize).ceil(),
      (image.height / GridConstants.cellSize).ceil(),
    );
  }

  // --- Drag handling (Draw Box, Paint Mask, Add Port) -----------------------

  void dragStart(int cellX, int cellY) {
    if (state.image == null) return;
    switch (state.tool) {
      case Phase1Tool.drawBox || Phase1Tool.addPort:
        _dragAnchor = (x: cellX, y: cellY);
        state = state.copyWith(
          dragPreview: () => DragPreview(
              gridX: cellX, gridY: cellY, widthCells: 1, heightCells: 1),
        );
      case Phase1Tool.paintMask:
        _lastPaintCell = (cellX, cellY);
        state = state.copyWith(paintPreview: () => {(cellX, cellY)});
      case Phase1Tool.move:
        _startMove(cellX, cellY);
      case Phase1Tool.select:
        break;
    }
  }

  void dragUpdate(int cellX, int cellY) {
    switch (state.tool) {
      case Phase1Tool.drawBox:
        _updateRectPreview(cellX, cellY, clampToStrip: false);
      case Phase1Tool.addPort:
        _updateRectPreview(cellX, cellY, clampToStrip: true);
      case Phase1Tool.move:
        _updateMove(cellX, cellY);
      case Phase1Tool.paintMask:
        final cells = state.paintPreview;
        if (cells == null) return;
        // Interpolate from the previous sample so fast drags leave a
        // continuous stroke instead of scattered cells.
        final from = _lastPaintCell ?? (cellX, cellY);
        _lastPaintCell = (cellX, cellY);
        state = state.copyWith(
            paintPreview: () =>
                {...cells, ..._lineCells(from, (cellX, cellY))});
      case Phase1Tool.select:
        break;
    }
  }

  void _updateRectPreview(int cellX, int cellY, {required bool clampToStrip}) {
    final anchor = _dragAnchor;
    if (anchor == null) return;
    var x = cellX;
    var y = cellY;

    if (state.tool == Phase1Tool.drawBox &&
        state.activeCategory == BlockCategory.islandTile) {
      x = anchor.x;
      y = anchor.y;
    }

    if (clampToStrip) {
      // Port marquees are one row or one column: collapse the minor axis.
      if ((cellX - anchor.x).abs() >= (cellY - anchor.y).abs()) {
        y = anchor.y;
      } else {
        x = anchor.x;
      }
    }
    final x0 = x < anchor.x ? x : anchor.x;
    final y0 = y < anchor.y ? y : anchor.y;
    final x1 = x > anchor.x ? x : anchor.x;
    final y1 = y > anchor.y ? y : anchor.y;
    state = state.copyWith(
      dragPreview: () => DragPreview(
        gridX: x0,
        gridY: y0,
        widthCells: x1 - x0 + 1,
        heightCells: y1 - y0 + 1,
      ),
    );
  }

  /// Bresenham line between two cells, inclusive of both ends.
  static Iterable<Cell> _lineCells(Cell from, Cell to) sync* {
    var (x, y) = from;
    final (x1, y1) = to;
    final dx = (x1 - x).abs();
    final dy = -(y1 - y).abs();
    final sx = x < x1 ? 1 : -1;
    final sy = y < y1 ? 1 : -1;
    var err = dx + dy;
    while (true) {
      yield (x, y);
      if (x == x1 && y == y1) return;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y += sy;
      }
    }
  }

  void dragEnd() {
    _dragAnchor = null;
    _lastPaintCell = null;
    switch (state.tool) {
      case Phase1Tool.drawBox:
        _commitBox();
      case Phase1Tool.paintMask:
        _commitPaintedMask();
      case Phase1Tool.addPort:
        _commitPortStrip();
      case Phase1Tool.move:
        _commitMove();
      case Phase1Tool.select:
        break;
    }
  }

  void tapCell(int cellX, int cellY) {
    switch (state.tool) {
      case Phase1Tool.select || Phase1Tool.move:
        _selectAt(cellX, cellY);
      case Phase1Tool.addPort:
        // A click is a 1x1 marquee.
        state = state.copyWith(
          dragPreview: () => DragPreview(
              gridX: cellX, gridY: cellY, widthCells: 1, heightCells: 1),
        );
        _commitPortStrip();
      case Phase1Tool.drawBox:
        if (state.activeCategory == BlockCategory.islandTile) {
          state = state.copyWith(
            dragPreview: () => DragPreview(
                gridX: cellX, gridY: cellY, widthCells: 1, heightCells: 1),
          );
          _commitBox();
        }
        break;
      case Phase1Tool.paintMask:
        break;
    }
  }

  void _commitBox() {
    final preview = state.dragPreview;
    if (preview == null) return;
    final mask = MaskDraft(
      id: 'block_${_nextBlockNumber++}',
      gridX: preview.gridX,
      gridY: preview.gridY,
      widthCells: preview.widthCells,
      heightCells: preview.heightCells,
      category: state.activeCategory,
    );
    state = state.copyWith(
      masks: [...state.masks, mask],
      selectedIndex: () => state.masks.length,
      dragPreview: () => null,
      statusMessage: () =>
          'Added ${mask.id} (${mask.widthCells} x ${mask.heightCells} cells)',
    );
  }

  // --- Move (reposition an existing block) ----------------------------------

  void _startMove(int cellX, int cellY) {
    for (var i = state.masks.length - 1; i >= 0; i--) {
      if (state.masks[i].containsCell(cellX, cellY)) {
        _dragAnchor = (x: cellX, y: cellY);
        state = state.copyWith(
          selectedIndex: () => i,
          movePreview: () => MovePreview(index: i, dx: 0, dy: 0),
        );
        return;
      }
    }
    // Drag started on empty space: nothing to move.
    _dragAnchor = null;
  }

  void _updateMove(int cellX, int cellY) {
    final anchor = _dragAnchor;
    final move = state.movePreview;
    if (anchor == null || move == null) return;
    final mask = state.masks[move.index];
    final (cols, rows) = _gridSize;
    // Clamp so the whole bounding box stays inside the image.
    final dx = (cellX - anchor.x)
        .clamp(-mask.gridX, cols - mask.widthCells - mask.gridX);
    final dy = (cellY - anchor.y)
        .clamp(-mask.gridY, rows - mask.heightCells - mask.gridY);
    state = state.copyWith(
        movePreview: () => MovePreview(index: move.index, dx: dx, dy: dy));
  }

  void _commitMove() {
    final move = state.movePreview;
    if (move == null) return;
    if (move.dx == 0 && move.dy == 0) {
      state = state.copyWith(movePreview: () => null);
      return;
    }
    final mask = state.masks[move.index];
    final moved = mask.copyWith(
      gridX: mask.gridX + move.dx,
      gridY: mask.gridY + move.dy,
    );
    final masks = [...state.masks];
    masks[move.index] = moved;
    state = state.copyWith(
      masks: masks,
      movePreview: () => null,
      statusMessage: () =>
          'Moved ${moved.id} to (${moved.gridX}, ${moved.gridY})',
    );
  }

  void _commitPaintedMask() {
    final cells = state.paintPreview;
    if (cells == null || cells.isEmpty) return;
    final mask = MaskDraft.fromCells(
      id: 'block_${_nextBlockNumber++}',
      absoluteCells: cells,
      category: state.activeCategory,
    );
    state = state.copyWith(
      masks: [...state.masks, mask],
      selectedIndex: () => state.masks.length,
      paintPreview: () => null,
      statusMessage: () => 'Added freeform ${mask.id} '
          '(${cells.length} cells in a ${mask.widthCells} x '
          '${mask.heightCells} box)',
    );
  }

  void _commitPortStrip() {
    final preview = state.dragPreview;
    if (preview == null) return;

    // Prefer the selected mask when the strip lies inside it; otherwise
    // pick the topmost mask containing the strip and select it.
    var maskIndex = state.selectedIndex;
    if (maskIndex == null ||
        !state.masks[maskIndex]
            .containsRect(preview.gridX, preview.gridY, preview.widthCells,
                preview.heightCells)) {
      maskIndex = null;
      for (var i = state.masks.length - 1; i >= 0; i--) {
        if (state.masks[i].containsRect(preview.gridX, preview.gridY,
            preview.widthCells, preview.heightCells)) {
          maskIndex = i;
          break;
        }
      }
    }
    if (maskIndex == null) {
      state = state.copyWith(
        dragPreview: () => null,
        statusMessage: () => 'Port selection must lie inside a block',
      );
      return;
    }

    final mask = state.masks[maskIndex];
    final placement = resolvePortStrip(
      mask: mask,
      gridX: preview.gridX,
      gridY: preview.gridY,
      widthCells: preview.widthCells,
      heightCells: preview.heightCells,
    );

    switch (placement) {
      case PortPlacementError(:final message):
        state = state.copyWith(
          selectedIndex: () => maskIndex,
          dragPreview: () => null,
          statusMessage: () => message,
        );
      case PortPlacementOk(:final port):
        if (mask.ports.contains(port)) {
          state = state.copyWith(
            selectedIndex: () => maskIndex,
            dragPreview: () => null,
          );
          return;
        }
        final masks = [...state.masks];
        masks[maskIndex] = mask.copyWith(ports: [...mask.ports, port]);
        state = state.copyWith(
          masks: masks,
          selectedIndex: () => maskIndex,
          dragPreview: () => null,
          statusMessage: () => 'Added ${port.bidirectional ? "pass-through " : ""}'
              'port ${port.direction.jsonValue} (span ${port.span}) '
              'on ${mask.id}',
        );
    }
  }

  // --- Selection and editing -------------------------------------------------

  /// Direct selection from the block list, independent of the active tool.
  void selectMask(int? index) =>
      state = state.copyWith(selectedIndex: () => index);

  void _selectAt(int cellX, int cellY) {
    for (var i = state.masks.length - 1; i >= 0; i--) {
      if (state.masks[i].containsCell(cellX, cellY)) {
        state = state.copyWith(selectedIndex: () => i);
        return;
      }
    }
    state = state.copyWith(selectedIndex: () => null);
  }

  void renameMask(int index, String id) =>
      _updateMask(index, state.masks[index].copyWith(id: id));

  void setMaskCategory(int index, BlockCategory category) {
    // Corner marking only applies to island tiles; reset it otherwise.
    _updateMask(
      index,
      state.masks[index].copyWith(
        category: category,
        cornerType: category == BlockCategory.islandTile
            ? state.masks[index].cornerType
            : CornerType.none,
      ),
    );
  }

  void setMaskCornerType(int index, CornerType type) =>
      _updateMask(index, state.masks[index].copyWith(cornerType: type));

  void removeMask(int index) {
    final masks = [...state.masks]..removeAt(index);
    state = state.copyWith(masks: masks, selectedIndex: () => null);
  }

  void updatePort(int maskIndex, int portIndex, Port port) {
    final mask = state.masks[maskIndex];
    final ports = [...mask.ports];
    ports[portIndex] = port;
    _updateMask(maskIndex, mask.copyWith(ports: ports));
  }

  void addPort(int maskIndex, Port port) {
    final mask = state.masks[maskIndex];
    _updateMask(maskIndex, mask.copyWith(ports: [...mask.ports, port]));
  }

  void removePort(int maskIndex, int portIndex) {
    final mask = state.masks[maskIndex];
    final ports = [...mask.ports]..removeAt(portIndex);
    _updateMask(maskIndex, mask.copyWith(ports: ports));
  }

  void _updateMask(int index, MaskDraft mask) {
    final masks = [...state.masks];
    masks[index] = mask;
    state = state.copyWith(masks: masks);
  }

  // --- Bundle save / open ---------------------------------------------------

  /// Writes the single-source-of-truth .rgpack: raw draft image, editor
  /// state (masks and ports), and the derived packed sheet plus sprite
  /// dictionary. Also hands the freshly packed assets to the shared
  /// library so Phase 2 sees them without a reload.
  ///
  /// With the multi-category image architecture, each category's masks are
  /// exported using that category's own source image.
  Future<void> saveBundle() async {
    if (!state.canExport) return;

    final duplicateIds = _findDuplicateIds();
    if (duplicateIds.isNotEmpty) {
      state = state.copyWith(
          statusMessage: () =>
              'Save blocked: duplicate block IDs ${duplicateIds.join(', ')}');
      return;
    }

    // Collect per-category raw images for the multi-source export.
    final categoryImages = <BlockCategory, Uint8List>{};
    for (final c in BlockCategory.values) {
      final catImage = state.images[c];
      final catMasks = state.masksByCategory[c];
      if (catImage != null && catMasks != null && catMasks.isNotEmpty) {
        categoryImages[c] = catImage.bytes;
      }
    }

    final Uint8List bundleBytes;
    try {
      bundleBytes = writeAssetBundle(
        categoryImages: categoryImages,
        imageName: state.imageName ?? 'draft.png',
        masks: state.allMasks,
      );
    } on Object catch (e) {
      state = state.copyWith(statusMessage: () => 'Save failed: $e');
      return;
    }

    final suggestedName = _bundleFileNameFor(state.imageName);
    // On macOS file_picker writes the provided bytes to the chosen path.
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save asset bundle',
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: ['rgpack'],
      bytes: bundleBytes,
    );
    if (path == null) {
      state = state.copyWith(statusMessage: () => 'Save cancelled');
      return;
    }

    // Populate the shared library from the same bundle we just wrote.
    try {
      final data = readAssetBundle(bundleBytes);
      await ref.read(assetLibraryProvider.notifier).loadAssets(
            blocks: data.blocks,
            sheetBytes: data.sheetBytes,
            sourceName: suggestedName,
          );
    } on Object {
      // Non-fatal: the file is saved regardless of the in-memory hand-off.
    }

    state = state.copyWith(
      statusMessage: () =>
          'Saved ${state.allMasks.length} blocks to $path (available in Phase 2)',
    );
  }

  /// Opens a .rgpack back into the Phase 1 editor for further editing.
  Future<void> openBundle() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open asset bundle',
      type: FileType.custom,
      allowedExtensions: ['rgpack'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    await _loadBundleBytes(bytes, sourceName: result!.files.single.name);
  }

  /// Opens a .rgpack given a filesystem path, used when the OS launches or
  /// activates the app with an associated file (Finder double-click,
  /// "Open With"). Under the app sandbox this read is permitted because
  /// Launch Services grants access to the user-opened file.
  Future<void> openBundleFromPath(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      state = state.copyWith(statusMessage: () => 'File not found: $path');
      return;
    }
    final bytes = await file.readAsBytes();
    await _loadBundleBytes(bytes, sourceName: path.split('/').last);
  }

  Future<void> _loadBundleBytes(
    Uint8List bytes, {
    required String sourceName,
  }) async {
    final AssetBundleData data;
    try {
      data = readAssetBundle(bytes);
    } on Object catch (e) {
      state = state.copyWith(statusMessage: () => 'Open failed: $e');
      return;
    }

    // Decode the raw source image for the canvas editor.
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(data.rawImageBytes, completer.complete);
    final image = await completer.future;

    // Group masks by category and build per-category image map.
    // When opening a v1 bundle, all masks share the same source image.
    // We assign each category's masks to the shared raw source image.
    final groupedMasks = <BlockCategory, List<MaskDraft>>{};
    for (final mask in data.masks) {
      groupedMasks.putIfAbsent(mask.category, () => []).add(mask);
    }
    final images = <BlockCategory, CategoryImage>{};
    // Also decode per-category images if the bundle provides them.
    if (data.categoryRawImages.isNotEmpty) {
      for (final entry in data.categoryRawImages.entries) {
        final c = Completer<ui.Image>();
        ui.decodeImageFromList(entry.value, c.complete);
        images[entry.key] = CategoryImage(
          bytes: entry.value,
          image: await c.future,
          name: data.imageName,
        );
      }
    } else {
      // Legacy single-image bundle: share the raw source across all
      // categories that have masks.
      for (final cat in groupedMasks.keys) {
        images[cat] = CategoryImage(
          bytes: data.rawImageBytes,
          image: image,
          name: data.imageName,
        );
      }
    }

    state = AssetDefinerState(
      images: images,
      masksByCategory: groupedMasks,
      activeCategory: groupedMasks.keys.first,
      tool: Phase1Tool.select,
      statusMessage: 'Opened $sourceName (${data.masks.length} blocks)',
    );
    // Keep the highest existing block_N counter so new boxes do not collide.
    _nextBlockNumber = _highestBlockNumber(data.masks) + 1;

    // Also make it available to Phase 2 immediately.
    await ref.read(assetLibraryProvider.notifier).loadAssets(
          blocks: data.blocks,
          sheetBytes: data.sheetBytes,
          sourceName: sourceName,
        );
  }

  static String _bundleFileNameFor(String? imageName) {
    if (imageName == null || imageName.isEmpty) return 'assets.rgpack';
    final dot = imageName.lastIndexOf('.');
    final stem = dot > 0 ? imageName.substring(0, dot) : imageName;
    return '$stem.rgpack';
  }

  static int _highestBlockNumber(List<MaskDraft> masks) {
    var highest = 0;
    final pattern = RegExp(r'^block_(\d+)$');
    for (final mask in masks) {
      final match = pattern.firstMatch(mask.id);
      if (match != null) {
        highest = math.max(highest, int.parse(match.group(1)!));
      }
    }
    return highest;
  }

  List<String> _findDuplicateIds() {
    final seen = <String>{};
    final duplicates = <String>{};
    for (final mask in state.masks) {
      if (!seen.add(mask.id)) duplicates.add(mask.id);
    }
    return duplicates.toList();
  }
}

final assetDefinerProvider =
    NotifierProvider<AssetDefinerNotifier, AssetDefinerState>(
        AssetDefinerNotifier.new);
