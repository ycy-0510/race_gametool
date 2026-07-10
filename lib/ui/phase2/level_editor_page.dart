import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logic/asset_bundle.dart';
import '../../models/port.dart';
import '../../state/app_providers.dart';
import '../../state/level_editor_providers.dart';
import '../widgets/block_thumbnail.dart';
import 'diagnostics_panel.dart';
import 'level_canvas.dart';

/// Phase 2: load a .rgpack bundle into a palette, stamp blocks on the grid
/// canvas, then (in later steps) route ports, generate the island, and
/// export the map scene.
class LevelEditorPage extends ConsumerWidget {
  const LevelEditorPage({super.key});

  Future<void> _importBundle(WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import asset bundle',
      type: FileType.custom,
      allowedExtensions: ['rgpack'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    final data = readAssetBundle(bytes);
    await ref.read(assetLibraryProvider.notifier).loadAssets(
          blocks: data.blocks,
          sheetBytes: data.sheetBytes,
          sourceName: result!.files.single.name,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final library = ref.watch(assetLibraryProvider);
    final state = ref.watch(levelEditorProvider);
    final notifier = ref.read(levelEditorProvider.notifier);

    return Row(
      children: [
        _Palette(
          onImport: () => _importBundle(ref),
          selectedId: state.selectedPaletteId,
          onSelect: notifier.selectPalette,
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              _Toolbar(state: state, notifier: notifier),
              const Divider(height: 1),
              Expanded(
                child: library.isEmpty
                    ? Center(
                        child: Text(
                          'Import a .rgpack bundle to start building a level',
                          style: theme.textTheme.bodyLarge,
                        ),
                      )
                    : Focus(
                        autofocus: true,
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              (event.logicalKey ==
                                      LogicalKeyboardKey.delete ||
                                  event.logicalKey ==
                                      LogicalKeyboardKey.backspace)) {
                            notifier.deleteSelected();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: const LevelCanvas(),
                      ),
              ),
              if (library.isNotEmpty) const DiagnosticsPanel(),
            ],
          ),
        ),
      ],
    );
  }
}

class _Palette extends StatelessWidget {
  const _Palette({
    required this.onImport,
    required this.selectedId,
    required this.onSelect,
  });

  final VoidCallback onImport;
  final String? selectedId;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final library = ref.watch(assetLibraryProvider);
        final activeLayer =
            ref.watch(levelEditorProvider.select((s) => s.activeLayer));
        final theme = Theme.of(context);
        // Only show blocks whose category belongs to the active layer.
        final blocks = [
          for (final b in library.blocks)
            if (activeLayer.accepts(b.category)) b,
        ];
        return SizedBox(
          width: 240,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Block Palette',
                          style: theme.textTheme.titleMedium),
                    ),
                    IconButton(
                      tooltip: 'Import bundle (.rgpack)',
                      icon: const Icon(Icons.folder_open),
                      onPressed: onImport,
                    ),
                  ],
                ),
              ),
              if (library.sourceName != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Source: ${library.sourceName}',
                      style: theme.textTheme.bodySmall),
                ),
              Expanded(
                child: library.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'No blocks loaded. Save a bundle in Phase 1, or '
                            'import a .rgpack here.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      )
                    : blocks.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'No ${activeLayer.label} blocks in this bundle.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          )
                        : ListView.builder(
                        itemCount: blocks.length,
                        itemBuilder: (context, index) {
                          final block = blocks[index];
                          final selected = block.id == selectedId;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor: theme
                                .colorScheme.primaryContainer
                                .withValues(alpha: 0.4),
                            leading: SizedBox(
                              width: 40,
                              height: 40,
                              child: library.sheetImage == null
                                  ? const Icon(Icons.widgets_outlined)
                                  : BlockThumbnail(
                                      image: library.sheetImage!,
                                      rect: block.spriteSheetRect,
                                    ),
                            ),
                            title: Text(block.id),
                            subtitle: Text(
                                '${block.boundingBox.width} x '
                                '${block.boundingBox.height}, '
                                '${block.ports.length} ports'),
                            onTap: () => onSelect(block.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.state, required this.notifier});

  final LevelEditorState state;
  final LevelEditorNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Icon(Icons.layers_outlined,
                  size: 18, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              SegmentedButton<MapLayer>(
                showSelectedIcon: false,
                segments: [
                  for (final layer in MapLayer.values)
                    ButtonSegment(value: layer, label: Text(layer.label)),
                ],
                selected: {state.activeLayer},
                onSelectionChanged: (s) => notifier.setLayer(s.first),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<LevelTool>(
                showSelectedIcon: false,
                segments: [
                  for (final tool in LevelTool.values)
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
                selected: {state.tool},
                onSelectionChanged: (s) => notifier.setTool(s.first),
              ),
              Text('${state.placements.length} placed',
                  style: theme.textTheme.labelMedium),
              OutlinedButton.icon(
                onPressed: state.highlighted.length == 1
                    ? () => notifier
                        .deleteStraightAndClose(state.highlighted.first)
                    : null,
                icon: const Icon(Icons.compress, size: 18),
                label: const Text('Remove & close'),
              ),
              if (state.tool == LevelTool.spawn)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Facing'),
                    const SizedBox(width: 4),
                    DropdownButton<PortDirection>(
                      value: state.spawnFacing,
                      isDense: true,
                      items: const [
                        DropdownMenuItem(
                            value: PortDirection.up, child: Text('Up')),
                        DropdownMenuItem(
                            value: PortDirection.right, child: Text('Right')),
                        DropdownMenuItem(
                            value: PortDirection.down, child: Text('Down')),
                        DropdownMenuItem(
                            value: PortDirection.left, child: Text('Left')),
                      ],
                      onChanged: (d) {
                        if (d != null) notifier.setSpawnFacing(d);
                      },
                    ),
                  ],
                ),
              OutlinedButton.icon(
                onPressed: state.placements.isEmpty ? null : notifier.clearAll,
                icon: const Icon(Icons.clear_all, size: 18),
                label: const Text('Clear'),
              ),
              FilledButton.icon(
                onPressed: notifier.exportMap,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('Export map'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Text(
            state.statusMessage ?? '',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
