import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/screens/live_scan_screen.dart';
import 'package:shelfsight/screens/sphere_viewer_screen.dart';

void main() {
  test('a full-turn panorama wraps the whole sphere around the horizon', () {
    const geometry = SphereGeometry(horizontalDegrees: 360, verticalDegrees: 60);
    expect(geometry.fullWidth, 1);
    expect(geometry.fullHeight, .5);
    expect(geometry.croppedArea.left, 0);
    expect(geometry.croppedArea.height, closeTo(60 / 360, 1e-9));
    expect(geometry.croppedArea.top, closeTo((.5 - 60 / 360) / 2, 1e-9));
    final centre = geometry.position(.5, .5);
    expect(centre.longitude, 0);
    expect(centre.latitude, 0);
    final rightEdgeTop = geometry.position(1, 0);
    expect(rightEdgeTop.longitude, 180);
    expect(rightEdgeTop.latitude, 30);
  });

  test('a partial turn is centred and covers only its share of the sphere', () {
    const geometry = SphereGeometry(horizontalDegrees: 180, verticalDegrees: 45);
    expect(geometry.fullWidth, 2);
    expect(geometry.croppedArea.left, .5);
    expect(geometry.croppedArea.width, 1);
    expect(geometry.position(0, .5).longitude, -90);
  });

  test('live outlines are repainted only when the frame result changes', () {
    const a = LiveDetectionPainter(detections: [], imageWidth: 480, imageHeight: 640);
    const b = LiveDetectionPainter(detections: [], imageWidth: 480, imageHeight: 640);
    const c = LiveDetectionPainter(detections: [], imageWidth: 640, imageHeight: 480);
    expect(a.shouldRepaint(b), isFalse);
    expect(a.shouldRepaint(c), isTrue);
  });
}
