import '../models/block_def.dart';
import '../models/map_scene.dart';
import '../models/port.dart';
import '../state/level_editor_providers.dart';

/// A clean, directed seam between two placed blocks: [nearIndex]'s port
/// (facing [dir]) meets [farIndex]'s back-facing port, strip-for-strip.
class Seam {
  const Seam({
    required this.nearIndex,
    required this.nearPortIndex,
    required this.dir,
    required this.farIndex,
    required this.farPortIndex,
    required this.span,
  });

  final int nearIndex;
  final int nearPortIndex;
  final PortDirection dir; // outward from near toward far
  final int farIndex;
  final int farPortIndex;
  final int span;
}

/// Finds every clean, flush-aligned seam (reported once per direction, so a
/// connected pair yields two Seams: near->far and far->near). A seam exists
/// when a port's outward strip exactly equals a single neighbour's
/// back-facing port strip of the same span.
List<Seam> findSeams(
  List<BlockPlacement> placements,
  BlockDef? Function(String id) defOf,
) {
  // Map each occupied cell to its placement index for neighbour lookup.
  final owner = <(int, int), int>{};
  for (var i = 0; i < placements.length; i++) {
    final def = defOf(placements[i].blockId);
    if (def == null) continue;
    final p = placements[i];
    for (var y = 0; y < def.boundingBox.height; y++) {
      for (var x = 0; x < def.boundingBox.width; x++) {
        owner[(p.gridX + x, p.gridY + y)] = i;
      }
    }
  }

  final seams = <Seam>[];
  for (var i = 0; i < placements.length; i++) {
    final def = defOf(placements[i].blockId);
    if (def == null) continue;
    final p = placements[i];
    for (var pi = 0; pi < def.ports.length; pi++) {
      final port = def.ports[pi];
      for (final dir in portOutwardDirections(def, port)) {
        final outward = portOutwardCells(p.gridX, p.gridY, port, dir);
        // All outward cells must belong to one single neighbour.
        final owners = <int>{};
        for (final c in outward) {
          final o = owner[c];
          if (o == null || o == i) {
            owners.add(-1);
          } else {
            owners.add(o);
          }
        }
        if (owners.length != 1 || owners.first == -1) continue;
        final j = owners.first;
        final ndef = defOf(placements[j].blockId)!;
        // Ports are isolated per asset family: a seam only forms between two
        // blocks of the same category (island tiles never seam to track).
        if (ndef.category != def.category) continue;
        final np = placements[j];
        final target = outward.toSet();

        // The neighbour must have a back-facing port of equal span whose
        // strip is exactly these cells.
        for (var pj = 0; pj < ndef.ports.length; pj++) {
          final nport = ndef.ports[pj];
          if (nport.span != port.span) continue;
          if (!portOutwardDirections(ndef, nport).contains(dir.opposite)) {
            continue;
          }
          final strip = portStripCells(np.gridX, np.gridY, nport);
          if (strip.length == target.length && strip.containsAll(target)) {
            seams.add(Seam(
              nearIndex: i,
              nearPortIndex: pi,
              dir: dir,
              farIndex: j,
              farPortIndex: pj,
              span: port.span,
            ));
            break;
          }
        }
      }
    }
  }
  return seams;
}

/// Undirected adjacency between placements derived from seams.
Map<int, Set<int>> buildAdjacency(int count, List<Seam> seams) {
  final adj = {for (var i = 0; i < count; i++) i: <int>{}};
  for (final s in seams) {
    adj[s.nearIndex]!.add(s.farIndex);
    adj[s.farIndex]!.add(s.nearIndex);
  }
  return adj;
}

/// Set of placements reachable from [start] over [adj], optionally ignoring
/// the single undirected edge {edgeA, edgeB} (the seam being operated on).
Set<int> reachable(
  Map<int, Set<int>> adj,
  int start, {
  int? edgeA,
  int? edgeB,
}) {
  final visited = <int>{};
  final queue = <int>[start];
  while (queue.isNotEmpty) {
    final u = queue.removeLast();
    if (!visited.add(u)) continue;
    for (final v in adj[u] ?? const <int>{}) {
      final blocked = (u == edgeA && v == edgeB) || (u == edgeB && v == edgeA);
      if (!blocked && !visited.contains(v)) queue.add(v);
    }
  }
  return visited;
}
