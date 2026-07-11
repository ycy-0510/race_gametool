import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../models/block_def.dart';
import '../state/app_providers.dart';
import '../state/asset_definer_providers.dart';
import '../state/file_open_service.dart';
import '../state/level_editor_providers.dart';
import 'phase1/asset_definer_page.dart';
import 'phase2/level_editor_page.dart';

/// Main shell: a NavigationRail switching between the two tool phases.
/// The active mode lives in Riverpod so any part of the app can switch modes.
/// The top bar is custom-rendered to integrate with window manager frame hiding.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WindowListener, WidgetsBindingObserver {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    _syncMaximized();
    WidgetsBinding.instance.addObserver(this);
    // Start listening for .rgpack files opened from Finder.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(fileOpenServiceProvider)
          .start(
            onOpenRequest: () async {
              final assetState = ref.read(assetDefinerProvider);
              final assetNotifier = ref.read(assetDefinerProvider.notifier);

              if (assetState.isDirty) {
                final proceed = await _promptUnsavedChanges(
                  title: 'Save Config Changes?',
                  content:
                      'Your asset config has unsaved changes. Do you want to save before opening the new config?',
                  onSave: () => assetNotifier.save(),
                );
                if (!proceed) {
                  return false;
                }
              }

              for (final id in ref.read(workspaceProvider).levelTabs) {
                final levelState = ref.read(levelEditorProvider(id));
                if (!levelState.isDirty) continue;
                final levelNotifier = ref.read(levelEditorProvider(id).notifier);
                final proceed = await _promptUnsavedChanges(
                  title: 'Save Game Map Changes?',
                  content:
                      'The level "${levelState.mapName}" has unsaved changes. Do you want to save before opening the new config?',
                  onSave: () => levelNotifier.save(),
                );
                if (!proceed) {
                  return false;
                }
              }

              return true;
            },
          );
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _isMaximized) {
      setState(() => _isMaximized = maximized);
    }
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  Future<bool> _checkUnsavedChangesAndPrompt() async {
    final assetState = ref.read(assetDefinerProvider);
    final assetNotifier = ref.read(assetDefinerProvider.notifier);

    if (assetState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Config Changes?',
        content: 'Your asset config has unsaved changes. Do you want to save before quitting?',
        onSave: () => assetNotifier.save(),
      );
      if (!proceed) {
        return false;
      }
    }

    for (final id in ref.read(workspaceProvider).levelTabs) {
      final levelState = ref.read(levelEditorProvider(id));
      if (!levelState.isDirty) continue;
      final levelNotifier = ref.read(levelEditorProvider(id).notifier);
      final proceed = await _promptUnsavedChanges(
        title: 'Save Game Map Changes?',
        content:
            'The level "${levelState.mapName}" has unsaved changes. Do you want to save before quitting?',
        onSave: () => levelNotifier.save(),
      );
      if (!proceed) {
        return false;
      }
    }

    return true;
  }

  @override
  void onWindowClose() async {
    final proceed = await _checkUnsavedChangesAndPrompt();
    if (proceed) {
      await windowManager.destroy();
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    final proceed = await _checkUnsavedChangesAndPrompt();
    return proceed ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  Future<bool> _promptUnsavedChanges({
    required String title,
    required String content,
    required Future<void> Function() onSave,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (result == 'save') {
      await onSave();
      return true;
    }
    return result == 'discard';
  }

  /// The active level tab id, or null when the pinned Phase 1 tab is active.
  int? get _activeLevelTab => ref.read(workspaceProvider).activeLevelTab;

  /// Whether a new Phase 2 tab may be opened yet. Level editing needs an asset
  /// set, which Phase 1 establishes (by saving a config or opening one), so the
  /// pinned Phase 1 tab must have produced assets first.
  bool get _canOpenLevelTab => ref.read(assetLibraryProvider).isNotEmpty;

  void _notifyAssetsFirst() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Load or define assets in Phase 1 before opening a level.')),
    );
  }

  Future<void> _handleNewConfig(WidgetRef ref) async {
    final assetState = ref.read(assetDefinerProvider);
    final assetNotifier = ref.read(assetDefinerProvider.notifier);

    if (assetState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Config Changes?',
        content:
            'Your asset config has unsaved changes. Do you want to save before creating a new config?',
        onSave: () => assetNotifier.save(),
      );
      if (!proceed) return;
    }

    if (!mounted) return;

    for (final id in ref.read(workspaceProvider).levelTabs) {
      final levelState = ref.read(levelEditorProvider(id));
      if (!levelState.isDirty) continue;
      final levelNotifier = ref.read(levelEditorProvider(id).notifier);
      final proceed = await _promptUnsavedChanges(
        title: 'Save Game Map Changes?',
        content:
            'The level "${levelState.mapName}" has unsaved changes. Do you want to save before creating a new config?',
        onSave: () => levelNotifier.save(),
      );
      if (!proceed) return;
      if (!mounted) return;
    }

    assetNotifier.newConfig();
    // The open levels reference the discarded asset set, so close them all.
    ref.read(workspaceProvider.notifier).closeAllLevelTabs();
  }

  /// Opens a fresh Phase 2 tab. New tabs start empty, so there is nothing to
  /// discard and no save prompt.
  void _handleNewGameMap(WidgetRef ref) {
    if (!_canOpenLevelTab) {
      _notifyAssetsFirst();
      return;
    }
    ref.read(workspaceProvider.notifier).openLevelTab();
  }

  Future<void> _handleOpenConfig(WidgetRef ref) async {
    final assetState = ref.read(assetDefinerProvider);
    final assetNotifier = ref.read(assetDefinerProvider.notifier);

    if (assetState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Config Changes?',
        content:
            'Your asset config has unsaved changes. Do you want to save before opening another config?',
        onSave: () => assetNotifier.save(),
      );
      if (!proceed) return;
    }

    if (!mounted) return;

    await assetNotifier.openBundle();
  }

  /// Opens a saved level into a new Phase 2 tab.
  Future<void> _handleOpenGameLevel(WidgetRef ref) async {
    if (!_canOpenLevelTab) {
      _notifyAssetsFirst();
      return;
    }
    final id = ref.read(workspaceProvider.notifier).openLevelTab();
    await ref.read(levelEditorProvider(id).notifier).openGameLevelDialog();
  }

  void _handleSave(WidgetRef ref) {
    final id = _activeLevelTab;
    if (id == null) {
      ref.read(assetDefinerProvider.notifier).save();
    } else {
      ref.read(levelEditorProvider(id).notifier).save();
    }
  }

  void _handleSaveAs(WidgetRef ref) {
    final id = _activeLevelTab;
    if (id == null) {
      ref.read(assetDefinerProvider.notifier).saveAs();
    } else {
      ref.read(levelEditorProvider(id).notifier).saveAs();
    }
  }

  void _handleUndo(WidgetRef ref) {
    final id = _activeLevelTab;
    if (id != null) {
      ref.read(levelEditorProvider(id).notifier).undo();
    }
  }

  /// Prompts to save a dirty level tab, then closes it. Returns without closing
  /// if the user cancels. Cmd/Ctrl+W and the tab's close button route here.
  Future<void> _handleCloseTab(int id) async {
    final levelState = ref.read(levelEditorProvider(id));
    if (levelState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Game Map Changes?',
        content:
            'The level "${levelState.mapName}" has unsaved changes. Do you want to save before closing this tab?',
        onSave: () => ref.read(levelEditorProvider(id).notifier).save(),
      );
      if (!proceed) return;
    }
    ref.read(workspaceProvider.notifier).closeLevelTab(id);
  }

  Future<void> _handleClearLayer(WidgetRef ref) async {
    final id = _activeLevelTab;
    if (id == null) return;

    final levelState = ref.read(levelEditorProvider(id));
    final levelNotifier = ref.read(levelEditorProvider(id).notifier);
    final activeLayer = levelState.activeLayer;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear ${activeLayer.label} Layer?'),
        content: Text(
          'Are you sure you want to clear all placements on the ${activeLayer.label} layer? This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );

    if (!mounted) return;

    if (confirm == true) {
      levelNotifier.clearLayer(activeLayer);
    }
  }

  Future<void> _handleAutotile(int id) async {
    final levelNotifier = ref.read(levelEditorProvider(id).notifier);
    final levelState = ref.read(levelEditorProvider(id));
    if (levelState.islandGrassMask != null) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard Manual Edits?'),
          content: const Text(
            'This will discard your manual island edits and regenerate from the track footprint. Continue?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirm != true) return;
    }
    levelNotifier.generateIsland();
  }

  Widget _buildSidebarItem(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onPressed,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 70,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: selected
              ? Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.5))
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontSize: 10,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuBar(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 32,
      child: MenuBar(
        style: MenuStyle(
          elevation: WidgetStateProperty.all(0),
          backgroundColor: WidgetStateProperty.all(Colors.transparent),
        ),
        children: [
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyN,
                  control: true,
                  shift: true,
                ),
                onPressed: () => _handleNewConfig(ref),
                child: const Text('New Config'),
              ),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyN, control: true),
                onPressed: () => _handleNewGameMap(ref),
                child: const Text('New Game Map'),
              ),
              const PopupMenuDivider(),
              MenuItemButton(
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyO,
                  control: true,
                  shift: true,
                ),
                onPressed: () => _handleOpenConfig(ref),
                child: const Text('Open Config...'),
              ),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyO, control: true),
                onPressed: () => _handleOpenGameLevel(ref),
                child: const Text('Open Game Level...'),
              ),
              const PopupMenuDivider(),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyS, control: true),
                onPressed: () => _handleSave(ref),
                child: const Text('Save'),
              ),
              MenuItemButton(
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyS,
                  control: true,
                  shift: true,
                ),
                onPressed: () => _handleSaveAs(ref),
                child: const Text('Save As...'),
              ),
            ],
            child: const Text('File'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
                onPressed: () => _handleUndo(ref),
                child: const Text('Undo'),
              ),
              const PopupMenuDivider(),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.delete, control: true),
                onPressed: () => _handleClearLayer(ref),
                child: const Text('Clear Active Layer'),
              ),
            ],
            child: const Text('Edit'),
          ),
        ],
      ),
    );
  }

  Widget _buildRootShell(BuildContext context, Widget child) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return PlatformMenuBar(
        menus: [
          PlatformMenu(
            label: 'Race Game Tool',
            menus: [
              PlatformMenuItemGroup(
                members: [
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
                ],
              ),
            ],
          ),
          PlatformMenu(
            label: 'File',
            menus: [
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'New Config',
                    shortcut: const SingleActivator(
                      LogicalKeyboardKey.keyN,
                      meta: true,
                      shift: true,
                    ),
                    onSelected: () => _handleNewConfig(ref),
                  ),
                  PlatformMenuItem(
                    label: 'New Game Map',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
                    onSelected: () => _handleNewGameMap(ref),
                  ),
                ],
              ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Open Config...',
                    shortcut: const SingleActivator(
                      LogicalKeyboardKey.keyO,
                      meta: true,
                      shift: true,
                    ),
                    onSelected: () => _handleOpenConfig(ref),
                  ),
                  PlatformMenuItem(
                    label: 'Open Game Level...',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
                    onSelected: () => _handleOpenGameLevel(ref),
                  ),
                ],
              ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Save',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
                    onSelected: () => _handleSave(ref),
                  ),
                  PlatformMenuItem(
                    label: 'Save As...',
                    shortcut: const SingleActivator(
                      LogicalKeyboardKey.keyS,
                      meta: true,
                      shift: true,
                    ),
                    onSelected: () => _handleSaveAs(ref),
                  ),
                ],
              ),
            ],
          ),
          PlatformMenu(
            label: 'Edit',
            menus: [
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Undo',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
                    onSelected: () => _handleUndo(ref),
                  ),
                ],
              ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Clear Active Layer',
                    shortcut: const SingleActivator(LogicalKeyboardKey.delete, meta: true),
                    onSelected: () => _handleClearLayer(ref),
                  ),
                ],
              ),
            ],
          ),
        ],
        child: child,
      );
    }
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workspace = ref.watch(workspaceProvider);
    final mode = workspace.mode;
    final activeId = workspace.activeLevelTab;
    final hasAssets = ref.watch(assetLibraryProvider.select((l) => l.isNotEmpty));

    // Watch specific provider states to render in the unified top toolbar.
    // This avoids rebuilding the AppShell (and triggering macOS native menubar rebuilds) on every mouse hover/movement.
    final activeCategory = ref.watch(assetDefinerProvider.select((s) => s.activeCategory));
    final assetTool = ref.watch(assetDefinerProvider.select((s) => s.tool));
    final hasActiveImage = ref.watch(assetDefinerProvider.select((s) => s.activeImage != null));
    final assetStatusMessage = ref.watch(assetDefinerProvider.select((s) => s.statusMessage));
    final physicsStatusMessage =
        ref.watch(assetDefinerProvider.select((s) => s.physicsStatusMessage));
    final assetNotifier = ref.read(assetDefinerProvider.notifier);

    // Level toolbar/status state is scoped to the active tab; the fallbacks
    // apply only while Phase 1 is active, where they go unused.
    final levelNotifier = activeId == null
        ? null
        : ref.read(levelEditorProvider(activeId).notifier);
    final activeLayer = activeId == null
        ? MapLayer.track
        : ref.watch(levelEditorProvider(activeId).select((s) => s.activeLayer));
    final levelTool = activeId == null
        ? LevelTool.stamp
        : ref.watch(levelEditorProvider(activeId).select((s) => s.tool));
    final islandBrushRadius = activeId == null
        ? 0
        : ref.watch(levelEditorProvider(activeId).select((s) => s.islandBrushRadius));
    final levelStatusMessage = activeId == null
        ? null
        : ref.watch(levelEditorProvider(activeId).select((s) => s.statusMessage));
    final placementsLength = activeId == null
        ? 0
        : ref.watch(levelEditorProvider(activeId).select((s) => s.placements.length));
    final hasSpawn = activeId == null
        ? false
        : ref.watch(levelEditorProvider(activeId).select((s) => s.spawn != null));

    final mainContent = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () => levelNotifier?.undo(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () => levelNotifier?.undo(),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
          if (activeId != null) _handleCloseTab(activeId);
        },
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () {
          if (activeId != null) _handleCloseTab(activeId);
        },
        if (defaultTargetPlatform != TargetPlatform.macOS) ...{
          // New Config: Ctrl+Shift+N / Cmd+Shift+N
          const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): () =>
              _handleNewConfig(ref),
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true): () =>
              _handleNewConfig(ref),

          // New Game Map: Ctrl+N / Cmd+N
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              _handleNewGameMap(ref),
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => _handleNewGameMap(ref),

          // Open Config: Ctrl+Shift+O / Cmd+Shift+O
          const SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true): () =>
              _handleOpenConfig(ref),
          const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true): () =>
              _handleOpenConfig(ref),

          // Open Game Level: Ctrl+O / Cmd+O
          const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
              _handleOpenGameLevel(ref),
          const SingleActivator(LogicalKeyboardKey.keyO, meta: true): () =>
              _handleOpenGameLevel(ref),

          // Save: Ctrl+S / Cmd+S
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _handleSave(ref),
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => _handleSave(ref),

          // Save As: Ctrl+Shift+S / Cmd+Shift+S
          const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true): () =>
              _handleSaveAs(ref),
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true): () =>
              _handleSaveAs(ref),

          // Clear Active Layer: Ctrl+Delete / Cmd+Delete
          const SingleActivator(LogicalKeyboardKey.delete, control: true): () =>
              _handleClearLayer(ref),
          const SingleActivator(LogicalKeyboardKey.delete, meta: true): () =>
              _handleClearLayer(ref),
        },
      },
      child: Scaffold(
        body: Row(
          children: [
            Container(
              width: 80,
              color: theme.colorScheme.surfaceContainerLow,
              child: Column(
                children: [
                  const SizedBox(height: 40),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          if (mode == AppMode.assetDefiner) ...[
                            for (final cat in [
                              BlockCategory.track,
                              BlockCategory.islandTile,
                              BlockCategory.decoration,
                            ]) ...[
                              _buildSidebarItem(
                                context,
                                label: categoryLabel(cat),
                                selected: activeCategory == cat,
                                onPressed: () => assetNotifier.setActiveCategory(cat),
                                icon: switch (cat) {
                                  BlockCategory.track => Icons.alt_route,
                                  BlockCategory.islandTile => Icons.landscape,
                                  BlockCategory.decoration => Icons.park,
                                  _ => Icons.circle,
                                },
                              ),
                              const SizedBox(height: 12),
                            ],
                            // Decoration spans multiple images; list them
                            // below the categories (behind a divider) so
                            // the active one can be switched, added, or
                            // removed.
                            if (activeCategory == BlockCategory.decoration) ...[
                              const Divider(indent: 12, endIndent: 12),
                              const SizedBox(height: 8),
                              const _DecorationSourceList(),
                            ],
                          ] else if (mode == AppMode.levelEditor) ...[
                            for (final layer in MapLayer.values) ...[
                              _buildSidebarItem(
                                context,
                                label: layer.label,
                                selected: activeLayer == layer,
                                onPressed: () => levelNotifier!.setLayer(layer),
                                icon: switch (layer) {
                                  MapLayer.island => Icons.landscape,
                                  MapLayer.track => Icons.alt_route,
                                  MapLayer.decoration => Icons.park,
                                  MapLayer.function => Icons.settings_suggest,
                                },
                              ),
                              const SizedBox(height: 12),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  // Unified Top Toolbar and Window Control Row (Split into 2 Lines)
                  Container(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (defaultTargetPlatform != TargetPlatform.macOS)
                          Container(
                            height: 40,
                            color: theme.colorScheme.surfaceContainerLow,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Center(child: _buildMenuBar(context, ref)),
                                Expanded(
                                  child: DragToMoveArea(
                                    child: Container(color: Colors.transparent),
                                  ),
                                ),
                                WindowCaptionButton.minimize(
                                  brightness: theme.brightness,
                                  onPressed: windowManager.minimize,
                                ),
                                if (_isMaximized)
                                  WindowCaptionButton.unmaximize(
                                    brightness: theme.brightness,
                                    onPressed: windowManager.unmaximize,
                                  )
                                else
                                  WindowCaptionButton.maximize(
                                    brightness: theme.brightness,
                                    onPressed: windowManager.maximize,
                                  ),
                                WindowCaptionButton.close(
                                  brightness: theme.brightness,
                                  onPressed: windowManager.close,
                                ),
                              ],
                            ),
                          ),
                        // Chrome-style title bar: the browser tab strip lives in the
                        // window drag region next to the OS window controls. The
                        // active tab shares the toolbar's colour so it reads as one
                        // connected surface, with no divider between them.
                        Container(
                          height: 40,
                          color: theme.colorScheme.surfaceContainerLow,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(width: 8),

                              // Tabs: pinned Phase 1 + one per open level. Shrinks
                              // when the row runs out of space, leaving a drag area.
                              _Phase1TabChip(
                                selected: activeId == null,
                                onSelect: () =>
                                    ref.read(workspaceProvider.notifier).activatePhase1(),
                              ),
                              Flexible(
                                flex: 10,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (final id in workspace.levelTabs)
                                      Flexible(
                                        flex: activeId == id ? 3 : 1,
                                        child: _LevelTabChip(
                                          key: ValueKey(id),
                                          id: id,
                                          selected: activeId == id,
                                          onSelect: () => ref
                                              .read(workspaceProvider.notifier)
                                              .activateLevelTab(id),
                                          onClose: () => _handleCloseTab(id),
                                        ),
                                      ),
                                    Tooltip(
                                      message: hasAssets
                                          ? 'New level tab'
                                          : 'Define or load assets in Phase 1 first',
                                      child: Padding(
                                        padding: const EdgeInsets.all(5),
                                        child: IconButton(
                                          iconSize: 18,
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(Icons.add),
                                          onPressed: hasAssets
                                              ? () => _handleNewGameMap(ref)
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 1,
                                child: DragToMoveArea(child: Container(color: Colors.transparent)),
                              ),
                            ],
                          ),
                        ),

                        // Line 2: Tools and Action buttons (horizontal scrollable row)
                        Container(
                          height: 44,
                          color: theme.colorScheme.surfaceContainerHigh,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                if (mode == AppMode.assetDefiner) ...[
                                  // Tool SegmentedButton
                                  SegmentedButton<Phase1Tool>(
                                    showSelectedIcon: false,
                                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                                    segments: [
                                      for (final t in Phase1Tool.values)
                                        if ((activeCategory == BlockCategory.track) ||
                                            (activeCategory == BlockCategory.islandTile &&
                                                t != Phase1Tool.paintMask &&
                                                t != Phase1Tool.addPort &&
                                                t != Phase1Tool.drawPhysicsArea) ||
                                            (activeCategory == BlockCategory.decoration &&
                                                t != Phase1Tool.addPort &&
                                                t != Phase1Tool.drawPhysicsArea))
                                          ButtonSegment(
                                            value: t,
                                            tooltip: t.label,
                                            icon: Icon(switch (t) {
                                              Phase1Tool.select => Icons.near_me_outlined,
                                              Phase1Tool.move => Icons.open_with,
                                              Phase1Tool.drawBox => Icons.crop_square,
                                              Phase1Tool.paintMask => Icons.brush_outlined,
                                              Phase1Tool.addPort => Icons.adjust,
                                              Phase1Tool.drawPhysicsArea => Icons.polyline,
                                            }),
                                          ),
                                    ],
                                    selected: {assetTool},
                                    onSelectionChanged: (selection) =>
                                        assetNotifier.setTool(selection.first),
                                  ),
                                  const SizedBox(width: 12),

                                  // Action Buttons
                                  FilledButton.tonalIcon(
                                    onPressed: assetNotifier.loadImage,
                                    style: FilledButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    icon: const Icon(Icons.image_outlined, size: 16),
                                    label: Text(!hasActiveImage ? 'Load Image' : 'Replace Image'),
                                  ),
                                ] else if (mode == AppMode.levelEditor) ...[
                                  // Tool SegmentedButton
                                  SegmentedButton<LevelTool>(
                                    showSelectedIcon: false,
                                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                                    segments: [
                                      for (final tool in LevelTool.values)
                                        if ((activeLayer != MapLayer.island &&
                                                activeLayer != MapLayer.decoration) ||
                                            (tool != LevelTool.connect && tool != LevelTool.spawn))
                                          ButtonSegment(
                                            value: tool,
                                            tooltip: tool.label,
                                            icon: Icon(switch (tool) {
                                              LevelTool.select => Icons.near_me_outlined,
                                              LevelTool.multi => Icons.select_all,
                                              LevelTool.stamp => Icons.add_box_outlined,
                                              LevelTool.connect => Icons.hub_outlined,
                                              LevelTool.spawn => Icons.flag_outlined,
                                              LevelTool.erase => Icons.cleaning_services,
                                            }),
                                          ),
                                    ],
                                    selected: {levelTool},
                                    onSelectionChanged: (s) => levelNotifier!.setTool(s.first),
                                  ),
                                  const SizedBox(width: 12),

                                  // Island Brush Controls
                                  if (activeLayer == MapLayer.island) ...[
                                    const Icon(Icons.brush, size: 16),
                                    const SizedBox(width: 4),
                                    SegmentedButton<int>(
                                      showSelectedIcon: false,
                                      style: const ButtonStyle(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      segments: const [
                                        ButtonSegment(value: 0, label: Text('1x1')),
                                        ButtonSegment(value: 1, label: Text('3x3')),
                                        ButtonSegment(value: 2, label: Text('5x5')),
                                        ButtonSegment(value: 3, label: Text('7x7')),
                                      ],
                                      selected: {islandBrushRadius},
                                      onSelectionChanged: (s) =>
                                          levelNotifier!.setIslandBrushRadius(s.first),
                                    ),
                                    const SizedBox(width: 6),
                                    FilledButton.tonalIcon(
                                      onPressed: () => _handleAutotile(activeId!),
                                      style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      icon: const Icon(Icons.grass, size: 16),
                                      label: const Text('Autotile'),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // Main View Content
                  Expanded(
                    child: activeId == null
                        ? const AssetDefinerPage()
                        : LevelEditorPage(key: ValueKey(activeId), tabId: activeId),
                  ),
                  const Divider(height: 1),

                  // Desktop IDE-Style bottom Status Bar
                  Container(
                    height: 22,
                    color: theme.colorScheme.surfaceContainerLow,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            mode == AppMode.assetDefiner
                                ? (physicsStatusMessage ??
                                      assetStatusMessage ??
                                      'Asset Definer ready')
                                : (levelStatusMessage ?? 'Level Editor ready'),
                            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (mode == AppMode.levelEditor) ...[
                          Text(
                            '$placementsLength blocks placed',
                            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                          ),
                          const SizedBox(width: 16),
                          if (hasSpawn)
                            const Text(
                              'Spawn set',
                              style: TextStyle(color: Colors.greenAccent, fontSize: 11),
                            )
                          else
                            const Text(
                              'No Spawn',
                              style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return _buildRootShell(context, mainContent);
  }
}

/// The decoration category's image list, shown in the sidebar. Lets the user
/// switch between decoration images, add another, or remove one. Watches only
/// the source names and active index so painting on the canvas does not
/// rebuild it.
class _DecorationSourceList extends ConsumerWidget {
  const _DecorationSourceList();

  /// Removing a decoration image also drops the blocks masked on it, so it is
  /// confirmed first.
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, int index, String label) async {
    final decorationMasks = ref.read(assetDefinerProvider).decorationMasks;
    final blockCount = index < decorationMasks.length ? decorationMasks[index].length : 0;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Decoration Image?'),
        content: Text(
          'Removing "$label" also deletes its $blockCount block(s). '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm == true) {
      ref.read(assetDefinerProvider.notifier).removeDecorationImage(index);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Names joined by newline (which cannot appear in a filename), so the
    // watched value is a plain String and compares by value.
    final joined = ref.watch(
      assetDefinerProvider.select((s) => s.decorationSources.map((d) => d.name).join('\n')),
    );
    final activeIndex = ref.watch(assetDefinerProvider.select((s) => s.activeDecorationIndex));
    final names = joined.isEmpty ? const <String>[] : joined.split('\n');
    final notifier = ref.read(assetDefinerProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < names.length; i++)
          _DecorationSourceTile(
            label: names[i].isEmpty ? 'image ${i + 1}' : names[i],
            selected: i == activeIndex,
            onTap: () => notifier.setActiveDecorationIndex(i),
            onDelete: () =>
                _confirmDelete(context, ref, i, names[i].isEmpty ? 'image ${i + 1}' : names[i]),
          ),
        const SizedBox(height: 4),
        _AddDecorationButton(onTap: notifier.addDecorationImage),
      ],
    );
  }
}

/// Circular "+ / Add" button that appends a decoration image.
class _AddDecorationButton extends StatelessWidget {
  const _AddDecorationButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Tooltip(
      message: 'Add decoration image',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 70,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: .circular(8),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 18, color: color),
              Text('Add', style: theme.textTheme.labelSmall?.copyWith(color: color, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DecorationSourceTile extends StatelessWidget {
  const _DecorationSourceTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 70,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.only(left: 8, right: 2, top: 4, bottom: 4),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: selected
              ? Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  height: 1.2,
                  color: fg,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close, size: 12, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pinned Phase 1 tab. Watches only the asset config's dirty flag so it
/// repaints its indicator without rebuilding the whole shell.
class _Phase1TabChip extends ConsumerWidget {
  const _Phase1TabChip({required this.selected, required this.onSelect});

  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirty = ref.watch(assetDefinerProvider.select((s) => s.isDirty));
    return _TabChip(
      icon: Icons.category,
      label: 'Asset Definer',
      dirty: dirty,
      selected: selected,
      onSelect: onSelect,
    );
  }
}

/// One Phase 2 level tab. Watches only its own map name and dirty flag.
class _LevelTabChip extends ConsumerWidget {
  const _LevelTabChip({
    super.key,
    required this.id,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  final int id;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapName = ref.watch(levelEditorProvider(id).select((s) => s.mapName));
    final dirty = ref.watch(levelEditorProvider(id).select((s) => s.isDirty));
    return _TabChip(
      icon: Icons.map,
      label: mapName,
      dirty: dirty,
      selected: selected,
      onSelect: onSelect,
      onClose: onClose,
    );
  }
}

/// Shared visual for a single tab in the strip. A closable tab shows a close
/// button; the pinned Phase 1 tab (no [onClose]) shows only a dirty dot.
class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.icon,
    required this.label,
    required this.dirty,
    required this.selected,
    required this.onSelect,
    this.onClose,
  });

  final IconData icon;
  final String label;
  final bool dirty;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onSelect,
      child: Container(
        height: 40,
        constraints: const BoxConstraints(maxWidth: 220),
        padding: EdgeInsets.only(left: 12, right: onClose == null ? 12 : 4),
        decoration: BoxDecoration(
          // The active tab shares the toolbar surface directly below it so the
          // two read as one connected panel, Chrome-style.
          color: selected ? theme.colorScheme.surfaceContainerHigh : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
            right: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;

            // Dynamically hide elements based on available width to prevent overflow
            final showIcon = width > 50;
            final showClose = onClose != null && width > 35;
            final showDirty = dirty && width > 70;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showIcon) ...[
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (dirty && showDirty) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
                  ),
                ],
                if (onClose != null && showClose) ...[
                  const SizedBox(width: 2),
                  IconButton(
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    tooltip: 'Close tab',
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
