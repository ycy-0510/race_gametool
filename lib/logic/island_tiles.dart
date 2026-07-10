import '../models/mask_draft.dart';
import '../models/port.dart';

/// Island autotiling is driven by 8-direction port marking: a port in a
/// direction means "grass continues that way". A tile's KIND is the set of
/// directions it has ports in. This module classifies those signatures and
/// checks whether a bundle has the full set needed by the generators.

typedef DirSet = Set<PortDirection>;

const _up = PortDirection.up;
const _down = PortDirection.down;
const _left = PortDirection.left;
const _right = PortDirection.right;
const _ur = PortDirection.diagUR;
const _ul = PortDirection.diagUL;
const _dr = PortDirection.diagDR;
const _dl = PortDirection.diagDL;

/// A stable key for a direction set (order-independent).
String sigKey(DirSet dirs) {
  final list = dirs.map((d) => d.jsonValue).toList()..sort();
  return list.join('|');
}

/// Interior tile: grass on all 8 neighbours.
final DirSet interiorSignature = {_up, _down, _left, _right, _ur, _ul, _dr, _dl};

/// The 4 edge tiles: one cardinal side is water, so that cardinal and the
/// two diagonals on the water side are absent.
final List<DirSet> edgeSignatures = [
  {_up, _left, _right, _ul, _ur}, // water below
  {_down, _left, _right, _dl, _dr}, // water above
  {_up, _down, _right, _ur, _dr}, // water left
  {_up, _down, _left, _ul, _dl}, // water right
];

/// The 4 convex (outer) corners: grass on two adjacent cardinals plus the
/// diagonal between them.
final List<DirSet> convexCornerSignatures = [
  {_up, _right, _ur},
  {_up, _left, _ul},
  {_down, _right, _dr},
  {_down, _left, _dl},
];

/// The 4 concave (inner) corners: grass on all four cardinals but one
/// diagonal is water (nothing points diagonally into the notch).
final List<DirSet> concaveCornerSignatures = [
  {_up, _down, _left, _right, _ur, _ul, _dr}, // notch at down-left
  {_up, _down, _left, _right, _ur, _ul, _dl}, // notch at down-right
  {_up, _down, _left, _right, _ur, _dr, _dl}, // notch at up-left
  {_up, _down, _left, _right, _ul, _dr, _dl}, // notch at up-right
];

/// Signatures required for the basic (convex-only) generator.
List<DirSet> get convexSetSignatures =>
    [interiorSignature, ...edgeSignatures, ...convexCornerSignatures];

/// Human-readable kind label for a signature.
String islandKindLabel(DirSet dirs) {
  final key = sigKey(dirs);
  if (key == sigKey(interiorSignature)) return 'Interior';
  if (edgeSignatures.any((s) => sigKey(s) == key)) return 'Edge';
  if (convexCornerSignatures.any((s) => sigKey(s) == key)) {
    return 'Convex corner';
  }
  if (concaveCornerSignatures.any((s) => sigKey(s) == key)) {
    return 'Concave corner';
  }
  return 'Other';
}

/// Tally + readiness of the island tiles authored so far.
class IslandTileStats {
  const IslandTileStats({
    required this.countBySignature,
    required this.countByKind,
    required this.total,
    required this.convexComplete,
    required this.concaveComplete,
    required this.missingConvex,
    required this.missingConcave,
    required this.duplicated,
  });

  /// How many masks carry each exact signature.
  final Map<String, int> countBySignature;

  /// How many masks fall into each kind label.
  final Map<String, int> countByKind;

  final int total;

  /// Whether every convex-set signature is present at least once (basic
  /// generator usable).
  final bool convexComplete;

  /// Whether every concave corner is also present (advanced generator).
  final bool concaveComplete;

  /// Convex/concave signatures still missing (as kind labels), for hints.
  final List<String> missingConvex;
  final List<String> missingConcave;

  /// Signatures that have more than one tile (the generator picks randomly).
  final List<String> duplicated;
}

IslandTileStats computeIslandStats(List<MaskDraft> islandMasks) {
  final countBySignature = <String, int>{};
  final countByKind = <String, int>{};
  for (final mask in islandMasks) {
    final sig = mask.ports.map((p) => p.direction).toSet();
    final key = sigKey(sig);
    countBySignature[key] = (countBySignature[key] ?? 0) + 1;
    final kind = islandKindLabel(sig);
    countByKind[kind] = (countByKind[kind] ?? 0) + 1;
  }

  List<String> missing(List<DirSet> required) => [
        for (final s in required)
          if (!countBySignature.containsKey(sigKey(s))) islandKindLabel(s),
      ];

  final missingConvex = missing(convexSetSignatures);
  final missingConcave = missing(concaveCornerSignatures);

  return IslandTileStats(
    countBySignature: countBySignature,
    countByKind: countByKind,
    total: islandMasks.length,
    convexComplete: missingConvex.isEmpty,
    concaveComplete: missingConcave.isEmpty,
    missingConvex: missingConvex,
    missingConcave: missingConcave,
    duplicated: [
      for (final e in countBySignature.entries)
        if (e.value > 1) e.key,
    ],
  );
}
