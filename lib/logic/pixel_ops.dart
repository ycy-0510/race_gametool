import 'dart:collection';
import 'dart:typed_data';

/// Pure pixel-buffer operations for the pixel editor. Buffers are ARGB ints
/// in row-major order (see PixelDocument). Every drawing op takes an optional
/// selection [mask] (same length, non-zero = selected) and only writes inside
/// it, so tools transparently respect the active selection.
///
/// This file runs on the plain Dart VM: no dart:ui.

/// Mirror axes for symmetry drawing. Mirroring is around the canvas center
/// (pixel-exact for both even and odd sizes: x maps to width-1-x).
enum SymmetryMode {
  none('none'),
  horizontal('x'),
  vertical('y'),
  both('xy');

  const SymmetryMode(this.jsonValue);
  final String jsonValue;

  static SymmetryMode fromJson(String value) => SymmetryMode.values
      .firstWhere((m) => m.jsonValue == value, orElse: () => SymmetryMode.none);
}

/// The mirrored copies of a point under [mode], including the point itself.
/// May contain duplicates on the axis; callers just over-stamp.
List<(int, int)> symmetryPoints(int x, int y, int w, int h, SymmetryMode mode) {
  return switch (mode) {
    SymmetryMode.none => [(x, y)],
    SymmetryMode.horizontal => [(x, y), (w - 1 - x, y)],
    SymmetryMode.vertical => [(x, y), (x, h - 1 - y)],
    SymmetryMode.both => [
        (x, y),
        (w - 1 - x, y),
        (x, h - 1 - y),
        (w - 1 - x, h - 1 - y),
      ],
  };
}

/// Whether two ARGB colors are within [tolerance] on every channel
/// (alpha included). Tolerance 0 is an exact match.
bool colorWithinTolerance(int a, int b, int tolerance) {
  if (tolerance <= 0) return a == b;
  int diff(int shift) => ((a >>> shift) & 0xff) - ((b >>> shift) & 0xff);
  return diff(24).abs() <= tolerance &&
      diff(16).abs() <= tolerance &&
      diff(8).abs() <= tolerance &&
      diff(0).abs() <= tolerance;
}

bool _writable(Uint8List? mask, int index) => mask == null || mask[index] != 0;

void _set(Uint32List buf, int w, int h, int x, int y, int color,
    Uint8List? mask) {
  if (x < 0 || y < 0 || x >= w || y >= h) return;
  final i = y * w + x;
  if (_writable(mask, i)) buf[i] = color;
}

/// Stamps a square brush of side [brushSize]. The brush extends from the
/// anchor pixel toward the bottom-right for even sizes so a size-1 brush is
/// exactly the hovered pixel.
void stampBrush(Uint32List buf, int w, int h, int x, int y, int color,
    {int brushSize = 1, Uint8List? mask}) {
  final start = -(brushSize - 1) ~/ 2;
  for (var dy = start; dy < start + brushSize; dy++) {
    for (var dx = start; dx < start + brushSize; dx++) {
      _set(buf, w, h, x + dx, y + dy, color, mask);
    }
  }
}

/// Bresenham line, stamped with the brush at every step.
void drawLine(Uint32List buf, int w, int h, int x0, int y0, int x1, int y1,
    int color,
    {int brushSize = 1, Uint8List? mask}) {
  var x = x0, y = y0;
  final dx = (x1 - x0).abs(), dy = -(y1 - y0).abs();
  final sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
  var err = dx + dy;
  while (true) {
    stampBrush(buf, w, h, x, y, color, brushSize: brushSize, mask: mask);
    if (x == x1 && y == y1) break;
    final e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y += sy;
    }
  }
}

/// Axis-aligned rectangle between two corners (any order), outline or filled.
void drawRectShape(Uint32List buf, int w, int h, int x0, int y0, int x1,
    int y1, int color,
    {bool filled = false, int brushSize = 1, Uint8List? mask}) {
  final left = x0 < x1 ? x0 : x1, right = x0 < x1 ? x1 : x0;
  final top = y0 < y1 ? y0 : y1, bottom = y0 < y1 ? y1 : y0;
  if (filled) {
    for (var y = top; y <= bottom; y++) {
      for (var x = left; x <= right; x++) {
        _set(buf, w, h, x, y, color, mask);
      }
    }
    return;
  }
  drawLine(buf, w, h, left, top, right, top, color,
      brushSize: brushSize, mask: mask);
  drawLine(buf, w, h, right, top, right, bottom, color,
      brushSize: brushSize, mask: mask);
  drawLine(buf, w, h, right, bottom, left, bottom, color,
      brushSize: brushSize, mask: mask);
  drawLine(buf, w, h, left, bottom, left, top, color,
      brushSize: brushSize, mask: mask);
}

/// Ellipse inscribed in the rectangle between two corners (any order).
/// Integer midpoint algorithm (Zingl), correct for even and odd diameters.
void drawEllipseShape(Uint32List buf, int w, int h, int rx0, int ry0, int rx1,
    int ry1, int color,
    {bool filled = false, int brushSize = 1, Uint8List? mask}) {
  var x0 = rx0 < rx1 ? rx0 : rx1, x1 = rx0 < rx1 ? rx1 : rx0;
  var y0 = ry0 < ry1 ? ry0 : ry1, y1 = ry0 < ry1 ? ry1 : ry0;

  void plot(int x, int y) {
    stampBrush(buf, w, h, x, y, color, brushSize: brushSize, mask: mask);
  }

  void span(int xa, int xb, int y) {
    for (var x = xa; x <= xb; x++) {
      _set(buf, w, h, x, y, color, mask);
    }
  }

  // Zingl's plotEllipseRect, with the four quadrant pixels replaced by row
  // spans in filled mode.
  final a = x1 - x0, b = y1 - y0;
  final b1 = b & 1;
  var ddx = 4 * (1 - a) * b * b;
  var ddy = 4 * (b1 + 1) * a * a;
  var err = ddx + ddy + b1 * a * a;

  y0 += (b + 1) ~/ 2;
  y1 = y0 - b1;
  final a8 = 8 * a * a, b8 = 8 * b * b;

  do {
    if (filled) {
      span(x0, x1, y0);
      if (y1 != y0) span(x0, x1, y1);
    } else {
      plot(x1, y0);
      plot(x0, y0);
      plot(x0, y1);
      plot(x1, y1);
    }
    final e2 = 2 * err;
    if (e2 <= ddy) {
      y0++;
      y1--;
      err += ddy += a8;
    }
    if (e2 >= ddx || 2 * err > ddy) {
      x0++;
      x1--;
      err += ddx += b8;
    }
  } while (x0 <= x1);

  while (y0 - y1 < b) {
    // Finish the tips of flat ellipses (a == 1 stops the loop too early).
    if (filled) {
      span(x0 - 1, x1 + 1, y0);
      span(x0 - 1, x1 + 1, y1);
    } else {
      plot(x0 - 1, y0);
      plot(x1 + 1, y0);
      plot(x0 - 1, y1);
      plot(x1 + 1, y1);
    }
    y0++;
    y1--;
  }
}

/// Bucket fill. Contiguous mode flood-fills the 4-connected region around
/// the seed; non-contiguous mode recolors every matching pixel (this doubles
/// as the color-replace tool). Matching uses [tolerance] against the seed
/// pixel's color; writes respect [mask].
void floodFill(Uint32List buf, int w, int h, int x, int y, int color,
    {int tolerance = 0, bool contiguous = true, Uint8List? mask}) {
  if (x < 0 || y < 0 || x >= w || y >= h) return;
  final target = buf[y * w + x];
  if (tolerance <= 0 && target == color && contiguous) return;

  if (!contiguous) {
    for (var i = 0; i < buf.length; i++) {
      if (_writable(mask, i) && colorWithinTolerance(buf[i], target, tolerance)) {
        buf[i] = color;
      }
    }
    return;
  }

  final visited = Uint8List(w * h);
  final queue = Queue<int>()..add(y * w + x);
  visited[y * w + x] = 1;
  while (queue.isNotEmpty) {
    final i = queue.removeFirst();
    if (!colorWithinTolerance(buf[i], target, tolerance)) continue;
    if (_writable(mask, i)) buf[i] = color;
    final px = i % w, py = i ~/ w;
    for (final (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]) {
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      final ni = ny * w + nx;
      if (visited[ni] == 0) {
        visited[ni] = 1;
        queue.add(ni);
      }
    }
  }
}

/// Magic-wand selection: the mask of pixels matching the seed color, either
/// the 4-connected region (contiguous) or globally.
Uint8List magicWandMask(Uint32List buf, int w, int h, int x, int y,
    {int tolerance = 0, bool contiguous = true}) {
  final out = Uint8List(w * h);
  if (x < 0 || y < 0 || x >= w || y >= h) return out;
  final target = buf[y * w + x];

  if (!contiguous) {
    for (var i = 0; i < buf.length; i++) {
      if (colorWithinTolerance(buf[i], target, tolerance)) out[i] = 1;
    }
    return out;
  }

  final queue = Queue<int>()..add(y * w + x);
  out[y * w + x] = 1;
  final visited = Uint8List(w * h);
  visited[y * w + x] = 1;
  while (queue.isNotEmpty) {
    final i = queue.removeFirst();
    if (!colorWithinTolerance(buf[i], target, tolerance)) {
      out[i] = 0;
      continue;
    }
    final px = i % w, py = i ~/ w;
    for (final (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]) {
      if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
      final ni = ny * w + nx;
      if (visited[ni] == 0) {
        visited[ni] = 1;
        out[ni] = 1;
        queue.add(ni);
      }
    }
  }
  return out;
}

/// Selection mask covering the rectangle between two corners (any order).
Uint8List rectMask(int w, int h, int x0, int y0, int x1, int y1) {
  final out = Uint8List(w * h);
  final left = (x0 < x1 ? x0 : x1).clamp(0, w - 1);
  final right = (x0 < x1 ? x1 : x0).clamp(0, w - 1);
  final top = (y0 < y1 ? y0 : y1).clamp(0, h - 1);
  final bottom = (y0 < y1 ? y1 : y0).clamp(0, h - 1);
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      out[y * w + x] = 1;
    }
  }
  return out;
}

/// Selection mask of the polygon through [points] (lasso), filled with the
/// even-odd rule sampled at pixel centers.
Uint8List polygonMask(int w, int h, List<(double, double)> points) {
  final out = Uint8List(w * h);
  if (points.length < 3) return out;
  final n = points.length;
  for (var y = 0; y < h; y++) {
    final cy = y + 0.5;
    final xs = <double>[];
    for (var i = 0; i < n; i++) {
      final (ax, ay) = points[i];
      final (bx, by) = points[(i + 1) % n];
      if ((ay <= cy && by > cy) || (by <= cy && ay > cy)) {
        xs.add(ax + (cy - ay) / (by - ay) * (bx - ax));
      }
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      // A pixel is inside when its center x+0.5 falls in [xs[k], xs[k+1]).
      final start = (xs[k] - 0.5).ceil().clamp(0, w);
      final end = ((xs[k + 1] - 0.5).ceil() - 1).clamp(-1, w - 1);
      for (var x = start; x <= end; x++) {
        out[y * w + x] = 1;
      }
    }
  }
  return out;
}

/// Bounding box of a mask's selected pixels, or null when empty:
/// (left, top, right, bottom) inclusive.
(int, int, int, int)? maskBounds(Uint8List mask, int w, int h) {
  var left = w, top = h, right = -1, bottom = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (mask[y * w + x] == 0) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  return right < 0 ? null : (left, top, right, bottom);
}

/// Copies the masked pixels out of [buf] into a tight buffer and clears them
/// from the source ("lift" for a floating selection). Returns the lifted
/// buffer; its dimensions are those of [maskBounds].
Uint32List liftMaskedPixels(Uint32List buf, int w, int h, Uint8List mask,
    (int, int, int, int) bounds) {
  final (left, top, right, bottom) = bounds;
  final lw = right - left + 1, lh = bottom - top + 1;
  final out = Uint32List(lw * lh);
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      final i = y * w + x;
      if (mask[i] != 0) {
        out[(y - top) * lw + (x - left)] = buf[i];
        buf[i] = 0;
      }
    }
  }
  return out;
}

/// Stamps [src] (dimensions [sw] x [sh]) onto [buf] at (dx, dy), skipping
/// fully transparent source pixels so lifted content keeps its silhouette.
void blit(Uint32List buf, int w, int h, Uint32List src, int sw, int sh,
    int dx, int dy) {
  for (var y = 0; y < sh; y++) {
    final ty = dy + y;
    if (ty < 0 || ty >= h) continue;
    for (var x = 0; x < sw; x++) {
      final tx = dx + x;
      if (tx < 0 || tx >= w) continue;
      final p = src[y * sw + x];
      if ((p >>> 24) != 0) buf[ty * w + tx] = p;
    }
  }
}

/// Nearest-neighbor scale, the only resampling appropriate for pixel art.
Uint32List scaleNearest(
    Uint32List src, int sw, int sh, int dw, int dh) {
  final out = Uint32List(dw * dh);
  for (var y = 0; y < dh; y++) {
    final sy = (y * sh) ~/ dh;
    for (var x = 0; x < dw; x++) {
      out[y * dw + x] = src[sy * sw + (x * sw) ~/ dw];
    }
  }
  return out;
}

/// Rotates a buffer 90 degrees; returns the new buffer whose dimensions are
/// the source's swapped.
Uint32List rotate90(Uint32List src, int sw, int sh, {required bool clockwise}) {
  final out = Uint32List(sw * sh);
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final p = src[y * sw + x];
      if (clockwise) {
        out[x * sh + (sh - 1 - y)] = p;
      } else {
        out[(sw - 1 - x) * sh + y] = p;
      }
    }
  }
  return out;
}

void flipHorizontal(Uint32List buf, int w, int h) {
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w ~/ 2; x++) {
      final a = y * w + x, b = y * w + (w - 1 - x);
      final t = buf[a];
      buf[a] = buf[b];
      buf[b] = t;
    }
  }
}

void flipVertical(Uint32List buf, int w, int h) {
  for (var y = 0; y < h ~/ 2; y++) {
    for (var x = 0; x < w; x++) {
      final a = y * w + x, b = (h - 1 - y) * w + x;
      final t = buf[a];
      buf[a] = buf[b];
      buf[b] = t;
    }
  }
}

/// Copies [src] into a canvas of the new size. Anchor components are -1
/// (align start), 0 (center), or 1 (align end) and pick which existing
/// content edge stays put when growing or cropping.
Uint32List resizeCanvas(Uint32List src, int sw, int sh, int dw, int dh,
    {int anchorX = -1, int anchorY = -1}) {
  int offset(int s, int d, int anchor) => switch (anchor) {
        -1 => 0,
        0 => (d - s) ~/ 2,
        _ => d - s,
      };
  final out = Uint32List(dw * dh);
  final ox = offset(sw, dw, anchorX), oy = offset(sh, dh, anchorY);
  for (var y = 0; y < sh; y++) {
    final ty = y + oy;
    if (ty < 0 || ty >= dh) continue;
    for (var x = 0; x < sw; x++) {
      final tx = x + ox;
      if (tx < 0 || tx >= dw) continue;
      out[ty * dw + tx] = src[y * sw + x];
    }
  }
  return out;
}

/// Crops [src] to the inclusive box, returning the new buffer.
Uint32List cropCanvas(Uint32List src, int sw, int sh,
    (int, int, int, int) bounds) {
  final (left, top, right, bottom) = bounds;
  final dw = right - left + 1, dh = bottom - top + 1;
  final out = Uint32List(dw * dh);
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      out[y * dw + x] = src[(top + y) * sw + (left + x)];
    }
  }
  return out;
}
