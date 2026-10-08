import 'dart:async';

import 'package:flutter/material.dart';

import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'detection_review_screen.dart';

/// Queues the visit's photos for upload and follows each one through analysis.
/// Works offline: photos stay queued on the device and upload when the
/// connection returns, so the officer can leave this screen and carry on.
class AuditUploadScreen extends StatefulWidget {
  const AuditUploadScreen({
    super.key,
    required this.storeName,
    required this.visitId,
    required this.categoryId,
    required this.categoryName,
    required this.imagePaths,
  });
  final String storeName;
  final String visitId;
  final String categoryId;
  final String categoryName;
  final List<String> imagePaths;

  @override
  State<AuditUploadScreen> createState() => _AuditUploadScreenState();
}

class _AuditUploadScreenState extends State<AuditUploadScreen> {
  final _queue = UploadQueue.instance;
  final Map<String, Map<String, dynamic>> _captures = {}; // capture id -> server status
  Timer? _poll;
  bool _enqueued = false;

  @override
  void initState() {
    super.initState();
    _queue.addListener(_onQueue);
    _enqueue();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _queue.removeListener(_onQueue);
    super.dispose();
  }

  void _onQueue() {
    if (mounted) setState(() {});
  }

  Future<void> _enqueue() async {
    for (final path in widget.imagePaths) {
      await _queue.enqueue(
        visitId: widget.visitId,
        sourcePath: path,
        area: widget.categoryName,
        categoryId: widget.categoryId,
      );
    }
    if (mounted) setState(() => _enqueued = true);
  }

  List<QueuedCapture> get _items => _queue.forVisit(widget.visitId);

  bool _finished(QueuedCapture item) {
    if (item.state == UploadState.rejected) return true;
    if (item.state != UploadState.uploaded) return false;
    if (item.duplicateOf != null) return true;
    final status = _captures[item.captureId]?['status'];
    return status == 'analysed' || status == 'failed';
  }

  Future<void> _refresh() async {
    _queue.drain();
    for (final item in _items) {
      if (item.state != UploadState.uploaded || item.captureId == null || _finished(item)) continue;
      try {
        final capture = await PlatformApi.instance.capture(item.captureId!);
        if (mounted) setState(() => _captures[item.captureId!] = capture);
      } on ApiException {
        // Offline or busy: the next tick tries again.
      }
    }
  }

  bool get _allFinished => _enqueued && _items.isNotEmpty && _items.every(_finished);
  List<String> get _analysedIds => [
    for (final item in _items)
      if (item.captureId != null && _captures[item.captureId]?['status'] == 'analysed') item.captureId!,
  ];
  int get _waitingOffline => _items.where((i) => i.state == UploadState.queued && i.attempts > 0).length;

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Upload and analysis'),
            Text(
              '${widget.storeName} · ${widget.categoryName}',
              style: const TextStyle(fontSize: 12, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: PrimaryButton(
            label: _allFinished
                ? (_analysedIds.isEmpty ? 'No photo could be analysed' : 'Review detections')
                : 'Waiting for ${items.where((i) => !_finished(i)).length} photo(s)…',
            icon: Icons.fact_check_outlined,
            onPressed: _allFinished && _analysedIds.isNotEmpty
                ? () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => DetectionReviewScreen(
                        storeName: widget.storeName,
                        visitId: widget.visitId,
                        captureIds: _analysedIds,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_waitingOffline > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SurfaceCard(
                color: AppColors.amberSoft,
                borderColor: AppColors.amber,
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off_rounded, color: Color(0xFF92580A)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$_waitingOffline photo(s) saved on this phone. They upload automatically when the '
                        'connection returns. You can continue the visit and come back from Visits.',
                        style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF92580A)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _CaptureRow(
                index: i + 1,
                item: items[i],
                capture: _captures[items[i].captureId],
                onRemove: items[i].state == UploadState.rejected ? () => _queue.remove(items[i]) : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _CaptureRow extends StatelessWidget {
  const _CaptureRow({required this.index, required this.item, required this.capture, this.onRemove});
  final int index;
  final QueuedCapture item;
  final Map<String, dynamic>? capture;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final inference = capture?['inference'] as Map<String, dynamic>?;
    final status = capture?['status'];
    late final String title;
    late final IconData icon;
    var color = AppColors.inkMuted;
    var busy = false;
    switch (item.state) {
      case UploadState.queued:
        title = item.attempts > 0 ? 'Saved offline · will retry' : 'Queued';
        icon = Icons.schedule_rounded;
      case UploadState.uploading:
        title = 'Uploading…';
        icon = Icons.cloud_upload_outlined;
        busy = true;
      case UploadState.rejected:
        title = 'Not accepted';
        icon = Icons.error_outline_rounded;
        color = AppColors.red;
      case UploadState.uploaded:
        if (item.duplicateOf != null) {
          title = 'Duplicate of another photo · skipped';
          icon = Icons.content_copy_rounded;
        } else if (status == 'analysed') {
          title = '${inference?['detections_total'] ?? 0} facings found · '
              '${inference?['needs_review'] ?? 0} need review';
          icon = Icons.check_circle_rounded;
          color = AppColors.emeraldDark;
        } else if (status == 'failed') {
          title = 'Analysis failed';
          icon = Icons.error_outline_rounded;
          color = AppColors.red;
        } else {
          title = 'Uploaded · analysing…';
          icon = Icons.auto_awesome_outlined;
          busy = true;
        }
    }
    final warnings = [
      ...item.qualityWarnings,
      ...((inference?['warnings'] as List?) ?? const []).cast<String>(),
    ];
    final model = inference?['model'] as Map?;
    return SurfaceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          busy
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
              : Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Photo $index', style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink)),
                Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                if (item.error != null && item.state != UploadState.uploaded)
                  Text(item.error!, style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted)),
                for (final warning in warnings.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('⚠ $warning', style: const TextStyle(fontSize: 12.5, color: Color(0xFF92580A))),
                  ),
                if (model != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      'Model: ${model['provider']}',
                      style: const TextStyle(fontSize: 11.5, color: AppColors.inkMuted),
                    ),
                  ),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(tooltip: 'Remove', onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
        ],
      ),
    );
  }
}
