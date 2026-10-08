import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'outlet_screen.dart';

/// Outcome of a submitted shelf audit, straight from the platform's response.
class AuditResultScreen extends StatelessWidget {
  const AuditResultScreen({super.key, required this.storeName, required this.intelligence});
  final String storeName;
  final Map<String, dynamic> intelligence;

  @override
  Widget build(BuildContext context) {
    final shelf = intelligence['shelf'] as Map<String, dynamic>?;
    final all = shelf?['all'] as Map<String, dynamic>?;
    final verified = shelf?['verified'] as Map<String, dynamic>?;
    final placement = intelligence['placement'] as Map<String, dynamic>;
    final results = (placement['results'] as List).cast<Map<String, dynamic>>();
    final recs = (intelligence['recommendations'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => (r['source'] as String).startsWith('placement') ||
            (r['source'] as String).startsWith('competitor'))
        .toList();
    final range = (all?['share_of_shelf_range'] as List?)?.cast<num>();
    final fullyVerified = (all?['verified_ratio'] as num? ?? 0) >= 1;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Audit submitted'),
            Text(
              storeName,
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
            label: 'Back to outlet',
            icon: Icons.storefront_rounded,
            // Close the camera and review screens underneath and land on the outlet.
            onPressed: () => Navigator.of(context).popUntil(
              (route) => route.isFirst || route.settings.name == OutletScreen.routeName,
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (intelligence['data_origin'] == 'synthetic') const SyntheticBanner(),
          if (all == null)
            const SurfaceCard(child: Text('No facings were detected in this audit.'))
          else
            SurfaceCard(
              color: AppColors.navy,
              borderColor: AppColors.navy,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Own share of shelf', style: TextStyle(color: Colors.white70)),
                  Text(
                    pct((fullyVerified ? verified : all)?['share_of_shelf'] as num?),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                  ),
                  Text(
                    fullyVerified
                        ? 'Human-verified · ${verified?['own_facings']} of ${verified?['total_facings']} facings'
                        : '${all['own_facings']} of ${all['total_facings']} facings · '
                              '${pct(all['verified_ratio'] as num)} verified'
                              '${range != null && range[0] != range[1] ? ' · could be ${pct(range[0])}–${pct(range[1])}' : ''}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  if (!fullyVerified && (all['unknown_facings'] as num) > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '${all['unknown_facings']} facings could not be identified, so the true share is a range.',
                        style: const TextStyle(color: Color(0xFFFDE68A), fontSize: 12.5),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 18),
          SectionTitle(
            title: placement['score'] == null
                ? 'Placement rules'
                : 'Placement compliance ${(placement['score'] as num).round()}%',
          ),
          const SizedBox(height: 8),
          if (results.isEmpty)
            const SurfaceCard(child: Text('No placement rules apply to what was captured.')),
          for (final result in results)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RuleRow(result: result),
            ),
          const SizedBox(height: 12),
          if (recs.isNotEmpty) ...[
            const SectionTitle(title: 'Actions from this audit'),
            const SizedBox(height: 8),
            for (final rec in recs)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: RecommendationCard(rec: rec),
              ),
          ],
        ],
      ),
    );
  }

}

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final status = result['status'] as String;
    final observed = result['observed'] as Map;
    final (icon, color, label) = switch (status) {
      'compliant' => (Icons.check_circle_rounded, AppColors.emeraldDark, 'Met'),
      'non_compliant' => (Icons.cancel_rounded, AppColors.red, 'Not met'),
      _ => (Icons.help_outline_rounded, AppColors.inkMuted, 'Cannot tell'),
    };
    final details = status == 'not_evaluable'
        ? ['${observed['reason']}']
        : ((observed['failures'] as List?) ?? const []).cast<String>();
    return SurfaceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result['description'] as String,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink),
                ),
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
                for (final detail in details)
                  Text('• $detail', style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
