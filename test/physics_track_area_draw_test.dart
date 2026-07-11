import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/geometry.dart';
import 'package:race_gametool/state/asset_definer_providers.dart';

/// Exercises the redesigned Draw Physics Area interaction: mode-based drawing,
/// no auto-close, click-to-complete/undo, and the line/curve flow. These run
/// on the notifier directly; trackAreaTap works off the selected mask's
/// geometry, so no source image is needed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late AssetDefinerNotifier notifier;
  AssetDefinerState read() => container.read(assetDefinerProvider);
  List<Vec2> area() => read().selectedMask!.physicsTrackArea;

  // Seeds a single selected mask (a 1x1 island tile) and enters physics draw
  // mode with snapping off so click coordinates map straight through.
  void seedDrawingMask() {
    notifier.setActiveCategory(BlockCategory.islandTile);
    notifier.setTool(Phase1Tool.drawBox);
    notifier.tapCell(0, 0);
    notifier.setTool(Phase1Tool.drawPhysicsArea);
    notifier.setSnapToGrid(false);
  }

  // Two 1x1 masks: index 0 at cell (0,0) (pixels 0..16), index 1 at cell (2,0)
  // (pixels 32..48). Physics tool active, snapping off.
  void seedTwoMasks() {
    notifier.setActiveCategory(BlockCategory.islandTile);
    notifier.setTool(Phase1Tool.drawBox);
    notifier.tapCell(0, 0);
    notifier.tapCell(2, 0);
    notifier.setTool(Phase1Tool.drawPhysicsArea);
    notifier.setSnapToGrid(false);
  }

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(assetDefinerProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('selecting an empty-area block enters draw mode', () {
    seedDrawingMask();
    expect(read().physicsDrawing, isTrue);
  });

  test('line taps append points and never auto-close the polyline', () {
    seedDrawingMask();
    notifier.trackAreaTap(const ui.Offset(0, 0));
    notifier.trackAreaTap(const ui.Offset(16, 0));
    notifier.trackAreaTap(const ui.Offset(8, 16));

    expect(area(), [const Vec2(0, 0), const Vec2(16, 0), const Vec2(8, 16)]);
    // Still drawing the same block; nothing snapped back to the origin.
    expect(read().physicsDrawing, isTrue);
    expect(read().selectedIndex, isNotNull);
  });

  test('clicking the first point completes and returns to normal mode', () {
    seedDrawingMask();
    notifier.trackAreaTap(const ui.Offset(0, 0));
    notifier.trackAreaTap(const ui.Offset(16, 0));
    notifier.trackAreaTap(const ui.Offset(8, 16));

    // A click near the first vertex closes the shape.
    notifier.trackAreaTap(const ui.Offset(1, 1));

    expect(read().physicsDrawing, isFalse);
    expect(read().selectedIndex, isNull);
    // The finished area is kept on the mask.
    final masks = container.read(assetDefinerProvider).masks;
    expect(masks.single.physicsTrackArea.length, 3);
  });

  test('clicking the last point undoes it', () {
    seedDrawingMask();
    notifier.trackAreaTap(const ui.Offset(0, 0));
    notifier.trackAreaTap(const ui.Offset(16, 0));
    notifier.trackAreaTap(const ui.Offset(8, 16));

    notifier.trackAreaTap(const ui.Offset(8, 15)); // near the last vertex
    expect(area(), [const Vec2(0, 0), const Vec2(16, 0)]);
    expect(read().physicsDrawing, isTrue);
  });

  test('Esc-style cancel discards the in-progress area and deselects', () {
    seedDrawingMask();
    notifier.trackAreaTap(const ui.Offset(0, 0));
    notifier.trackAreaTap(const ui.Offset(16, 0));

    notifier.cancelPhysicsArea();
    expect(read().selectedIndex, isNull);
    expect(read().physicsDrawing, isFalse);
    final masks = container.read(assetDefinerProvider).masks;
    expect(masks.single.physicsTrackArea, isEmpty);
  });

  group('curve mode', () {
    test('empty polyline collects start then center before the arc', () {
      seedDrawingMask();
      notifier.toggleCurveMode();

      notifier.trackAreaTap(const ui.Offset(0, 0)); // start
      expect(read().curveDraftPoints, [const Vec2(0, 0)]);
      expect(area(), isEmpty);

      notifier.trackAreaTap(const ui.Offset(8, 8)); // center
      expect(read().curveDraftPoints.length, 2);
      expect(area(), isEmpty);

      notifier.trackAreaTap(const ui.Offset(16, 0)); // end -> commit arc
      expect(read().curveDraftPoints, isEmpty);
      // An arc is many points, and drawing stays open (not auto-completed).
      expect(area().length, greaterThan(3));
      expect(read().physicsDrawing, isTrue);
    });

    test('an existing point becomes the arc start (center then end)', () {
      seedDrawingMask();
      notifier.trackAreaTap(const ui.Offset(0, 0)); // committed start
      notifier.toggleCurveMode();

      notifier.trackAreaTap(const ui.Offset(8, 8)); // center only
      expect(read().curveDraftPoints, [const Vec2(8, 8)]);

      notifier.trackAreaTap(const ui.Offset(16, 0)); // end -> commit arc
      final pts = area();
      // The committed start is not duplicated by the arc's first point.
      expect(pts.first, const Vec2(0, 0));
      expect(pts[1], isNot(const Vec2(0, 0)));
      expect(pts.length, greaterThan(3));
    });

    test('undo steps back through the arc draft before touching vertices', () {
      seedDrawingMask();
      notifier.toggleCurveMode();
      notifier.trackAreaTap(const ui.Offset(0, 0)); // start
      notifier.trackAreaTap(const ui.Offset(8, 8)); // center
      expect(read().curveDraftPoints.length, 2);

      notifier.undoPhysicsAreaVertex();
      expect(read().curveDraftPoints.length, 1);
      notifier.undoPhysicsAreaVertex();
      expect(read().curveDraftPoints, isEmpty);
    });
  });

  test('a block that already has an area opens in view mode; Clear re-draws', () {
    seedDrawingMask();
    notifier.trackAreaTap(const ui.Offset(0, 0));
    notifier.trackAreaTap(const ui.Offset(16, 0));
    notifier.trackAreaTap(const ui.Offset(8, 16));
    notifier.closePhysicsArea(); // completes and deselects

    // Re-selecting the finished block does not re-enter draw mode.
    notifier.selectMask(0);
    expect(read().physicsDrawing, isFalse);
    expect(area().length, 3);

    // Clear is the only way to edit: it wipes the area and enters draw mode.
    notifier.clearPhysicsArea();
    expect(read().physicsDrawing, isTrue);
    expect(area(), isEmpty);
  });

  group('selection lock', () {
    test('in draw mode with nothing drawn, tapping another block switches', () {
      seedTwoMasks();
      notifier.selectMask(0); // empty block -> draw mode
      expect(read().selectedIndex, 0);
      expect(read().physicsDrawing, isTrue);

      notifier.trackAreaTap(const ui.Offset(32, 0)); // block 1's region
      expect(read().selectedIndex, 1);
    });

    test('once a point is placed, selection locks to that block', () {
      seedTwoMasks();
      notifier.selectMask(0);
      notifier.trackAreaTap(const ui.Offset(0, 0)); // first point in block 0
      expect(read().selectedIndex, 0);
      expect(read().selectedMask!.physicsTrackArea.length, 1);

      // Tapping block 1's region no longer switches; it draws in block 0.
      notifier.trackAreaTap(const ui.Offset(32, 0));
      expect(read().selectedIndex, 0);
    });

    test('in view mode, tapping another block switches', () {
      seedTwoMasks();
      notifier.selectMask(0);
      notifier.trackAreaTap(const ui.Offset(0, 0));
      notifier.trackAreaTap(const ui.Offset(16, 0));
      notifier.trackAreaTap(const ui.Offset(0, 16));
      notifier.closePhysicsArea(); // deselects, block 0 keeps its area

      notifier.selectMask(0); // re-select in view mode
      expect(read().physicsDrawing, isFalse);

      notifier.trackAreaTap(const ui.Offset(32, 0));
      expect(read().selectedIndex, 1);
    });
  });

  test('a curve is one-shot: mode returns to line after committing an arc', () {
    seedDrawingMask();
    notifier.toggleCurveMode();
    expect(read().curveMode, isTrue);

    notifier.trackAreaTap(const ui.Offset(0, 0)); // start
    notifier.trackAreaTap(const ui.Offset(8, 8)); // center
    notifier.trackAreaTap(const ui.Offset(16, 0)); // end -> commit

    expect(read().curveMode, isFalse);
  });
}
