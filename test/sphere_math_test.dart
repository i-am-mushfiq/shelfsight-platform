import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/screens/sphere_capture_screen.dart';

void main() {
  test('a dot straight ahead is at the centre of the view', () {
    final c = toCamera(const CameraPose(30, 10, 5), sphereDirection(30, 10));
    expect(c[0], closeTo(0, 1e-9));
    expect(c[1], closeTo(0, 1e-9));
    expect(c[2], closeTo(1, 1e-9));
    expect(angleTo(const CameraPose(30, 10, 5), const SphereTarget(30, 10)), closeTo(0, 1e-6));
  });

  test('a dot further right is to the right, a dot higher up is above', () {
    const pose = CameraPose(0, 0, 0);
    expect(toCamera(pose, sphereDirection(24, 0))[0], greaterThan(0));
    expect(toCamera(pose, sphereDirection(0, 40))[1], greaterThan(0));
  });

  test('rolling the phone clockwise turns what it sees anticlockwise', () {
    // With the phone rolled 90° clockwise, a dot to the right of the view appears at the top.
    final c = toCamera(const CameraPose(0, 0, 90), sphereDirection(20, 0));
    expect(c[1], greaterThan(0));
    expect(c[0].abs(), lessThan(1e-9));
  });

  test('targets: 15 at eye level, then the rings above and below', () {
    expect(SphereCaptureScreen.targets.length, 35);
    expect(SphereCaptureScreen.targets.take(SphereCaptureScreen.eyeLevel).every((t) => t.pitch == 0), isTrue);
  });
}
