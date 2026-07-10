import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'state/file_open_service.dart';
import 'ui/app_shell.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1440, 900),
    minimumSize: Size(1100, 700),
    center: true,
    title: 'Race Game Tool',
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    ProviderScope(
      overrides: [
        launchArgumentsProvider.overrideWithValue(args),
      ],
      child: const RaceGameToolApp(),
    ),
  );
}

class RaceGameToolApp extends StatelessWidget {
  const RaceGameToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Race Game Tool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.cyan,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}
