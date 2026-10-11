import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'package:panorama_viewer/panorama_viewer.dart';

import '../services/platform_api.dart';
import '../theme/app_theme.dart';

/// Placement of a stitched panorama on the viewing sphere. The panorama covers
/// [horizontalDegrees] × [verticalDegrees]; it is centred on the horizon.
class SphereGeometry {
  const SphereGeometry({required this.horizontalDegrees, required this.verticalDegrees});

  factory SphereGeometry.fromCapture(Map<String, dynamic> capture) {
    final sphere = capture['sphere'] as Map<String, dynamic>? ?? const {};
    return SphereGeometry(
      horizontalDegrees: (sphere['horizontal_degrees'] as num? ?? 360).toDouble(),
      verticalDegrees: (sphere['vertical_degrees'] as num? ?? 60).toDouble(),
    );
  }

  final double horizontalDegrees;
  final double verticalDegrees;

  // In units of the panorama's width (1.0) and height (vertical/horizontal of it).
  double get fullWidth => 360 / horizontalDegrees;
  double get fullHeight => fullWidth / 2;
  double get height => verticalDegrees / horizontalDegrees;
  Rect get croppedArea => Rect.fromLTWH((fullWidth - 1) / 2, (fullHeight - height) / 2, 1, height);

  /// Viewer coordinates of a point given as fractions of the panorama.
  ({double longitude, double latitude}) position(double x, double y) =>
      (longitude: (x - 0.5) * horizontalDegrees, latitude: (0.5 - y) * verticalDegrees);
}

/// Shows a photo sphere in 360°: drag or move the phone to look around. Recognised products
/// are pinned where they are once the server has analysed the panorama.
class SphereViewerScreen extends StatefulWidget {
  const SphereViewerScreen({super.key, required this.capture, required this.storeName});
  final Map<String, dynamic> capture;
  final String storeName;

  @override
  State<SphereViewerScreen> createState() => _SphereViewerScreenState();
}

class _SphereViewerScreenState extends State<SphereViewerScreen> {
  late Map<String, dynamic> _capture = widget.capture;
  Uint8List? _image;
  Map<String, String> _names = const {};
  Timer? _poll;
  bool _gyroLook = false;
  String? _error;

  String get _id => widget.capture['id'] as String;
  bool get _analysed => _capture['status'] == 'analysed' || _capture['status'] == 'failed';

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final capture = await PlatformApi.instance.capture(_id);
      if (_names.isEmpty) {
        _names = {for (final p in await PlatformApi.instance.products()) p['id'] as String: p['name'] as String};
      }
      final annotated = (capture['inference'] as Map?)?['annotated_url'] as String?;
      final ready = capture['status'] == 'analysed' || capture['status'] == 'failed';
      if (_image == null || (ready && annotated != null)) {
        final bytes = await PlatformApi.instance.imageBytes(annotated ?? '/v2/captures/$_id/image');
        if (mounted) setState(() => _image = bytes);
      }
      if (!mounted) return;
      setState(() {
        _capture = capture;
        _error = null;
      });
      if (ready) _poll?.cancel();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  List<Map<String, dynamic>> get _identified => ((_capture['detections'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .where((d) => (d['final'] as Map)['product_id'] != null && d['verification'] != 'rejected')
      .toList();

  @override
  Widget build(BuildContext context) {
    final geometry = SphereGeometry.fromCapture(_capture);
    final sphere = _capture['sphere'] as Map<String, dynamic>? ?? const {};
    final identified = _identified;
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('360° · ${widget.storeName}', style: const TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            tooltip: _gyroLook ? 'Look around by dragging' : 'Look around by moving the phone',
            onPressed: () => setState(() => _gyroLook = !_gyroLook),
            icon: Icon(_gyroLook ? Icons.touch_app_outlined : Icons.screen_rotation_alt_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: image == null
                ? Center(
                    child: _error != null
                        ? Text(_error!, style: const TextStyle(color: Colors.white))
                        : const CircularProgressIndicator(color: AppColors.emerald),
                  )
                : PanoramaViewer(
                    key: ValueKey(image.length),
                    sensorControl: _gyroLook ? SensorControl.orientation : SensorControl.none,
                    croppedArea: geometry.croppedArea,
                    croppedFullWidth: geometry.fullWidth,
                    croppedFullHeight: geometry.fullHeight,
                    minLatitude: -geometry.verticalDegrees / 2,
                    maxLatitude: geometry.verticalDegrees / 2,
                    hotspots: [
                      for (final d in identified)
                        _hotspot(geometry, d, _names[(d['final'] as Map)['product_id']] ?? 'Product'),
                    ],
                    child: Image.memory(image),
                  ),
          ),
          Container(
            width: double.infinity,
            color: const Color(0xFF07101F),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _analysed
                        ? '${identified.where((d) => (d['final'] as Map)['label'] == 'own').length} Square packs '
                              'recognised · ${(_capture['inference'] as Map?)?['detections_total'] ?? 0} boxes in total'
                        : 'Looking for products in the sphere…',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${sphere['frames']} photos · ${(sphere['horizontal_degrees'] as num? ?? 0).round()}° wide'
                    '${sphere['stitched'] == false ? ' · placed side by side (could not stitch)' : ''}',
                    style: const TextStyle(color: Colors.white60, fontSize: AppFontSize.sm),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(_capture),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.emerald,
                      foregroundColor: AppColors.navy,
                      minimumSize: const Size.fromHeight(50),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.check_rounded),
                    label: Text(t('Add to visit')),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Hotspot _hotspot(SphereGeometry geometry, Map<String, dynamic> d, String name) {
    final box = d['box'] as Map;
    final at = geometry.position(
      (box['x'] as num) + (box['width'] as num) / 2,
      (box['y'] as num) + (box['height'] as num) / 2,
    );
    final own = (d['final'] as Map)['label'] == 'own';
    final confidence = (((d['predicted'] as Map)['confidence'] as num) * 100).round();
    return Hotspot(
      latitude: at.latitude,
      longitude: at.longitude,
      width: 150,
      height: 44,
      widget: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: (own ? AppColors.emeraldDark : AppColors.red).withValues(alpha: .9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('$name $confidence%',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: AppFontSize.xs, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
