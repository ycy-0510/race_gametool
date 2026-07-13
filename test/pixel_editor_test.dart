import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:race_gametool/logic/pixel_ops.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/asset_definer_providers.dart';
import 'package:race_gametool/state/pixel_editor_providers.dart';

/// Pixel editor notifier behavior: tool gestures, undo/redo, selection and
/// floating moves, symmetry, canvas ops, and the Phase 1 hand-off. All
/// assertions read the raw layer buffer, so the async image cache never
/// races the tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const red = 0xffff0000;
  const blue = 0xff0000ff;

  late ProviderContainer container;
  late PixelEditorNotifier notifier;

  PixelEditorState read() => container.read(pixelEditorProvider);
  Uint32List px() => read().document.layers.first.pixels;
  int at(int x, int y) => px()[y * read().document.width + x];

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(pixelEditorProvider.notifier);
    notifier.newDocument(4, 4);
    notifier.setColor(red);
  });

  tearDown(() => container.dispose());

  group('pencil and eraser', () {
    test('tap paints one pixel; a drag paints the whole path', () {
      notifier.tapAt(1.2, 1.7);
      expect(at(1, 1), red);

      notifier.strokeStart(0.5, 3.5);
      notifier.strokeUpdate(3.5, 3.5);
      notifier.strokeEnd();
      for (var x = 0; x < 4; x++) {
        expect(at(x, 3), red, reason: 'stroke covers ($x,3)');
      }
    });

    test('eraser clears back to transparent', () {
      notifier.tapAt(1, 1);
      notifier.setTool(PixelTool.eraser);
      notifier.tapAt(1, 1);
      expect(at(1, 1), 0);
    });

    test('undo/redo walk the stroke history', () {
      notifier.tapAt(0, 0);
      notifier.tapAt(1, 0);
      expect(read().canUndo, isTrue);

      notifier.undo();
      expect(at(1, 0), 0);
      expect(at(0, 0), red);

      notifier.undo();
      expect(at(0, 0), 0);
      expect(read().canUndo, isFalse);

      notifier.redo();
      notifier.redo();
      expect(at(0, 0), red);
      expect(at(1, 0), red);
    });
  });

  group('shape tools', () {
    test('line drag commits on release and undoes as one step', () {
      notifier.setTool(PixelTool.line);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(2.0, 0.4); // preview grows during the drag
      notifier.strokeUpdate(3.9, 0.4);
      notifier.strokeEnd();
      for (var x = 0; x < 4; x++) {
        expect(at(x, 0), red);
      }
      notifier.undo();
      expect(px().every((p) => p == 0), isTrue,
          reason: 'the intermediate preview is not a separate history step');
    });

    test('rectangle drag draws the outline only', () {
      notifier.setTool(PixelTool.rect);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(3.9, 3.9);
      notifier.strokeEnd();
      expect(at(0, 0), red);
      expect(at(3, 3), red);
      expect(at(1, 1), 0);
    });
  });

  group('fill tool', () {
    test('contiguous fill stays inside the connected region', () {
      // A vertical red wall at x=2 splits the canvas.
      notifier.setTool(PixelTool.line);
      notifier.strokeStart(2, 0);
      notifier.strokeUpdate(2, 3.9);
      notifier.strokeEnd();

      notifier.setColor(blue);
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);
      expect(at(0, 0), blue);
      expect(at(3, 0), 0, reason: 'other side of the wall untouched');
    });

    test('non-contiguous fill is a color replace', () {
      notifier.tapAt(0, 0);
      notifier.tapAt(3, 3); // two disconnected red pixels
      notifier.setTool(PixelTool.fill);
      notifier.setFillContiguous(false);
      notifier.setColor(blue);
      notifier.tapAt(0, 0);
      expect(at(0, 0), blue);
      expect(at(3, 3), blue);
      expect(at(1, 1), 0, reason: 'only the tapped color is replaced');
    });
  });

  test('eyedropper picks the tapped color and skips transparency', () {
    notifier.tapAt(1, 1);
    notifier.setColor(blue);
    notifier.setTool(PixelTool.eyedropper);
    notifier.tapAt(1, 1);
    expect(read().color, red);
    notifier.tapAt(3, 3);
    expect(read().color, red, reason: 'transparent tap keeps the color');
  });

  group('selection', () {
    void selectRect(double x0, double y0, double x1, double y1) {
      notifier.setTool(PixelTool.selectRect);
      notifier.strokeStart(x0, y0);
      notifier.strokeUpdate(x1, y1);
      notifier.strokeEnd();
    }

    test('rectangle selection masks every drawing tool', () {
      selectRect(0, 0, 1.9, 1.9); // top-left 2x2
      notifier.setTool(PixelTool.pencil);
      notifier.tapAt(3, 3);
      expect(at(3, 3), 0, reason: 'outside the selection, write blocked');
      notifier.tapAt(1, 1);
      expect(at(1, 1), red);
    });

    test('magic wand selects the tapped region; Delete clears it', () {
      notifier.tapAt(0, 0);
      notifier.tapAt(1, 0); // connected pair
      notifier.tapAt(3, 3); // separate pixel
      notifier.setTool(PixelTool.wand);
      notifier.tapAt(0, 0);
      expect(read().selection, isNotNull);

      notifier.deleteSelectionContents();
      expect(at(0, 0), 0);
      expect(at(1, 0), 0);
      expect(at(3, 3), red, reason: 'not part of the wand region');
    });

    test('lasso drag produces a mask; tap clears the selection', () {
      notifier.setTool(PixelTool.lasso);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(4, 0);
      notifier.strokeUpdate(4, 4);
      notifier.strokeUpdate(0, 4);
      notifier.strokeEnd();
      expect(read().selection, isNotNull);

      notifier.tapAt(2, 2);
      expect(read().selection, isNull);
    });
  });

  group('move tool', () {
    test('drag lifts the selection and a click outside commits it', () {
      notifier.tapAt(0, 0);
      notifier.setTool(PixelTool.selectRect);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(0.9, 0.9);
      notifier.strokeEnd();

      notifier.setTool(PixelTool.move);
      notifier.strokeStart(0.5, 0.5);
      notifier.strokeUpdate(2.5, 2.5);
      notifier.strokeEnd();
      expect(read().floating, isNotNull);
      expect(read().floating!.offsetX, 2);
      expect(at(0, 0), 0, reason: 'lifted off the layer');

      notifier.tapAt(0, 3); // outside the floating box: commit
      expect(read().floating, isNull);
      expect(at(2, 2), red);

      // One undo reverts the whole move (lift + drop).
      notifier.undo();
      expect(at(0, 0), red);
      expect(at(2, 2), 0);
    });

    test('Esc cancels an in-flight move back to the source', () {
      notifier.tapAt(1, 1);
      notifier.selectAll();
      notifier.setTool(PixelTool.move);
      notifier.strokeStart(1.5, 1.5);
      notifier.strokeUpdate(3.5, 3.5);
      notifier.strokeEnd();
      expect(read().floating, isNotNull);

      notifier.cancelFloatingOrSelection();
      expect(read().floating, isNull);
      expect(at(1, 1), red, reason: 'pixels restored where they were');
    });

    test('corner-handle scaling resamples nearest-neighbor', () {
      notifier.tapAt(0, 0);
      notifier.setTool(PixelTool.selectRect);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(0.9, 0.9);
      notifier.strokeEnd();
      notifier.setTool(PixelTool.move);
      notifier.strokeStart(0.5, 0.5); // lift the 1x1 selection
      notifier.strokeEnd();

      notifier.startHandleScale(3); // bottom-right handle
      notifier.strokeStart(0.5, 0.5);
      notifier.strokeUpdate(1.5, 1.5); // stretch to 2x2
      notifier.strokeEnd();
      final f = read().floating!;
      expect((f.width, f.height), (2, 2));
      expect(f.pixels.toList(), List.filled(4, red),
          reason: 'nearest-neighbor keeps the flat color crisp');
    });
  });

  test('symmetry mirrors strokes around the canvas center', () {
    notifier.setSymmetry(SymmetryMode.horizontal);
    notifier.tapAt(0, 1);
    expect(at(0, 1), red);
    expect(at(3, 1), red);

    notifier.setSymmetry(SymmetryMode.both);
    notifier.tapAt(1, 0);
    expect(at(1, 0), red);
    expect(at(2, 0), red);
    expect(at(1, 3), red);
    expect(at(2, 3), red);
  });

  group('canvas operations', () {
    test('rotate 90 swaps dimensions and moves content', () {
      notifier.newDocument(2, 1);
      notifier.setColor(red);
      notifier.tapAt(0, 0);
      notifier.rotate90Action(clockwise: true);
      expect(read().document.width, 1);
      expect(read().document.height, 2);
      expect(at(0, 0), red);
      expect(at(0, 1), 0);
    });

    test('flip mirrors the whole canvas', () {
      notifier.tapAt(0, 0);
      notifier.flipAction(horizontal: true);
      expect(at(0, 0), 0);
      expect(at(3, 0), red);
    });

    test('resize keeps content at the chosen anchor', () {
      notifier.newDocument(1, 1);
      notifier.setColor(red);
      notifier.tapAt(0, 0);
      notifier.resizeCanvasTo(3, 3, anchorX: 1, anchorY: 1);
      expect(read().document.width, 3);
      expect(at(2, 2), red);
      expect(at(0, 0), 0);
    });

    test('crop to selection tightens the canvas', () {
      notifier.tapAt(1, 1);
      notifier.setTool(PixelTool.wand);
      notifier.tapAt(1, 1);
      notifier.cropToSelection();
      expect(read().document.width, 1);
      expect(read().document.height, 1);
      expect(at(0, 0), red);
    });

    test('canvas ops are undoable', () {
      notifier.tapAt(0, 0);
      notifier.flipAction(horizontal: true);
      expect(at(3, 0), red);
      notifier.undo();
      expect(at(0, 0), red);
      expect(at(3, 0), 0);
    });
  });

  test('newDocument resets history, selection, and dirty state', () {
    notifier.tapAt(0, 0);
    notifier.selectAll();
    notifier.newDocument(8, 8);
    expect(read().document.width, 8);
    expect(read().selection, isNull);
    expect(read().isDirty, isFalse);
    expect(read().canUndo, isFalse);
    expect(px().every((p) => p == 0), isTrue);
  });

  group('send to Phase 1', () {
    test('replaces the track source image with the drawn pixels', () async {
      notifier.newDocument(32, 16);
      notifier.setColor(red);
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);

      await notifier.sendToPhase1(BlockCategory.track);

      final asset = container.read(assetDefinerProvider);
      final image = asset.images[BlockCategory.track];
      expect(image, isNotNull);
      expect(image!.image.width, 32);
      expect(image.image.height, 16);
      // The PNG bytes decode back to the drawn color.
      final decoded = img.decodePng(image.bytes)!;
      expect(decoded.getPixel(5, 5).r, 0xff);
      expect(decoded.getPixel(5, 5).g, 0);

      // The hand-off lands the user in Phase 1.
      expect(container.read(workspaceProvider).mode, AppMode.assetDefiner);
    });

    test('decoration images are appended, not replaced', () async {
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);
      await notifier.sendToPhase1(BlockCategory.decoration);
      await notifier.sendToPhase1(BlockCategory.decoration);

      final asset = container.read(assetDefinerProvider);
      expect(asset.decorationSources.length, 2);
      expect(asset.decorationMasks.length, 2);
      expect(asset.activeDecorationIndex, 1);
    });
  });
}
