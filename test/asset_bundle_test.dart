import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:race_gametool/logic/asset_bundle.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/mask_draft.dart';
import 'package:race_gametool/models/port.dart';

Uint8List _draft() {
  final draft = img.Image(width: 160, height: 160, numChannels: 4);
  img.fillRect(draft,
      x1: 0, y1: 0, x2: 79, y2: 31, color: img.ColorRgba8(255, 0, 0, 255));
  img.fillRect(draft,
      x1: 96, y1: 48, x2: 143, y2: 143, color: img.ColorRgba8(0, 0, 255, 255));
  return Uint8List.fromList(img.encodePng(draft));
}

void main() {
  final masks = [
    const MaskDraft(
      id: 'straight_h',
      gridX: 0,
      gridY: 0,
      widthCells: 5,
      heightCells: 2,
      ports: [
        Port(
            localGridX: 0,
            localGridY: 0,
            direction: PortDirection.up,
            span: 5,
            bidirectional: true),
      ],
    ),
    MaskDraft.fromCells(
      id: 'corner_bl',
      absoluteCells: {(6, 3), (6, 4), (7, 4), (8, 4)},
    ),
  ];

  test('write then read round trips editor state and game assets', () {
    final bundle = writeAssetBundle(
      categoryImages: {BlockCategory.track: _draft()},
      imageName: 'draft.png',
      masks: masks,
    );

    final data = readAssetBundle(bundle);
    expect(data.imageName, 'draft.png');
    expect(data.cellSize, 16);
    expect(data.masks.length, 2);

    final straight = data.masks.firstWhere((m) => m.id == 'straight_h');
    expect(straight.ports.single.bidirectional, isTrue);
    expect(straight.ports.single.span, 5);

    final corner = data.masks.firstWhere((m) => m.id == 'corner_bl');
    expect(corner.isFreeform, isTrue);
    expect(corner.cells, contains((0, 0)));
    expect(corner.cells, isNot(contains((1, 0))));

    expect(data.blocks.length, 2);
    expect(img.decodePng(data.sheetBytes), isNotNull);
  });

  test('extractGameAssets returns the sheet and dict without editor data', () {
    final bundle = writeAssetBundle(
      categoryImages: {BlockCategory.track: _draft()},
      imageName: 'draft.png',
      masks: masks,
    );
    final assets = extractGameAssets(bundle);
    expect(img.decodePng(assets.sheetBytes), isNotNull);
    expect(assets.spriteDictJson, contains('straight_h'));
    expect(assets.spriteDictJson, contains('spriteSheet'));
  });

  test('reading a bundle missing entries throws FormatException', () {
    expect(() => readAssetBundle(Uint8List.fromList([1, 2, 3])),
        throwsA(anything));
  });
}
