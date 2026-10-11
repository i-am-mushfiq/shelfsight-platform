// Screenshots of every screen of the app, for the app map (app_map/index.html).
//
// Needs the backend running with the demo data (see app_map/make_fixture.py), then:
//   flutter test app_map/app_map_test.dart --dart-define=SHELFSIGHT_API_URL=http://127.0.0.1:8000
// PNGs are written to app_map/shots/. The camera is replaced by one that "sees" a photo of a
// demo shelf shown on a monitor (app_map/shelf_a.jpg); everything else is the real app talking
// to the real server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sensors_plus_platform_interface/sensors_plus_platform_interface.dart';
import 'package:shelfsight/models/field_models.dart';
import 'package:shelfsight/models/session.dart';
import 'package:shelfsight/screens/app_shell.dart';
import 'package:shelfsight/screens/audit_upload_screen.dart';
import 'package:shelfsight/screens/capture_screen.dart';
import 'package:shelfsight/screens/detection_review_screen.dart';
import 'package:shelfsight/screens/live_scan_screen.dart';
import 'package:shelfsight/screens/location_permission_screen.dart';
import 'package:shelfsight/screens/login_screen.dart';
import 'package:shelfsight/screens/order_screen.dart';
import 'package:shelfsight/screens/outlet_screen.dart';
import 'package:shelfsight/screens/review_screen.dart';
import 'package:shelfsight/screens/sphere_capture_screen.dart';
import 'package:shelfsight/screens/sphere_viewer_screen.dart';
import 'package:shelfsight/screens/splash_screen.dart';
import 'package:shelfsight/screens/support_screens.dart';
import 'package:shelfsight/screens/visit_report_screen.dart';
import 'package:shelfsight/services/platform_api.dart';
import 'package:shelfsight/theme/app_theme.dart';

final _shotKey = GlobalKey();
final _out = Directory('app_map/shots');
late Map<String, dynamic> fixture;
late UserSession officer;
late Directory temp;
late String officerToken;

class _Documents extends PathProviderPlatform with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => temp.path;
  @override
  Future<String?> getTemporaryPath() async => temp.path;
}

class _Sensors extends SensorsPlatform with MockPlatformInterfaceMixin {
  @override
  Stream<GyroscopeEvent> gyroscopeEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      const Stream.empty();
  @override
  Stream<AccelerometerEvent> accelerometerEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      const Stream.empty();
  @override
  Stream<UserAccelerometerEvent> userAccelerometerEventStream(
          {Duration samplingPeriod = SensorInterval.normalInterval}) =>
      const Stream.empty();
  @override
  Stream<MagnetometerEvent> magnetometerEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      const Stream.empty();
  @override
  Stream<BarometerEvent> barometerEventStream({Duration samplingPeriod = SensorInterval.normalInterval}) =>
      const Stream.empty();
}

/// A camera that sees a phone photo of a demo shelf on a monitor.
class _Camera extends CameraPlatform with MockPlatformInterfaceMixin {
  _Camera(this.frame);
  final File frame;
  int _shots = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
    CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90),
  ];
  @override
  Future<int> createCameraWithSettings(CameraDescription description, MediaSettings? settings) async => 1;
  @override
  Future<int> createCamera(CameraDescription description, ResolutionPreset? preset,
          {bool enableAudio = false}) async =>
      1;
  @override
  Future<void> initializeCamera(int cameraId, {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(CameraInitializedEvent(cameraId, 1280, 720, ExposureMode.auto, true, FocusMode.auto, true));
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => StreamController<CameraErrorEvent>().stream;
  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) => const Stream.empty();
  @override
  Stream<CameraResolutionChangedEvent> onCameraResolutionChanged(int cameraId) => const Stream.empty();
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() => const Stream.empty();
  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}
  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {}
  @override
  Future<void> setExposureMode(int cameraId, ExposureMode mode) async {}
  @override
  Future<void> lockCaptureOrientation(int cameraId, DeviceOrientation orientation) async {}
  @override
  Future<void> unlockCaptureOrientation(int cameraId) async {}
  @override
  Future<double> getMinZoomLevel(int cameraId) async => 1;
  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 1;
  @override
  Future<void> pausePreview(int cameraId) async {}
  @override
  Future<void> resumePreview(int cameraId) async {}
  @override
  Future<void> dispose(int cameraId) async {}
  @override
  Future<XFile> takePicture(int cameraId) async {
    final copy = File('${temp.path}/shot_${_shots++}.jpg');
    frame.copySync(copy.path);
    return XFile(copy.path);
  }

  @override
  Widget buildPreview(int cameraId) => Image.file(frame, fit: BoxFit.cover);
}

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    loader.addFont(Future.value(ByteData.view(File(file).readAsBytesSync().buffer)));
  }
  await loader.load();
}

Widget _app(Widget home) => RepaintBoundary(
  key: _shotKey,
  child: MaterialApp(theme: AppTheme.light, debugShowCheckedModeBanner: false, home: home),
);

/// Lets real network and image decoding happen while the fake clock moves on.
Future<void> settle(WidgetTester tester, {int seconds = 3}) async {
  for (var i = 0; i < seconds * 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> shot(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${_out.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> open(WidgetTester tester, Widget home, {int seconds = 3}) async {
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.625;
  await tester.pumpWidget(_app(home));
  await settle(tester, seconds: seconds);
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  final scrollables = find.byType(Scrollable);
  for (final delta in [-300.0, 300.0]) {
    if (target.evaluate().isNotEmpty || scrollables.evaluate().isEmpty) break;
    try {
      await tester.scrollUntilVisible(target, delta, scrollable: scrollables.first, maxScrolls: 30);
    } catch (_) {}
  }
}

Future<void> tapText(WidgetTester tester, String text, {int seconds = 2, bool scroll = true}) async {
  await reveal(tester, find.text(text));
  // Scrolling a target to the very top can tuck it under a fixed header; skip when it is already on screen.
  if (scroll) await tester.ensureVisible(find.text(text).first);
  await tester.pump();
  await tester.tap(find.text(text).first);
  await settle(tester, seconds: seconds);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    HttpOverrides.global = null; // talk to the real server
    _out.createSync(recursive: true);
    temp = Directory.systemTemp.createTempSync('app_map');
    fixture = jsonDecode(File('app_map/fixture.json').readAsStringSync()) as Map<String, dynamic>;
    const fonts = 'C:/devtools/flutter/bin/cache/artifacts/material_fonts';
    await _font('Poppins', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/Poppins-$w.ttf']);
    await _font('Roboto', ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf']);
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
    // Text painted without a font family uses the test's placeholder font (solid boxes); give it
    // Roboto, which is what a phone uses there.
    await _font('FlutterTest', ['$fonts/roboto-medium.ttf']);
    try {
      await _font('Segoe UI', ['C:/Windows/Fonts/Nirmala.ttc']); // Bangla glyphs
    } catch (_) {}
    PathProviderPlatform.instance = _Documents();
    SensorsPlatform.instance = _Sensors();
    CameraPlatform.instance = _Camera(File('app_map/shelf_a.jpg'));
    officer = UserSession.fromAuth(await PlatformApi.instance.login('SO-1001', 'shelf123'));
    currentSession.value = officer;
  });

  setUp(() async {
    // A fresh connection pool per test: idle connections from a previous test's fake clock hang.
    PlatformApi.instance.httpClient = http.Client();
    await PlatformApi.instance.login('SO-1001', 'shelf123');
    currentSession.value = officer;
  });

  Shop shop() => Shop.fromJson(fixture['outlet'] as Map<String, dynamic>);
  String storeName() => (fixture['outlet'] as Map)['name'] as String;
  List<CapturedPhoto> photos() => [
    for (final name in ['shelf_a.jpg', 'shelf_b.jpg'])
      CapturedPhoto(path: (File('app_map/$name').copySync('${temp.path}/review_$name')).path),
  ];

  testWidgets('01-02 splash and sign-in', (tester) async {
    await open(tester, const SplashScreen(), seconds: 0);
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, '01_splash');
    await tester.pump(const Duration(seconds: 3));
    await settle(tester, seconds: 1);
    await shot(tester, '02_login');
    await tester.tap(find.byKey(const Key('server-address')));
    await settle(tester, seconds: 1);
    await tapText(tester, 'Test', seconds: 2);
    await shot(tester, '03_server_address');
    await tester.tap(find.text('Save'));
    await settle(tester, seconds: 1);
    await tapText(tester, 'Need help?', seconds: 1);
    await shot(tester, '04_sign_in_help');
  });

  testWidgets('05 location', (tester) async {
    await open(tester, LocationPermissionScreen(session: officer), seconds: 1);
    await shot(tester, '05_location');
  });

  testWidgets('06-08 home, notifications, new shop', (tester) async {
    await open(tester, AppShell(session: officer));
    await shot(tester, '06_home');
    await tester.tap(find.byTooltip('Notifications').first);
    await settle(tester, seconds: 2);
    await shot(tester, '07_notifications');
    await tester.pageBack();
    await settle(tester, seconds: 1);
    await tapText(tester, 'New shop');
    await shot(tester, '08_register_shop');
  });

  testWidgets('09-12 outlet, actions, details, brief, suggested order, store type', (tester) async {
    await open(tester, OutletScreen(shop: shop(), atShop: true), seconds: 4);
    await shot(tester, '09_outlet');
    await tester.tap(find.textContaining('Add Meril Milk').first);
    await settle(tester, seconds: 2);
    await shot(tester, '09b_action');
    await tester.tapAt(const Offset(200, 60)); // close the sheet
    await settle(tester, seconds: 1);
    if (find.textContaining('See all').evaluate().isNotEmpty) {
      await tapText(tester, find.textContaining('See all').evaluate().first.widget is Text
          ? ((find.textContaining('See all').evaluate().first.widget as Text).data ?? 'See all')
          : 'See all', seconds: 2);
      await shot(tester, '09c_all_actions');
      await tester.pageBack();
      await settle(tester, seconds: 1);
    }
    await tapText(tester, 'Shop details', seconds: 2);
    await shot(tester, '09d_shop_details');
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -600));
    await settle(tester, seconds: 1);
    await shot(tester, '09e_shop_details_more');
    await tester.pageBack();
    await settle(tester, seconds: 1);
    await tapText(tester, 'What to talk about', seconds: 3);
    await shot(tester, '10_pre_call_brief');
    await tester.tapAt(const Offset(200, 60));
    await settle(tester, seconds: 1);
    await tapText(tester, 'Suggested order', seconds: 3);
    await shot(tester, '11_suggested_order');
    await tester.tap(find.byType(InkWell).at(1));
    await settle(tester, seconds: 1);
    await shot(tester, '11b_suggested_order_why');
    await tester.pageBack();
    await settle(tester, seconds: 3);
    await tester.tap(find.text('Start visit').last);
    await settle(tester, seconds: 3);
    await shot(tester, '12_store_type');
  });

  testWidgets('13-14 camera and rack', (tester) async {
    await open(
      tester,
      CaptureScreen(storeName: storeName(), storeTypeName: 'Super Shop', visitId: fixture['capture_visit'] as String),
      seconds: 3,
    );
    await shot(tester, '13_capture');
    await tapText(tester, 'Rack: All products', seconds: 2);
    await shot(tester, '14_rack');
  });

  testWidgets('15 live scan', (tester) async {
    await open(tester, LiveScanScreen(storeName: storeName()), seconds: 10);
    await shot(tester, '15_live_scan');
  });

  testWidgets('16 sphere capture', (tester) async {
    await open(
      tester,
      SphereCaptureScreen(storeName: storeName(), visitId: fixture['review_visit'] as String),
      seconds: 2,
    );
    await shot(tester, '16_sphere_capture');
  });

  testWidgets('17 sphere viewer', (tester) async {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => debugPrint('ignored: ${details.exceptionAsString().split('\n').first}');
    await open(
      tester,
      SphereViewerScreen(capture: fixture['sphere_capture'] as Map<String, dynamic>, storeName: storeName()),
      seconds: 6,
    );
    await shot(tester, '17_sphere_viewer');
    FlutterError.onError = previous;
  });

  testWidgets('18-19 review and upload', (tester) async {
    final visit = await tester.runAsync(
      () => PlatformApi.instance.startVisit(
        clientVisitId: newClientId(),
        outletId: shop().id,
        storeTypeId: (fixture['store_type'] as Map)['id'] as String,
      ),
    );
    final visitId = visit!['id'] as String;
    await open(
      tester,
      ReviewScreen(storeName: storeName(), storeTypeName: 'Super Shop', visitId: visitId, photos: photos()),
      seconds: 2,
    );
    await shot(tester, '18_review_photos');
    await tapText(tester, 'Send photos', seconds: 2);
    await shot(tester, '19a_uploading');
    for (var i = 0; i < 30 && find.text('Check the results').evaluate().isEmpty; i++) {
      await settle(tester, seconds: 2);
    }
    await settle(tester, seconds: 4);
    await shot(tester, '19b_upload_done');
  });

  testWidgets('20 detection review', (tester) async {
    await open(
      tester,
      DetectionReviewScreen(
        storeName: storeName(),
        visitId: fixture['review_visit'] as String,
        captureIds: (fixture['review_captures'] as List).cast<String>(),
      ),
      seconds: 6,
    );
    await shot(tester, '20_detection_review');
    final image = find.byType(Image);
    if (image.evaluate().isNotEmpty) {
      await tester.tapAt(tester.getCenter(image.first));
      await settle(tester, seconds: 1);
      await shot(tester, '20b_box_selected');
    }
  });

  testWidgets('21-23 visit report, order, cancel', (tester) async {
    await open(tester, VisitReportScreen(visitId: fixture['visit_report'] as String), seconds: 4);
    await shot(tester, '21a_report');
    final scroll = find.byType(Scrollable).first;
    for (final part in ['21b', '21c', '21d', '21e']) {
      await tester.drag(scroll, const Offset(0, -750));
      await settle(tester, seconds: 1);
      await shot(tester, '${part}_report');
    }
    final order = fixture['report_order'] as Map<String, dynamic>?;
    await reveal(tester, find.text('Cancel order'));
    if (find.text('Cancel order').evaluate().isNotEmpty) {
      await tapText(tester, 'Cancel order', seconds: 1);
      await shot(tester, '23_cancel_order');
      await tester.tap(find.text('Keep order'));
      await settle(tester, seconds: 1);
    }
    if (order != null) {
      await open(
        tester,
        OrderScreen(
          outletId: shop().id,
          outletName: storeName(),
          visitId: fixture['visit_report'] as String,
          order: order,
        ),
        seconds: 3,
      );
      await shot(tester, '22_order_edit');
    }
  });

  testWidgets('24-30 visits, learn, profile and settings', (tester) async {
    await open(tester, AppShell(session: officer));
    await tapText(tester, 'Visits', seconds: 3);
    await shot(tester, '24_visits');
    await tapText(tester, 'Learn', seconds: 2);
    await shot(tester, '25_learn');
    await tapText(tester, 'Profile', seconds: 2);
    await shot(tester, '26_profile');
    await tapText(tester, 'All data synced', seconds: 2, scroll: false);
    await shot(tester, '27_sync_center');
    await tester.pageBack();
    await settle(tester, seconds: 1);
    await tapText(tester, 'Language', seconds: 1);
    await shot(tester, '28_language');
    await tester.tapAt(const Offset(200, 60));
    await settle(tester, seconds: 1);
    await tapText(tester, 'App permissions', seconds: 1);
    await shot(tester, '29_permissions');
    await tester.pageBack();
    await settle(tester, seconds: 1);
    await tapText(tester, 'Help & support', seconds: 1);
    await shot(tester, '30_help');
  });

  testWidgets('31-33 supervisor', (tester) async {
    final supervisor = UserSession.fromAuth((await tester.runAsync(() => PlatformApi.instance.login('TO-2001', 'shelf123')))!);
    currentSession.value = supervisor;
    await open(tester, AppShell(session: supervisor), seconds: 4);
    await shot(tester, '31_dashboard');
    await tapText(tester, 'Exceptions', seconds: 3);
    await shot(tester, '32_exceptions');
    await tapText(tester, 'Team', seconds: 3);
    await shot(tester, '33_team');
  });

  testWidgets('34-35 screens not linked from anywhere', (tester) async {
    await open(tester, const ReportFiltersScreen(), seconds: 1);
    await shot(tester, '34_report_filters_unlinked');
    await open(tester, const ShelfViewerScreen(), seconds: 1);
    await shot(tester, '35_shelf_viewer_unlinked');
  });

  tearDownAll(() {
    binding.platformDispatcher.clearAllTestValues();
  });
}
