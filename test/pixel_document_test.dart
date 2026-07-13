import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/logic/pal_file.dart';
import 'package:race_gametool/models/pixel_document.dart';

/// Pixel document compositing plus the .rgpix and .pal file formats.
void main() {
  group('PixelDocument.composite', () {
    test('skips invisible layers and applies layer opacity', () {
      final doc = PixelDocument(
        width: 2,
        height: 1,
        layers: [
          PixelLayer(
            name: 'bottom',
            pixels: Uint32List.fromList([0xffff0000, 0xffff0000]),
          ),
          PixelLayer(
            name: 'hidden',
            visible: false,
            pixels: Uint32List.fromList([0xff00ff00, 0xff00ff00]),
          ),
          PixelLayer(
            name: 'top-half',
            opacity: 0.5,
            pixels: Uint32List.fromList([0xff0000ff, 0x00000000]),
          ),
        ],
      );
      final out = doc.composite();
      // Fully covered by an opaque bottom, blended 50/50 with the top.
      expect((out[0] >>> 24) & 0xff, 0xff);
      expect((out[0] >>> 16) & 0xff, closeTo(127, 1));
      expect(out[0] & 0xff, closeTo(128, 1));
      expect(out[1], 0xffff0000, reason: 'transparent top leaves bottom');
    });

    test('opaque source over empty destination copies straight through', () {
      final doc = PixelDocument.blank(1, 1);
      doc.layers[0].pixels[0] = 0xff123456;
      expect(doc.composite().toList(), [0xff123456]);
    });
  });

  group('rgpix format', () {
    test('encode/decode round-trips document, palette, and settings', () {
      final doc = PixelDocument.blank(3, 2);
      doc.layers[0].pixels.setAll(0, [1, 2, 3, 0xff804020, 5, 6]);
      final file = RgpixFile(
        document: doc,
        palette: const [0xff112233, 0x80ffffff],
        showPixelGrid: false,
        showCellGrid: true,
        symmetry: 'xy',
      );

      final decoded = RgpixFile.decode(file.encode());
      expect(decoded.document.width, 3);
      expect(decoded.document.height, 2);
      expect(decoded.document.layers.single.pixels.toList(),
          doc.layers.single.pixels.toList());
      expect(decoded.palette, const [0xff112233, 0x80ffffff]);
      expect(decoded.showPixelGrid, isFalse);
      expect(decoded.showCellGrid, isTrue);
      expect(decoded.symmetry, 'xy');
    });

    test('multi-layer documents survive the round-trip', () {
      final doc = PixelDocument(
        width: 1,
        height: 1,
        layers: [
          PixelLayer(
            name: 'a',
            pixels: Uint32List.fromList([0xff000001]),
          ),
          PixelLayer(
            name: 'b',
            visible: false,
            opacity: 0.25,
            pixels: Uint32List.fromList([0xff000002]),
          ),
        ],
      );
      final decoded = RgpixFile.decode(RgpixFile(document: doc).encode());
      expect(decoded.document.layers.length, 2);
      expect(decoded.document.layers[1].name, 'b');
      expect(decoded.document.layers[1].visible, isFalse);
      expect(decoded.document.layers[1].opacity, 0.25);
    });

    test('rejects foreign or corrupt payloads', () {
      expect(() => RgpixFile.decode('{"format":"other"}'),
          throwsFormatException);
      expect(() => RgpixFile.decode('not json at all'),
          throwsFormatException);

      final doc = PixelDocument.blank(2, 2);
      final tampered = RgpixFile(document: doc)
          .encode()
          .replaceFirst('"width": 2', '"width": 3');
      expect(() => RgpixFile.decode(tampered), throwsFormatException,
          reason: 'layer pixel count no longer matches the dimensions');
    });
  });

  group('JASC-PAL format', () {
    test('encode/decode round-trips opaque colors', () {
      const palette = [0xffff0000, 0xff00ff00, 0xff123456];
      expect(decodeJascPal(encodeJascPal(palette)), palette);
    });

    test('parses files with plain LF endings too', () {
      expect(decodeJascPal('JASC-PAL\n0100\n1\n0 128 255\n'),
          [0xff0080ff]);
    });

    test('rejects wrong headers and short files', () {
      expect(() => decodeJascPal('RIFF-PAL\n0100\n0\n'),
          throwsFormatException);
      expect(() => decodeJascPal('JASC-PAL\n0100\n2\n1 2 3\n'),
          throwsFormatException);
    });
  });
}
