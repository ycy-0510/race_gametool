import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/pixel_editor_providers.dart';

/// Right-hand color panel: current color with hex/RGB entry, visual HSV
/// sliders, and the indexed palette (tap to pick, right-click to remove,
/// import/export as JASC .pal).
class ColorPanel extends ConsumerStatefulWidget {
  const ColorPanel({super.key});

  @override
  ConsumerState<ColorPanel> createState() => _ColorPanelState();
}

class _ColorPanelState extends ConsumerState<ColorPanel> {
  final _hexController = TextEditingController();

  // HSV kept locally so dragging value/saturation at, e.g., V=0 does not
  // snap hue back to 0 (many ARGB values map to the same HSV).
  HSVColor _hsv = HSVColor.fromColor(const Color(0xff000000));
  int _lastSeenColor = 0xff000000;

  @override
  void initState() {
    super.initState();
    _syncFrom(ref.read(pixelEditorProvider).color);
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _syncFrom(int argb) {
    _lastSeenColor = argb;
    _hexController.text =
        argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    final color = Color(argb);
    final hsv = HSVColor.fromColor(color);
    // Preserve the local hue when the color is achromatic.
    _hsv = HSVColor.fromAHSV(
      hsv.alpha,
      hsv.saturation == 0 || hsv.value == 0 ? _hsv.hue : hsv.hue,
      hsv.value == 0 ? _hsv.saturation : hsv.saturation,
      hsv.value,
    );
  }

  void _applyHsv(HSVColor hsv) {
    setState(() => _hsv = hsv);
    final argb = hsv.toColor().toARGB32();
    _lastSeenColor = argb;
    _hexController.text = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    ref.read(pixelEditorProvider.notifier).setColor(argb);
  }

  void _applyHex(String text) {
    var s = text.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    final value = int.tryParse(s, radix: 16);
    if (value == null || s.length != 8) return;
    ref.read(pixelEditorProvider.notifier).setColor(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = ref.watch(pixelEditorProvider.select((s) => s.color));
    final palette = ref.watch(pixelEditorProvider.select((s) => s.palette));
    final notifier = ref.read(pixelEditorProvider.notifier);

    if (color != _lastSeenColor) _syncFrom(color);

    return SizedBox(
      width: 232,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('Color', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Color(color),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _hexController,
                  decoration: const InputDecoration(
                    prefixText: '#',
                    isDense: true,
                    labelText: 'AARRGGBB',
                  ),
                  style: theme.textTheme.bodySmall,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9a-fA-F#]')),
                    LengthLimitingTextInputFormatter(9),
                  ],
                  onSubmitted: _applyHex,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _GradientSlider(
            label: 'H',
            value: _hsv.hue / 360,
            colors: [
              for (var i = 0; i <= 6; i++)
                HSVColor.fromAHSV(1, i * 60.0, 1, 1).toColor(),
            ],
            onChanged: (v) =>
                _applyHsv(_hsv.withHue((v * 360).clamp(0, 359.9))),
          ),
          _GradientSlider(
            label: 'S',
            value: _hsv.saturation,
            colors: [
              _hsv.withSaturation(0).toColor(),
              _hsv.withSaturation(1).toColor(),
            ],
            onChanged: (v) => _applyHsv(_hsv.withSaturation(v)),
          ),
          _GradientSlider(
            label: 'V',
            value: _hsv.value,
            colors: [
              _hsv.withValue(0).toColor(),
              _hsv.withValue(1).toColor(),
            ],
            onChanged: (v) => _applyHsv(_hsv.withValue(v)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text('Palette', style: theme.textTheme.titleSmall),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Add current color',
                icon: const Icon(Icons.add),
                onPressed: notifier.addCurrentColorToPalette,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Import palette (.pal)',
                icon: const Icon(Icons.file_open_outlined),
                onPressed: notifier.importPalette,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Export palette (.pal)',
                icon: const Icon(Icons.save_alt),
                onPressed: notifier.exportPalette,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Click to pick, right-click to remove.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var i = 0; i < palette.length; i++)
                GestureDetector(
                  onTap: () => notifier.setColor(palette[i]),
                  onSecondaryTap: () => notifier.removePaletteColor(i),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Color(palette[i]),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        width: palette[i] == color ? 2 : 1,
                        color: palette[i] == color
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A slider drawn as a gradient bar with a position marker; drag anywhere on
/// the bar to set the 0..1 value.
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                void handle(Offset local) => onChanged(
                    (local.dx / constraints.maxWidth).clamp(0.0, 1.0));
                return GestureDetector(
                  onTapDown: (d) => handle(d.localPosition),
                  onHorizontalDragUpdate: (d) => handle(d.localPosition),
                  child: Container(
                    height: 18,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: colors),
                      borderRadius: BorderRadius.circular(4),
                      border:
                          Border.all(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Align(
                      alignment: Alignment((value * 2 - 1).clamp(-1.0, 1.0), 0),
                      child: Container(
                        width: 4,
                        height: 18,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(2),
                          border: Border.all(color: Colors.black45),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
