/// JASC-PAL palette file support (the common `.pal` text format):
///
///   JASC-PAL
///   0100
///   `<count>`
///   `<r> <g> <b>`   (one line per color)
///
/// Colors are ARGB ints with full alpha; the format itself has no alpha.
library;

String encodeJascPal(List<int> palette) {
  final buffer = StringBuffer('JASC-PAL\r\n0100\r\n${palette.length}\r\n');
  for (final color in palette) {
    final r = (color >>> 16) & 0xff;
    final g = (color >>> 8) & 0xff;
    final b = color & 0xff;
    buffer.write('$r $g $b\r\n');
  }
  return buffer.toString();
}

/// Throws [FormatException] when the payload is not a JASC-PAL file.
List<int> decodeJascPal(String source) {
  final lines = source
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length < 3 || lines[0] != 'JASC-PAL') {
    throw const FormatException('not a JASC-PAL file');
  }
  final count = int.tryParse(lines[2]);
  if (count == null || count < 0) {
    throw const FormatException('invalid JASC-PAL color count');
  }
  final colors = <int>[];
  for (var i = 3; i < lines.length && colors.length < count; i++) {
    final parts = lines[i].split(RegExp(r'\s+'));
    if (parts.length < 3) {
      throw FormatException('invalid JASC-PAL color line: ${lines[i]}');
    }
    final channels = parts.take(3).map(int.tryParse).toList();
    if (channels.any((c) => c == null || c < 0 || c > 255)) {
      throw FormatException('invalid JASC-PAL color line: ${lines[i]}');
    }
    colors.add(0xff000000 |
        (channels[0]! << 16) |
        (channels[1]! << 8) |
        channels[2]!);
  }
  if (colors.length != count) {
    throw const FormatException('JASC-PAL color count mismatch');
  }
  return colors;
}
