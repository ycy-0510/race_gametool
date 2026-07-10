import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

BlockDef _block(String id, BlockCategory category) => BlockDef(
      id: id,
      boundingBox: const BoundingBox(width: 3, height: 3),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 48, h: 48),
      category: category,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late LevelEditorNotifier notifier;
  LevelEditorState read() => container.read(levelEditorProvider);

  setUp(() async {
    container = ProviderContainer();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final image = await recorder.endRecording().toImage(8, 8);
    container.read(assetLibraryProvider.notifier).setAssets(
      blocks: [
        _block('road', BlockCategory.track),
        _block('grass', BlockCategory.islandTile),
      ],
      sheetBytes: Uint8List(0),
      sheetImage: image,
    );
    notifier = container.read(levelEditorProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('MapLayer maps categories to layers', () {
    expect(MapLayer.forCategory(BlockCategory.track), MapLayer.track);
    expect(MapLayer.forCategory(BlockCategory.islandTile), MapLayer.island);
    expect(MapLayer.forCategory(BlockCategory.decoration), MapLayer.decoration);
  });

  test('blocks on different layers may overlap', () {
    notifier.setLayer(MapLayer.track);
    notifier.selectPalette('road');
    notifier.stampAt(0, 0);
    notifier.setLayer(MapLayer.island);
    notifier.selectPalette('grass');
    notifier.stampAt(0, 0); // same cells, different layer -> allowed
    expect(read().placements.length, 2);
  });

  test('same-layer overlap is still rejected', () {
    notifier.setLayer(MapLayer.track);
    notifier.selectPalette('road');
    notifier.stampAt(0, 0);
    notifier.stampAt(1, 1); // overlaps the first track block
    expect(read().placements.length, 1);
  });

  test('selection hit-test respects the active layer', () {
    notifier.setLayer(MapLayer.track);
    notifier.selectPalette('road');
    notifier.stampAt(0, 0);
    notifier.setLayer(MapLayer.island);
    notifier.selectPalette('grass');
    notifier.stampAt(0, 0);

    // On the island layer, a click hits the island block (index 1).
    notifier.selectAt(1, 1);
    expect(read().selectedPlacementIndex, 1);

    // Switching to the track layer, the same click hits the road (index 0).
    notifier.setLayer(MapLayer.track);
    notifier.selectAt(1, 1);
    expect(read().selectedPlacementIndex, 0);
  });
}
