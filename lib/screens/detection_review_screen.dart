import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'visit_report_screen.dart';
import 'shelf_result_screen.dart';

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
    this.followQueue = false,
    this.autoFinish = false,
    this.reviewOnly = false,
  });
  final String storeName;
  final String visitId;
  final List<String> captureIds;

  /// Also shows the visit's photos still being read, adding each one as soon as it is ready.
  final bool followQueue;

  /// Finish the visit as soon as every photo is read, without asking about packs first
  /// (packs can still be checked afterwards from the visit report).
  final bool autoFinish;

  /// Opened from a finished visit's report: check packs only, no Finish visit button.
  final bool reviewOnly;

  @override
  State<DetectionReviewScreen> createState() => _DetectionReviewScreenState();
}

class _DetectionReviewScreenState extends State<DetectionReviewScreen> {
  final _api = PlatformApi.instance;
  int _photo = 0;
  late final List<String> _ids = [];
  final Set<String> _waiting = {}; // capture ids (or queue ids) not read yet
  int _unreadable = 0;
  Timer? _poll;
  final Map<String, Map<String, dynamic>> _captures = {};
  final Map<String, Uint8List> _images = {};
  List<Map<String, dynamic>> _products = const [];
  String? _selected; // detection id
  final Set<String> _skipped = {};
  String? _error;
  bool _busy = false;
  String? _finishError; // auto-finish stopped on this error until Try again

  String? get _captureId => _ids.isEmpty ? null : _ids[_photo];
  Map<String, dynamic>? get _capture => _captures[_captureId];
  List<Map<String, dynamic>> get _detections =>
      ((_capture?['detections'] as List?) ?? const []).cast<Map<String, dynamic>>();
  int get _unverified => _detections.where((d) => d['verification'] == 'unverified').length;

  @override
  void initState() {
    super.initState();
    _waiting.addAll(widget.captureIds);
    _loadAll();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() => _error = null);
    try {
      _products = await _api.products();
      await _gather();
      _poll ??= Timer.periodic(const Duration(milliseconds: 1200), (_) => _gather());
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  bool _gathering = false;

  /// Picks up photos as they finish reading. The first one ready opens straight away.
  Future<void> _gather() async {
    if (_gathering) return;
    _gathering = true;
    try {
      final candidates = <String>[..._waiting.where((id) => !id.startsWith('queue:'))];
      _waiting.removeWhere((id) => id.startsWith('queue:'));
      if (widget.followQueue) {
        final queue = UploadQueue.instance;
        unawaited(queue.drain());
        var unreadable = 0;
        for (final item in queue.forVisit(widget.visitId)) {
          if (item.state == UploadState.rejected || item.duplicateOf != null) {
            unreadable++;
          } else if (item.captureId == null) {
            _waiting.add('queue:${item.clientCaptureId}');
          } else if (!_ids.contains(item.captureId) && !candidates.contains(item.captureId)) {
            candidates.add(item.captureId!);
          }
        }
        _unreadable = unreadable;
      }
      for (final id in candidates) {
        if (_ids.contains(id)) continue;
        try {
          final capture = await _api.capture(id);
          final status = capture['status'];
          if (status == 'analysed') {
            _waiting.remove(id);
            _captures[id] = capture;
            _ids.add(id);
          } else if (status == 'failed') {
            _waiting.remove(id);
            _unreadable++;
          } else {
            _waiting.add(id);
          }
        } on ApiException {
          _waiting.add(id); // next tick
        }
      }
      // Photos taken just before Next may still be joining the queue, so keep following it.
      if (_waiting.isEmpty && !widget.followQueue) _poll?.cancel();
      if (!mounted) return;
      setState(() {});
      if (widget.autoFinish) {
        if (!_busy && _finishError == null && _waiting.isEmpty && (_ids.isNotEmpty || _unreadable > 0)) {
          await _submit();
        }
        return;
      }
      if (_ids.isNotEmpty && _images.isEmpty) {
        await _loadImage();
        _selectNext();
      }
    } finally {
      _gathering = false;
    }
  }

  Future<void> _loadImage() async {
    final id = _captureId;
    if (id == null || _images.containsKey(id)) return;
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
      if (widget.autoFinish) {
        // Straight to the photos with what was found drawn on them; the result follows.
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => ShelfResultScreen(
              visitId: widget.visitId,
              captureIds: List.of(_ids),
              report: result['report'] as Map<String, dynamic>,
            ),
          ),
        );
        return;
      }
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
      if (widget.autoFinish) {
        // "Still being analysed" clears itself on a later tick; anything else waits for Try again.
        final transient = error.message.contains('still being analysed');
        if (mounted) setState(() => _finishError = transient ? null : error.message);
      } else {
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _finishing(int reading) => Scaffold(
    backgroundColor: AppColors.canvas,
    appBar: AppBar(title: Text(t('Finishing visit'))),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_finishError ?? _error case final message?) ...[
              const Icon(Icons.error_outline_rounded, color: AppColors.red, size: 40),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              PrimaryButton(
                label: t('Try again'),
                onPressed: () {
                  setState(() => _finishError = null);
                  _error != null ? _loadAll() : _gather();
                },
              ),
            ] else ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(
                _busy
                    ? 'Working out the result and the order…'
                    : reading > 0
                    ? 'Reading ${reading == 1 ? 'the last photo' : '$reading photos'}…'
                    : 'Getting the photos ready…',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'You can check the packs on the next page.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.inkMuted),
              ),
              if (_unreadable > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '$_unreadable photo${_unreadable == 1 ? '' : 's'} could not be read and will be left out.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.inkMuted),
                ),
              ],
            ],
          ],
        ),
      ),
    ),
  );

  String _productName(String? id) =>
      _products.where((p) => p['id'] == id).map((p) => p['name'] as String).firstOrNull ?? '';

  /// Packs on this photo that still need an answer (skipped ones come back last).
  List<Map<String, dynamic>> get _pending => _detections.where((d) => d['needs_review'] == true).toList();

  int? get _nextPhotoWithWork {
    for (var i = 1; i <= _ids.length; i++) {
      final index = (_photo + i) % _ids.length;
      if (index == _photo) break;
      final detections = ((_captures[_ids[index]]?['detections'] as List?) ?? const [])
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
    final reading = _waiting.length;
    final current = _current;
    final pending = _pending;
    final position = current == null ? 0 : pending.indexWhere((d) => d['id'] == current['id']) + 1;
    final nextPhoto = _nextPhotoWithWork;
    if (widget.autoFinish) return _finishing(reading);
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('Check the results')),
            Text(
              [
                if (_ids.length > 1) 'Photo ${_photo + 1} of ${_ids.length}',
                if (reading > 0) 'reading $reading more…'
                else if (pending.isEmpty) 'All checked'
                else '${pending.length} to check',
              ].join(' · '),
              style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
      bottomNavigationBar: widget.reviewOnly ? null : SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 12),
          child: PrimaryButton(
            label: _busy ? 'Please wait…' : 'Finish visit',
            icon: Icons.flag_outlined,
            onPressed: _busy || capture == null || reading > 0 ? null : _submit,
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
          ? _Reading(waiting: reading, unreadable: _unreadable)
          : ListView(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 4, AppSpace.page, AppSpace.xl),
              children: [
                if (reading > 0) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: const LinearProgressIndicator(minHeight: 3),
                  ),
                  const SizedBox(height: AppSpace.sm),
                ],
                if (_unreadable > 0 && reading == 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.sm),
                    child: Text(
                      '$_unreadable photo(s) skipped (repeated or unreadable).',
                      style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                    ),
                  ),
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
                    reviewOnly: widget.reviewOnly,
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
    this.reviewOnly = false,
    required this.nextPhoto,
    required this.unverified,
    required this.busy,
    required this.onNextPhoto,
    required this.onConfirmRest,
  });
  final bool reviewOnly;
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
              ? (reviewOnly ? 'Go back to see the updated result.' : 'Tap Finish visit to see the result and the order.')
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

/// Shown only until the first photo is ready, which is usually immediate.
class _Reading extends StatelessWidget {
  const _Reading({required this.waiting, required this.unreadable});
  final int waiting;
  final int unreadable;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (waiting > 0 || unreadable == 0) const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            waiting > 0 || unreadable == 0
                ? t('Reading the shelf…')
                : t('No photo could be read. Go back and take another.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.inkMuted, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    ),
  );
}
