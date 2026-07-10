import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../models/block_def.dart';
import '../models/port.dart';
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

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    // Start listening for .rgpack files opened from Finder.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(fileOpenServiceProvider).start();
    });
  }

  Future<void> _showClearConfirmation(
      BuildContext context, LevelEditorNotifier notifier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Placements?'),
        content: const Text(
            'Are you sure you want to clear all placed blocks? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      notifier.clearAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appModeProvider);
    final theme = Theme.of(context);

    // Watch both provider states to render in the unified top toolbar.
    final assetState = ref.watch(assetDefinerProvider);
    final assetNotifier = ref.read(assetDefinerProvider.notifier);

    final levelState = ref.watch(levelEditorProvider);
    final levelNotifier = ref.read(levelEditorProvider.notifier);

    return Scaffold(
      body: Column(
        children: [
          // Unified Top Toolbar and Window Control Row (Split into 2 Lines)
          Container(
            color: theme.colorScheme.surfaceContainerHigh,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Line 1: Window Controls + Category/Layer selection + Drag Area
                Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      // macOS spacing to avoid the system Traffic Light buttons
                      if (defaultTargetPlatform == TargetPlatform.macOS)
                        const SizedBox(width: 80),

                      // Esport Icon and Title
                      const Icon(Icons.sports_esports, size: 20, color: Colors.cyan),
                      const SizedBox(width: 8),
                      Text(
                        'Race Game Tool',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const VerticalDivider(width: 24, indent: 10, endIndent: 10),

                      // Category/Layer selection
                      if (mode == AppMode.assetDefiner) ...[
                        Text('Category: ', style: theme.textTheme.labelMedium),
                        const SizedBox(width: 4),
                        SegmentedButton<BlockCategory>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: [
                            for (final c in [
                              BlockCategory.track,
                              BlockCategory.islandTile,
                              BlockCategory.decoration,
                            ])
                              ButtonSegment(
                                value: c,
                                label: Text(categoryLabel(c)),
                              ),
                          ],
                          selected: {assetState.activeCategory},
                          onSelectionChanged: (selection) =>
                              assetNotifier.setActiveCategory(selection.first),
                        ),
                      ] else if (mode == AppMode.levelEditor) ...[
                        SegmentedButton<MapLayer>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: [
                            for (final layer in MapLayer.values)
                              ButtonSegment(value: layer, label: Text(layer.label)),
                          ],
                          selected: {levelState.activeLayer},
                          onSelectionChanged: (s) => levelNotifier.setLayer(s.first),
                        ),
                      ],

                      // Draggable Middle Area
                      Expanded(
                        child: DragToMoveArea(
                          child: Container(
                            height: 40,
                            color: Colors.transparent,
                          ),
                        ),
                      ),

                      // Windows OS control buttons (rendered using WindowCaption)
                      if (defaultTargetPlatform != TargetPlatform.macOS)
                        SizedBox(
                          width: 140,
                          height: 40,
                          child: WindowCaption(
                            backgroundColor: Colors.transparent,
                            brightness: theme.brightness,
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),

                // Line 2: Tools and Action buttons (horizontal scrollable row)
                Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        if (mode == AppMode.assetDefiner) ...[
                          // Tool SegmentedButton
                          SegmentedButton<Phase1Tool>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: [
                              for (final t in Phase1Tool.values)
                                if (assetState.activeCategory != BlockCategory.islandTile ||
                                    (t != Phase1Tool.paintMask && t != Phase1Tool.addPort))
                                  ButtonSegment(
                                    value: t,
                                    tooltip: t.label,
                                    icon: Icon(switch (t) {
                                      Phase1Tool.select => Icons.near_me_outlined,
                                      Phase1Tool.move => Icons.open_with,
                                      Phase1Tool.drawBox => Icons.crop_square,
                                      Phase1Tool.paintMask => Icons.brush_outlined,
                                      Phase1Tool.addPort => Icons.adjust,
                                    }),
                                  ),
                            ],
                            selected: {assetState.tool},
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
                            label: Text(assetState.activeImage == null ? 'Load Image' : 'Replace Image'),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            onPressed: assetNotifier.openBundle,
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.folder_open, size: 16),
                            label: const Text('Open Bundle'),
                          ),
                          const SizedBox(width: 6),
                          FilledButton.icon(
                            onPressed: assetState.canExport ? assetNotifier.saveBundle : null,
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.save_alt, size: 16),
                            label: const Text('Save Bundle'),
                          ),
                        ] else if (mode == AppMode.levelEditor) ...[
                          // Tool SegmentedButton
                          SegmentedButton<LevelTool>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: [
                              for (final tool in LevelTool.values)
                                if (levelState.activeLayer != MapLayer.island ||
                                    (tool != LevelTool.connect &&
                                        tool != LevelTool.insert &&
                                        tool != LevelTool.spawn))
                                  ButtonSegment(
                                    value: tool,
                                    tooltip: tool.label,
                                    icon: Icon(switch (tool) {
                                      LevelTool.select => Icons.near_me_outlined,
                                      LevelTool.multi => Icons.select_all,
                                      LevelTool.stamp => Icons.add_box_outlined,
                                      LevelTool.connect => Icons.hub_outlined,
                                      LevelTool.insert => Icons.linear_scale,
                                      LevelTool.spawn => Icons.flag_outlined,
                                      LevelTool.erase => Icons.delete_outline,
                                    }),
                                  ),
                            ],
                            selected: {levelState.tool},
                            onSelectionChanged: (s) => levelNotifier.setTool(s.first),
                          ),
                          const SizedBox(width: 12),

                          // Island Brush Controls
                          if (levelState.activeLayer == MapLayer.island) ...[
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
                              selected: {levelState.islandBrushRadius},
                              onSelectionChanged: (s) =>
                                  levelNotifier.setIslandBrushRadius(s.first),
                            ),
                            const SizedBox(width: 6),
                            FilledButton.tonalIcon(
                              onPressed: levelNotifier.generateIsland,
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.grass, size: 16),
                              label: const Text('Autotile'),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton.icon(
                              onPressed: levelNotifier.resetIslandMask,
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Reset'),
                            ),
                            const SizedBox(width: 12),
                          ],

                          // Spawn Direction Dropdown
                          if (levelState.tool == LevelTool.spawn) ...[
                            const Text('Facing'),
                            const SizedBox(width: 4),
                            DropdownButton<PortDirection>(
                              value: levelState.spawnFacing,
                              isDense: true,
                              items: const [
                                DropdownMenuItem(value: PortDirection.up, child: Text('Up')),
                                DropdownMenuItem(value: PortDirection.right, child: Text('Right')),
                                DropdownMenuItem(value: PortDirection.down, child: Text('Down')),
                                DropdownMenuItem(value: PortDirection.left, child: Text('Left')),
                              ],
                              onChanged: (d) {
                                if (d != null) levelNotifier.setSpawnFacing(d);
                              },
                            ),
                            const SizedBox(width: 12),
                          ],

                          // Remove & Close Connection
                          if (levelState.highlighted.length == 1) ...[
                            OutlinedButton.icon(
                              onPressed: () => levelNotifier
                                  .deleteStraightAndClose(levelState.highlighted.first),
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.compress, size: 16),
                              label: const Text('Remove & Close'),
                            ),
                            const SizedBox(width: 6),
                          ],

                          // Undo, Clear, Export Actions
                          OutlinedButton.icon(
                            onPressed: levelState.undoStack.isEmpty ? null : levelNotifier.undo,
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.undo, size: 16),
                            label: const Text('Undo'),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            onPressed: levelState.placements.isEmpty
                                ? null
                                : () => _showClearConfirmation(context, levelNotifier),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.clear_all, size: 16),
                            label: const Text('Clear'),
                          ),
                          const SizedBox(width: 6),
                          FilledButton.icon(
                            onPressed: levelNotifier.exportMap,
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.save_alt, size: 16),
                            label: const Text('Export'),
                          ),
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
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: mode.index,
                  onDestinationSelected: (index) => ref
                      .read(appModeProvider.notifier)
                      .select(AppMode.values[index]),
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.category_outlined),
                      selectedIcon: Icon(Icons.category),
                      label: Text('Asset\nDefiner', textAlign: TextAlign.center),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.map_outlined),
                      selectedIcon: Icon(Icons.map),
                      label: Text('Level\nEditor', textAlign: TextAlign.center),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: switch (mode) {
                    AppMode.assetDefiner => const AssetDefinerPage(),
                    AppMode.levelEditor => const LevelEditorPage(),
                  },
                ),
              ],
            ),
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
                        ? (assetState.statusMessage ?? 'Asset Definer ready')
                        : (levelState.statusMessage ?? 'Level Editor ready'),
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (mode == AppMode.levelEditor) ...[
                  Text(
                    '${levelState.placements.length} blocks placed',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                  const SizedBox(width: 16),
                  if (levelState.spawn != null)
                    const Text('🏁 Spawn set', style: TextStyle(color: Colors.greenAccent, fontSize: 11))
                  else
                    const Text('⚠️ No Spawn', style: TextStyle(color: Colors.orangeAccent, fontSize: 11)),
                ]
              ],
            ),
          ),
        ],
      ),
    );
  }
}
