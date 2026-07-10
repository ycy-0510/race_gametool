import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../core/constants.dart';
import '../models/block_def.dart';
import '../models/mask_draft.dart';
import 'sprite_exporter.dart';

/// Internal file names inside a .rgpack asset bundle.
class BundleEntries {
  BundleEntries._();
  static const manifest = 'manifest.json';
  static const rawSource = 'raw_source.png';
  static const editor = 'editor.json';
  static const spriteSheet = 'SpriteSheet.png';
  static const spriteDict = 'sprite_dict.json';
}

/// Everything read back out of a .rgpack. Splits cleanly into the two
/// audiences: the editor half (rawImageBytes + masks, for re-editing in
/// Phase 1) and the consumer half (sheetBytes + blocks, for Phase 2 and
/// the game).
class AssetBundleData {
  const AssetBundleData({
    required this.rawImageBytes,
    required this.imageName,
    required this.masks,
    required this.sheetBytes,
    required this.spriteDictJson,
    required this.blocks,
    required this.cellSize,
    this.categoryRawImages = const {},
  });

  final Uint8List rawImageBytes;
  final String imageName;
  final List<MaskDraft> masks;
  final Uint8List sheetBytes;
  final String spriteDictJson;
  final List<BlockDef> blocks;
  final int cellSize;

  /// Per-category raw source images. Empty for legacy single-image bundles.
  final Map<BlockCategory, Uint8List> categoryRawImages;
}

/// The game-ready pair extracted from a bundle: the packed sheet PNG and
/// the sprite dictionary JSON. Used by the build-time extractor CLI and
/// by a Flame game reading the bundle directly at runtime.
class GameAssets {
  const GameAssets({required this.sheetBytes, required this.spriteDictJson});
  final Uint8List sheetBytes;
  final String spriteDictJson;
}

/// Builds a .rgpack bundle from the editor state. The packed sprite sheet
/// and sprite dictionary are generated here from the raw image and masks,
/// so the bundle stays the single source of truth: editor data and the
/// derived game assets are always written together and can never drift.
///
/// [categoryImages] maps each BlockCategory to its raw source image bytes.
/// Each mask is cropped from the image belonging to its category.
Uint8List writeAssetBundle({
  required Map<BlockCategory, Uint8List> categoryImages,
  required String imageName,
  required List<MaskDraft> masks,
}) {
  final export = buildSpriteExportMultiSource(
    categoryImages: categoryImages,
    masks: masks,
  );

  final editorJson = const JsonEncoder.withIndent('  ').convert({
    'version': 2,
    'cellSize': GridConstants.cellSize.round(),
    'imageName': imageName,
    'masks': masks.map((m) => m.toJson()).toList(),
  });

  final manifestJson = const JsonEncoder.withIndent('  ').convert({
    'format': 'race_gametool.assets',
    'version': 2,
    'cellSize': GridConstants.cellSize.round(),
    'blockCount': export.blocks.length,
    'entries': {
      'rawSource': BundleEntries.rawSource,
      'editor': BundleEntries.editor,
      'spriteSheet': BundleEntries.spriteSheet,
      'spriteDict': BundleEntries.spriteDict,
    },
  });

  // Use the first available category image as the legacy raw_source.png
  // for backward compatibility.
  final fallbackBytes = categoryImages.values.first;

  final archive = Archive()
    ..addFile(_textFile(BundleEntries.manifest, manifestJson))
    ..addFile(_bytesFile(BundleEntries.rawSource, fallbackBytes))
    ..addFile(_textFile(BundleEntries.editor, editorJson))
    ..addFile(_bytesFile(BundleEntries.spriteSheet, export.pngBytes))
    ..addFile(_textFile(BundleEntries.spriteDict, export.jsonText));

  // Write each category's raw source image under its own filename.
  for (final entry in categoryImages.entries) {
    final catFile = 'raw_source_${entry.key.jsonValue.toLowerCase()}.png';
    archive.addFile(_bytesFile(catFile, entry.value));
  }

  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

/// Reads a full .rgpack for editing and importing.
AssetBundleData readAssetBundle(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);

  Uint8List requireBytes(String name) {
    final file = archive.findFile(name);
    if (file == null) {
      throw FormatException('Bundle is missing "$name"');
    }
    return file.readBytes() ?? Uint8List(0);
  }

  Uint8List? optionalBytes(String name) {
    final file = archive.findFile(name);
    return file?.readBytes();
  }

  String requireText(String name) => utf8.decode(requireBytes(name));

  final editor = jsonDecode(requireText(BundleEntries.editor))
      as Map<String, dynamic>;
  final dictJson = requireText(BundleEntries.spriteDict);
  final parsed = parseSpriteDict(dictJson);

  // Read per-category raw source images if available (v2 bundles).
  final categoryRawImages = <BlockCategory, Uint8List>{};
  for (final cat in BlockCategory.values) {
    final catFile = 'raw_source_${cat.jsonValue.toLowerCase()}.png';
    final bytes = optionalBytes(catFile);
    if (bytes != null) {
      categoryRawImages[cat] = bytes;
    }
  }

  return AssetBundleData(
    rawImageBytes: requireBytes(BundleEntries.rawSource),
    imageName: editor['imageName'] as String? ?? 'draft.png',
    masks: (editor['masks'] as List<dynamic>)
        .map((m) => MaskDraft.fromJson(m as Map<String, dynamic>))
        .toList(),
    sheetBytes: requireBytes(BundleEntries.spriteSheet),
    spriteDictJson: dictJson,
    blocks: parsed.blocks,
    cellSize: (editor['cellSize'] as num?)?.round() ??
        GridConstants.cellSize.round(),
    categoryRawImages: categoryRawImages,
  );
}

/// Pulls only the game-ready assets out of a bundle, without decoding the
/// editor state. Cheap enough to call at game load time.
GameAssets extractGameAssets(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final sheet = archive.findFile(BundleEntries.spriteSheet);
  final dict = archive.findFile(BundleEntries.spriteDict);
  if (sheet == null || dict == null) {
    throw const FormatException(
        'Bundle is missing the packed sheet or sprite dictionary');
  }
  return GameAssets(
    sheetBytes: sheet.readBytes() ?? Uint8List(0),
    spriteDictJson: utf8.decode(dict.readBytes() ?? Uint8List(0)),
  );
}

ArchiveFile _textFile(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

ArchiveFile _bytesFile(String name, Uint8List bytes) =>
    ArchiveFile(name, bytes.length, bytes);
