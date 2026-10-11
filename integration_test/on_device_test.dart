// Runs the on-device recogniser (bundled ONNX models, Dart pipeline) on demo shelves on a real
// platform: flutter test integration_test/on_device_test.dart -d <android device | windows>.
// On Windows this needs Developer Mode (Flutter links plugins with symlinks).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shelfsight/recognition/on_device.dart';

const _root = 'C:/Personal_Endeavours/FMCG/shelfsight-platform/FMCG_Shelf_Test_Set_20';
const _screens =
    'C:/Users/Mushfiq/AppData/Local/Temp/claude/c--Personal-Endeavours-FMCG/27acc120-6dc3-486b-958a-17bdf9a8ba68/scratchpad/screen20';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recognises demo shelves on the device', (tester) async {
    final recognizer = OnDeviceRecognizer.instance;
    await tester.runAsync(() async {
      final load = Stopwatch()..start();
      await recognizer.load();
      // ignore: avoid_print
      print('models loaded in ${load.elapsedMilliseconds} ms');
      const cases = [
        ('$_root/supershop/shelf_01_80pct_own.png', false, 80),
        ('$_root/competitor_heavy/sparse_05_supershop_target08pct.png', false, 8),
        ('$_root/mudi_dokan/mudi_02_65pct_own.png', false, 65),
        ('$_screens/supershop/shelf_01_80pct_own.jpg', true, 80),
        ('$_screens/competitor_heavy/sparse_05_supershop_target08pct.jpg', true, 8),
        ('$_screens/mudi_dokan/mudi_02_65pct_own.jpg', true, 65),
      ];
      for (final (path, screen, target) in cases) {
        final result = await recognizer.recognize(await File(path).readAsBytes(), screenPhoto: screen);
        final summary = result['summary'] as Map;
        final total = summary['facings'] as int, own = summary['own_facings'] as int;
        final share = total == 0 ? 0 : 100 * own / total;
        // ignore: avoid_print
        print('${path.split('/').last} (${screen ? 'screen' : 'clean'}): $own Square of $total packs = '
            '${share.toStringAsFixed(1)}% (target $target%) in ${result['latency_ms']} ms');
        expect(total, greaterThan(5));
        expect((share - target).abs(), lessThan(25));
      }
    });
  });
}
