import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'outlet_screen.dart';

String _money(num value) => value >= 100000
    ? '৳${(value / 100000).toStringAsFixed(1)} lakh'
    : '৳${value.round()}';

/// Loads one API payload and renders loading, error and data states consistently.
class _Loader extends StatefulWidget {
  const _Loader({required this.title, required this.subtitle, required this.load, required this.builder});
  final String title;
  final String Function(Map<String, dynamic>? data) subtitle;
  final Future<Map<String, dynamic>> Function() load;
  final List<Widget> Function(BuildContext context, Map<String, dynamic> data) builder;

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final data = await widget.load();
      if (mounted) setState(() => _data = data);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return FixedHeaderScrollView(
      title: widget.title,
      subtitle: widget.subtitle(data),
      trailing: IconButton(
        tooltip: t('Refresh'),
        onPressed: _load,
        icon: const Icon(Icons.refresh_rounded),
      ),
      slivers: [
        pagePadding([
          if (_error != null)
            SurfaceCard(
              color: AppColors.redSoft,
              borderColor: AppColors.red,
              onTap: _load,
              child: Text('$_error  Tap to retry.'),
            )
          else if (data == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (data['data_origin'] == 'synthetic') const SyntheticBanner(),
            ...widget.builder(context, data),
          ],
        ]),
      ],
    );
  }
}

class TerritoryDashboardScreen extends StatelessWidget {
  const TerritoryDashboardScreen({super.key, required this.session});
  final UserSession session;

  Future<Map<String, dynamic>> _load() async {
    final results = await Future.wait([
      PlatformApi.instance.overview(groupBy: 'territory'),
      PlatformApi.instance.competition(groupBy: 'channel'),
    ]);
    return {...results[0], 'competition': results[1]};
  }

  @override
  Widget build(BuildContext context) {
    return _Loader(
      title: t('Dashboard'),
      subtitle: (data) => '${session.territory} · ${session.roleLabel}',
      load: _load,
      builder: (context, data) {
        final groups = (data['groups'] as List).cast<Map<String, dynamic>>();
        final competition = data['competition'] as Map<String, dynamic>;
        final channels = (competition['groups'] as List).cast<Map<String, dynamic>>();
        num own = 0, total = 0, outlets = 0, visited = 0, value = 0, opportunity = 0;
        for (final g in groups) {
          own += g['own_facings'] as num;
          total += g['total_facings'] as num;
          outlets += g['outlets'] as num;
          visited += g['visited_30d'] as num;
          value += g['monthly_value_bdt'] as num;
          opportunity += g['opportunity_bdt_per_month'] as num;
        }
        final byManufacturer = <String, ({String name, bool isOwn, num facings})>{};
        for (final channel in channels) {
          for (final m in (channel['manufacturers'] as List).cast<Map<String, dynamic>>()) {
            final previous = byManufacturer[m['id']];
            byManufacturer[m['id'] as String] = (
              name: m['name'] as String,
              isOwn: m['is_own'] as bool,
              facings: (previous?.facings ?? 0) + (m['facings'] as num),
            );
          }
        }
        final manufacturers = byManufacturer.values.toList()
          ..sort((a, b) => b.facings.compareTo(a.facings));
        return [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: AppColors.navy, borderRadius: BorderRadius.circular(22)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('OWN SHARE OF SHELF'),
                  style: TextStyle(
                    color: Color(0xFFB6C2D4),
                    fontSize: AppFontSize.sm,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  total > 0 ? pct(own / total) : 'No audits yet',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: total > 0 ? AppFontSize.hero : AppFontSize.xxl,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${competition['outlets_audited']} of ${competition['outlets_in_scope']} outlets audited · '
                  '${total.round()} facings counted',
                  style: const TextStyle(color: Color(0xFFB6C2D4)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _Metric(label: t('Own sales / month'), value: _money(value))),
              const SizedBox(width: 10),
              Expanded(
                child: _Metric(
                  label: t('Visited in 30 days'),
                  value: outlets > 0 ? pct(visited / outlets) : '—',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Metric(
            label: t('Open portfolio opportunity (peer-based estimate)'),
            value: '${_money(opportunity)} / month',
          ),
          const SizedBox(height: 22),
          SectionTitle(title: t('Share of shelf by company')),
          const SizedBox(height: 8),
          SurfaceCard(
            child: manufacturers.isEmpty
                ? Text(t('Appears after the first shelf audits. Competitor brands need SKU-level recognition.'))
                : Column(
                    children: [
                      for (final m in manufacturers)
                        _ShareRow(
                          m.name,
                          total > 0 ? m.facings / total * 100 : 0,
                          m.isOwn ? AppColors.emeraldDark : AppColors.navy,
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 22),
          SectionTitle(title: t('By territory')),
          const SizedBox(height: 8),
          for (final g in groups)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SurfaceCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            g['label'] as String,
                            style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
                          ),
                          Text(
                            '${g['outlets']} outlets · ${_money(g['monthly_value_bdt'] as num)}/month · '
                            '${g['open_recommendations']} open actions',
                            style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
                          ),
                        ],
                      ),
                    ),
                    StatusPill(
                      label: 'Coverage ${pct(g['coverage_30d'] as num)}',
                      icon: Icons.route_outlined,
                    ),
                  ],
                ),
              ),
            ),
        ];
      },
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: AppFontSize.xl, fontWeight: FontWeight.w600, color: AppColors.ink)),
      ],
    ),
  );
}

class _ShareRow extends StatelessWidget {
  const _ShareRow(this.name, this.value, this.color);
  final String name;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          flex: 5,
          child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink)),
        ),
        Expanded(
          flex: 6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (value / 100).clamp(0, 1),
              minHeight: 8,
              backgroundColor: AppColors.surfaceAlt,
              color: color,
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            '${value.round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink),
          ),
        ),
      ],
    ),
  );
}

/// Outlets that need a supervisor's attention, ranked from real platform data.
class TerritoryAlertsScreen extends StatelessWidget {
  const TerritoryAlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _Loader(
      title: t('Exceptions'),
      subtitle: (data) => 'Outlets needing attention',
      load: () => PlatformApi.instance.overview(groupBy: 'outlet'),
      builder: (context, data) {
        final outlets = (data['groups'] as List).cast<Map<String, dynamic>>();
        final notVisited = outlets.where((o) => (o['visited_30d'] as num) == 0).toList()
          ..sort((a, b) => (b['monthly_value_bdt'] as num).compareTo(a['monthly_value_bdt'] as num));
        final opportunity = outlets.where((o) => (o['opportunity_bdt_per_month'] as num) > 0).toList()
          ..sort((a, b) =>
              (b['opportunity_bdt_per_month'] as num).compareTo(a['opportunity_bdt_per_month'] as num));
        final lowShare = outlets.where((o) => o['share_of_shelf'] != null).toList()
          ..sort((a, b) => (a['share_of_shelf'] as num).compareTo(b['share_of_shelf'] as num));
        return [
          SectionTitle(title: t('Lowest own share of shelf')),
          const SizedBox(height: 8),
          if (lowShare.isEmpty) SurfaceCard(child: Text(t('No audited outlets yet.'))),
          for (final o in lowShare.take(5))
            _ExceptionRow(
              important: true,
              title: o['label'] as String,
              detail: 'Own share ${pct(o['share_of_shelf'] as num)} at the latest audit',
            ),
          const SizedBox(height: 18),
          SectionTitle(title: t('Largest portfolio gaps')),
          const SizedBox(height: 8),
          for (final o in opportunity.take(5))
            _ExceptionRow(
              important: false,
              title: o['label'] as String,
              detail: '${o['open_recommendations']} open actions · peer-based potential '
                  '${_money(o['opportunity_bdt_per_month'] as num)}/month (estimate)',
            ),
          const SizedBox(height: 18),
          SectionTitle(title: t('Not visited in 30 days')),
          const SizedBox(height: 8),
          if (notVisited.isEmpty) SurfaceCard(child: Text(t('Every outlet was visited in the last 30 days.'))),
          for (final o in notVisited.take(5))
            _ExceptionRow(
              important: false,
              title: o['label'] as String,
              detail: '${_money(o['monthly_value_bdt'] as num)}/month in own sales',
            ),
          if (notVisited.length > 5)
            Text(
              '+ ${notVisited.length - 5} more',
              style: const TextStyle(color: AppColors.inkMuted),
            ),
        ];
      },
    );
  }
}

class _ExceptionRow extends StatelessWidget {
  const _ExceptionRow({required this.important, required this.title, required this.detail});
  final bool important;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: SurfaceCard(
      borderColor: important ? AppColors.red : AppColors.border,
      child: Row(
        children: [
          Icon(
            important ? Icons.priority_high_rounded : Icons.info_outline_rounded,
            color: important ? AppColors.red : AppColors.inkMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.ink)),
                Text(detail, style: const TextStyle(fontSize: AppFontSize.md, color: AppColors.inkMuted, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class TerritoryTeamScreen extends StatelessWidget {
  const TerritoryTeamScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _Loader(
      title: t('Team'),
      subtitle: (data) => data == null ? 'Sales Officers' : '${(data['groups'] as List).length} Sales Officers',
      load: () => PlatformApi.instance.overview(groupBy: 'officer'),
      builder: (context, data) => [
        for (final m in (data['groups'] as List).cast<Map<String, dynamic>>())
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SurfaceCard(
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.navy, borderRadius: BorderRadius.circular(15)),
                    child: Text(
                      (m['label'] as String).split(' ').where((p) => p.isNotEmpty).map((p) => p[0]).take(2).join(),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m['label'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppFontSize.lg, color: AppColors.ink),
                        ),
                        Text(
                          '${m['outlets']} outlets · ${m['visited_30d']} visited in 30 days · '
                          '${m['open_recommendations']} open actions',
                          style: const TextStyle(color: AppColors.inkMuted, fontSize: AppFontSize.md),
                        ),
                      ],
                    ),
                  ),
                  StatusPill(
                    label: m['share_of_shelf'] == null ? 'No audits' : 'Own ${pct(m['share_of_shelf'] as num)}',
                    icon: Icons.pie_chart_outline_rounded,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
