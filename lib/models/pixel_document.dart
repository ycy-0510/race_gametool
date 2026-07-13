import 'dart:convert';
import 'dart:typed_data';

/// One raster layer of a pixel document. Pixels are ARGB ints (the Flutter
/// Color convention) in row-major order, length `width * height` of the
/// owning document.
class PixelLayer {
  PixelLayer({
    required this.name,
    required this.pixels,
    this.visible = true,
    this.opacity = 1.0,
  });

  factory PixelLayer.blank(String name, int width, int height) =>
      PixelLayer(name: name, pixels: Uint32List(width * height));

  final String name;
  final bool visible;

  /// 0..1 multiplier applied on top of per-pixel alpha when compositing.
  final double opacity;

  final Uint32List pixels;

  PixelLayer copyWith({
    String? name,
    bool? visible,
    double? opacity,
    Uint32List? pixels,
  }) =>
      PixelLayer(
        name: name ?? this.name,
        visible: visible ?? this.visible,
        opacity: opacity ?? this.opacity,
        pixels: pixels ?? this.pixels,
      );

  /// Deep copy, for undo snapshots.
  PixelLayer clone() => copyWith(pixels: Uint32List.fromList(pixels));
}

/// An editable pixel image: fixed dimensions plus a bottom-to-top stack of
/// layers. The current editor UI only exposes a single layer, but the model
/// and the .rgpix format carry the full stack so files stay forward
/// compatible when layer editing lands.
class PixelDocument {
  PixelDocument({
    required this.width,
    required this.height,
    required this.layers,
  }) : assert(layers.isNotEmpty);

  factory PixelDocument.blank(int width, int height) => PixelDocument(
        width: width,
        height: height,
        layers: [PixelLayer.blank('Layer 1', width, height)],
      );

  final int width;
  final int height;

  /// Bottom-to-top draw order.
  final List<PixelLayer> layers;

  PixelDocument copyWith({int? width, int? height, List<PixelLayer>? layers}) =>
      PixelDocument(
        width: width ?? this.width,
        height: height ?? this.height,
        layers: layers ?? this.layers,
      );

  PixelDocument clone() => PixelDocument(
        width: width,
        height: height,
        layers: [for (final l in layers) l.clone()],
      );

  /// Flattens visible layers bottom-to-top with source-over blending into a
  /// single ARGB buffer.
  Uint32List composite() {
    final out = Uint32List(width * height);
    for (final layer in layers) {
      if (!layer.visible || layer.opacity <= 0) continue;
      final opacity = layer.opacity.clamp(0.0, 1.0);
      final src = layer.pixels;
      for (var i = 0; i < out.length; i++) {
        final s = src[i];
        var sa = (s >>> 24) & 0xff;
        if (sa == 0) continue;
        sa = (sa * opacity).round();
        if (sa == 0) continue;
        final d = out[i];
        final da = (d >>> 24) & 0xff;
        if (sa == 255 || da == 0) {
          out[i] = (sa << 24) | (s & 0x00ffffff);
          continue;
        }
        final outA = sa + da * (255 - sa) ~/ 255;
        int blend(int sc, int dc) =>
            ((sc * sa + dc * da * (255 - sa) ~/ 255) / outA).round().clamp(0, 255);
        final r = blend((s >>> 16) & 0xff, (d >>> 16) & 0xff);
        final g = blend((s >>> 8) & 0xff, (d >>> 8) & 0xff);
        final b = blend(s & 0xff, d & 0xff);
        out[i] = (outA << 24) | (r << 16) | (g << 8) | b;
      }
    }
    return out;
  }
}

/// The saved form of a pixel editor session: the document plus the editing
/// context worth restoring (palette, grid toggles, symmetry). Serialized as
/// JSON in a `.rgpix` file.
class RgpixFile {
  const RgpixFile({
    required this.document,
    this.palette = const [],
    this.showPixelGrid = true,
    this.showCellGrid = true,
    this.symmetry = 'none',
  });

  final PixelDocument document;

  /// ARGB ints.
  final List<int> palette;

  final bool showPixelGrid;
  final bool showCellGrid;
  final String symmetry;

  static const formatName = 'rgpix';
  static const formatVersion = 1;

  String encode() {
    return const JsonEncoder.withIndent('  ').convert({
      'format': formatName,
      'version': formatVersion,
      'width': document.width,
      'height': document.height,
      'layers': [
        for (final layer in document.layers)
          {
            'name': layer.name,
            'visible': layer.visible,
            'opacity': layer.opacity,
            'pixels': base64Encode(pixelsToRgbaBytes(layer.pixels)),
          },
      ],
      'palette': [for (final c in palette) _argbToHex(c)],
      'settings': {
        'showPixelGrid': showPixelGrid,
        'showCellGrid': showCellGrid,
        'symmetry': symmetry,
      },
    });
  }

  /// Throws [FormatException] on anything that is not a valid rgpix payload.
  static RgpixFile decode(String source) {
    final root = jsonDecode(source);
    if (root is! Map<String, dynamic> || root['format'] != formatName) {
      throw const FormatException('not an rgpix file');
    }
    final version = root['version'];
    if (version is! int || version < 1 || version > formatVersion) {
      throw FormatException('unsupported rgpix version: $version');
    }
    final width = root['width'];
    final height = root['height'];
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      throw const FormatException('invalid rgpix dimensions');
    }

    final layersJson = root['layers'];
    if (layersJson is! List || layersJson.isEmpty) {
      throw const FormatException('rgpix file has no layers');
    }
    final layers = <PixelLayer>[];
    for (final entry in layersJson) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('invalid rgpix layer');
      }
      final pixels =
          rgbaBytesToPixels(base64Decode(entry['pixels'] as String));
      if (pixels.length != width * height) {
        throw const FormatException('rgpix layer size mismatch');
      }
      layers.add(PixelLayer(
        name: entry['name'] as String? ?? 'Layer',
        visible: entry['visible'] as bool? ?? true,
        opacity: (entry['opacity'] as num?)?.toDouble() ?? 1.0,
        pixels: pixels,
      ));
    }

    final paletteJson = root['palette'];
    final palette = <int>[
      if (paletteJson is List)
        for (final entry in paletteJson)
          if (entry is String) _hexToArgb(entry),
    ];

    final settings = root['settings'];
    final settingsMap =
        settings is Map<String, dynamic> ? settings : const <String, dynamic>{};

    return RgpixFile(
      document:
          PixelDocument(width: width, height: height, layers: layers),
      palette: palette,
      showPixelGrid: settingsMap['showPixelGrid'] as bool? ?? true,
      showCellGrid: settingsMap['showCellGrid'] as bool? ?? true,
      symmetry: settingsMap['symmetry'] as String? ?? 'none',
    );
  }
}

/// Serialized pixel byte order is RGBA per pixel, independent of host
/// endianness, so files are portable.
Uint8List pixelsToRgbaBytes(Uint32List pixels) {
  final bytes = Uint8List(pixels.length * 4);
  for (var i = 0; i < pixels.length; i++) {
    final p = pixels[i];
    bytes[i * 4] = (p >>> 16) & 0xff;
    bytes[i * 4 + 1] = (p >>> 8) & 0xff;
    bytes[i * 4 + 2] = p & 0xff;
    bytes[i * 4 + 3] = (p >>> 24) & 0xff;
  }
  return bytes;
}

Uint32List rgbaBytesToPixels(Uint8List bytes) {
  if (bytes.length % 4 != 0) {
    throw const FormatException('rgpix pixel data is not RGBA');
  }
  final pixels = Uint32List(bytes.length ~/ 4);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = (bytes[i * 4 + 3] << 24) |
        (bytes[i * 4] << 16) |
        (bytes[i * 4 + 1] << 8) |
        bytes[i * 4 + 2];
  }
  return pixels;
}

String _argbToHex(int argb) =>
    '#${(argb & 0xffffffff).toRadixString(16).padLeft(8, '0')}';

int _hexToArgb(String hex) {
  var s = hex.startsWith('#') ? hex.substring(1) : hex;
  if (s.length == 6) s = 'ff$s';
  final value = int.tryParse(s, radix: 16);
  if (value == null || s.length != 8) {
    throw FormatException('invalid palette color: $hex');
  }
  return value;
}
