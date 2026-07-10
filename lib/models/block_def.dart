import 'geometry.dart';
import 'port.dart';

/// The kind of asset a block represents. All categories share the same
/// masking + ports authoring flow and pack into one sprite sheet / bundle.
enum BlockCategory {
  track('TRACK'),
  islandTile('ISLAND_TILE'),
  decoration('DECORATION'),
  wall('WALL'),
  checkLine('CHECK_LINE');

  const BlockCategory(this.jsonValue);
  final String jsonValue;

  static BlockCategory fromJson(String? value) => BlockCategory.values
      .firstWhere((c) => c.jsonValue == value, orElse: () => track);
}

/// Distinguishes island corner tiles that share the same port count but
/// differ visually: a convex (outer) corner vs a concave (inner) corner.
enum CornerType {
  none('NONE'),
  convex('CONVEX'),
  concave('CONCAVE');

  const CornerType(this.jsonValue);
  final String jsonValue;

  static CornerType fromJson(String? value) => CornerType.values
      .firstWhere((c) => c.jsonValue == value, orElse: () => none);
}

/// Size of a block in grid cells. Irregular pieces are treated as a
/// hollow rectangle covering their full extent.
class BoundingBox {
  const BoundingBox({required this.width, required this.height});

  final int width;
  final int height;

  factory BoundingBox.fromJson(Map<String, dynamic> json) => BoundingBox(
        width: json['width'] as int,
        height: json['height'] as int,
      );

  Map<String, dynamic> toJson() => {'width': width, 'height': height};
}

/// Pixel rectangle locating the block's art inside the packed SpriteSheet.png.
class SpriteSheetRect {
  const SpriteSheetRect({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final int x;
  final int y;
  final int w;
  final int h;

  factory SpriteSheetRect.fromJson(Map<String, dynamic> json) =>
      SpriteSheetRect(
        x: json['x'] as int,
        y: json['y'] as int,
        w: json['w'] as int,
        h: json['h'] as int,
      );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}

/// Kinds of decoration the level editor can apply automatically
/// when neighboring blocks meet certain rules.
enum DecalType {
  kerbGradient('KERB_GRADIENT'),
  kerbSolid('KERB_SOLID');

  const DecalType(this.jsonValue);
  final String jsonValue;

  static DecalType fromJson(String value) =>
      DecalType.values.firstWhere((d) => d.jsonValue == value);
}

/// An automatic decoration slot, positioned in grid cells relative to the
/// block origin. Example: red-white kerbs rendered where a straight block
/// meets a corner block.
class AutoDecal {
  const AutoDecal({
    required this.localGridX,
    required this.localGridY,
    required this.type,
  });

  final int localGridX;
  final int localGridY;
  final DecalType type;

  factory AutoDecal.fromJson(Map<String, dynamic> json) => AutoDecal(
        localGridX: json['localGridX'] as int,
        localGridY: json['localGridY'] as int,
        type: DecalType.fromJson(json['type'] as String),
      );

  Map<String, dynamic> toJson() => {
        'localGridX': localGridX,
        'localGridY': localGridY,
        'type': type.jsonValue,
      };
}

/// The smart prefab definition: one entry in the sprite dictionary.
///
/// Visuals (spriteSheetRect) and physics (track area, walls, check lines)
/// are both defined here in local coordinates. The map scene only stores
/// block IDs and positions, so this class is the single source of truth
/// for what a block IS.
class BlockDef {
  const BlockDef({
    required this.id,
    required this.boundingBox,
    required this.spriteSheetRect,
    this.category = BlockCategory.track,
    this.cornerType = CornerType.none,
    this.ports = const [],
    this.autoDecals = const [],
    this.physicsTrackArea = const [],
    this.physicsHardWalls = const [],
    this.checkLines = const [],
  });

  /// Human-readable unique key, e.g. "fork_1_to_2", "corner_top_left".
  final String id;

  final BoundingBox boundingBox;
  final SpriteSheetRect spriteSheetRect;

  /// Which asset family this block belongs to.
  final BlockCategory category;

  /// For island corner tiles, whether it is a convex or concave corner.
  final CornerType cornerType;

  final List<Port> ports;
  final List<AutoDecal> autoDecals;

  /// Local vertices of the asphalt polygon. Inside means normal friction,
  /// outside means sand or grass friction.
  final List<Vec2> physicsTrackArea;

  /// Polylines for solid collision walls (inner and outer barriers).
  final List<List<Vec2>> physicsHardWalls;

  /// Gates crossed in order for lap counting and anti-cheat validation.
  final List<LineSegment> checkLines;

  factory BlockDef.fromJson(Map<String, dynamic> json) => BlockDef(
        id: json['id'] as String,
        boundingBox:
            BoundingBox.fromJson(json['boundingBox'] as Map<String, dynamic>),
        spriteSheetRect: SpriteSheetRect.fromJson(
            json['spriteSheetRect'] as Map<String, dynamic>),
        category: BlockCategory.fromJson(json['category'] as String?),
        cornerType: CornerType.fromJson(json['cornerType'] as String?),
        ports: (json['ports'] as List<dynamic>? ?? [])
            .map((p) => Port.fromJson(p as Map<String, dynamic>))
            .toList(),
        autoDecals: (json['autoDecals'] as List<dynamic>? ?? [])
            .map((d) => AutoDecal.fromJson(d as Map<String, dynamic>))
            .toList(),
        physicsTrackArea: (json['physicsTrackArea'] as List<dynamic>? ?? [])
            .map((v) => Vec2.fromJson(v as List<dynamic>))
            .toList(),
        physicsHardWalls: (json['physicsHardWalls'] as List<dynamic>? ?? [])
            .map((wall) => (wall as List<dynamic>)
                .map((v) => Vec2.fromJson(v as List<dynamic>))
                .toList())
            .toList(),
        checkLines: (json['checkLines'] as List<dynamic>? ?? [])
            .map((l) => LineSegment.fromJson(l as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'boundingBox': boundingBox.toJson(),
        'spriteSheetRect': spriteSheetRect.toJson(),
        'category': category.jsonValue,
        'cornerType': cornerType.jsonValue,
        'ports': ports.map((p) => p.toJson()).toList(),
        'autoDecals': autoDecals.map((d) => d.toJson()).toList(),
        'physicsTrackArea':
            physicsTrackArea.map((v) => v.toJson()).toList(),
        'physicsHardWalls': physicsHardWalls
            .map((wall) => wall.map((v) => v.toJson()).toList())
            .toList(),
        'checkLines': checkLines.map((l) => l.toJson()).toList(),
      };

  BlockDef copyWith({
    String? id,
    BoundingBox? boundingBox,
    SpriteSheetRect? spriteSheetRect,
    BlockCategory? category,
    CornerType? cornerType,
    List<Port>? ports,
    List<AutoDecal>? autoDecals,
    List<Vec2>? physicsTrackArea,
    List<List<Vec2>>? physicsHardWalls,
    List<LineSegment>? checkLines,
  }) =>
      BlockDef(
        id: id ?? this.id,
        boundingBox: boundingBox ?? this.boundingBox,
        spriteSheetRect: spriteSheetRect ?? this.spriteSheetRect,
        category: category ?? this.category,
        cornerType: cornerType ?? this.cornerType,
        ports: ports ?? this.ports,
        autoDecals: autoDecals ?? this.autoDecals,
        physicsTrackArea: physicsTrackArea ?? this.physicsTrackArea,
        physicsHardWalls: physicsHardWalls ?? this.physicsHardWalls,
        checkLines: checkLines ?? this.checkLines,
      );
}
