import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'package:image_picker/image_picker.dart';

import '../models/field_models.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import 'live_scan_screen.dart';
import 'review_screen.dart';
import 'sphere_capture_screen.dart';

/// Step 2 of the visit: photograph the racks. Each photo remembers which rack it
/// shows; "Mixed rack" (the default) lets the server identify every product on it.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.storeName,
    required this.storeTypeName,
    required this.visitId,
  });
  final String storeName;
  final String storeTypeName;
  final String visitId;
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();
  final List<CapturedPhoto> _photos = [];
  final List<Map<String, dynamic>> _spheres = [];
  String? _rackId;
  String? _rackName;
  List<Map<String, dynamic>>? _categories;
  CameraController? _cameraController;
  String? _cameraError;
  bool _initializingCamera = false;
  bool _capturing = false;
  bool _flash = false;
  bool _grid = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed &&
        _cameraController == null) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (_initializingCamera) return;
    _initializingCamera = true;
    setState(() => _cameraError = null);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('noCamera', 'No camera found');
      }
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _cameraController = controller);
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _cameraError = error.code == 'CameraAccessDenied'
            ? 'Camera permission is required to capture the shelf.'
            : 'Could not start the camera. Please try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameraError = 'Could not start the camera. Please try again.';
      });
    } finally {
      _initializingCamera = false;
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) await controller.dispose();
  }

  Future<void> _toggleFlash() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final enabled = !_flash;
    try {
      await controller.setFlashMode(enabled ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _flash = enabled);
    } on CameraException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Flash is not available on this camera.'))),
      );
    }
  }

  Future<void> _takePhoto() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final photo = await controller.takePicture();
      if (mounted) setState(() => _photos.add(_photo(photo.path)));
    } on CameraException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Photo could not be captured. Try again.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _pickFromGallery() async {
    final photos = await _picker.pickMultiImage(
      imageQuality: 88,
      maxWidth: 2400,
    );
    if (photos.isNotEmpty && mounted) {
      setState(() => _photos.addAll(photos.map((photo) => _photo(photo.path))));
    }
  }

  /// Live scan and the photo sphere need the camera, so this screen releases it meanwhile.
  Future<T?> _withCameraReleased<T>(Route<T> route) async {
    final navigator = Navigator.of(context);
    await _disposeCamera();
    if (mounted) setState(() {});
    final result = await navigator.push<T>(route);
    if (mounted) await _initializeCamera();
    return result;
  }

  Future<void> _liveScan() async {
    final kept = await _withCameraReleased<List<String>>(MaterialPageRoute(
      builder: (_) => LiveScanScreen(storeName: widget.storeName, categoryId: _rackId),
    ));
    if (kept != null && kept.isNotEmpty && mounted) setState(() => _photos.addAll(kept.map(_photo)));
  }

  Future<void> _sphere() async {
    final capture = await _withCameraReleased<Map<String, dynamic>>(MaterialPageRoute(
      builder: (_) => SphereCaptureScreen(storeName: widget.storeName, visitId: widget.visitId, categoryId: _rackId),
    ));
    if (capture != null && mounted && !_spheres.any((s) => s['id'] == capture['id'])) {
      setState(() => _spheres.add(capture));
    }
  }

  CapturedPhoto _photo(String path) =>
      CapturedPhoto(path: path, categoryId: _rackId, categoryName: _rackName);

  /// Which rack the next photos show. Optional: a mixed rack is identified product by product.
  Future<void> _pickRack() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      _categories ??= (await PlatformApi.instance.categories())
          .where((c) => (c['level'] as int) >= 1)
          .toList();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    if (!mounted) return;
    final choice = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .7),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(t('Which rack is this?'), style: Theme.of(context).textTheme.titleLarge),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: const Icon(Icons.auto_awesome_mosaic_outlined),
                title: Text(t('All products')),
                subtitle: Text(t('Identify every product on it')),
                onTap: () => Navigator.of(context).pop(const <String, dynamic>{}),
              ),
              for (final c in _categories!)
                ListTile(
                  contentPadding: EdgeInsets.only(left: 20.0 + 16 * ((c['level'] as int) - 1), right: 20),
                  title: Text(c['name'] as String),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).pop(c),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      _rackId = choice['id'] as String?;
      _rackName = choice['name'] as String?;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  bool get _hasCaptures => _photos.isNotEmpty || _spheres.isNotEmpty;

  void _review() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ReviewScreen(
        storeName: widget.storeName,
        storeTypeName: widget.storeTypeName,
        visitId: widget.visitId,
        photos: List.unmodifiable(_photos),
        spheres: List.unmodifiable(_spheres),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final captures = _photos.length + _spheres.length;
    return Scaffold(
      backgroundColor: _camBackground,
      appBar: AppBar(
        backgroundColor: _camBackground,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('Shelf photos'), style: TextStyle(color: Colors.white)),
            Text(
              '${widget.storeName} · ${widget.storeTypeName}',
              style: AppText.small.copyWith(color: Colors.white60),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _flash ? 'Flash on' : 'Flash off',
            onPressed: _toggleFlash,
            icon: Icon(_flash ? Icons.flash_on_rounded : Icons.flash_off_rounded),
          ),
          IconButton(
            tooltip: _grid ? 'Hide grid' : 'Show grid',
            onPressed: () => setState(() => _grid = !_grid),
            icon: Icon(_grid ? Icons.grid_on_rounded : Icons.grid_off_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildCameraPreview(),
                      if (_grid) const Positioned.fill(child: CustomPaint(painter: _GridPainter())),
                      Positioned(
                        top: AppSpace.md,
                        left: AppSpace.md,
                        child: _OverlayChip(
                          key: const Key('rack-selector'),
                          label: 'Rack: ${_rackName ?? 'All products'}',
                          trailing: Icons.expand_more_rounded,
                          onTap: _pickRack,
                        ),
                      ),
                      if (!_hasCaptures)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: AppSpace.lg,
                          child: Center(
                            child: _OverlayChip(label: t('One section at a time · avoid glare')),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.lg, AppSpace.xl, AppSpace.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SideAction(icon: Icons.photo_library_outlined, label: t('Gallery'), onTap: _pickFromGallery),
                  _Shutter(busy: _capturing, onTap: _takePhoto),
                  _SideAction(
                    icon: Icons.arrow_forward_rounded,
                    count: captures,
                    label: t('Next'),
                    onTap: _hasCaptures ? _review : null,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ModeLink(key: const Key('live-scan'), label: t('Live scan'), onTap: _liveScan),
                  const Text('·', style: TextStyle(color: Colors.white38)),
                  _ModeLink(
                    key: const Key('photo-sphere'),
                    label: _spheres.isEmpty ? '360° sphere' : '360° sphere (${_spheres.length})',
                    onTap: _sphere,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraController;
    if (_cameraError != null) {
      return ColoredBox(
        color: const Color(0xFF111827),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.no_photography_outlined,
                  color: Colors.white70,
                  size: 42,
                ),
                const SizedBox(height: 12),
                Text(
                  _cameraError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _initializeCamera,
                  child: Text(t('Try again')),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(
        color: Color(0xFF111827),
        child: Center(
          child: CircularProgressIndicator(color: AppColors.emerald),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final previewSize = controller.value.previewSize!;
        return FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: previewSize.height,
            height: previewSize.width,
            child: CameraPreview(controller),
          ),
        );
      },
    );
  }
}

const _camBackground = Color(0xFF07101F);
const _camSurface = Color(0xB3111827);

/// Small translucent label over the viewfinder; tappable when [onTap] is set.
class _OverlayChip extends StatelessWidget {
  const _OverlayChip({super.key, required this.label, this.trailing, this.onTap});
  final String label;
  final IconData? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: _camSurface,
    borderRadius: BorderRadius.circular(AppRadius.pill),
    child: InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.small.copyWith(color: Colors.white, fontWeight: FontWeight.w500),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 2),
              Icon(trailing, size: 16, color: Colors.white70),
            ],
          ],
        ),
      ),
    ),
  );
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: t('Take photo'),
    child: GestureDetector(
      key: const Key('capture-button'),
      onTap: onTap,
      child: Container(
        width: 76,
        height: 76,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: _camBackground),
                )
              : null,
        ),
      ),
    ),
  );
}

/// Gallery on the left of the shutter, Review on the right. Review shows the
/// capture count and stays dimmed until there is something to review.
class _SideAction extends StatelessWidget {
  const _SideAction({required this.icon, required this.label, required this.onTap, this.count});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final hasCount = count != null && count! > 0;
    return Opacity(
      opacity: enabled ? 1 : .4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: SizedBox(
          width: 64,
          child: Column(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: hasCount ? Colors.white : Colors.white12,
                  shape: BoxShape.circle,
                ),
                child: hasCount
                    ? Text('$count', style: AppText.label.copyWith(color: _camBackground))
                    : Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(height: 6),
              Text(label, style: AppText.small.copyWith(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Alternative capture modes, as quiet text under the shutter.
class _ModeLink extends StatelessWidget {
  const _ModeLink({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(foregroundColor: Colors.white70),
    child: Text(label, style: AppText.small.copyWith(color: Colors.white70, fontWeight: FontWeight.w500)),
  );
}

class _GridPainter extends CustomPainter {
  const _GridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .22)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(size.width * i / 3, 0),
        Offset(size.width * i / 3, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(0, size.height * i / 3),
        Offset(size.width, size.height * i / 3),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
