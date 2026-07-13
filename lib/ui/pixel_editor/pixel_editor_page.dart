import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logic/pixel_ops.dart';
import '../../models/block_def.dart';
import '../../state/pixel_editor_providers.dart';
import 'color_panel.dart';
import 'pixel_canvas.dart';

/// The Pixel Editor tab: its own toolbar (tools, options, file actions), the
/// zoomable canvas, and the color/palette panel. Self-contained so the app
/// shell only routes to it; Phase 1/2 UI is not shared.
class PixelEditorPage extends ConsumerWidget {
  const PixelEditorPage({super.key});

  Future<void> _newDocumentDialog(
      BuildContext context, WidgetRef ref) async {
    final state = ref.read(pixelEditorProvider);
    if (state.isDirty) {
      final discard = await _confirmDiscard(context, 'creating a new canvas');
      if (!discard) return;
    }
    if (!context.mounted) return;
    final size = await _promptSize(
      context,
      title: 'New Canvas',
      initialWidth: state.document.width,
      initialHeight: state.document.height,
    );
    if (size == null) return;
    ref.read(pixelEditorProvider.notifier).newDocument(size.$1, size.$2);
  }

  Future<void> _openDialog(BuildContext context, WidgetRef ref) async {
    final state = ref.read(pixelEditorProvider);
    if (state.isDirty) {
      final discard = await _confirmDiscard(context, 'opening another file');
      if (!discard) return;
    }
    await ref.read(pixelEditorProvider.notifier).openFile();
  }

  Future<bool> _confirmDiscard(BuildContext context, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard Pixel Art Changes?'),
        content: Text('Your pixel art has unsaved changes. Discard them '
            'before $action?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _resizeDialog(BuildContext context, WidgetRef ref) async {
    final state = ref.read(pixelEditorProvider);
    var anchorX = -1, anchorY = -1;
    final size = await _promptSize(
      context,
      title: 'Canvas Size',
      initialWidth: state.document.width,
      initialHeight: state.document.height,
      extra: StatefulBuilder(
        builder: (context, setState) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text('Anchor existing content:'),
            const SizedBox(height: 4),
            for (final y in [-1, 0, 1])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final x in [-1, 0, 1])
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      isSelected: anchorX == x && anchorY == y,
                      icon: Icon(
                        anchorX == x && anchorY == y
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 16,
                      ),
                      onPressed: () => setState(() {
                        anchorX = x;
                        anchorY = y;
                      }),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
    if (size == null) return;
    ref.read(pixelEditorProvider.notifier).resizeCanvasTo(
          size.$1,
          size.$2,
          anchorX: anchorX,
          anchorY: anchorY,
        );
  }

  Future<(int, int)?> _promptSize(
    BuildContext context, {
    required String title,
    required int initialWidth,
    required int initialHeight,
    Widget? extra,
  }) async {
    final widthController = TextEditingController(text: '$initialWidth');
    final heightController = TextEditingController(text: '$initialHeight');
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widthController,
                    decoration: const InputDecoration(
                        labelText: 'Width (px)', isDense: true),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: heightController,
                    decoration: const InputDecoration(
                        labelText: 'Height (px)', isDense: true),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
              ],
            ),
            const Text(
              '1-1024 px. One grid cell is 16 px.',
              style: TextStyle(fontSize: 11),
            ),
            ?extra,
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final w = int.tryParse(widthController.text);
              final h = int.tryParse(heightController.text);
              if (w == null || h == null || w < 1 || h < 1) return;
              Navigator.pop(context, (w.clamp(1, 1024), h.clamp(1, 1024)));
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    widthController.dispose();
    heightController.dispose();
    return result;
  }

  Future<void> _sendToPhase1Dialog(BuildContext context, WidgetRef ref) async {
    final category = await showDialog<BlockCategory>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Send to Phase 1 as...'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BlockCategory.track),
            child: const Text('Track source image (replaces current)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BlockCategory.islandTile),
            child: const Text('Island source image (replaces current)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BlockCategory.decoration),
            child: const Text('New decoration image (added)'),
          ),
        ],
      ),
    );
    if (category == null) return;
    await ref.read(pixelEditorProvider.notifier).sendToPhase1(category);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(pixelEditorProvider.notifier);
    final tool = ref.watch(pixelEditorProvider.select((s) => s.tool));
    final brushSize =
        ref.watch(pixelEditorProvider.select((s) => s.brushSize));
    final symmetry = ref.watch(pixelEditorProvider.select((s) => s.symmetry));
    final fillContiguous =
        ref.watch(pixelEditorProvider.select((s) => s.fillContiguous));
    final fillTolerance =
        ref.watch(pixelEditorProvider.select((s) => s.fillTolerance));
    final showPixelGrid =
        ref.watch(pixelEditorProvider.select((s) => s.showPixelGrid));
    final showCellGrid =
        ref.watch(pixelEditorProvider.select((s) => s.showCellGrid));
    final hasSelection = ref.watch(
        pixelEditorProvider.select((s) => s.selection != null || s.floating != null));

    // Single-letter tool shortcuts live on the canvas area only (not the
    // whole page), so typing in the color panel's hex field never switches
    // tools.
    final canvasShortcuts = <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyB): () =>
            notifier.setTool(PixelTool.pencil),
        const SingleActivator(LogicalKeyboardKey.keyE): () =>
            notifier.setTool(PixelTool.eraser),
        const SingleActivator(LogicalKeyboardKey.keyL): () =>
            notifier.setTool(PixelTool.line),
        const SingleActivator(LogicalKeyboardKey.keyR): () =>
            notifier.setTool(PixelTool.rect),
        const SingleActivator(LogicalKeyboardKey.keyO): () =>
            notifier.setTool(PixelTool.ellipse),
        const SingleActivator(LogicalKeyboardKey.keyG): () =>
            notifier.setTool(PixelTool.fill),
        const SingleActivator(LogicalKeyboardKey.keyI): () =>
            notifier.setTool(PixelTool.eyedropper),
        const SingleActivator(LogicalKeyboardKey.keyM): () =>
            notifier.setTool(PixelTool.selectRect),
        const SingleActivator(LogicalKeyboardKey.keyQ): () =>
            notifier.setTool(PixelTool.lasso),
        const SingleActivator(LogicalKeyboardKey.keyW): () =>
            notifier.setTool(PixelTool.wand),
        const SingleActivator(LogicalKeyboardKey.keyV): () =>
            notifier.setTool(PixelTool.move),
        const SingleActivator(LogicalKeyboardKey.bracketLeft): () =>
            notifier.setBrushSize(
                ref.read(pixelEditorProvider).brushSize - 1),
        const SingleActivator(LogicalKeyboardKey.bracketRight): () =>
            notifier.setBrushSize(
                ref.read(pixelEditorProvider).brushSize + 1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            notifier.cancelFloatingOrSelection(),
        const SingleActivator(LogicalKeyboardKey.delete): () =>
            notifier.deleteSelectionContents(),
        const SingleActivator(LogicalKeyboardKey.backspace): () =>
            notifier.deleteSelectionContents(),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
            notifier.selectAll(),
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
            notifier.selectAll(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () =>
            notifier.undo(),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            notifier.undo(),
        const SingleActivator(LogicalKeyboardKey.keyZ,
            meta: true, shift: true): () => notifier.redo(),
        const SingleActivator(LogicalKeyboardKey.keyZ,
            control: true, shift: true): () => notifier.redo(),
    };

    return Column(
          children: [
            Container(
              height: 44,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    SegmentedButton<PixelTool>(
                      showSelectedIcon: false,
                      style:
                          const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: [
                        for (final t in PixelTool.values)
                          ButtonSegment(
                            value: t,
                            tooltip: '${t.label}${_shortcutFor(t)}',
                            icon: Icon(_iconFor(t), size: 18),
                          ),
                      ],
                      selected: {tool},
                      onSelectionChanged: (s) => notifier.setTool(s.first),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.brush, size: 14),
                    const SizedBox(width: 4),
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                      style:
                          const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: const [
                        ButtonSegment(value: 1, label: Text('1')),
                        ButtonSegment(value: 2, label: Text('2')),
                        ButtonSegment(value: 3, label: Text('3')),
                        ButtonSegment(value: 4, label: Text('4')),
                      ],
                      selected: {brushSize.clamp(1, 4)},
                      onSelectionChanged: (s) => notifier.setBrushSize(s.first),
                    ),
                    const SizedBox(width: 12),
                    Tooltip(
                      message: 'Symmetry (mirror drawing)',
                      child: SegmentedButton<SymmetryMode>(
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                            visualDensity: VisualDensity.compact),
                        segments: const [
                          ButtonSegment(
                              value: SymmetryMode.none, label: Text('Off')),
                          ButtonSegment(
                              value: SymmetryMode.horizontal, label: Text('X')),
                          ButtonSegment(
                              value: SymmetryMode.vertical, label: Text('Y')),
                          ButtonSegment(
                              value: SymmetryMode.both, label: Text('XY')),
                        ],
                        selected: {symmetry},
                        onSelectionChanged: (s) => notifier.setSymmetry(s.first),
                      ),
                    ),
                    if (tool == PixelTool.fill || tool == PixelTool.wand) ...[
                      const SizedBox(width: 12),
                      FilterChip(
                        visualDensity: VisualDensity.compact,
                        label: const Text('Contiguous'),
                        tooltip: 'Off: recolor/select every matching pixel '
                            '(color replace)',
                        selected: fillContiguous,
                        onSelected: notifier.setFillContiguous,
                      ),
                      const SizedBox(width: 8),
                      const Text('Tolerance', style: TextStyle(fontSize: 11)),
                      SizedBox(
                        width: 110,
                        child: Slider(
                          value: fillTolerance.toDouble(),
                          max: 128,
                          divisions: 32,
                          label: '$fillTolerance',
                          onChanged: (v) =>
                              notifier.setFillTolerance(v.round()),
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Pixel grid',
                      isSelected: showPixelGrid,
                      icon: const Icon(Icons.grid_3x3, size: 18),
                      onPressed: notifier.togglePixelGrid,
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '16 px cell grid',
                      isSelected: showCellGrid,
                      icon: const Icon(Icons.grid_4x4, size: 18),
                      onPressed: notifier.toggleCellGrid,
                    ),
                    const SizedBox(width: 12),
                    MenuAnchor(
                      builder: (context, controller, _) => IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Canvas operations',
                        icon: const Icon(Icons.aspect_ratio, size: 18),
                        onPressed: () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                      ),
                      menuChildren: [
                        MenuItemButton(
                          onPressed: () => _resizeDialog(context, ref),
                          child: const Text('Canvas Size...'),
                        ),
                        MenuItemButton(
                          onPressed:
                              hasSelection ? notifier.cropToSelection : null,
                          child: const Text('Crop to Selection'),
                        ),
                        const Divider(height: 1),
                        MenuItemButton(
                          onPressed: () =>
                              notifier.rotate90Action(clockwise: true),
                          child: Text(hasSelection
                              ? 'Rotate Selection 90 CW'
                              : 'Rotate Canvas 90 CW'),
                        ),
                        MenuItemButton(
                          onPressed: () =>
                              notifier.rotate90Action(clockwise: false),
                          child: Text(hasSelection
                              ? 'Rotate Selection 90 CCW'
                              : 'Rotate Canvas 90 CCW'),
                        ),
                        MenuItemButton(
                          onPressed: () =>
                              notifier.flipAction(horizontal: true),
                          child: Text(hasSelection
                              ? 'Flip Selection Horizontal'
                              : 'Flip Canvas Horizontal'),
                        ),
                        MenuItemButton(
                          onPressed: () =>
                              notifier.flipAction(horizontal: false),
                          child: Text(hasSelection
                              ? 'Flip Selection Vertical'
                              : 'Flip Canvas Vertical'),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.add_box_outlined, size: 16),
                      label: const Text('New'),
                      onPressed: () => _newDocumentDialog(context, ref),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.file_open_outlined, size: 16),
                      label: const Text('Open .rgpix'),
                      onPressed: () => _openDialog(context, ref),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: const Text('Export PNG'),
                      onPressed: notifier.exportPng,
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.send, size: 16),
                      label: const Text('Send to Phase 1'),
                      onPressed: () => _sendToPhase1Dialog(context, ref),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: canvasShortcuts,
                      child: Focus(
                        autofocus: true,
                        child: Builder(
                          builder: (context) => Listener(
                            // Clicking the canvas returns keyboard focus to it
                            // after typing in the color panel.
                            onPointerDown: (_) =>
                                Focus.of(context).requestFocus(),
                            child: Container(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerLowest,
                              child: const PixelCanvas(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  const ColorPanel(),
                ],
              ),
            ),
          ],
    );
  }

  IconData _iconFor(PixelTool tool) => switch (tool) {
        PixelTool.pencil => Icons.edit,
        PixelTool.eraser => Icons.cleaning_services,
        PixelTool.line => Icons.timeline,
        PixelTool.rect => Icons.crop_square,
        PixelTool.ellipse => Icons.circle_outlined,
        PixelTool.fill => Icons.format_color_fill,
        PixelTool.eyedropper => Icons.colorize,
        PixelTool.selectRect => Icons.highlight_alt,
        PixelTool.lasso => Icons.gesture,
        PixelTool.wand => Icons.auto_fix_high,
        PixelTool.move => Icons.open_with,
      };

  String _shortcutFor(PixelTool tool) => switch (tool) {
        PixelTool.pencil => ' (B)',
        PixelTool.eraser => ' (E)',
        PixelTool.line => ' (L)',
        PixelTool.rect => ' (R)',
        PixelTool.ellipse => ' (O)',
        PixelTool.fill => ' (G)',
        PixelTool.eyedropper => ' (I)',
        PixelTool.selectRect => ' (M)',
        PixelTool.lasso => ' (Q)',
        PixelTool.wand => ' (W)',
        PixelTool.move => ' (V)',
      };
}
