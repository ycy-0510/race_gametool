import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/logic/island_tiles.dart';
import 'package:race_gametool/models/mask_draft.dart';
import 'package:race_gametool/models/port.dart';

int _n = 0;
MaskDraft _tile(Set<PortDirection> dirs) => MaskDraft(
      id: 'i${_n++}',
      gridX: 0,
      gridY: 0,
      widthCells: 1,
      heightCells: 1,
      ports: [
        for (final d in dirs)
          Port(localGridX: 0, localGridY: 0, direction: d, span: 1),
      ],
    );

void main() {
  test('kind labels follow the 8-direction signatures', () {
    expect(islandKindLabel(interiorSignature), 'Interior');
    expect(islandKindLabel(edgeSignatures.first), 'Edge');
    expect(islandKindLabel(convexCornerSignatures.first), 'Convex corner');
    expect(islandKindLabel(concaveCornerSignatures.first), 'Concave corner');
    expect(islandKindLabel({PortDirection.up}), 'Other');
  });

  test('convex set complete but concave missing', () {
    final masks = [
      _tile(interiorSignature),
      for (final s in edgeSignatures) _tile(s),
      for (final s in convexCornerSignatures) _tile(s),
    ];
    final stats = computeIslandStats(masks);
    expect(stats.total, 9);
    expect(stats.convexComplete, isTrue);
    expect(stats.concaveComplete, isFalse);
    expect(stats.missingConcave.length, 4);
    expect(stats.countByKind['Interior'], 1);
    expect(stats.countByKind['Edge'], 4);
    expect(stats.countByKind['Convex corner'], 4);
  });

  test('adding all concave corners unlocks the advanced generator', () {
    final masks = [
      _tile(interiorSignature),
      for (final s in edgeSignatures) _tile(s),
      for (final s in convexCornerSignatures) _tile(s),
      for (final s in concaveCornerSignatures) _tile(s),
    ];
    final stats = computeIslandStats(masks);
    expect(stats.convexComplete, isTrue);
    expect(stats.concaveComplete, isTrue);
  });

  test('duplicate signatures are reported', () {
    final masks = [
      _tile(interiorSignature),
      _tile(interiorSignature),
    ];
    final stats = computeIslandStats(masks);
    expect(stats.duplicated.length, 1);
    expect(stats.convexComplete, isFalse); // edges/corners still missing
  });
}
