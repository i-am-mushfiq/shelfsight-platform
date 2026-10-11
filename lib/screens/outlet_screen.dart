import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import '../widgets/store_type_picker.dart';
import 'capture_screen.dart';
import 'order_screen.dart';

String pct(num? value, {int digits = 0}) => value == null ? '—' : '${(value * 100).toStringAsFixed(digits)}%';

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
  // The officer may change the store type at the start of a visit; the header follows.
  late String _storeTypeName = widget.shop.channel;
  late String? _storeTypeId = widget.shop.channelId;

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

  /// Step 1 of the visit: what kind of store this is. The server applies the rules,
  /// targets and order policy of that store type, and updates the shop if it changed.
  Future<void> _startAudit() async {
    setState(() => _startingVisit = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final storeType = await pickStoreType(context, shopName: widget.shop.name, recordedId: _storeTypeId);
      if (storeType == null) return;
      final visit = await PlatformApi.instance.startVisit(
        clientVisitId: newClientId(),
        outletId: widget.shop.id,
        storeTypeId: storeType.id,
        lat: SimulatedGps.lat,
        lng: SimulatedGps.lng,
      );
      if (mounted) {
        setState(() {
          _storeTypeId = storeType.id;
          _storeTypeName = storeType.name;
        });
      }
      await navigator.push(
        MaterialPageRoute(
          builder: (_) =>
              CaptureScreen(storeName: widget.shop.name, storeTypeName: storeType.name, visitId: visit['id'] as String),
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

  Future<void> _openOrder() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => OrderScreen(outletId: widget.shop.id, outletName: widget.shop.name)),
    );
    if (mounted) await _load();
  }

  Future<void> _openAction(Map<String, dynamic> rec) async {
    final decision = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => _ActionSheet(rec: rec),
    );
    if (decision != null) await _feedback(rec, decision);
  }

  void _openAllActions(List<Map<String, dynamic>> recs) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _AllActionsScreen(shopName: widget.shop.name, recs: recs, onOpen: _openAction),
      ),
    );
  }

  void _openDetails(Map<String, dynamic> intel) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _ShopDetailsScreen(shop: widget.shop, intel: intel)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final intel = _intel;
    final recs = intel == null
        ? const <Map<String, dynamic>>[]
        : (intel['recommendations'] as List).cast<Map<String, dynamic>>().where((r) => r['status'] == 'open').toList();
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.shop.name),
            Text(
              _storeTypeName,
              style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: PrimaryButton(
            label: _startingVisit ? 'Starting visit…' : 'Start visit',
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
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 24),
                children: [
                  if (!widget.shop.isVerified || !widget.atShop)
                    _Note(
                      [
                        if (!widget.shop.isVerified) 'New shop, awaiting verification',
                        if (!widget.atShop) 'You are not at this shop',
                      ].join(' · '),
                    ),
                  _Summary(intel: intel, openActions: recs.length),
                  const SizedBox(height: 24),
                  _SectionTitle(t('Before you go in')),
                  SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        _LinkRow(
                          icon: Icons.chat_bubble_outline_rounded,
                          title: t('What to talk about'),
                          subtitle: t('Points to raise with the shopkeeper'),
                          onTap: _showBrief,
                        ),
                        const Divider(height: 1, indent: 56),
                        _LinkRow(
                          icon: Icons.receipt_long_outlined,
                          title: t('Suggested order'),
                          subtitle: t('What this shop usually buys, ready to send'),
                          onTap: _openOrder,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(child: _SectionTitle(t('To do in this shop'))),
                      if (recs.length > 3)
                        TextButton(onPressed: () => _openAllActions(recs), child: Text('See all ${recs.length}')),
                    ],
                  ),
                  if (recs.isEmpty)
                    SurfaceCard(child: Text(t('Nothing to act on right now.')))
                  else
                    SurfaceCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (final (i, rec) in recs.take(3).indexed) ...[
                            if (i > 0) const Divider(height: 1, indent: 16),
                            _ActionRow(rec: rec, onTap: () => _openAction(rec)),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),
                  SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: _LinkRow(
                      icon: Icons.insights_outlined,
                      title: t('Shop details'),
                      subtitle: t('All the numbers for this shop'),
                      onTap: () => _openDetails(intel),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// A recommendation's action without product codes, which mean nothing to an officer.
String _plainAction(String action) => action.replaceAll(RegExp(r'\s*\([A-Z0-9][A-Z0-9-]{3,}\)'), '');

/// Confidence as words an officer can act on.
String _sure(num confidence) => confidence >= .85
    ? 'We are sure about this'
    : confidence >= .6
    ? 'We are fairly sure about this'
    : 'We are not sure about this';

String _money(num value) {
  final digits = value.round().toString();
  final grouped = digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '৳$grouped';
}

num? _score(Map<String, dynamic> intel, String dimension) {
  for (final s in (intel['scores'] as List).cast<Map<String, dynamic>>()) {
    if (s['dimension'] == dimension) return s['value'] as num?;
  }
  return null;
}

/// The three numbers an officer needs walking in; everything else is under Shop details.
class _Summary extends StatelessWidget {
  const _Summary({required this.intel, required this.openActions});
  final Map<String, dynamic> intel;
  final int openActions;

  @override
  Widget build(BuildContext context) {
    final share = ((intel['shelf'] as Map?)?['all'] as Map?)?['share_of_shelf'] as num?;
    final opportunity = _score(intel, 'opportunity');
    final classification = intel['classification'] as Map?;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _Figure(value: share == null ? '—' : pct(share), label: t('Square on shelf'))),
              Expanded(
                child: _Figure(value: opportunity == null ? '—' : _money(opportunity), label: t('Extra sales / month')),
              ),
              Expanded(child: _Figure(value: '$openActions', label: t('Things to do'))),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            [
              if (classification != null) 'Class ${classification['code']} · ${classification['label']}',
              if (share == null) 'No shelf audit yet',
              if (intel['data_origin'] == 'synthetic') 'Demo data',
            ].join('  ·  '),
            style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          style: const TextStyle(fontSize: AppFontSize.xl, fontWeight: FontWeight.w600, color: AppColors.ink),
        ),
      ),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: AppFontSize.base, fontWeight: FontWeight.w600, color: AppColors.inkMuted),
    ),
  );
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    leading: Icon(icon, color: AppColors.ink),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink)),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted)),
    trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.inkSubtle),
  );
}

/// One recommendation as a single calm row: what to do, and what it is worth.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.rec, required this.onTap});
  final Map<String, dynamic> rec;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final value = ((rec['expected_impact'] as Map?) ?? const {})['monthly_value_bdt'] as num?;
    final high = (rec['priority'] as int? ?? 2) == 1;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(
        _plainAction(rec['action'] as String),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500, color: AppColors.ink, height: 1.3),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          [if (value != null) '${_money(value)}/month', if (high) 'High priority'].join('  ·  '),
          style: TextStyle(fontSize: AppFontSize.sm, color: high ? AppColors.emeraldDark : AppColors.inkMuted),
        ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.inkSubtle),
    );
  }
}

/// The full recommendation, opened from its row; returns 'accepted' or 'rejected'.
class _ActionSheet extends StatelessWidget {
  const _ActionSheet({required this.rec});
  final Map<String, dynamic> rec;
  @override
  Widget build(BuildContext context) {
    final lines = evidenceLines((rec['evidence'] as Map).cast<String, dynamic>());
    final value = ((rec['expected_impact'] as Map?) ?? const {})['monthly_value_bdt'] as num?;
    const muted = TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted, height: 1.4);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(_plainAction(rec['action'] as String), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(rec['reason'] as String, style: const TextStyle(height: 1.45, color: AppColors.ink)),
            const SizedBox(height: 10),
            Text(
              [
                _sure(rec['confidence'] as num),
                if (value != null) 'could add about ${_money(value)} a month',
              ].join('  ·  '),
              style: muted,
            ),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(t('Why we suggest it'), style: TextStyle(fontWeight: FontWeight.w500, color: AppColors.ink)),
              const SizedBox(height: 6),
              for (final line in lines.where((l) => !l.startsWith('Rules:')))
                Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(line, style: muted)),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, 'rejected'),
                    child: Text(t('Does not apply')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, 'accepted'),
                    child: const Text("I'll do it"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AllActionsScreen extends StatelessWidget {
  const _AllActionsScreen({required this.shopName, required this.recs, required this.onOpen});
  final String shopName;
  final List<Map<String, dynamic>> recs;
  final Future<void> Function(Map<String, dynamic>) onOpen;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.canvas,
    appBar: AppBar(title: Text('Actions · $shopName')),
    body: ListView(
      padding: const EdgeInsets.all(AppSpace.page),
      children: [
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, rec) in recs.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 16),
                _ActionRow(
                  rec: rec,
                  onTap: () async {
                    await onOpen(rec);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

/// Everything measured about the shop, kept off the main page.
class _ShopDetailsScreen extends StatelessWidget {
  const _ShopDetailsScreen({required this.shop, required this.intel});
  final Shop shop;
  final Map<String, dynamic> intel;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.canvas,
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('Shop details')),
          Text(
            '${shop.name} · ${shop.code}',
            style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(AppSpace.page),
      children: [
        if (intel['data_origin'] == 'synthetic') const SyntheticBanner(),
        _ScoresCard(scores: (intel['scores'] as List).cast<Map<String, dynamic>>()),
        const SizedBox(height: 12),
        _ClassificationCard(classification: intel['classification'] as Map<String, dynamic>?),
        const SizedBox(height: 12),
        _ShelfCard(intel: intel),
        const SizedBox(height: 12),
        _PortfolioCard(portfolio: intel['portfolio'] as Map<String, dynamic>),
      ],
    ),
  );
}

/// Shown wherever numbers come from the synthetic demo organization.
class SyntheticBanner extends StatelessWidget {
  const SyntheticBanner({super.key});
  @override
  Widget build(BuildContext context) => _Note(t('SYNTHETIC DEMO DATA — not real sales or market figures'));
}

/// A quiet one-line note above the content.
class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
  );
}

/// A card that shows its title and a one-line summary, and opens for the detail.
class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.title, this.subtitle, required this.children});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SurfaceCard(
    padding: EdgeInsets.zero,
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted)),
        children: children,
      ),
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
          PrimaryButton(label: t('Try again'), onPressed: onRetry),
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
      return SurfaceCard(child: Text(t('Not classified yet.')));
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
            style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
          subtitle: Text(
            human ? 'Set by a manager' : 'Rule-based · data completeness ${pct(c['confidence'] as num)}',
            style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted),
          ),
          children: [
            if (human) Text('Note: ${(c['evidence'] as Map?)?['note'] ?? ''}'),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_rounded, size: 16, color: AppColors.inkMuted),
                    const SizedBox(width: 6),
                    Expanded(child: Text(reason, style: const TextStyle(fontSize: AppFontSize.md))),
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
        Text(
          t('Outlet scores'),
          style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
        ),
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
                      style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                    ),
                  )
                else
                  Text(
                    s['unit'] == 'bdt_per_month'
                        ? '৳${(s['value'] as num).round()}/mo'
                        : s['unit'] == 'pct_of_target'
                        ? '${(s['value'] as num).round()}% of target'
                        : '${(s['value'] as num).round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
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
    const meta = TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            rec['action'] as String,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppFontSize.lg, color: AppColors.ink),
          ),
          const SizedBox(height: 4),
          Text(rec['reason'] as String, style: const TextStyle(fontSize: AppFontSize.md, height: 1.35)),
          const SizedBox(height: 6),
          Row(
            children: [
              if (priority == 1) ...[
                Text(t('High priority'), style: TextStyle(fontSize: AppFontSize.sm, color: AppColors.emeraldDark)),
                const Text('  ·  ', style: meta),
              ],
              Text('Confidence ${pct(rec['confidence'] as num)}', style: meta),
            ],
          ),
          if (impact['monthly_value_bdt'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Peer-based potential ≈ ৳${(impact['monthly_value_bdt'] as num).round()}/month (estimate)',
                style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
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
                title: Text(
                  t('Why?'),
                  style: TextStyle(fontSize: AppFontSize.md, fontWeight: FontWeight.w500, color: AppColors.inkMuted),
                ),
                children: [
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text('• $line', style: const TextStyle(fontSize: AppFontSize.md)),
                    ),
                  Text(
                    'Source: ${rec['source']} · ${rec['generator_version']}',
                    style: const TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
          if (onAccept != null && rec['status'] == 'open')
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: AppSpace.sm,
                children: [
                  TextButton(onPressed: onReject, child: Text(t('Not relevant'))),
                  FilledButton(onPressed: onAccept, child: Text(t('Accept'))),
                ],
              ),
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
    return _DetailsCard(
      title: t('Own portfolio mix'),
      subtitle: '৳${(totals['monthly_value'] as num).round()}/month · ${totals['distinct_skus']} SKUs',
      children: [
        Text(
          'Last ${window['days']} days · orders of own brands only',
          style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
        ),
        const SizedBox(height: 12),
        if (current.isEmpty) Text(t('No orders in this period.')),
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
                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
                      ),
                    ),
                    Text(
                      pct(entry['value_share'] as num),
                      style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (entry['value_share'] as num).toDouble().clamp(0, 1),
                    minHeight: 4,
                    backgroundColor: AppColors.surfaceAlt,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Target ${pct(targets[entry['key']])} · peers ${pct(peers[entry['key']])}',
                  style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
      ],
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
      return SurfaceCard(child: Text(t('No shelf audit yet. Start one to measure share of shelf and placement.')));
    }
    final all = shelf['all'] as Map<String, dynamic>;
    final range = (all['share_of_shelf_range'] as List?)?.cast<num>();
    final competitors = ((intel['competition'] as Map)['presence'] as List).cast<Map<String, dynamic>>();
    return _DetailsCard(
      title: t('Latest shelf audit'),
      subtitle:
          'Own share of shelf ${pct(all['share_of_shelf'] as num?)}'
          '${range != null && range[0] != range[1] ? ' (${pct(range[0])}–${pct(range[1])})' : ''}',
      children: [
        Text(
          '${all['own_facings']} own · ${all['competitor_facings']} competitor · '
          '${all['unknown_facings']} unidentified of ${all['total_facings']} facings · '
          '${pct(all['verified_ratio'] as num)} human-verified',
          style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
        ),
        for (final c in competitors.where((c) => c['is_own'] != true).take(4))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${c['name']}: ${c['facings']} facings (${pct(c['share_of_shelf'] as num?)})'),
          ),
      ],
    );
  }
}

class _BriefSheet extends StatefulWidget {
  const _BriefSheet({required this.brief});
  final Map<String, dynamic> brief;
  @override
  State<_BriefSheet> createState() => _BriefSheetState();
}

class _BriefSheetState extends State<_BriefSheet> {
  static const _icons = {
    'opportunity': Icons.trending_up_rounded,
    'promotion': Icons.local_offer_outlined,
    'competitor': Icons.visibility_outlined,
    'relationship': Icons.receipt_long_outlined,
  };
  static const _first = 3;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final points = (widget.brief['talking_points'] as List).cast<Map<String, dynamic>>();
    final shown = _all ? points : points.take(_first).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(t('What to talk about'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              widget.brief['headline'] as String,
              style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted),
            ),
            const SizedBox(height: 20),
            if (points.isEmpty) Text(t('Nothing specific to raise for this outlet yet.')),
            for (final point in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_icons[point['kind']] ?? Icons.chat_outlined, size: 20, color: AppColors.emeraldDark),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(point['text'] as String, style: const TextStyle(height: 1.45, color: AppColors.ink)),
                    ),
                  ],
                ),
              ),
            if (points.length > _first)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _all = !_all),
                  child: Text(_all ? 'Show less' : 'Show ${points.length - _first} more'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
