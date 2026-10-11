import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/field_models.dart';
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
    required this.photos,
    this.sphereCaptureIds = const [],
  });
  final String storeName;
  final String visitId;
  final List<CapturedPhoto> photos;

  /// Photo spheres are uploaded when taken; here they are only followed through analysis.
  final List<String> sphereCaptureIds;

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
    for (final photo in widget.photos) {
      await _queue.enqueue(
        visitId: widget.visitId,
        sourcePath: photo.path,
        area: photo.categoryName,
        categoryId: photo.categoryId,
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

  bool _sphereFinished(String id) {
    final status = _captures[id]?['status'];
    return status == 'analysed' || status == 'failed';
  }

  Future<void> _refresh() async {
    _queue.drain();
    for (final id in widget.sphereCaptureIds) {
      if (_sphereFinished(id)) continue;
      try {
        final capture = await PlatformApi.instance.capture(id);
        if (mounted) setState(() => _captures[id] = capture);
      } on ApiException {
        // Next tick.
      }
    }
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

  bool get _allFinished =>
      _enqueued &&
      (_items.isNotEmpty || widget.sphereCaptureIds.isNotEmpty) &&
      _items.every(_finished) &&
      widget.sphereCaptureIds.every(_sphereFinished);
  List<String> get _analysedIds => [
    for (final item in _items)
      if (item.captureId != null && _captures[item.captureId]?['status'] == 'analysed') item.captureId!,
    for (final id in widget.sphereCaptureIds)
      if (_captures[id]?['status'] == 'analysed') id,
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
            Text(t('Sending photos')),
            Text(
              '${widget.storeName} · ${widget.photos.length} photo(s)',
              style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
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
                ? (_analysedIds.isEmpty ? 'No photo could be read' : 'Check the results')
                : 'Waiting for ${items.where((i) => !_finished(i)).length + widget.sphereCaptureIds.where((id) => !_sphereFinished(id)).length} photo(s)…',
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
        padding: const EdgeInsets.all(AppSpace.page),
        children: [
          if (_waitingOffline > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SurfaceCard(
                color: AppColors.amberSoft,
                borderColor: AppColors.amber,
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off_rounded, color: AppColors.amberInk),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$_waitingOffline photo(s) saved on this phone. They upload automatically when the '
                        'connection returns. You can continue the visit and come back from Visits.',
                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.amberInk),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          for (final id in widget.sphereCaptureIds)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SurfaceCard(
                child: Row(
                  children: [
                    _sphereFinished(id)
                        ? const Icon(Icons.threesixty_rounded, color: AppColors.emeraldDark)
                        : const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _captures[id]?['status'] == 'analysed'
                            ? '360° sphere · ${(_captures[id]?['inference'] as Map?)?['detections_total'] ?? 0} packs found'
                            : _captures[id]?['status'] == 'failed'
                            ? '360° sphere · analysis failed'
                            : '360° sphere · analysing…',
                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
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
          title = '${inference?['detections_total'] ?? 0} packs found · '
              '${inference?['needs_review'] ?? 0} to check';
          icon = Icons.check_circle_rounded;
          color = AppColors.emeraldDark;
        } else if (status == 'failed') {
          title = 'Could not read this photo';
          icon = Icons.error_outline_rounded;
          color = AppColors.red;
        } else {
          title = 'Sent · reading the shelf…';
          icon = Icons.auto_awesome_outlined;
          busy = true;
        }
    }
    // Only problems with this photo; how recognition works is explained once, in the report.
    final warnings = item.qualityWarnings;
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
                Text('Photo $index', style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink)),
                const SizedBox(height: 2),
                Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
                if (item.error != null && item.state != UploadState.uploaded)
                  Text(item.error!, style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
                for (final warning in warnings.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text('⚠ $warning', style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.amberInk)),
                  ),
              ],
            ),
          ),
          if (onRemove != null)
            IconButton(tooltip: t('Remove'), onPressed: onRemove, icon: const Icon(Icons.close_rounded)),
        ],
      ),
    );
  }
}
