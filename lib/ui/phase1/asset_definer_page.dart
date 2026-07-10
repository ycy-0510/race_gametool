import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/block_def.dart';
import '../../state/asset_definer_providers.dart';
import 'inspector_panel.dart';
import 'mask_canvas.dart';

/// Short display label for each asset category.
String categoryLabel(BlockCategory c) => switch (c) {
      BlockCategory.track => 'Track',
      BlockCategory.islandTile => 'Island',
      BlockCategory.decoration => 'Decoration',
      BlockCategory.wall => 'Wall',
      BlockCategory.checkLine => 'Check Line',
    };

/// Phase 1: load a raw draft image, mask track pieces with bounding boxes,
/// define ports on their edges, then crop, bin-pack, and export
/// SpriteSheet.png plus sprite_dict.json.
class AssetDefinerPage extends ConsumerWidget {
  const AssetDefinerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(assetDefinerProvider);
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Container(
            color: theme.colorScheme.surfaceContainerLowest,
            child: state.image == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.image_outlined,
                            size: 64,
                            color: theme.colorScheme.outline),
                        const SizedBox(height: 12),
                        Text(
                          'Load a ${categoryLabel(state.activeCategory)} '
                          'image, then drag boxes over each piece',
                          style: theme.textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  )
                : const MaskCanvas(),
          ),
        ),
        const VerticalDivider(width: 1),
        const SizedBox(width: 280, child: InspectorPanel()),
      ],
    );
  }
}

