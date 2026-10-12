import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/l10n.dart';
import 'offline/offline_backend.dart';
import 'recognition/debug_log.dart';
import 'recognition/on_device.dart';
import 'screens/splash_screen.dart';
import 'services/platform_api.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PlatformApi.loadServerAddress();
  await loadLanguage();
  // With no server, read the demo data while the splash screen shows.
  if (PlatformApi.offline) unawaited(OfflineBackend.instance.ready());
  // Load the recognition models up front so a load failure shows in the log straight away.
  RecognitionLog.log('app start: offline=${PlatformApi.offline}, recognition=${PlatformApi.offline ? 'phone' : 'laptop ${PlatformApi.baseUrl}'}');
  if (PlatformApi.offline) unawaited(OnDeviceRecognizer.instance.load().catchError((Object _) {}));
  runApp(const ShelfSightApp());
}

class ShelfSightApp extends StatefulWidget {
  const ShelfSightApp({super.key});

  @override
  State<ShelfSightApp> createState() => _ShelfSightAppState();
}

class _ShelfSightAppState extends State<ShelfSightApp> {
  @override
  void initState() {
    super.initState();
    appLanguage.addListener(_languageChanged);
  }

  @override
  void dispose() {
    appLanguage.removeListener(_languageChanged);
    super.dispose();
  }

  /// Text is looked up while building, so every screen on the stack is rebuilt in the new
  /// language; the user stays where they are.
  void _languageChanged() {
    setState(() {});
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ShelfSight',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    locale: Locale(appLanguage.value.name),
    supportedLocales: const [Locale('en'), Locale('bn')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const SplashScreen(),
  );
}
