import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'audit_result_screen.dart';

Color labelColor(String label, String verification) {
  if (verification == 'rejected') return const Color(0xFF94A3B8);
  return switch (label) {
    'own' => AppColors.emeraldDark,
    'competitor' => AppColors.red,
    _ => AppColors.amber,
  };
}

/// Human-in-the-loop review. The model's prediction is never overwritten: each
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
  String? _error;
  bool _busy = false;

  String get _captureId => widget.captureIds[_photo];
  Map<String, dynamic>? get _capture => _captures[_captureId];
  List<Map<String, dynamic>> get _detections =>
      ((_capture?['detections'] as List?) ?? const []).cast<Map<String, dynamic>>();
  int get _needReview => _detections.where((d) => d['needs_review'] == true).length;
  int get _unverified => _detections.where((d) => d['verification'] == 'unverified').length;

  int get _totalNeedReview => _captures.values
      .expand((c) => ((c['detections'] as List?) ?? const []).cast<Map<String, dynamic>>())
      .where((d) => d['needs_review'] == true)
      .length;

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

  void _selectNext() {
    final next = _detections.where((d) => d['needs_review'] == true).firstOrNull;
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
          builder: (_) => AuditResultScreen(
            storeName: widget.storeName,
            intelligence: result['intelligence'] as Map<String, dynamic>,
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

  @override
  Widget build(BuildContext context) {
    final capture = _capture;
    final image = _images[_captureId];
    final current = _current;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Review detections'),
            Text(
              'Photo ${_photo + 1} of ${widget.captureIds.length} · $_needReview need review',
              style: const TextStyle(fontSize: 12, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          if (widget.captureIds.length > 1)
            IconButton(
              tooltip: 'Next photo',
              onPressed: () async {
                setState(() {
                  _photo = (_photo + 1) % widget.captureIds.length;
                  _selected = null;
                });
                await _loadImage();
                _selectNext();
              },
              icon: const Icon(Icons.navigate_next_rounded),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: PrimaryButton(
            label: _totalNeedReview > 0
                ? 'Submit visit ($_totalNeedReview still uncertain)'
                : 'Submit verified audit',
            icon: Icons.check_rounded,
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
                    PrimaryButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: _loadAll),
                  ],
                ),
              ),
            )
          : capture == null || image == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
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
                const SizedBox(height: 8),
                const Wrap(
                  spacing: 12,
                  children: [
                    _Legend(color: AppColors.emeraldDark, label: 'Own'),
                    _Legend(color: AppColors.red, label: 'Competitor'),
                    _Legend(color: AppColors.amber, label: 'Uncertain'),
                    _Legend(color: Color(0xFF94A3B8), label: 'Not a product'),
                  ],
                ),
                const SizedBox(height: 12),
                if (current == null)
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _needReview == 0
                              ? 'Nothing left that needs review on this photo.'
                              : 'Tap a box to review it.',
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink),
                        ),
                        if (_unverified > 0) ...[
                          const SizedBox(height: 8),
                          Text(
                            '$_unverified confident detection(s) are not yet human-verified. '
                            'Check the boxes, then confirm them to put this audit on a verified basis.',
                            style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _confirmConfident,
                            icon: const Icon(Icons.done_all_rounded),
                            label: const Text('Boxes look right: confirm them'),
                          ),
                        ],
                      ],
                    ),
                  )
                else
                  _ReviewPanel(
                    detection: current,
                    productName: _productName((current['final'] as Map)['product_id'] as String?),
                    busy: _busy,
                    onOwn: () => _review('correct', label: 'own'),
                    onCompetitor: () => _review('correct', label: 'competitor'),
                    onReject: () => _review('reject'),
                    onConfirm: (current['predicted'] as Map)['label'] == 'unknown'
                        ? null
                        : () => _review('confirm'),
                    onPickProduct: _pickProduct,
                  ),
              ],
            ),
    );
  }
}

class _ReviewPanel extends StatelessWidget {
  const _ReviewPanel({
    required this.detection,
    required this.productName,
    required this.busy,
    required this.onOwn,
    required this.onCompetitor,
    required this.onReject,
    required this.onConfirm,
    required this.onPickProduct,
  });
  final Map<String, dynamic> detection;
  final String productName;
  final bool busy;
  final VoidCallback onOwn;
  final VoidCallback onCompetitor;
  final VoidCallback onReject;
  final VoidCallback? onConfirm;
  final VoidCallback onPickProduct;

  @override
  Widget build(BuildContext context) {
    final predicted = detection['predicted'] as Map;
    final finalLabel = (detection['final'] as Map)['label'] as String;
    final verification = detection['verification'] as String;
    final confidence = ((predicted['confidence'] as num) * 100).round();
    return SurfaceCard(
      borderColor: labelColor(finalLabel, verification),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            verification == 'unverified'
                ? 'Model says: ${predicted['label']} ($confidence% confident)'
                : 'Reviewed: ${verification == 'rejected' ? 'not a product' : finalLabel}'
                      '${productName.isEmpty ? '' : ' · $productName'}',
            style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink),
          ),
          Text(
            'Shelf row ${detection['shelf_row']} of ${detection['shelf_rows_total']} (from the top)',
            style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
          ),
          const SizedBox(height: 12),
          const Text('What is this?', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onConfirm != null)
                FilledButton.icon(
                  onPressed: busy ? null : onConfirm,
                  style: FilledButton.styleFrom(backgroundColor: AppColors.navy),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Model is right'),
                ),
              OutlinedButton(onPressed: busy ? null : onOwn, child: const Text('Our product')),
              OutlinedButton(onPressed: busy ? null : onCompetitor, child: const Text('Competitor')),
              OutlinedButton(onPressed: busy ? null : onPickProduct, child: const Text('Choose exact product…')),
              OutlinedButton(onPressed: busy ? null : onReject, child: const Text('Not a product')),
            ],
          ),
        ],
      ),
    );
  }
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
      Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted)),
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
                  decoration: const InputDecoration(
                    hintText: 'Search product or brand',
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
