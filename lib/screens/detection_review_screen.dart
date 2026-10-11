import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'visit_report_screen.dart';

Color labelColor(String label, String verification) {
  if (verification == 'rejected') return AppColors.inkSubtle;
  return switch (label) {
    'own' => AppColors.emeraldDark,
    'competitor' => AppColors.red,
    _ => AppColors.amber,
  };
}

/// Human-in-the-loop review, asked one pack at a time. The model's prediction is never overwritten: each
/// action is stored as a correction tied to the model version that made it.
class DetectionReviewScreen extends StatefulWidget {
  const DetectionReviewScreen({
    super.key,
    required this.storeName,
    required this.visitId,
    required this.captureIds,
  });
  final String storeName;
  final String visitId;
  final List<String> captureIds;

  @override
  State<DetectionReviewScreen> createState() => _DetectionReviewScreenState();
}

class _DetectionReviewScreenState extends State<DetectionReviewScreen> {
  final _api = PlatformApi.instance;
  int _photo = 0;
  final Map<String, Map<String, dynamic>> _captures = {};
  final Map<String, Uint8List> _images = {};
  List<Map<String, dynamic>> _products = const [];
  String? _selected; // detection id
  final Set<String> _skipped = {};
  String? _error;
  bool _busy = false;

  String get _captureId => widget.captureIds[_photo];
  Map<String, dynamic>? get _capture => _captures[_captureId];
  List<Map<String, dynamic>> get _detections =>
      ((_capture?['detections'] as List?) ?? const []).cast<Map<String, dynamic>>();
  int get _unverified => _detections.where((d) => d['verification'] == 'unverified').length;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _error = null);
    try {
      _products = await _api.products();
      for (final id in widget.captureIds) {
        _captures[id] = await _api.capture(id);
        if (mounted) setState(() {});
      }
      await _loadImage();
      _selectNext();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _loadImage() async {
    final id = _captureId;
    if (_images.containsKey(id)) return;
    try {
      final bytes = await _api.imageBytes('/v2/captures/$id/image');
      if (mounted) setState(() => _images[id] = bytes);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  /// The next pack to ask about. Skipped packs come back once the others are answered.
  void _selectNext() {
    final pending = _detections.where((d) => d['needs_review'] == true).toList();
    if (pending.isNotEmpty && pending.every((d) => _skipped.contains(d['id']))) _skipped.clear();
    final next = pending.where((d) => !_skipped.contains(d['id'])).firstOrNull;
    setState(() => _selected = next?['id'] as String?);
  }

  Map<String, dynamic>? get _current =>
      _detections.where((d) => d['id'] == _selected).firstOrNull;

  Future<void> _review(String action, {String? label, String? productId}) async {
    final detection = _current;
    if (detection == null || _busy) return;
    setState(() => _busy = true);
    try {
      final updated = await _api.reviewDetection(
        detection['id'] as String,
        action,
        label: label,
        productId: productId,
      );
      final list = _capture!['detections'] as List;
      list[list.indexWhere((d) => (d as Map)['id'] == detection['id'])] = updated;
      _selectNext();
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Confirms every detection on this photo that the model was confident about.
  Future<void> _confirmConfident() async {
    setState(() => _busy = true);
    final list = _capture!['detections'] as List;
    try {
      for (var i = 0; i < list.length; i++) {
        final d = list[i] as Map<String, dynamic>;
        if (d['verification'] != 'unverified' || d['needs_review'] == true) continue;
        list[i] = await _api.reviewDetection(d['id'] as String, 'confirm');
        if (mounted) setState(() {});
      }
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickProduct() async {
    final product = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => _ProductPicker(products: _products),
    );
    if (product != null) await _review('correct', productId: product['id'] as String);
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await _api.submitVisit(widget.visitId);
      await UploadQueue.instance.clearVisit(widget.visitId);
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => VisitReportScreen(
            visitId: widget.visitId,
            report: result['report'] as Map<String, dynamic>,
            closeToOutlet: true,
          ),
        ),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      if (mounted) setState(() => _busy = false);
    }
  }

  String _productName(String? id) =>
      _products.where((p) => p['id'] == id).map((p) => p['name'] as String).firstOrNull ?? '';

  /// Packs on this photo that still need an answer (skipped ones come back last).
  List<Map<String, dynamic>> get _pending => _detections.where((d) => d['needs_review'] == true).toList();

  int? get _nextPhotoWithWork {
    for (var i = 1; i <= widget.captureIds.length; i++) {
      final index = (_photo + i) % widget.captureIds.length;
      if (index == _photo) break;
      final detections = ((_captures[widget.captureIds[index]]?['detections'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      if (detections.any((d) => d['needs_review'] == true)) return index;
    }
    return null;
  }

  Future<void> _goToPhoto(int index) async {
    setState(() {
      _photo = index;
      _selected = null;
      _skipped.clear();
    });
    await _loadImage();
    _selectNext();
  }

  void _skip() {
    final current = _selected;
    if (current == null) return;
    _skipped.add(current);
    _selectNext();
  }

  @override
  Widget build(BuildContext context) {
    final capture = _capture;
    final image = _images[_captureId];
    final current = _current;
    final pending = _pending;
    final position = current == null ? 0 : pending.indexWhere((d) => d['id'] == current['id']) + 1;
    final nextPhoto = _nextPhotoWithWork;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('Check the results')),
            Text(
              [
                if (widget.captureIds.length > 1) 'Photo ${_photo + 1} of ${widget.captureIds.length}',
                pending.isEmpty ? 'All checked' : '${pending.length} to check',
              ].join(' · '),
              style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 12),
          child: PrimaryButton(
            label: _busy ? 'Please wait…' : 'Finish visit',
            icon: Icons.flag_outlined,
            onPressed: _busy || capture == null ? null : _submit,
          ),
        ),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    PrimaryButton(label: t('Try again'), onPressed: _loadAll),
                  ],
                ),
              ),
            )
          : capture == null || image == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 4, AppSpace.page, AppSpace.xl),
              children: [
                if (current != null) ...[
                  _PackZoom(image: image, capture: capture, detection: current),
                  const SizedBox(height: AppSpace.lg),
                  _Question(
                    detection: current,
                    productName: _productName((current['final'] as Map)['product_id'] as String?),
                    position: position,
                    total: pending.length,
                    busy: _busy,
                    onConfirm: (current['predicted'] as Map)['label'] == 'unknown' ? null : () => _review('confirm'),
                    onOwn: () => _review('correct', label: 'own'),
                    onCompetitor: () => _review('correct', label: 'competitor'),
                    onReject: () => _review('reject'),
                    onPickProduct: _pickProduct,
                    onSkip: pending.length > 1 ? _skip : null,
                  ),
                ] else
                  _Done(
                    nextPhoto: nextPhoto == null ? null : nextPhoto + 1,
                    unverified: _unverified,
                    busy: _busy,
                    onNextPhoto: nextPhoto == null ? null : () => _goToPhoto(nextPhoto),
                    onConfirmRest: _confirmConfident,
                  ),
                const SizedBox(height: AppSpace.section),
                Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    t('Where it is on the shelf'),
                    style: TextStyle(fontSize: AppFontSize.md, fontWeight: FontWeight.w500, color: AppColors.inkMuted),
                  ),
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  child: AspectRatio(
                    aspectRatio: (capture['width'] as num) / (capture['height'] as num),
                    child: LayoutBuilder(
                      builder: (context, box) => GestureDetector(
                        onTapUp: (tap) {
                          final x = tap.localPosition.dx / box.maxWidth;
                          final y = tap.localPosition.dy / box.maxHeight;
                          // Smallest box under the finger wins.
                          Map<String, dynamic>? hit;
                          for (final d in _detections) {
                            final b = d['box'] as Map;
                            final inside = x >= b['x'] && x <= b['x'] + b['width'] &&
                                y >= b['y'] && y <= b['y'] + b['height'];
                            if (inside &&
                                (hit == null ||
                                    b['width'] * b['height'] <
                                        (hit['box'] as Map)['width'] * (hit['box'] as Map)['height'])) {
                              hit = d;
                            }
                          }
                          if (hit != null) setState(() => _selected = hit!['id'] as String);
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(image, fit: BoxFit.fill, gaplessPlayback: true),
                            CustomPaint(painter: _BoxPainter(_detections, _selected)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    _Legend(color: AppColors.emeraldDark, label: t('Square')),
                    _Legend(color: AppColors.red, label: t('Other company')),
                    _Legend(color: AppColors.amber, label: t('Not sure')),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  t('Tap any box on the photo to check that pack.'),
                  style: TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                ),
              ],
            ),
    );
  }
}

/// The pack being asked about, cut out of the shelf photo and enlarged.
class _PackZoom extends StatelessWidget {
  const _PackZoom({required this.image, required this.capture, required this.detection});
  final Uint8List image;
  final Map<String, dynamic> capture;
  final Map<String, dynamic> detection;

  @override
  Widget build(BuildContext context) {
    final b = detection['box'] as Map;
    final x = (b['x'] as num).toDouble(), y = (b['y'] as num).toDouble();
    final w = (b['width'] as num).toDouble(), h = (b['height'] as num).toDouble();
    final aspect = (capture['width'] as num) / (capture['height'] as num);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        height: 240,
        color: AppColors.navy,
        child: LayoutBuilder(
          builder: (context, view) {
            // Scale the photo so the pack fills about two thirds of the view, centred.
            var width = view.maxWidth * .66 / w;
            var height = width / aspect;
            if (h * height > view.maxHeight * .8) {
              height = view.maxHeight * .8 / h;
              width = height * aspect;
            }
            final left = view.maxWidth / 2 - (x + w / 2) * width;
            final top = view.maxHeight / 2 - (y + h / 2) * height;
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: width,
                  height: height,
                  child: Image.memory(image, fit: BoxFit.fill, gaplessPlayback: true),
                ),
                Positioned(
                  left: left + x * width - 4,
                  top: top + y * height - 4,
                  width: w * width + 8,
                  height: h * height + 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _certainty(num confidence) => confidence >= .85
    ? 'Sure'
    : confidence >= .6
    ? 'Probably'
    : 'Not sure';

/// One question about one pack, with answers as big, plain buttons.
class _Question extends StatelessWidget {
  const _Question({
    required this.detection,
    required this.productName,
    required this.position,
    required this.total,
    required this.busy,
    required this.onConfirm,
    required this.onOwn,
    required this.onCompetitor,
    required this.onReject,
    required this.onPickProduct,
    required this.onSkip,
  });
  final Map<String, dynamic> detection;
  final String productName;
  final int position;
  final int total;
  final bool busy;
  final VoidCallback? onConfirm;
  final VoidCallback onOwn;
  final VoidCallback onCompetitor;
  final VoidCallback onReject;
  final VoidCallback onPickProduct;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final predicted = detection['predicted'] as Map;
    final label = predicted['label'] as String;
    final guess = switch (label) {
      'own' => productName.isEmpty ? 'a Square product' : productName,
      'competitor' => productName.isEmpty ? "another company's product" : productName,
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Pack $position of $total',
          style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
        ),
        const SizedBox(height: 4),
        Text(
          guess == null ? 'What is this pack?' : 'Is this $guess?',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (guess != null) ...[
          const SizedBox(height: 4),
          Text(
            'Our guess · ${_certainty(predicted['confidence'] as num)}',
            style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        if (onConfirm != null) ...[
          FilledButton.icon(
            onPressed: busy ? null : onConfirm,
            icon: const Icon(Icons.check_rounded),
            label: Text(t('Yes, that is right')),
          ),
          const SizedBox(height: AppSpace.sm),
        ],
        _Answer(
          icon: Icons.verified_outlined,
          text: label == 'own' ? 'No, it is another company' : 'It is a Square product',
          onPressed: busy ? null : (label == 'own' ? onCompetitor : onOwn),
        ),
        if (label == 'unknown') ...[
          const SizedBox(height: AppSpace.sm),
          _Answer(icon: Icons.storefront_outlined, text: "It is another company's", onPressed: busy ? null : onCompetitor),
        ],
        const SizedBox(height: AppSpace.sm),
        _Answer(icon: Icons.block_rounded, text: t('It is not a product'), onPressed: busy ? null : onReject),
        const SizedBox(height: AppSpace.xs),
        Row(
          children: [
            TextButton(onPressed: busy ? null : onPickProduct, child: Text(t('Choose the exact product'))),
            const Spacer(),
            if (onSkip != null) TextButton(onPressed: busy ? null : onSkip, child: Text(t('Skip'))),
          ],
        ),
      ],
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer({required this.icon, required this.text, required this.onPressed});
  final IconData icon;
  final String text;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, backgroundColor: AppColors.surface),
    icon: Icon(icon, size: 20),
    label: Text(text),
  );
}

/// Shown when nothing on this photo needs an answer.
class _Done extends StatelessWidget {
  const _Done({
    required this.nextPhoto,
    required this.unverified,
    required this.busy,
    required this.onNextPhoto,
    required this.onConfirmRest,
  });
  final int? nextPhoto;
  final int unverified;
  final bool busy;
  final VoidCallback? onNextPhoto;
  final VoidCallback onConfirmRest;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_outline_rounded, color: AppColors.emeraldDark, size: 32),
        const SizedBox(height: AppSpace.sm),
        Text(
          nextPhoto == null ? 'Everything is checked' : 'This photo is done',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          nextPhoto == null
              ? 'Tap Finish visit to see the result and the order.'
              : 'Photo $nextPhoto still has packs to check.',
          style: const TextStyle(color: AppColors.inkMuted),
        ),
        if (onNextPhoto != null) ...[
          const SizedBox(height: AppSpace.lg),
          FilledButton(onPressed: onNextPhoto, child: Text('Go to photo $nextPhoto')),
        ],
        if (unverified > 0) ...[
          const SizedBox(height: AppSpace.sm),
          TextButton(
            onPressed: busy ? null : onConfirmRest,
            child: Text(t('The other packs look right')),
          ),
        ],
      ],
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 12, height: 12, decoration: BoxDecoration(border: Border.all(color: color, width: 2.5))),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
    ],
  );
}

class _BoxPainter extends CustomPainter {
  const _BoxPainter(this.detections, this.selected);
  final List<Map<String, dynamic>> detections;
  final String? selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in detections) {
      final b = d['box'] as Map;
      final rect = Rect.fromLTWH(
        (b['x'] as num) * size.width,
        (b['y'] as num) * size.height,
        (b['width'] as num) * size.width,
        (b['height'] as num) * size.height,
      );
      final color = labelColor((d['final'] as Map)['label'] as String, d['verification'] as String);
      final isSelected = d['id'] == selected;
      if (isSelected) {
        canvas.drawRect(rect, Paint()..color = color.withValues(alpha: .25));
      }
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSelected ? 4 : (d['verification'] == 'unverified' ? 2 : 3)
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => true;
}

class _ProductPicker extends StatefulWidget {
  const _ProductPicker({required this.products});
  final List<Map<String, dynamic>> products;
  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final needle = _query.toLowerCase();
    final matches = widget.products
        .where((p) =>
            needle.isEmpty ||
            (p['name'] as String).toLowerCase().contains(needle) ||
            (p['brand'] as String).toLowerCase().contains(needle))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  autofocus: true,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: t('Search product or brand'),
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final p = matches[index];
                    return ListTile(
                      leading: Icon(
                        Icons.circle,
                        size: 12,
                        color: p['is_own'] == true ? AppColors.emeraldDark : AppColors.red,
                      ),
                      title: Text(p['name'] as String),
                      subtitle: Text('${p['manufacturer']} · ${p['category']}'),
                      onTap: () => Navigator.of(context).pop(p),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
