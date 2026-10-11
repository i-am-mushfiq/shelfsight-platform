import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/shell_widgets.dart';
import 'detection_review_screen.dart';
import 'outlet_screen.dart';
import 'visit_report_screen.dart';

/// Visit history from the platform. Open visits can be resumed.
class AuditsScreen extends StatefulWidget {
  const AuditsScreen({super.key});

  @override
  State<AuditsScreen> createState() => _AuditsScreenState();
}

class _AuditsScreenState extends State<AuditsScreen> {
  List<Map<String, dynamic>>? _visits;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final visits = await PlatformApi.instance.visits();
      if (mounted) {
        setState(() {
          _visits = visits;
          _error = null;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _resume(Map<String, dynamic> visit) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final detail = await PlatformApi.instance.visit(visit['id'] as String);
      final captures = (detail['captures'] as List).cast<Map<String, dynamic>>();
      final analysed = [
        for (final c in captures)
          if (c['status'] == 'analysed') c['id'] as String,
      ];
      final pending = UploadQueue.instance
          .forVisit(visit['id'] as String)
          .where((i) => i.state == UploadState.queued || i.state == UploadState.uploading)
          .length;
      if (pending > 0) {
        messenger.showSnackBar(
          SnackBar(content: Text('$pending photo(s) are still waiting to upload.')),
        );
        UploadQueue.instance.drain();
        return;
      }
      if (analysed.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(t('No analysed photos on this visit yet.'))),
        );
        return;
      }
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => DetectionReviewScreen(
            storeName: visit['outlet_name'] as String,
            visitId: visit['id'] as String,
            captureIds: analysed,
          ),
        ),
      );
      if (mounted) _load();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _openReport(Map<String, dynamic> visit) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VisitReportScreen(visitId: visit['id'] as String)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final visits = _visits;
    return FixedHeaderScrollView(
      title: t('Visits'),
      subtitle: visits == null ? 'Loading…' : '${visits.length} recent',
      slivers: [
        pagePadding([
          ListenableBuilder(
            listenable: UploadQueue.instance,
            builder: (context, _) {
              final pending = UploadQueue.instance.pendingCount;
              if (pending == 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SurfaceCard(
                  color: AppColors.amberSoft,
                  borderColor: AppColors.amber,
                  onTap: UploadQueue.instance.drain,
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_upload_outlined, color: AppColors.amberInk),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '$pending photo(s) waiting to upload. Tap to retry now.',
                          style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.amberInk),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          if (_error != null)
            SurfaceCard(
              color: AppColors.redSoft,
              borderColor: AppColors.red,
              onTap: _load,
              child: Text('$_error  Tap to retry.'),
            )
          else if (visits == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (visits.isEmpty)
            SurfaceCard(
              child: Text(t('No visits yet. Open a shop from Home and start a shelf audit.')),
            )
          else
            for (final visit in visits)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _VisitCard(
                  visit: visit,
                  onTap: visit['status'] == 'open' ? () => _resume(visit) : () => _openReport(visit),
                ),
              ),
        ]),
      ],
    );
  }
}

class _VisitCard extends StatelessWidget {
  const _VisitCard({required this.visit, this.onTap});
  final Map<String, dynamic> visit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final started = DateTime.parse(visit['started_at'] as String).toLocal();
    final when =
        '${started.day.toString().padLeft(2, '0')}/${started.month.toString().padLeft(2, '0')} '
        '${started.hour.toString().padLeft(2, '0')}:${started.minute.toString().padLeft(2, '0')}';
    final shares = visit['share_of_shelf'] as Map;
    final verified = shares['verified'] as Map?;
    final all = shares['all'] as Map?;
    final share = verified ?? all;
    final open = visit['status'] == 'open';
    return SurfaceCard(
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            open ? Icons.pending_actions_rounded : Icons.assignment_turned_in_rounded,
            color: open ? AppColors.amber : AppColors.emeraldDark,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  visit['outlet_name'] as String,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
                ),
                Text(
                  '$when · ${(visit['store_type'] as Map?)?['name'] ?? ''} · ${visit['photos']} photo(s) · '
                  '${open ? 'not finished, tap to continue' : 'finished, tap to see the result'}',
                  style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          if (share != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  pct(share['value'] as num),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppFontSize.lg, color: AppColors.ink),
                ),
                Text(
                  t('Square'),
                  style: const TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
