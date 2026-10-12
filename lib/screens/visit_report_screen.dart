import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'package:flutter/services.dart';

import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'detection_review_screen.dart';
import 'order_screen.dart';
import 'outlet_screen.dart';

/// Everything one shop visit established: store type, shelf share by company, brand and
/// product, must-stock availability, placement, the order placed, and follow-up actions.
/// Built by the server from stored evidence, so it reflects the latest human review.
class VisitReportScreen extends StatefulWidget {
  const VisitReportScreen({super.key, required this.visitId, this.report, this.closeToOutlet = false});
  final String visitId;
  final Map<String, dynamic>? report;

  /// True right after submitting: "Done" returns to the outlet past the camera screens.
  final bool closeToOutlet;

  @override
  State<VisitReportScreen> createState() => _VisitReportScreenState();
}

class _VisitReportScreenState extends State<VisitReportScreen> {
  late Map<String, dynamic>? _report = widget.report;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_report == null) _load();
  }

  Future<void> _load() async {
    try {
      final report = await PlatformApi.instance.visitReport(widget.visitId);
      if (mounted) {
        setState(() {
          _report = report;
          _error = null;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Map<String, dynamic> get _outlet => _report!['outlet'] as Map<String, dynamic>;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } on ApiException catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editOrder(Map<String, dynamic> order) async {
    final changed = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OrderScreen(
          outletId: _outlet['id'] as String,
          outletName: _outlet['name'] as String,
          order: order,
        ),
      ),
    );
    if (changed != null) await _load();
  }

  Future<void> _createOrder() async {
    final placed = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OrderScreen(
          outletId: _outlet['id'] as String,
          outletName: _outlet['name'] as String,
          visitId: widget.visitId,
        ),
      ),
    );
    if (placed != null) await _load();
  }

  Future<void> _cancelOrder(Map<String, dynamic> order) async {
    final reason = await showDialog<String>(context: context, builder: (_) => const _CancelDialog());
    if (reason == null) return;
    await _run(() => PlatformApi.instance.cancelOrder(order['id'] as String, reason));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report!['summary_text'] as String));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Copied. Paste it into WhatsApp, SMS or email.'))),
      );
    }
  }

  /// Opens the visit's photos to check the packs the model found; the report is refreshed after.
  Future<void> _checkResults() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final visit = await PlatformApi.instance.visit(widget.visitId);
      final ids = [
        for (final c in (visit['captures'] as List? ?? const []).cast<Map<String, dynamic>>())
          if (c['status'] == 'analysed') c['id'] as String,
      ];
      if (ids.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(t('No photos with results in this visit.'))));
        return;
      }
      await navigator.push(MaterialPageRoute(
        builder: (_) => DetectionReviewScreen(
          storeName: _outlet['name'] as String? ?? '',
          visitId: widget.visitId,
          captureIds: ids,
          reviewOnly: true,
        ),
      ));
      await _load();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  void _done() {
    final navigator = Navigator.of(context);
    if (widget.closeToOutlet) {
      navigator.popUntil((route) => route.isFirst || route.settings.name == OutletScreen.routeName);
    } else {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.closeToOutlet,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('Visit result')),
            if (report != null)
              Text(
                [
                  _outlet['name'] as String,
                  if ((report['store_type'] as Map?)?['name'] != null) (report['store_type'] as Map)['name'] as String,
                ].join(' · '),
                style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
              ),
          ],
        ),
      ),
      bottomNavigationBar: report == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 12),
                child: Row(
                  children: [
                    SizedBox(
                      height: 56,
                      child: OutlinedButton.icon(
                        key: const Key('check-results'),
                        onPressed: _checkResults,
                        style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
                        icon: const Icon(Icons.fact_check_outlined),
                        label: Text(t('Check results')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      height: 56,
                      child: OutlinedButton(
                        onPressed: _copy,
                        style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
                        child: Tooltip(message: t('Share'), child: const Icon(Icons.ios_share_rounded)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: PrimaryButton(
                        label: widget.closeToOutlet ? 'Back to the shop' : 'Done',
                        onPressed: _done,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      body: _error != null && report == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    PrimaryButton(label: t('Try again'), onPressed: _load),
                  ],
                ),
              ),
            )
          : report == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 4, AppSpace.page, AppSpace.xl),
                children: [
                  _ResultCard(report: report),
                  const SizedBox(height: AppSpace.section),
                  SectionTitle(title: t('Order for the shop')),
                  const SizedBox(height: AppSpace.sm),
                  _OrderCard(
                    order: report['order'] as Map<String, dynamic>?,
                    busy: _busy,
                    onEdit: _editOrder,
                    onConfirm: (order) =>
                        _run(() => PlatformApi.instance.confirmOrder(order['id'] as String)),
                    onCancel: _cancelOrder,
                    onCreate: _createOrder,
                  ),
                  const SizedBox(height: AppSpace.section),
                  SectionTitle(title: t('Missing from the shelf')),
                  const SizedBox(height: AppSpace.sm),
                  _AvailabilityCard(items: (report['availability'] as List).cast<Map<String, dynamic>>()),
                  const SizedBox(height: AppSpace.section),
                  ..._companies(report['shelf'] as Map<String, dynamic>),
                  _MoreDetails(report: report),
                ],
              ),
            ),
    );
  }

  List<Widget> _companies(Map<String, dynamic> shelf) {
    final rows = (shelf['by_manufacturer'] as List).cast<Map<String, dynamic>>();
    if (rows.isEmpty) return const [];
    return [
      SectionTitle(title: t('Who has the shelf')),
      const SizedBox(height: AppSpace.sm),
      SurfaceCard(
        child: Column(
          children: [
            for (final (i, row) in rows.indexed)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
                child: _ShareBar(
                  label: row['name'] as String,
                  detail: '${row['facings']} packs',
                  share: (row['share'] as num?)?.toDouble() ?? 0,
                  color: row['is_own'] == true ? AppColors.emeraldDark : AppColors.red,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.section),
    ];
  }
}

/// The answer first, in plain words: how much of the shelf is Square.
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.report});
  final Map<String, dynamic> report;

  @override
  Widget build(BuildContext context) {
    final shelf = report['shelf'] as Map<String, dynamic>;
    final previous = report['previous_store_type'] as Map<String, dynamic>?;
    final storeType = report['store_type'] as Map<String, dynamic>?;
    if ((shelf['total_facings'] as num) == 0) {
      return SurfaceCard(child: Text(t('We could not find any packs in the photos of this visit.')));
    }
    final unknown = shelf['unknown_facings'] as num;
    return SurfaceCard(
      color: AppColors.navy,
      borderColor: AppColors.navy,
      padding: const EdgeInsets.fromLTRB(AppSpace.card, 22, AppSpace.card, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pct(shelf['share_of_shelf'] as num?),
            style: const TextStyle(color: Colors.white, fontSize: AppFontSize.hero, fontWeight: FontWeight.w600, letterSpacing: -1),
          ),
          Text(
            t('of this shelf is Square'),
            style: TextStyle(color: Colors.white, fontSize: AppFontSize.lg),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            '${shelf['own_facings']} Square packs · ${shelf['competitor_facings']} from other companies'
            '${unknown > 0 ? ' · $unknown we could not read' : ''}',
            style: const TextStyle(color: Colors.white70, fontSize: AppFontSize.md),
          ),
          if (previous != null && storeType != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Shop type changed to ${storeType['name']}',
                style: const TextStyle(color: Colors.white70, fontSize: AppFontSize.md),
              ),
            ),
          if (report['data_origin'] == 'synthetic')
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(t('Demo data'), style: TextStyle(color: Colors.white54, fontSize: AppFontSize.sm)),
            ),
        ],
      ),
    );
  }
}

/// Everything else about the visit, folded away: details, rules, products, actions, method.
class _MoreDetails extends StatelessWidget {
  const _MoreDetails({required this.report});
  final Map<String, dynamic> report;

  Widget _tile(String title, List<Widget> children, {String? subtitle}) => ExpansionTile(
    tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.card),
    childrenPadding: const EdgeInsets.fromLTRB(AppSpace.card, 0, AppSpace.card, AppSpace.lg),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500, color: AppColors.ink)),
    subtitle: subtitle == null
        ? null
        : Text(subtitle, style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
    children: children,
  );

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted, height: 1.5);
    final outlet = report['outlet'] as Map<String, dynamic>;
    final visit = report['visit'] as Map<String, dynamic>;
    final photos = report['photos'] as Map<String, dynamic>;
    final shelf = report['shelf'] as Map<String, dynamic>;
    final started = DateTime.parse(visit['started_at'] as String).toLocal();
    final klass = outlet['class'] as Map<String, dynamic>?;
    final officer = visit['officer'] as Map<String, dynamic>?;
    final placement = report['placement'] as Map<String, dynamic>;
    final rules = (placement['results'] as List).cast<Map<String, dynamic>>();
    final products = (shelf['by_product'] as List).cast<Map<String, dynamic>>();
    final recs = (report['recommendations'] as List).cast<Map<String, dynamic>>();
    final warnings = (report['warnings'] as List).cast<String>();
    final models = ((photos['models'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final range = (shelf['range'] as List?)?.cast<num>();
    final tiles = <Widget>[
      _tile(t('Visit details'), [
        Text(
          '${outlet['code']}${klass == null ? '' : ' · Class ${klass['code']} ${klass['label']}'}'
          '${outlet['is_verified'] == false ? ' · new shop, not yet verified' : ''}\n'
          '${started.day.toString().padLeft(2, '0')}/${started.month.toString().padLeft(2, '0')} '
          '${started.hour.toString().padLeft(2, '0')}:${started.minute.toString().padLeft(2, '0')}'
          '${officer == null ? '' : ' · ${officer['name']}'}\n'
          '${photos['analysed']} of ${photos['total']} photos read',
          style: small,
        ),
      ]),
      if (rules.isNotEmpty)
        _tile(
          t('Shelf rules'),
          [
            for (final rule in rules)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: RuleResultCard(result: rule)),
          ],
          subtitle: placement['score'] == null ? null : '${(placement['score'] as num).round()}% followed',
        ),
      if (products.isNotEmpty)
        _tile(t('All products seen'), [
          for (final p in products)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.circle, size: 8, color: p['is_own'] == true ? AppColors.emeraldDark : AppColors.red),
                  const SizedBox(width: 10),
                  Expanded(child: Text('${p['name']}', style: const TextStyle(fontSize: AppFontSize.md))),
                  Text('${p['facings']}', style: const TextStyle(color: AppColors.inkMuted)),
                ],
              ),
            ),
        ], subtitle: '${products.length} products'),
      if (recs.isNotEmpty)
        _tile(t('Next time in this shop'), [
          for (final rec in recs)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: RecommendationCard(rec: rec)),
        ], subtitle: '${recs.length} suggestions'),
      _tile(t('How this was measured'), [
        Text(
          t('Packs were found in the photos and matched to Square product pictures. Similar-looking products can be mixed up, so the numbers are a close estimate.'),
          style: small,
        ),
        if (range != null && range[0] != range[1])
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Square could be ${pct(range[0])}–${pct(range[1])} once the packs we could not read are checked.',
              style: small,
            ),
          ),
        for (final warning in warnings)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(warning, style: small)),
        for (final model in models)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Method: ${model['provider']} · ${model['version']}',
              style: const TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkSubtle),
            ),
          ),
      ]),
    ];
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (i, tile) in tiles.indexed) ...[
            if (i > 0) const Divider(height: 1, indent: AppSpace.card),
            tile,
          ],
        ],
      ),
    );
  }
}

class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.label, required this.detail, required this.share, required this.color});
  final String label;
  final String detail;
  final double share;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink)),
          ),
          Text(
            '${pct(share)} · $detail',
            style: const TextStyle(fontSize: AppFontSize.sm, fontWeight: FontWeight.w600, color: AppColors.inkMuted),
          ),
        ],
      ),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: share.clamp(0, 1),
          minHeight: 7,
          backgroundColor: AppColors.surfaceAlt,
          color: color,
        ),
      ),
    ],
  );
}

class _AvailabilityCard extends StatelessWidget {
  const _AvailabilityCard({required this.items});
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return SurfaceCard(child: Text(t('There is no must-have list for this shop type.')));
    }
    final problems = items.where((i) => i['status'] == 'missing' || i['status'] == 'low').toList();
    final onShelf = items.where((i) => i['status'] == 'on_shelf').length;
    final unchecked = items.where((i) => i['status'] == 'not_checked').length;
    const muted = TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (problems.isEmpty)
            Row(
              children: [
                Icon(Icons.check_circle_outline_rounded, color: AppColors.emeraldDark),
                SizedBox(width: 10),
                Text(t('Nothing missing'), style: TextStyle(fontWeight: FontWeight.w500, color: AppColors.ink)),
              ],
            ),
          for (final item in problems)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (item['product'] as Map)['name'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w500, color: AppColors.ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item['status'] == 'missing'
                              ? 'Not on the shelf'
                              : 'Only ${item['facings']} on the shelf, should be ${item['min_facings']}',
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  item['status'] == 'missing'
                      ? StatusPill(label: t('Missing'), color: AppColors.red, background: AppColors.redSoft)
                      : StatusPill(label: t('Few left'), color: AppColors.amberInk, background: AppColors.amberSoft),
                ],
              ),
            ),
          if (onShelf > 0 || unchecked > 0) ...[
            if (problems.isNotEmpty) const Divider(height: 8),
            const SizedBox(height: 8),
            if (onShelf > 0) Text('$onShelf must-have product${onShelf == 1 ? ' is' : 's are'} on the shelf', style: muted),
            if (unchecked > 0)
              Text(
                '$unchecked not checked: their rack was not photographed',
                style: muted,
              ),
          ],
        ],
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({
    required this.order,
    required this.busy,
    required this.onEdit,
    required this.onConfirm,
    required this.onCancel,
    required this.onCreate,
  });
  final Map<String, dynamic>? order;
  final bool busy;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(Map<String, dynamic>) onConfirm;
  final void Function(Map<String, dynamic>) onCancel;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final order = this.order;
    if (order == null) {
      return SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('No order was needed this time.'),
              style: TextStyle(color: AppColors.ink),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: busy ? null : onCreate,
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: Text(t('Create an order')),
            ),
          ],
        ),
      );
    }
    final status = order['status'] as String;
    final (label, color, background) = switch (status) {
      'confirmed' => ('Order placed', AppColors.emeraldDark, AppColors.mint),
      'draft' => ('Not placed yet', AppColors.amberInk, AppColors.amberSoft),
      _ => ('Cancelled', AppColors.red, AppColors.redSoft),
    };
    final lines = (order['lines'] as List).cast<Map<String, dynamic>>();
    final editable = order['editable'] == true;
    final reason = (order['meta'] as Map?)?['cancel_reason'];
    return SurfaceCard(
      borderColor: status == 'cancelled' ? AppColors.border : AppColors.emeraldDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusPill(label: label, color: color, background: background),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  order['source'] == 'auto' ? 'Made from this visit' : 'Made by you',
                  style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                ),
              ),
              Text(
                '৳${(order['value'] as num).round()}',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppFontSize.lg, color: AppColors.ink),
              ),
            ],
          ),
          if (reason != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Cancelled: $reason', style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
            ),
          const SizedBox(height: 10),
          // Product and quantity only; why each line was suggested is shown under Edit.
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(line['name'] as String, style: const TextStyle(color: AppColors.ink)),
                  ),
                  Text(
                    '× ${line['quantity']}',
                    style: const TextStyle(fontWeight: FontWeight.w500, color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          if (editable)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (status == 'draft')
                  FilledButton.icon(
                    onPressed: busy ? null : () => onConfirm(order),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.navy),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(t('Confirm order')),
                  ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => onEdit(order),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(t('Edit')),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => onCancel(order),
                  icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.red),
                  label: Text(t('Cancel order')),
                ),
              ],
            ),
          if (status == 'cancelled')
            OutlinedButton.icon(
              onPressed: busy ? null : onCreate,
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: Text(t('Create a new order')),
            ),
        ],
      ),
    );
  }
}

class _CancelDialog extends StatefulWidget {
  const _CancelDialog();
  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('Cancel this order?')),
    content: TextField(
      controller: _reason,
      autofocus: true,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(labelText: t('Reason'), hintText: t('e.g. Owner will order next week')),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t('Keep order'))),
      FilledButton(
        onPressed: _reason.text.trim().length < 3 ? null : () => Navigator.of(context).pop(_reason.text.trim()),
        style: FilledButton.styleFrom(backgroundColor: AppColors.red),
        child: Text(t('Cancel order')),
      ),
    ],
  );
}

/// One placement rule's outcome on the shelf.
class RuleResultCard extends StatelessWidget {
  const RuleResultCard({super.key, required this.result});
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
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
                ),
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: AppFontSize.md)),
                for (final detail in details)
                  Text('• $detail', style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
