import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import 'sphere_viewer_screen.dart';

/// A direction to photograph: heading (degrees, growing to the right from where the capture
/// started) and pitch (degrees, up is positive).
class SphereTarget {
  const SphereTarget(this.yaw, this.pitch);
  final double yaw;
  final double pitch;
}

/// Camera orientation: heading from the gyroscope, pitch and roll from gravity.
class CameraPose {
  const CameraPose(this.yaw, this.pitch, this.roll);
  final double yaw;
  final double pitch;
  final double roll;
}

double _rad(double d) => d * math.pi / 180;

/// Unit vector of a heading/pitch in world space (x right, y up, z ahead at heading 0).
List<double> sphereDirection(double yaw, double pitch) {
  final h = _rad(yaw), p = _rad(pitch);
  return [math.cos(p) * math.sin(h), math.sin(p), math.cos(p) * math.cos(h)];
}

/// Angle in degrees between the camera's view and a target.
double angleTo(CameraPose pose, SphereTarget target) {
  final a = sphereDirection(pose.yaw, pose.pitch), b = sphereDirection(target.yaw, target.pitch);
  final dot = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]).clamp(-1.0, 1.0);
  return math.acos(dot) * 180 / math.pi;
}

/// A world direction in the camera's own axes (x right, y up, z ahead), the inverse of the
/// server's camera-to-world rotation (roll, then pitch, then yaw).
List<double> toCamera(CameraPose pose, List<double> world) {
  final h = _rad(pose.yaw), p = _rad(pose.pitch), r = _rad(pose.roll);
  // Undo yaw.
  var x = math.cos(h) * world[0] - math.sin(h) * world[2];
  var y = world[1];
  var z = math.sin(h) * world[0] + math.cos(h) * world[2];
  // Undo pitch.
  final y2 = math.cos(p) * y - math.sin(p) * z;
  final z2 = math.sin(p) * y + math.cos(p) * z;
  y = y2;
  z = z2;
  // Undo roll.
  final x3 = math.cos(r) * x - math.sin(r) * y;
  final y3 = math.sin(r) * x + math.cos(r) * y;
  return [x3, y3, z];
}

/// Guided 360° capture as in Google's Street View app: dots mark where to point the phone
/// (a ring at eye level, one above, one below); hold the centre circle on a dot and the photo
/// is taken by itself. Each photo carries the phone's orientation, so the server places it on
/// a full 360° × 180° sphere. Returns the sphere capture, or null.
class SphereCaptureScreen extends StatefulWidget {
  const SphereCaptureScreen({super.key, required this.storeName, required this.visitId, this.categoryId});
  final String storeName;
  final String visitId;
  final String? categoryId;

  /// 15 at eye level (every 24°), 10 at 40° up and 10 at 40° down (every 36°).
  static final List<SphereTarget> targets = [
    for (var i = 0; i < 15; i++) SphereTarget(i * 24.0, 0),
    for (var i = 0; i < 10; i++) SphereTarget(i * 36.0, 40),
    for (var i = 0; i < 10; i++) SphereTarget(i * 36.0 + 18, -40),
  ];

  /// The eye-level ring is enough for shelves; the other rings complete the sphere.
  static const eyeLevel = 15;

  @override
  State<SphereCaptureScreen> createState() => _SphereCaptureScreenState();
}

class _Shot {
  const _Shot(this.path, this.pose);
  final String path;
  final CameraPose pose;
}

class _SphereCaptureScreenState extends State<SphereCaptureScreen> {
  static const _alignDegrees = 3.5; // how close the centre must be to a dot
  static const _steadyRate = 0.35; // rad/s: slower than this counts as held still
  static const _previewLongSideFov = 70.0; // degrees across the preview's long side

  // One id for this sphere: a retried upload cannot create a second capture.
  final String _clientCaptureId = newClientId();
  CameraController? _controller;
  StreamSubscription<GyroscopeEvent>? _gyro;
  StreamSubscription<AccelerometerEvent>? _accel;
  String? _error;

  List<double>? _up; // gravity's "up" in phone axes, smoothed
  double _yaw = 0;
  double _rate = 0; // rad/s, any axis
  DateTime? _lastGyro;
  bool _started = false;
  bool _capturing = false;
  bool _uploading = false;
  final Map<int, _Shot> _shots = {}; // by target index

  CameraPose get _pose {
    final up = _up ?? const [0.0, 1.0, 0.0];
    final pitch = math.asin((-up[2]).clamp(-1.0, 1.0)) * 180 / math.pi;
    final roll = math.atan2(-up[0], up[1]) * 180 / math.pi;
    return CameraPose(_yaw, pitch, roll);
  }

  bool get _eyeLevelDone => Iterable.generate(SphereCaptureScreen.eyeLevel).every(_shots.containsKey);
  bool get _allDone => _shots.length == SphereCaptureScreen.targets.length;
  bool get _steady => _rate < _steadyRate;

  /// The nearest dot not yet photographed (eye level first, as Street View starts there).
  int? get _next {
    final pose = _pose;
    int? best;
    var bestAngle = double.infinity;
    for (var i = 0; i < SphereCaptureScreen.targets.length; i++) {
      if (_shots.containsKey(i)) continue;
      if (!_eyeLevelDone && i >= SphereCaptureScreen.eyeLevel) continue;
      final angle = angleTo(pose, SphereCaptureScreen.targets[i]);
      if (angle < bestAngle) {
        bestAngle = angle;
        best = i;
      }
    }
    return best;
  }

  @override
  void initState() {
    super.initState();
    _startCamera();
    _accel = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(_onAccel);
    _gyro = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen(_onGyro, onError: (_) {
      if (mounted) setState(() => _error = 'This phone has no gyroscope, so the sphere cannot be guided.');
    });
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      final controller = CameraController(camera, ResolutionPreset.veryHigh,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not start the camera.');
    }
  }

  void _onAccel(AccelerometerEvent e) {
    final n = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    if (n < 1) return;
    final now = [e.x / n, e.y / n, e.z / n];
    final up = _up;
    // Low-pass: gravity without the hand's shake.
    _up = up == null ? now : [for (var i = 0; i < 3; i++) up[i] * 0.85 + now[i] * 0.15];
  }

  void _onGyro(GyroscopeEvent e) {
    final now = e.timestamp;
    final last = _lastGyro;
    _lastGyro = now;
    if (last == null) return;
    final seconds = now.difference(last).inMicroseconds / 1e6;
    if (seconds <= 0 || seconds > 0.5) return;
    final up = _up ?? const [0.0, 1.0, 0.0];
    // Turning about gravity's axis, whatever the tilt; turning right (clockwise seen from
    // above) is a negative rotation about "up", and makes the heading grow.
    final aboutUp = e.x * up[0] + e.y * up[1] + e.z * up[2];
    _yaw -= aboutUp * seconds * 180 / math.pi;
    _rate = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    if (!mounted) return;
    setState(() {});
    if (_started && !_capturing && !_uploading && _steady) {
      final next = _next;
      if (next != null && angleTo(_pose, SphereCaptureScreen.targets[next]) < _alignDegrees) _shoot(next);
    }
  }

  void _start() {
    setState(() {
      _started = true;
      _yaw = 0; // the first eye-level dot is straight ahead
    });
  }

  Future<void> _shoot(int target) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) return;
    _capturing = true;
    final pose = _pose;
    try {
      final photo = await controller.takePicture();
      if (mounted) setState(() => _shots[target] = _Shot(photo.path, pose));
      if (_allDone) await _finish();
    } on CameraException {
      // The dot stays; holding on it again retries.
    } finally {
      _capturing = false;
    }
  }

  Future<void> _finish() async {
    if (_shots.length < 2 || _uploading) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _uploading = true);
    await _gyro?.cancel();
    await _accel?.cancel();
    final shots = _shots.values.toList();
    try {
      final capture = await PlatformApi.instance.uploadSphere(
        visitId: widget.visitId,
        framePaths: [for (final s in shots) s.path],
        yaws: [for (final s in shots) s.pose.yaw],
        pitches: [for (final s in shots) s.pose.pitch],
        rolls: [for (final s in shots) s.pose.roll],
        clientCaptureId: _clientCaptureId,
        categoryId: widget.categoryId,
      );
      for (final s in shots) {
        try {
          File(s.path).deleteSync();
        } on FileSystemException {
          // Already gone.
        }
      }
      final kept = await navigator.push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => SphereViewerScreen(capture: capture, storeName: widget.storeName)),
      );
      navigator.pop(kept ?? capture);
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('${error.message} Tap Finish to try again.')));
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _gyro?.cancel();
    _accel?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  String get _instruction {
    if (_error != null) return _error!;
    if (_uploading) return 'Building the sphere…';
    if (!_started) {
      return 'Stand in one spot. You will turn the phone around you, not walk. Tap Start, then hold the circle on each dot.';
    }
    if (!_steady) return 'Hold still…';
    if (_allDone) return 'Sphere complete';
    if (!_eyeLevelDone) {
      return 'Eye level: move the circle onto the dot · ${_shots.length} of ${SphereCaptureScreen.eyeLevel}';
    }
    return 'Now the dots above and below · or tap Finish';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final next = _started ? _next : null;
    return Scaffold(
      backgroundColor: const Color(0xFF07101F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF07101F),
        foregroundColor: Colors.white,
        title: Text(t('360° photo sphere'), style: const TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: LayoutBuilder(
                    builder: (context, box) => Stack(
                      fit: StackFit.expand,
                      children: [
                        if (controller != null && controller.value.isInitialized)
                          FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: controller.value.previewSize!.height,
                              height: controller.value.previewSize!.width,
                              child: CameraPreview(controller),
                            ),
                          )
                        else
                          const ColoredBox(color: Color(0xFF111827)),
                        if (_started)
                          CustomPaint(
                            painter: SphereTargetsPainter(
                              pose: _pose,
                              targets: SphereCaptureScreen.targets,
                              taken: _shots.keys.toSet(),
                              next: next,
                              longSideFov: _previewLongSideFov,
                              capturing: _capturing,
                            ),
                          ),
                        Center(
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 16,
                          right: 16,
                          top: 16,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: _started && !_steady ? AppColors.amber : const Color(0xD9111827),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              _instruction,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        if (_uploading) const Center(child: CircularProgressIndicator(color: AppColors.emerald)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Text(
                    '${_shots.length} / ${SphereCaptureScreen.targets.length}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 18),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: !_started
                        ? FilledButton.icon(
                            key: const Key('sphere-start'),
                            onPressed: controller == null || _error != null ? null : _start,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.emerald,
                              foregroundColor: AppColors.navy,
                              minimumSize: const Size.fromHeight(52),
                              shape: const StadiumBorder(),
                            ),
                            icon: const Icon(Icons.threesixty_rounded),
                            label: Text(t('Start')),
                          )
                        : FilledButton.icon(
                            // The eye-level ring is what shelves need; the rest is optional.
                            onPressed: !_eyeLevelDone || _uploading ? null : _finish,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.emerald,
                              foregroundColor: AppColors.navy,
                              minimumSize: const Size.fromHeight(52),
                              shape: const StadiumBorder(),
                            ),
                            icon: const Icon(Icons.check_rounded),
                            label: Text(_uploading ? 'Building…' : 'Finish'),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Street View-style targets drawn where they are in front of the camera: the next dot is
/// large and white, the others small; photographed areas are gone. When the next dot is out
/// of view, an arrow at the edge points to it.
class SphereTargetsPainter extends CustomPainter {
  const SphereTargetsPainter({
    required this.pose,
    required this.targets,
    required this.taken,
    required this.next,
    required this.longSideFov,
    required this.capturing,
  });
  final CameraPose pose;
  final List<SphereTarget> targets;
  final Set<int> taken;
  final int? next;
  final double longSideFov;
  final bool capturing;

  @override
  void paint(Canvas canvas, Size size) {
    final f = size.longestSide / 2 / math.tan(_rad(longSideFov) / 2);
    final centre = size.center(Offset.zero);
    Offset? project(SphereTarget t) {
      final c = toCamera(pose, sphereDirection(t.yaw, t.pitch));
      if (c[2] <= 0.05) return null;
      return centre + Offset(f * c[0] / c[2], -f * c[1] / c[2]);
    }

    for (var i = 0; i < targets.length; i++) {
      if (taken.contains(i) || i == next) continue;
      final p = project(targets[i]);
      if (p == null) continue;
      canvas.drawCircle(p, 7, Paint()..color = Colors.white54);
    }
    final n = next;
    if (n == null) return;
    final target = targets[n];
    final p = project(target);
    final visible = p != null && Rect.fromLTWH(0, 0, size.width, size.height).deflate(24).contains(p);
    if (visible) {
      canvas.drawCircle(p, 22, Paint()..color = capturing ? AppColors.emerald : Colors.white);
      canvas.drawCircle(p, 22, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.emerald);
      return;
    }
    // Off screen: an arrow at the edge in the dot's direction.
    final c = toCamera(pose, sphereDirection(target.yaw, target.pitch));
    var dir = Offset(c[0], -c[1]);
    if (dir.distance < 1e-6) dir = const Offset(1, 0);
    if (c[2] < 0 && dir.distance < 0.2) dir = Offset(dir.dx.sign == 0 ? 1 : dir.dx.sign, 0);
    dir = dir / dir.distance;
    final reach = math.min(
      dir.dx.abs() < 1e-6 ? double.infinity : (size.width / 2 - 40) / dir.dx.abs(),
      dir.dy.abs() < 1e-6 ? double.infinity : (size.height / 2 - 40) / dir.dy.abs(),
    );
    final tip = centre + dir * reach;
    final back = tip - dir * 30;
    final side = Offset(-dir.dy, dir.dx) * 14;
    final arrow = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((back + side).dx, (back + side).dy)
      ..lineTo((back - side).dx, (back - side).dy)
      ..close();
    canvas.drawPath(arrow, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant SphereTargetsPainter old) => true;
}
