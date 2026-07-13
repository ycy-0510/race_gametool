import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/logic/pixel_ops.dart';

/// Pure buffer operations behind the pixel editor tools. Buffers are tiny so
/// expected images can be written out literally.
void main() {
  const t = 0x00000000; // transparent
  const r = 0xffff0000;
  const g = 0xff00ff00;
  const b = 0xff0000ff;

  Uint32List buf(int w, int h) => Uint32List(w * h);

  List<int> row(Uint32List pixels, int w, int y) =>
      [for (var x = 0; x < w; x++) pixels[y * w + x]];

  group('stampBrush', () {
    test('size 1 paints exactly the anchor pixel', () {
      final p = buf(3, 3);
      stampBrush(p, 3, 3, 1, 1, r);
      expect(p.where((c) => c == r).length, 1);
      expect(p[4], r);
    });

    test('size 2 extends toward bottom-right and clips at edges', () {
      final p = buf(3, 3);
      stampBrush(p, 3, 3, 2, 2, r, brushSize: 2);
      // Anchor (2,2) plus (3,2), (2,3), (3,3) which are clipped.
      expect(p.where((c) => c == r).length, 1);
      expect(p[8], r);
    });

    test('size 3 centers on the anchor', () {
      final p = buf(5, 5);
      stampBrush(p, 5, 5, 2, 2, r, brushSize: 3);
      expect(p.where((c) => c == r).length, 9);
      expect(p[1 * 5 + 1], r);
      expect(p[3 * 5 + 3], r);
      expect(p[0], t);
    });
  });

  group('drawLine', () {
    test('horizontal and diagonal lines hit every step', () {
      final p = buf(4, 4);
      drawLine(p, 4, 4, 0, 0, 3, 0, r);
      expect(row(p, 4, 0), [r, r, r, r]);

      final q = buf(4, 4);
      drawLine(q, 4, 4, 0, 0, 3, 3, g);
      for (var i = 0; i < 4; i++) {
        expect(q[i * 4 + i], g);
      }
      expect(q.where((c) => c == g).length, 4);
    });
  });

  group('drawRectShape', () {
    test('outline leaves the interior untouched', () {
      final p = buf(4, 4);
      drawRectShape(p, 4, 4, 0, 0, 3, 3, r);
      expect(p[1 * 4 + 1], t);
      expect(p[1 * 4 + 2], t);
      expect(p.where((c) => c == r).length, 12);
    });

    test('filled covers the whole box regardless of corner order', () {
      final p = buf(4, 4);
      drawRectShape(p, 4, 4, 2, 3, 1, 1, r, filled: true);
      expect(p.where((c) => c == r).length, 6);
      expect(p[1 * 4 + 1], r);
      expect(p[3 * 4 + 2], r);
    });
  });

  group('drawEllipseShape', () {
    test('degenerate 1x1 box plots a single pixel', () {
      final p = buf(3, 3);
      drawEllipseShape(p, 3, 3, 1, 1, 1, 1, r, filled: true);
      expect(p.where((c) => c == r).length, 1);
      expect(p[4], r);
    });

    test('filled circle is symmetric and covers the mid row fully', () {
      const w = 7, h = 7;
      final p = buf(w, h);
      drawEllipseShape(p, w, h, 0, 0, 6, 6, r, filled: true);
      // Horizontal and vertical symmetry.
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          expect(p[y * w + x], p[y * w + (w - 1 - x)],
              reason: 'x-symmetry at ($x,$y)');
          expect(p[y * w + x], p[(h - 1 - y) * w + x],
              reason: 'y-symmetry at ($x,$y)');
        }
      }
      expect(row(p, w, 3), List.filled(7, r));
      // Corners stay empty.
      expect(p[0], t);
      expect(p[6], t);
    });

    test('outline matches the filled silhouette boundary', () {
      const w = 8, h = 6;
      final filled = buf(w, h);
      drawEllipseShape(filled, w, h, 0, 0, 7, 5, r, filled: true);
      final outline = buf(w, h);
      drawEllipseShape(outline, w, h, 0, 0, 7, 5, r);
      // Every outline pixel is on the filled shape, and every filled pixel
      // with a transparent 4-neighbour (or on the box edge) is outlined.
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = y * w + x;
          if (outline[i] == r) expect(filled[i], r);
          if (filled[i] != r) continue;
          final boundary = x == 0 ||
              y == 0 ||
              x == w - 1 ||
              y == h - 1 ||
              filled[i - 1] == t ||
              filled[i + 1] == t ||
              filled[i - w] == t ||
              filled[i + w] == t;
          if (boundary) {
            expect(outline[i], r, reason: 'missing outline at ($x,$y)');
          }
        }
      }
    });
  });

  group('floodFill', () {
    test('contiguous fill stops at a color boundary', () {
      final p = buf(4, 4);
      drawLine(p, 4, 4, 2, 0, 2, 3, r); // vertical wall at x=2
      floodFill(p, 4, 4, 0, 0, g);
      expect(p[0], g);
      expect(p[1], g);
      expect(p[2], r);
      expect(p[3], t, reason: 'right of the wall is unreachable');
    });

    test('tolerance treats near colors as the same region', () {
      final p = buf(2, 1);
      p[0] = 0xff646464;
      p[1] = 0xff6a6a6a; // 6 away per channel
      floodFill(p, 2, 1, 0, 0, r, tolerance: 8);
      expect(p[0], r);
      expect(p[1], r);
    });

    test('non-contiguous mode recolors matching pixels everywhere', () {
      final p = buf(3, 1);
      p[0] = r;
      p[1] = g;
      p[2] = r;
      floodFill(p, 3, 1, 0, 0, b, contiguous: false);
      expect(p.toList(), [b, g, b]);
    });

    test('writes stay inside the selection mask but flood crosses it', () {
      final p = buf(4, 1);
      final mask = Uint8List.fromList([1, 0, 0, 1]);
      floodFill(p, 4, 1, 0, 0, r, mask: mask);
      expect(p.toList(), [r, t, t, r],
          reason: 'region is all-transparent so it spans the row; only '
              'masked pixels get written');
    });
  });

  group('magicWandMask', () {
    test('contiguous selects the connected same-color region only', () {
      final p = buf(3, 1);
      p[0] = r;
      p[1] = g;
      p[2] = r;
      final mask = magicWandMask(p, 3, 1, 0, 0);
      expect(mask.toList(), [1, 0, 0]);
    });

    test('global selects every matching pixel', () {
      final p = buf(3, 1);
      p[0] = r;
      p[1] = g;
      p[2] = r;
      final mask = magicWandMask(p, 3, 1, 0, 0, contiguous: false);
      expect(mask.toList(), [1, 0, 1]);
    });
  });

  group('selection masks', () {
    test('rectMask covers the inclusive box with any corner order', () {
      final mask = rectMask(4, 3, 2, 2, 1, 0);
      expect(mask.toList(), [
        0, 1, 1, 0, //
        0, 1, 1, 0, //
        0, 1, 1, 0, //
      ]);
    });

    test('polygonMask fills a triangle sampled at pixel centers', () {
      // Hypotenuse x + y = 4; the center (x+0.5, y+0.5) is inside only when
      // x + y < 3, so the diagonal row of half-covered pixels stays out.
      final mask = polygonMask(4, 4, [(0, 0), (4, 0), (0, 4)]);
      expect(mask.toList(), [
        1, 1, 1, 0, //
        1, 1, 0, 0, //
        1, 0, 0, 0, //
        0, 0, 0, 0, //
      ]);
    });

    test('maskBounds finds the tight box; null when empty', () {
      final mask = Uint8List(4 * 3);
      expect(maskBounds(mask, 4, 3), isNull);
      mask[1 * 4 + 2] = 1;
      mask[2 * 4 + 1] = 1;
      expect(maskBounds(mask, 4, 3), (1, 1, 2, 2));
    });
  });

  group('lift and blit', () {
    test('lift clears the source and blit restores it', () {
      final p = buf(3, 3);
      p[4] = r;
      p[5] = g;
      final mask = Uint8List(9);
      mask[4] = 1;
      mask[5] = 1;
      final bounds = maskBounds(mask, 3, 3)!;
      final lifted = liftMaskedPixels(p, 3, 3, mask, bounds);
      expect(p[4], t);
      expect(p[5], t);
      expect(lifted.toList(), [r, g]);

      blit(p, 3, 3, lifted, 2, 1, 1, 1);
      expect(p[4], r);
      expect(p[5], g);
    });

    test('blit skips transparent source pixels and clips at edges', () {
      final p = buf(2, 1);
      p[0] = r;
      final src = Uint32List.fromList([t, g, b]);
      blit(p, 2, 1, src, 3, 1, 0, 0);
      expect(p.toList(), [r, g], reason: 'transparent kept r; b clipped');
    });
  });

  group('whole-buffer transforms', () {
    test('scaleNearest doubles pixels crisply', () {
      final p = Uint32List.fromList([r, g, b, t]);
      final scaled = scaleNearest(p, 2, 2, 4, 4);
      expect(row(scaled, 4, 0), [r, r, g, g]);
      expect(row(scaled, 4, 3), [b, b, t, t]);
    });

    test('rotate90 clockwise and counter-clockwise are inverses', () {
      final p = Uint32List.fromList([r, g, b, t, r, g]); // 3x2
      final cw = rotate90(p, 3, 2, clockwise: true); // 2x3
      expect(cw.toList(), [t, r, r, g, g, b]);
      final back = rotate90(cw, 2, 3, clockwise: false);
      expect(back.toList(), p.toList());
    });

    test('flips mirror in place', () {
      final p = Uint32List.fromList([r, g, b, t, r, g]); // 3x2
      flipHorizontal(p, 3, 2);
      expect(p.toList(), [b, g, r, g, r, t]);
      flipVertical(p, 3, 2);
      expect(p.toList(), [g, r, t, b, g, r]);
    });

    test('resizeCanvas honors the anchor when growing and cropping', () {
      final p = Uint32List.fromList([r, g, b, t]); // 2x2
      final grown = resizeCanvas(p, 2, 2, 4, 4, anchorX: 1, anchorY: 1);
      expect(grown[2 * 4 + 2], r);
      expect(grown[3 * 4 + 3], t);
      expect(grown[0], 0);

      final cropped = resizeCanvas(p, 2, 2, 1, 1, anchorX: 0, anchorY: 0);
      expect(cropped.toList(), [r], reason: 'center crop keeps top-left of 2x2');
    });

    test('cropCanvas extracts the inclusive box', () {
      final p = Uint32List.fromList([r, g, b, t, r, g, b, t, r]); // 3x3
      final cropped = cropCanvas(p, 3, 3, (1, 1, 2, 2));
      expect(cropped.toList(), [r, g, t, r]);
    });
  });

  group('symmetry and tolerance helpers', () {
    test('symmetryPoints mirrors around the pixel-exact center', () {
      expect(symmetryPoints(1, 0, 4, 3, SymmetryMode.horizontal),
          [(1, 0), (2, 0)]);
      expect(symmetryPoints(0, 0, 3, 3, SymmetryMode.both),
          [(0, 0), (2, 0), (0, 2), (2, 2)]);
      expect(symmetryPoints(1, 1, 3, 3, SymmetryMode.both),
          everyElement((1, 1)));
    });

    test('colorWithinTolerance compares all channels including alpha', () {
      expect(colorWithinTolerance(0xff000000, 0xfe000000, 0), isFalse);
      expect(colorWithinTolerance(0xff000000, 0xfe000000, 1), isTrue);
      expect(colorWithinTolerance(0xff102030, 0xff102040, 15), isFalse);
      expect(colorWithinTolerance(0xff102030, 0xff102040, 16), isTrue);
    });
  });
}
