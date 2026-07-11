import 'dart:math' as math;

import '../core/constants.dart';
import '../models/geometry.dart';
import '../models/mask_draft.dart';

/// Returns a user-facing error when a mask's optional drivable-area polygon
/// is invalid, or null when it is safe to save and export.
String? validatePhysicsTrackArea(MaskDraft mask) {
  final vertices = mask.physicsTrackArea;
  if (vertices.isEmpty) return null;
  if (vertices.length < 3) return 'needs at least 3 points';
  if (!isSimplePolygon(vertices)) return 'must be a simple polygon';

  for (final vertex in vertices) {
    if (!_isInsideMask(vertex, mask)) {
      return 'has a point outside the mask shape';
    }
  }
  return null;
}

bool _isInsideMask(Vec2 point, MaskDraft mask) {
  if (!point.x.isFinite || !point.y.isFinite) return false;

  final cell = GridConstants.cellSize;
  final width = mask.widthCells * cell;
  final height = mask.heightCells * cell;
  if (point.x < 0 || point.x > width || point.y < 0 || point.y > height) {
    return false;
  }

  final cells = mask.cells;
  if (cells == null) return true;

  // A freeform mask is the union of its painted cells. Checking each cell
  // keeps vertices out of the empty portions of its bounding rectangle.
  return cells.any((cellPos) {
    final left = cellPos.$1 * cell;
    final top = cellPos.$2 * cell;
    return point.x >= left &&
        point.x <= left + cell &&
        point.y >= top &&
        point.y <= top + cell;
  });
}

/// Whether a polygon has no self-intersections or overlapping edges.
bool isSimplePolygon(List<Vec2> vertices) {
  if (vertices.isEmpty) return true;
  if (vertices.length < 3) return false;

  final n = vertices.length;
  for (var i = 0; i < n; i++) {
    final p1 = vertices[i];
    final q1 = vertices[(i + 1) % n];
    for (var j = i + 1; j < n; j++) {
      final p2 = vertices[j];
      final q2 = vertices[(j + 1) % n];
      if (_segmentsIntersect(p1, q1, p2, q2)) return false;
    }
  }
  return true;
}

bool _segmentsIntersect(Vec2 p1, Vec2 q1, Vec2 p2, Vec2 q2) {
  final sharesVertex = p1 == p2 || p1 == q2 || q1 == p2 || q1 == q2;
  final o1 = _orientation(p1, q1, p2);
  final o2 = _orientation(p1, q1, q2);
  final o3 = _orientation(p2, q2, p1);
  final o4 = _orientation(p2, q2, q1);

  if (o1 != o2 && o3 != o4) return !sharesVertex;
  if (sharesVertex) {
    if (q1 == p2) {
      return (o3 == 0 && _onSegmentExclusive(p2, p1, q2)) ||
          (o2 == 0 && _onSegmentExclusive(p1, q2, q1));
    }
    if (p1 == p2) {
      return (o4 == 0 && _onSegmentExclusive(p2, q1, q2)) ||
          (o2 == 0 && _onSegmentExclusive(p1, q2, q1));
    }
    if (q1 == q2) {
      return (o3 == 0 && _onSegmentExclusive(p2, p1, q2)) ||
          (o1 == 0 && _onSegmentExclusive(p1, p2, q1));
    }
    return (o4 == 0 && _onSegmentExclusive(p2, q1, q2)) ||
        (o1 == 0 && _onSegmentExclusive(p1, p2, q1));
  }

  return (o1 == 0 && _onSegment(p1, p2, q1)) ||
      (o2 == 0 && _onSegment(p1, q2, q1)) ||
      (o3 == 0 && _onSegment(p2, p1, q2)) ||
      (o4 == 0 && _onSegment(p2, q1, q2));
}

int _orientation(Vec2 p, Vec2 q, Vec2 r) {
  final value = (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
  if (value == 0) return 0;
  return value > 0 ? 1 : 2;
}

bool _onSegment(Vec2 p, Vec2 r, Vec2 q) =>
    r.x <= math.max(p.x, q.x) &&
    r.x >= math.min(p.x, q.x) &&
    r.y <= math.max(p.y, q.y) &&
    r.y >= math.min(p.y, q.y);

bool _onSegmentExclusive(Vec2 p, Vec2 r, Vec2 q) =>
    r != p && r != q && _onSegment(p, r, q);
