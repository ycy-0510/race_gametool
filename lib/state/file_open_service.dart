import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';
import 'asset_definer_providers.dart';

/// Bridges the native "open .rgpack" events (Finder double-click, "Open
/// With", or launching the app on a file) into the app. The macOS
/// AppDelegate forwards paths over the "app.rgpack/open" method channel;
/// a file the app was launched with is held natively until we ask for it.
class FileOpenService {
  FileOpenService(this._ref);

  final Ref _ref;
  static const _channel = MethodChannel('app.rgpack/open');
  bool _started = false;
  Future<bool> Function()? _onOpenRequest;

  /// Wires up the channel and drains any file the app was launched with.
  /// Safe to call more than once.
  Future<void> start({Future<bool> Function()? onOpenRequest}) async {
    if (onOpenRequest != null) {
      _onOpenRequest = onOpenRequest;
    }
    if (_started) return;
    _started = true;

    _channel.setMethodCallHandler((call) async {
      debugPrint('FileOpenChannel: received method ${call.method}');
      if (call.method == 'openFile' && call.arguments is String) {
        final path = call.arguments as String;
        debugPrint('FileOpenChannel: path is $path');
        bool proceed = true;
        if (_onOpenRequest != null) {
          try {
            debugPrint('FileOpenChannel: calling onOpenRequest');
            proceed = await _onOpenRequest!();
            debugPrint('FileOpenChannel: onOpenRequest returned $proceed');
          } catch (e, stack) {
            debugPrint('FileOpenChannel: error in onOpenRequest: $e\n$stack');
            proceed = true; // Fallback to true so we still open the file
          }
        }
        if (proceed) {
          debugPrint('FileOpenChannel: opening file $path');
          await _open(path);
        }
      }
      return null;
    });

    try {
      debugPrint('FileOpenChannel: invoking getPendingFile');
      final pending = await _channel.invokeMethod<String>('getPendingFile');
      debugPrint('FileOpenChannel: getPendingFile returned $pending');
      if (pending != null && pending.isNotEmpty) {
        bool proceed = true;
        if (_onOpenRequest != null) {
          try {
            debugPrint('FileOpenChannel: calling onOpenRequest for pending file');
            proceed = await _onOpenRequest!();
            debugPrint('FileOpenChannel: onOpenRequest for pending returned $proceed');
          } catch (e, stack) {
            debugPrint('FileOpenChannel: error in onOpenRequest for pending: $e\n$stack');
            proceed = true; // Fallback to true so we still open the file
          }
        }
        if (proceed) {
          debugPrint('FileOpenChannel: opening pending file $pending');
          await _open(pending);
        }
      }
    } on MissingPluginException {
      debugPrint('FileOpenChannel: MissingPluginException');
    }

    // Handle command-line launch arguments (specifically for Windows/Linux double-click starts)
    final launchArgs = _ref.read(launchArgumentsProvider);
    if (launchArgs.isNotEmpty) {
      final fileArg = launchArgs.first;
      if (fileArg.endsWith('.rgpack')) {
        debugPrint('FileOpenChannel: found launch argument: $fileArg');
        bool proceed = true;
        if (_onOpenRequest != null) {
          try {
            proceed = await _onOpenRequest!();
          } catch (e, stack) {
            debugPrint('FileOpenChannel: error in onOpenRequest for argument: $e\n$stack');
            proceed = true;
          }
        }
        if (proceed) {
          debugPrint('FileOpenChannel: opening launch argument file $fileArg');
          await _open(fileArg);
        }
      }
    }
  }

  Future<void> _open(String path) async {
    debugPrint('FileOpenChannel: _open called for path $path');
    try {
      _ref.read(appModeProvider.notifier).select(AppMode.assetDefiner);
      await _ref.read(assetDefinerProvider.notifier).openBundleFromPath(path);
      debugPrint('FileOpenChannel: openBundleFromPath succeeded');
    } catch (e, stack) {
      debugPrint('FileOpenChannel: error inside _open: $e\n$stack');
    }
  }
}

/// Created once and kept alive for the app's lifetime.
final fileOpenServiceProvider =
    Provider<FileOpenService>((ref) => FileOpenService(ref));

/// Command-line arguments passed to the application at launch (specifically for Windows/Linux).
final launchArgumentsProvider = Provider<List<String>>((ref) => const []);
