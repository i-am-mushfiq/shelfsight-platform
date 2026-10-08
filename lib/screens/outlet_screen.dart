import 'package:flutter/material.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'capture_screen.dart';
import 'order_screen.dart';

String pct(num? value, {int digits = 0}) =>
    value == null ? '—' : '${(value * 100).toStringAsFixed(digits)}%';

/// Turns a recommendation's evidence map into short, readable facts.
List<String> evidenceLines(Map<String, dynamic> e) {
  final lines = <String>[];
  final peers = e['peer_group'];
  if (peers is Map) lines.add('Peer group: ${peers['basis']} (${peers['size']} outlets)');
  if (e['peer_penetration'] != null) {
    lines.add('${pct(e['peer_penetration'] as num)} of peers bought it (${e['peer_buyers']} outlets)');
  }
  if (e['peer_avg_monthly_units'] != null && (e['peer_avg_monthly_units'] as num) > 0) {
    lines.add('Peers that stock it average ${e['peer_avg_monthly_units']} units/month');
  }
  if (e['outlet_units_in_window'] != null) {
    lines.add('This outlet: ${e['outlet_units_in_window']} units in ${e['window_days']} days');
  }
  if (e['outlet_monthly_units'] != null) lines.add('This outlet: ${e['outlet_monthly_units']} units/month');
  if (e['target_share'] != null && e['actual_share'] != null) {
    lines.add('Share ${pct(e['actual_share'] as num)} vs target ${pct(e['target_share'] as num)}');
  }
  final observed = e['observed'];
  if (observed is Map) {
    for (final failure in (observed['failures'] as List? ?? const [])) {
      lines.add('Seen on shelf: $failure');
    }
    if ((observed['unknown_facings_in_scope'] as num? ?? 0) > 0) {
      lines.add('${observed['unknown_facings_in_scope']} facings could not be identified');
    }
  }
  if (e['share_of_shelf'] != null) {
    lines.add('Own facings ${e['own_facings']} of ${e['total_facings']} (${e['basis']} basis)');
  }
  final rules = e['rule_sets'];
  if (rules is Map) {
    final used = rules.entries
        .where((r) => r.value != null)
        .map((r) => '${r.key} v${(r.value as Map)['version']}')
        .join(', ');
    if (used.isNotEmpty) lines.add('Rules: $used');
  }
  return lines;
}

class OutletScreen extends StatefulWidget {
  const OutletScreen({super.key, required this.shop, required this.atShop});
  static const routeName = 'outlet';
  final Shop shop;
  final bool atShop;

  @override
  State<OutletScreen> createState() => _OutletScreenState();
}

class _OutletScreenState extends State<OutletScreen> {
  Map<String, dynamic>? _intel;
  String? _error;
  bool _startingVisit = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final intel = await PlatformApi.instance.refreshIntelligence(widget.shop.id);
      if (mounted) setState(() => _intel = intel);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _feedback(Map<String, dynamic> rec, String decision) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await PlatformApi.instance.recommendationFeedback(rec['id'] as String, decision);
      messenger.showSnackBar(SnackBar(content: Text('Marked as $decision.')));
      await _load();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Asks which shelf is being photographed. Placement rules and SKU recognition are
  /// scoped by category, so the audit cannot be evaluated without it.
  Future<Map<String, dynamic>?> _pickCategory() async {
    final categories = (await PlatformApi.instance.categories())
        .where((c) => (c['level'] as int) >= 1)
        .toList();
    if (!mounted) return null;
    return showModalBottomSheet<Map<String, dynamic>>(
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
                child: Text('Which shelf are you auditing?', style: Theme.of(context).textTheme.titleLarge),
              ),
              for (final c in categories)
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
  }

  Future<void> _startAudit() async {
    setState(() => _startingVisit = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final category = await _pickCategory();
      if (category == null) return;
      final visit = await PlatformApi.instance.startVisit(
        clientVisitId: newClientId(),
        outletId: widget.shop.id,
        lat: SimulatedGps.lat,
        lng: SimulatedGps.lng,
      );
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => CaptureScreen(
            storeName: widget.shop.name,
            visitId: visit['id'] as String,
            categoryId: category['id'] as String,
            categoryName: category['name'] as String,
          ),
        ),
      );
      if (mounted) await _load();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _startingVisit = false);
    }
  }

  Future<void> _showBrief() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final brief = await PlatformApi.instance.callBrief(widget.shop.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.white,
        builder: (context) => _BriefSheet(brief: brief),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final intel = _intel;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.shop.name),
            Text(
              '${widget.shop.channel} · ${widget.shop.code}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.inkMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
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
            label: _startingVisit ? 'Starting visit…' : 'Start shelf audit',
            icon: Icons.photo_camera_outlined,
            onPressed: _startingVisit ? null : _startAudit,
          ),
        ),
      ),
      body: _error != null
          ? _ErrorView(message: _error!, onRetry: _load)
          : intel == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (intel['data_origin'] == 'synthetic') const SyntheticBanner(),
                  if (!widget.atShop)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: StatusPill(
                        label: 'You are not at this shop (simulated GPS)',
                        icon: Icons.near_me_outlined,
                        color: Color(0xFF92580A),
                        background: AppColors.amberSoft,
                      ),
                    ),
                  _ClassificationCard(classification: intel['classification'] as Map<String, dynamic>?),
                  const SizedBox(height: 12),
                  _ScoresCard(scores: (intel['scores'] as List).cast<Map<String, dynamic>>()),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _showBrief,
                          icon: const Icon(Icons.record_voice_over_outlined),
                          label: const Text('Pre-call brief'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => OrderScreen(shop: widget.shop)),
                            );
                            if (mounted) await _load();
                          },
                          icon: const Icon(Icons.shopping_cart_outlined),
                          label: const Text('Suggested order'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SectionTitle(title: 'Recommended actions (${(intel['recommendations'] as List).length})'),
                  const SizedBox(height: 8),
                  if ((intel['recommendations'] as List).isEmpty)
                    const SurfaceCard(child: Text('No open recommendations for this outlet.')),
                  for (final rec in (intel['recommendations'] as List).cast<Map<String, dynamic>>())
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: RecommendationCard(
                        rec: rec,
                        onAccept: () => _feedback(rec, 'accepted'),
                        onReject: () => _feedback(rec, 'rejected'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  _PortfolioCard(portfolio: intel['portfolio'] as Map<String, dynamic>),
                  const SizedBox(height: 12),
                  _ShelfCard(intel: intel),
                ],
              ),
            ),
    );
  }
}

/// Shown wherever numbers come from the synthetic demo organization.
class SyntheticBanner extends StatelessWidget {
  const SyntheticBanner({super.key});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.amberSoft,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.amber),
    ),
    child: const Row(
      children: [
        Icon(Icons.science_outlined, size: 18, color: Color(0xFF92580A)),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'SYNTHETIC DEMO DATA — not real sales or market figures',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF92580A)),
          ),
        ),
      ],
    ),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.inkMuted),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          PrimaryButton(label: 'Try again', icon: Icons.refresh_rounded, onPressed: onRetry),
        ],
      ),
    ),
  );
}

class _ClassificationCard extends StatelessWidget {
  const _ClassificationCard({required this.classification});
  final Map<String, dynamic>? classification;

  @override
  Widget build(BuildContext context) {
    final c = classification;
    if (c == null) {
      return const SurfaceCard(child: Text('Not classified yet.'));
    }
    final reasons = ((c['evidence'] as Map?)?['reasons'] as List? ?? const []).cast<String>();
    final human = c['source'] == 'human';
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text(
            'Class ${c['code']} · ${c['label']}',
            style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink),
          ),
          subtitle: Text(
            human
                ? 'Set by a manager'
                : 'Rule-based · data completeness ${pct(c['confidence'] as num)}',
            style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
          ),
          children: [
            if (human) Text('Note: ${(c['evidence'] as Map?)?['note'] ?? ''}'),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_rounded, size: 16, color: AppColors.emeraldDark),
                    const SizedBox(width: 6),
                    Expanded(child: Text(reason, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScoresCard extends StatelessWidget {
  const _ScoresCard({required this.scores});
  final List<Map<String, dynamic>> scores;

  static const _labels = {
    'assortment': 'Assortment',
    'availability': 'Availability',
    'share_of_shelf': 'Share of shelf',
    'placement': 'Placement',
    'competitor_pressure': 'Competitor pressure',
    'opportunity': 'Opportunity',
  };

  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Outlet scores', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink)),
        const SizedBox(height: 10),
        for (final s in scores)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(child: Text(_labels[s['dimension']] ?? '${s['dimension']}')),
                if (s['value'] == null)
                  Flexible(
                    child: Text(
                      '${(s['inputs'] as Map?)?['reason'] ?? 'no data'}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
                    ),
                  )
                else
                  Text(
                    s['unit'] == 'bdt_per_month'
                        ? '৳${(s['value'] as num).round()}/mo'
                        : s['unit'] == 'pct_of_target'
                        ? '${(s['value'] as num).round()}% of target'
                        : '${(s['value'] as num).round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class RecommendationCard extends StatelessWidget {
  const RecommendationCard({super.key, required this.rec, this.onAccept, this.onReject});
  final Map<String, dynamic> rec;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final priority = rec['priority'] as int? ?? 2;
    final lines = evidenceLines((rec['evidence'] as Map).cast<String, dynamic>());
    final impact = (rec['expected_impact'] as Map?) ?? const {};
    return SurfaceCard(
      borderColor: priority == 1 ? AppColors.emeraldDark : AppColors.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusPill(
                label: priority == 1 ? 'High priority' : priority == 2 ? 'Medium' : 'Low',
                color: priority == 1 ? AppColors.emeraldDark : AppColors.inkMuted,
                background: priority == 1 ? AppColors.mint : AppColors.surfaceAlt,
              ),
              const Spacer(),
              Text(
                'Confidence ${pct(rec['confidence'] as num)}',
                style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            rec['action'] as String,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.ink),
          ),
          const SizedBox(height: 4),
          Text(rec['reason'] as String, style: const TextStyle(fontSize: 13.5, height: 1.35)),
          if (impact['monthly_value_bdt'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Peer-based potential ≈ ৳${(impact['monthly_value_bdt'] as num).round()}/month (estimate)',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.emeraldDark),
              ),
            ),
          if (lines.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 6),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                dense: true,
                title: const Text(
                  'Why? See the evidence',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.emeraldDark),
                ),
                children: [
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text('• $line', style: const TextStyle(fontSize: 13)),
                    ),
                  Text(
                    'Source: ${rec['source']} · ${rec['generator_version']}',
                    style: const TextStyle(fontSize: 11.5, color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
          if (onAccept != null && rec['status'] == 'open')
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: onReject, child: const Text('Not relevant')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: onAccept,
                    style: FilledButton.styleFrom(backgroundColor: AppColors.navy),
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PortfolioCard extends StatelessWidget {
  const _PortfolioCard({required this.portfolio});
  final Map<String, dynamic> portfolio;

  @override
  Widget build(BuildContext context) {
    final current = ((portfolio['current_mix'] as Map)['brand'] as List).cast<Map<String, dynamic>>();
    final targets = {
      for (final t in ((portfolio['target_mix'] as Map)['brand'] as List? ?? const []).cast<Map<String, dynamic>>())
        t['key']: t['target_share'] as num,
    };
    final peers = {
      for (final p in ((portfolio['peer_benchmark'] as Map)['brand'] as List).cast<Map<String, dynamic>>())
        p['key']: p['value_share'] as num,
    };
    final totals = portfolio['totals'] as Map;
    final window = portfolio['window'] as Map;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Own portfolio mix', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink)),
          Text(
            'Last ${window['days']} days · ৳${(totals['monthly_value'] as num).round()}/month · '
            '${totals['distinct_skus']} SKUs · orders of own brands only',
            style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
          ),
          const SizedBox(height: 12),
          if (current.isEmpty) const Text('No orders in this period.'),
          for (final entry in current)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry['label'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.ink),
                        ),
                      ),
                      Text(
                        pct(entry['value_share'] as num),
                        style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (entry['value_share'] as num).toDouble().clamp(0, 1),
                      minHeight: 7,
                      backgroundColor: AppColors.surfaceAlt,
                      color: AppColors.emeraldDark,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Target ${pct(targets[entry['key']])} · peers ${pct(peers[entry['key']])}',
                    style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ShelfCard extends StatelessWidget {
  const _ShelfCard({required this.intel});
  final Map<String, dynamic> intel;

  @override
  Widget build(BuildContext context) {
    final shelf = intel['shelf'] as Map<String, dynamic>?;
    if (shelf == null) {
      return const SurfaceCard(
        child: Text('No shelf audit yet. Start one to measure share of shelf and placement.'),
      );
    }
    final all = shelf['all'] as Map<String, dynamic>;
    final range = (all['share_of_shelf_range'] as List?)?.cast<num>();
    final competitors = ((intel['competition'] as Map)['presence'] as List).cast<Map<String, dynamic>>();
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Latest shelf audit', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink)),
          const SizedBox(height: 8),
          Text(
            'Own share of shelf ${pct(all['share_of_shelf'] as num?)}'
            '${range != null && range[0] != range[1] ? ' (between ${pct(range[0])} and ${pct(range[1])})' : ''}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          Text(
            '${all['own_facings']} own · ${all['competitor_facings']} competitor · '
            '${all['unknown_facings']} unidentified of ${all['total_facings']} facings · '
            '${pct(all['verified_ratio'] as num)} human-verified',
            style: const TextStyle(fontSize: 12.5, color: AppColors.inkMuted),
          ),
          for (final c in competitors.where((c) => c['is_own'] != true).take(4))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${c['name']}: ${c['facings']} facings (${pct(c['share_of_shelf'] as num?)})'),
            ),
        ],
      ),
    );
  }
}

class _BriefSheet extends StatelessWidget {
  const _BriefSheet({required this.brief});
  final Map<String, dynamic> brief;

  static const _icons = {
    'opportunity': Icons.trending_up_rounded,
    'promotion': Icons.local_offer_outlined,
    'competitor': Icons.visibility_outlined,
    'relationship': Icons.receipt_long_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final points = (brief['talking_points'] as List).cast<Map<String, dynamic>>();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text('Pre-call brief', style: Theme.of(context).textTheme.titleLarge),
            Text(brief['headline'] as String, style: const TextStyle(color: AppColors.inkMuted)),
            const SizedBox(height: 14),
            if (points.isEmpty) const Text('Nothing specific to raise for this outlet yet.'),
            for (final point in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_icons[point['kind']] ?? Icons.chat_outlined, color: AppColors.emeraldDark),
                    const SizedBox(width: 10),
                    Expanded(child: Text(point['text'] as String, style: const TextStyle(height: 1.35))),
                  ],
                ),
              ),
            const Text(
              'Built only from this outlet\'s orders, recommendations, promotions and observations.',
              style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}
