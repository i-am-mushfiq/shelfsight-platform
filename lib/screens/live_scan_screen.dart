import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../services/platform_api.dart';
import '../theme/app_theme.dart';

/// Live viewfinder: frames go to the platform, which looks each one up against the catalogue
/// pack shots and answers with the products it found, where, and how sure it is. Nothing is
/// stored until the officer keeps a frame; kept frames are returned as photo paths.
class LiveScanScreen extends StatefulWidget {
  const LiveScanScreen({super.key, required this.storeName, this.categoryId});
  final String storeName;
  final String? categoryId;

  @override
  State<LiveScanScreen> createState() => _LiveScanScreenState();
}

class _LiveScanScreenState extends State<LiveScanScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  String? _cameraError;
  String? _networkError;
  bool _running = true;
  bool _looping = false;
  Map<String, dynamic>? _result;
  String? _lastPath;
  int? _roundTripMs;
  final List<String> _kept = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _running = false;
    } else if (state == AppLifecycleState.resumed && !_running && mounted) {
      setState(() => _running = true);
      _loop();
    }
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('noCamera', 'No camera found');
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // Medium resolution keeps each frame small enough for several lookups a second over Wi-Fi.
      final controller = CameraController(camera, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      _loop();
    } catch (_) {
      if (mounted) setState(() => _cameraError = 'Could not start the camera.');
    }
  }

  Future<void> _loop() async {
    if (_looping) return;
    _looping = true;
    while (mounted && _running) {
      await _scanOnce();
    }
    _looping = false;
  }

  Future<void> _scanOnce() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || controller.value.isTakingPicture) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return;
    }
    final watch = Stopwatch()..start();
    try {
      final frame = await controller.takePicture();
      final result = await PlatformApi.instance.liveDetect(frame.path, categoryId: widget.categoryId);
      if (!mounted) return;
      final previous = _lastPath;
      setState(() {
        _result = result;
        _lastPath = frame.path;
        _roundTripMs = watch.elapsedMilliseconds;
        _networkError = null;
      });
      if (previous != null && !_kept.contains(previous)) _delete(previous);
    } on ApiException catch (error) {
      if (mounted) setState(() => _networkError = error.message);
      await Future<void>.delayed(const Duration(seconds: 1));
    } on CameraException {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  void _delete(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Temporary file already gone.
    }
  }

  void _keep() {
    final path = _lastPath;
    if (path == null || _kept.contains(path)) return;
    setState(() => _kept.add(path));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(seconds: 1), content: Text('Photo kept (${_kept.length}).')),
    );
  }

  void _togglePause() {
    setState(() => _running = !_running);
    if (_running) _loop();
  }

  @override
  void dispose() {
    _running = false;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    final last = _lastPath;
    if (last != null && !_kept.contains(last)) _delete(last);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final products = ((result?['summary'] as Map?)?['products'] as List? ?? const []).cast<Map<String, dynamic>>();
    final detections = (result?['detections'] as List? ?? const []).cast<Map<String, dynamic>>();
    return Scaffold(
      backgroundColor: const Color(0xFF07101F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF07101F),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('Live scan'), style: TextStyle(color: Colors.white)),
            Text(widget.storeName,
                style: TextStyle(color: Colors.white.withValues(alpha: .62), fontSize: AppFontSize.sm, fontWeight: FontWeight.w500)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _running ? 'Pause' : 'Resume',
            onPressed: _controller == null ? null : _togglePause,
            icon: Icon(_running ? Icons.pause_rounded : Icons.play_arrow_rounded),
          ),
        ],
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
                      _preview(detections),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: _LivePill(
                          running: _running,
                          text: _networkError ??
                              (_roundTripMs == null
                                  ? 'Starting…'
                                  : 'Scanning'),
                          error: _networkError != null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              constraints: const BoxConstraints(maxHeight: 210),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: products.isEmpty
                  ? Text(
                      result == null
                          ? 'Point the camera at the shelf.'
                          : 'No catalogue product recognised here. Move closer or face the packs straight on.',
                      style: const TextStyle(color: Colors.white70),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        Text(
                          '${(result!['summary'] as Map)['own_facings']} Square packs · '
                          '${products.length} products in view',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        for (final p in products) _ProductRow(product: p),
                      ],
                    ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                t('Green: Square.  Red: another company.  No box: not recognised.'),
                style: TextStyle(color: Colors.white54, fontSize: AppFontSize.xs),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _lastPath == null ? null : _keep,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                        minimumSize: const Size.fromHeight(52),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: Text(t('Keep photo')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(List<String>.unmodifiable(_kept)),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.emerald,
                        foregroundColor: AppColors.navy,
                        minimumSize: const Size.fromHeight(52),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.check_rounded),
                      label: Text('Done (${_kept.length})'),
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

  Widget _preview(List<Map<String, dynamic>> detections) {
    final controller = _controller;
    if (_cameraError != null) {
      return Center(child: Text(_cameraError!, style: const TextStyle(color: Colors.white)));
    }
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: AppColors.emerald));
    }
    final size = controller.value.previewSize!;
    final result = _result;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: size.height,
        height: size.width,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(controller),
            if (result != null)
              CustomPaint(
                painter: LiveDetectionPainter(
                  detections: detections,
                  imageWidth: (result['width'] as num).toDouble(),
                  imageHeight: (result['height'] as num).toDouble(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LivePill extends StatelessWidget {
  const _LivePill({required this.running, required this.text, required this.error});
  final bool running;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xD9111827), borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 9, color: error ? AppColors.amber : (running ? AppColors.red : Colors.white38)),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(
            running ? 'LIVE · $text' : 'PAUSED',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: AppFontSize.sm, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product});
  final Map<String, dynamic> product;

  @override
  Widget build(BuildContext context) {
    final own = product['is_own'] == true;
    final confidence = ((product['best_confidence'] as num) * 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: own ? AppColors.emeraldDark : AppColors.red,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(own ? 'SQUARE' : 'OTHER',
                style: const TextStyle(color: Colors.white, fontSize: AppFontSize.xs, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${product['name']}${(product['facings'] as int) > 1 ? ' × ${product['facings']}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          Text('$confidence%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Draws looked-up products over the preview. The analysed frame is fitted over the preview
/// the way the preview itself is shown (cover, centred), so outlines land on the packs.
class LiveDetectionPainter extends CustomPainter {
  const LiveDetectionPainter({required this.detections, required this.imageWidth, required this.imageHeight});
  final List<Map<String, dynamic>> detections;
  final double imageWidth;
  final double imageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = [size.width / imageWidth, size.height / imageHeight].reduce((a, b) => a > b ? a : b);
    final dx = (size.width - imageWidth * scale) / 2;
    final dy = (size.height - imageHeight * scale) / 2;
    Offset map(num x, num y) => Offset(dx + x * imageWidth * scale, dy + y * imageHeight * scale);
    for (final d in detections) {
      final colour = d['is_own'] == true ? AppColors.emerald : AppColors.red;
      final polygon = (d['polygon'] as List? ?? const []).cast<List>();
      final path = Path();
      if (polygon.length == 4) {
        path.addPolygon([for (final p in polygon) map(p[0] as num, p[1] as num)], true);
      } else {
        final b = d['box'] as Map;
        path.addRect(Rect.fromPoints(map(b['x'] as num, b['y'] as num),
            map((b['x'] as num) + (b['width'] as num), (b['y'] as num) + (b['height'] as num))));
      }
      canvas.drawPath(path, Paint()..color = colour.withValues(alpha: .18));
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = colour);
      final bounds = path.getBounds();
      final label = TextPainter(
        text: TextSpan(
          text: ' ${d['name']} ${((d['confidence'] as num) * 100).round()}% ',
          style: TextStyle(
            fontFamily: AppText.fontFamily,
            color: Colors.white,
            backgroundColor: colour,
            fontSize: AppFontSize.md,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: (bounds.width + 120).clamp(60, size.width));
      label.paint(canvas, Offset(bounds.left.clamp(0, size.width - label.width), (bounds.top - label.height).clamp(0, size.height)));
    }
  }

  @override
  bool shouldRepaint(covariant LiveDetectionPainter old) =>
      old.detections != detections || old.imageWidth != imageWidth || old.imageHeight != imageHeight;
}
