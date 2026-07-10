import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/port.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

/// A 5x1 horizontal straight: LEFT and RIGHT span-1 ports (symmetric).
BlockDef _straight = const BlockDef(
  id: 'straight',
  boundingBox: BoundingBox(width: 5, height: 1),
  spriteSheetRect: SpriteSheetRect(x: 0, y: 0, w: 80, h: 16),
  category: BlockCategory.track,
  ports: [
    Port(localGridX: 0, localGridY: 0, direction: PortDirection.left),
    Port(localGridX: 4, localGridY: 0, direction: PortDirection.right),
  ],
);

/// A track corner: LEFT + DOWN ports (adjacent, not opposite) -> not straight.
BlockDef _corner = const BlockDef(
  id: 'corner',
  boundingBox: BoundingBox(width: 5, height: 5),
  spriteSheetRect: SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
  category: BlockCategory.track,
  ports: [
    Port(localGridX: 0, localGridY: 0, direction: PortDirection.left),
    Port(localGridX: 0, localGridY: 4, direction: PortDirection.down),
  ],
);

/// An island tile whose LEFT port would falsely match a track RIGHT port.
BlockDef _islandTile = const BlockDef(
  id: 'grass',
  boundingBox: BoundingBox(width: 1, height: 1),
  spriteSheetRect: SpriteSheetRect(x: 0, y: 0, w: 16, h: 16),
  category: BlockCategory.islandTile,
  ports: [
    Port(localGridX: 0, localGridY: 0, direction: PortDirection.left),
    Port(localGridX: 0, localGridY: 0, direction: PortDirection.right),
  ],
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
      blocks: [_straight, _corner, _islandTile],
      sheetBytes: Uint8List(0),
      sheetImage: image,
    );
    notifier = container.read(levelEditorProvider.notifier);
    notifier.setLayer(MapLayer.track);
    notifier.selectPalette('straight');
    notifier.stampAt(10, 10); // covers x10..14
  });

  tearDown(() => container.dispose());

  test('track connect never offers an island tile', () {
    final hit = notifier.connectPortAt(15, 10)!; // RIGHT port
    final candidates = notifier.connectCandidates(hit);
    expect(candidates, isNotEmpty);
    expect(candidates.every((c) => c.def.category == BlockCategory.track),
        isTrue);
    expect(candidates.map((c) => c.def.id), isNot(contains('grass')));
  });

  test('only a true straight auto-extends; a corner places one', () {
    final hit = notifier.connectPortAt(15, 10)!;
    final candidates = notifier.connectCandidates(hit);

    final straight = candidates.firstWhere((c) => c.def.id == 'straight');
    notifier.chooseConnection(hit, straight, cols: 60, rows: 60);
    expect(read().extendPreview, isNotNull,
        reason: 'straight should preview a run');

    // Reset the preview, then connect the corner from the same port.
    notifier.cancelExtend();
    final corner = candidates.firstWhere((c) => c.def.id == 'corner');
    final before = read().placements.length;
    notifier.chooseConnection(hit, corner, cols: 60, rows: 60);
    expect(read().extendPreview, isNull,
        reason: 'a corner is not a straight, so no run');
    expect(read().placements.length, before + 1);
  });
}
