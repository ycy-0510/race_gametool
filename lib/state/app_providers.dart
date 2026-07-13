import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/block_def.dart';

/// The two top-level modes of the tool, selected via the NavigationRail.
enum AppMode {
  assetDefiner('Phase 1: Asset Definer'),
  levelEditor('Phase 2: Level Editor'),
  pixelEditor('Pixel Editor');

  const AppMode(this.label);
  final String label;
}

/// Browser-style workspace: a pinned Phase 1 (Asset Definer) tab plus zero or
/// more Phase 2 (Level Editor) tabs. Each level tab owns an independent
/// [LevelEditorState] via the `levelEditorProvider` family, keyed by the tab's
/// id here. Ids are monotonic so a closed tab's id is never reused, which keeps
/// stale family instances from being resurrected under a new tab.
class WorkspaceState {
  const WorkspaceState({
    this.levelTabs = const [],
    this.activeLevelTab,
    this.nextId = 0,
    this.pixelEditorActive = false,
  });

  /// Ids of the open Phase 2 tabs, in display order.
  final List<int> levelTabs;

  /// The active level tab id, or null when the pinned Phase 1 tab is active.
  final int? activeLevelTab;

  /// Next id to hand out. Never decremented.
  final int nextId;

  /// Whether the pinned Pixel Editor tab is the active pinned tab. Only
  /// consulted while no level tab is active.
  final bool pixelEditorActive;

  /// The top-level mode derived from which tab is active.
  AppMode get mode => activeLevelTab != null
      ? AppMode.levelEditor
      : pixelEditorActive
          ? AppMode.pixelEditor
          : AppMode.assetDefiner;

  WorkspaceState copyWith({
    List<int>? levelTabs,
    int? Function()? activeLevelTab,
    int? nextId,
    bool? pixelEditorActive,
  }) =>
      WorkspaceState(
        levelTabs: levelTabs ?? this.levelTabs,
        activeLevelTab:
            activeLevelTab != null ? activeLevelTab() : this.activeLevelTab,
        nextId: nextId ?? this.nextId,
        pixelEditorActive: pixelEditorActive ?? this.pixelEditorActive,
      );
}

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  @override
  WorkspaceState build() => const WorkspaceState();

  /// Opens a new empty level tab and activates it. Returns its id so the
  /// caller can drive that tab's `levelEditorProvider(id).notifier`.
  int openLevelTab() {
    final id = state.nextId;
    state = state.copyWith(
      levelTabs: [...state.levelTabs, id],
      activeLevelTab: () => id,
      nextId: id + 1,
    );
    return id;
  }

  /// Activates the pinned Phase 1 tab.
  void activatePhase1() => state = state.copyWith(
        activeLevelTab: () => null,
        pixelEditorActive: false,
      );

  /// Activates the pinned Pixel Editor tab.
  void activatePixelEditor() => state = state.copyWith(
        activeLevelTab: () => null,
        pixelEditorActive: true,
      );

  void activateLevelTab(int id) {
    if (state.levelTabs.contains(id)) {
      state = state.copyWith(activeLevelTab: () => id);
    }
  }

  /// Removes a level tab. When the closed tab was active, focus moves to the
  /// neighbour that slides into its slot (or Phase 1 if none remain).
  void closeLevelTab(int id) {
    final idx = state.levelTabs.indexOf(id);
    if (idx < 0) return;
    final remaining = [...state.levelTabs]..removeAt(idx);
    int? nextActive = state.activeLevelTab;
    if (state.activeLevelTab == id) {
      nextActive =
          remaining.isEmpty ? null : remaining[idx.clamp(0, remaining.length - 1)];
    }
    state = state.copyWith(
      levelTabs: remaining,
      activeLevelTab: () => nextActive,
    );
  }

  /// Closes every level tab and returns to Phase 1. Used when the asset set is
  /// replaced (New Config), since the open levels reference the old assets.
  void closeAllLevelTabs() {
    state = state.copyWith(
      levelTabs: const [],
      activeLevelTab: () => null,
      pixelEditorActive: false,
    );
  }
}

final workspaceProvider =
    NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);

/// The loaded asset set shared across the app: the block dictionary plus
/// the packed sprite sheet needed to render the blocks. Phase 1 populates
/// it when saving a bundle; Phase 2 also populates it when importing a
/// .rgpack, so a single Phase 1 output can feed many Phase 2 levels.
class AssetLibrary {
  const AssetLibrary({
    this.blocks = const [],
    this.sheetBytes,
    this.sheetImage,
    this.sourceName,
  });

  final List<BlockDef> blocks;
  final Uint8List? sheetBytes;

  /// Decoded sprite sheet for CustomPaint rendering in the palette/canvas.
  final ui.Image? sheetImage;

  /// Name of the bundle or session this came from, for display.
  final String? sourceName;

  bool get isEmpty => blocks.isEmpty;
  bool get isNotEmpty => blocks.isNotEmpty;

  BlockDef? blockById(String id) {
    for (final b in blocks) {
      if (b.id == id) return b;
    }
    return null;
  }
}

class AssetLibraryNotifier extends Notifier<AssetLibrary> {
  @override
  AssetLibrary build() => const AssetLibrary();

  /// Sets the library from already-decoded parts (Phase 1 hand-off, where
  /// the sheet image is decoded once at save time).
  void setAssets({
    required List<BlockDef> blocks,
    required Uint8List sheetBytes,
    required ui.Image sheetImage,
    String? sourceName,
  }) {
    state = AssetLibrary(
      blocks: List.unmodifiable(blocks),
      sheetBytes: sheetBytes,
      sheetImage: sheetImage,
      sourceName: sourceName,
    );
  }

  /// Loads the library from raw parts, decoding the sheet image.
  Future<void> loadAssets({
    required List<BlockDef> blocks,
    required Uint8List sheetBytes,
    String? sourceName,
  }) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(sheetBytes, completer.complete);
    final image = await completer.future;
    setAssets(
      blocks: blocks,
      sheetBytes: sheetBytes,
      sheetImage: image,
      sourceName: sourceName,
    );
  }

  void clear() => state = const AssetLibrary();
}

final assetLibraryProvider =
    NotifierProvider<AssetLibraryNotifier, AssetLibrary>(
        AssetLibraryNotifier.new);
