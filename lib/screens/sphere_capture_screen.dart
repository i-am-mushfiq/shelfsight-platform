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

/// Guided 360° capture: the officer turns slowly on the spot and a frame is taken every
/// [stepDegrees], measured with the gyroscope. The frames are stitched on the server into a
/// panorama that is analysed like a shelf photo. Returns the sphere capture, or null.
class SphereCaptureScreen extends StatefulWidget {
  const SphereCaptureScreen({super.key, required this.storeName, required this.visitId, this.categoryId});
  final String storeName;
  final String visitId;
  final String? categoryId;

  static const stepDegrees = 30.0;
  static const fullTurn = 12; // frames for 360°

  @override
  State<SphereCaptureScreen> createState() => _SphereCaptureScreenState();
}

class _Shot {
  const _Shot(this.path, this.yaw);
  final String path;
  final double yaw;
}

class _SphereCaptureScreenState extends State<SphereCaptureScreen> {
  // One id for this sphere: a retried upload cannot create a second capture.
  final String _clientCaptureId = newClientId();
  CameraController? _controller;
  StreamSubscription<GyroscopeEvent>? _gyro;
  String? _error;
  double _yaw = 0; // degrees turned since start, either direction
  double _rate = 0; // rad/s around the vertical axis
  DateTime? _lastEvent;
  bool _started = false;
  bool _capturing = false;
  bool _uploading = false;
  final List<_Shot> _shots = [];

  int get _next => _shots.length;
  bool get _complete => _shots.length >= SphereCaptureScreen.fullTurn;
  bool get _tooFast => _rate.abs() > 0.6;

  @override
  void initState() {
    super.initState();
    _startCamera();
    _gyro = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen(_onGyro, onError: (_) {
      if (mounted) setState(() => _error = 'This phone has no gyroscope, so the sphere cannot be guided.');
    });
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      final controller = CameraController(camera, ResolutionPreset.high,
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

  void _onGyro(GyroscopeEvent event) {
    final now = event.timestamp;
    final last = _lastEvent;
    _lastEvent = now;
    if (last == null || !_started) return;
    final seconds = now.difference(last).inMicroseconds / 1e6;
    if (seconds <= 0 || seconds > 0.5) return;
    // Held upright, turning on the spot rotates the phone around its own y axis.
    _rate = event.y;
    _yaw += (event.y * seconds).abs() * 180 / math.pi;
    if (mounted) setState(() {});
    final target = _next * SphereCaptureScreen.stepDegrees;
    if (!_complete && !_capturing && !_tooFast && _yaw >= target - 3) _shoot();
  }

  Future<void> _start() async {
    setState(() {
      _started = true;
      _yaw = 0;
    });
    await _shoot();
  }

  Future<void> _shoot() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) return;
    _capturing = true;
    final yaw = _yaw;
    try {
      final photo = await controller.takePicture();
      if (mounted) setState(() => _shots.add(_Shot(photo.path, yaw)));
      if (_complete) await _finish();
    } on CameraException {
      // The next gyroscope event retries this position.
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
    try {
      final capture = await PlatformApi.instance.uploadSphere(
        visitId: widget.visitId,
        framePaths: [for (final s in _shots) s.path],
        yaws: [for (final s in _shots) s.yaw],
        clientCaptureId: _clientCaptureId,
        categoryId: widget.categoryId,
      );
      for (final s in _shots) {
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
    _controller?.dispose();
    super.dispose();
  }

  String get _instruction {
    if (_error != null) return _error!;
    if (_uploading) return 'Stitching the sphere…';
    if (!_started) return 'Stand in the middle of the aisle, hold the phone upright at shelf height, then tap Start.';
    if (_tooFast) return 'Slow down — turn more slowly';
    if (_complete) return 'Full turn captured';
    return 'Turn slowly on the spot · photo ${_shots.length + 1} of ${SphereCaptureScreen.fullTurn}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: const Color(0xFF07101F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF07101F),
        foregroundColor: Colors.white,
        title: Text(t('360° photo sphere'), style: TextStyle(color: Colors.white)),
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
                  child: Stack(
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
                      const Center(child: Icon(Icons.add_rounded, color: Colors.white70, size: 40)),
                      Positioned(
                        left: 16,
                        right: 16,
                        top: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: _tooFast && _started ? AppColors.amber : const Color(0xD9111827),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(_instruction,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      if (_uploading) const Center(child: CircularProgressIndicator(color: AppColors.emerald)),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: CustomPaint(
                      painter: SphereProgressPainter(
                        captured: _shots.length,
                        total: SphereCaptureScreen.fullTurn,
                        yaw: _yaw,
                      ),
                    ),
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
                            onPressed: _shots.length < 2 || _uploading ? null : _finish,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.emerald,
                              foregroundColor: AppColors.navy,
                              minimumSize: const Size.fromHeight(52),
                              shape: const StadiumBorder(),
                            ),
                            icon: const Icon(Icons.check_rounded),
                            label: Text(_uploading ? 'Stitching…' : 'Finish (${_shots.length} photos)'),
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

/// Ring of the frames to take; filled ones are taken, the needle is how far the officer has turned.
class SphereProgressPainter extends CustomPainter {
  const SphereProgressPainter({required this.captured, required this.total, required this.yaw});
  final int captured;
  final int total;
  final double yaw;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 8;
    canvas.drawCircle(centre, radius, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white24);
    for (var i = 0; i < total; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / total;
      final point = centre + Offset(math.cos(angle), math.sin(angle)) * radius;
      canvas.drawCircle(point, 6, Paint()..color = i < captured ? AppColors.emerald : Colors.white30);
    }
    final needle = -math.pi / 2 + (yaw % 360) * math.pi / 180;
    canvas.drawLine(centre, centre + Offset(math.cos(needle), math.sin(needle)) * (radius - 10), Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white);
    final label = TextPainter(
      text: TextSpan(text: '${yaw.round()}°', style: const TextStyle(color: Colors.white, fontSize: AppFontSize.sm)),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, centre + Offset(-label.width / 2, 8));
  }

  @override
  bool shouldRepaint(covariant SphereProgressPainter old) =>
      old.captured != captured || old.yaw != yaw || old.total != total;
}
