import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _unreadOnly = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Notifications')),
        actions: [
          TextButton(onPressed: () {}, child: Text(t('Mark all read'))),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          Row(
            children: [
              ChoiceChip(
                label: Text(t('All')),
                selected: !_unreadOnly,
                showCheckmark: false,
                onSelected: (_) => setState(() => _unreadOnly = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text(t('Unread 3')),
                selected: _unreadOnly,
                showCheckmark: false,
                onSelected: (_) => setState(() => _unreadOnly = true),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _NoticeCard(
            icon: Icons.rate_review_outlined,
            title: t('Audit needs review'),
            body: t('7 uncertain products in Meena Bazar need classification.'),
            time: t('8 min ago'),
            color: AppColors.amber,
            unread: true,
          ),
          const SizedBox(height: 10),
          _NoticeCard(
            icon: Icons.cloud_done_outlined,
            title: t('Audit synced'),
            body: t('Shwapno Super Shop was uploaded successfully.'),
            time: t('34 min ago'),
            color: AppColors.emerald,
            unread: true,
          ),
          const SizedBox(height: 10),
          _NoticeCard(
            icon: Icons.trending_up_rounded,
            title: t('Share improved'),
            body: t('Gulshan route gained 5.8% Square-facing share this week.'),
            time: t('2 hours ago'),
            color: Color(0xFF38BDF8),
            unread: true,
          ),
          if (!_unreadOnly) ...[
            const SizedBox(height: 10),
            _NoticeCard(
              icon: Icons.assignment_turned_in_outlined,
              title: t('Daily target complete'),
              body: t('All 6 scheduled stores were visited yesterday.'),
              time: t('Yesterday'),
              color: AppColors.inkMuted,
            ),
          ],
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.time,
    required this.color,
    this.unread = false,
  });
  final IconData icon;
  final String title;
  final String body;
  final String time;
  final Color color;
  final bool unread;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (unread)
                      const Icon(
                        Icons.circle,
                        size: 9,
                        color: AppColors.emerald,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: AppFontSize.md,
                    height: 1.4,
                    color: AppColors.inkMuted,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  time,
                  style: const TextStyle(
                    fontSize: AppFontSize.xs,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SyncCenterScreen extends StatefulWidget {
  const SyncCenterScreen({super.key});
  @override
  State<SyncCenterScreen> createState() => _SyncCenterScreenState();
}

class _SyncCenterScreenState extends State<SyncCenterScreen> {
  bool _retrying = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t('Sync center'))),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFA7F3D0)),
          ),
          child: Row(
            children: [
              Icon(Icons.wifi_rounded, color: AppColors.emeraldDark, size: 28),
              SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('Online and ready'),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.emeraldDark,
                      ),
                    ),
                    Text(
                      t('Last successful sync • just now'),
                      style: TextStyle(
                        fontSize: AppFontSize.sm,
                        color: AppColors.emeraldDark,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _SyncStat(value: '0', label: t('Pending')),
            ),
            SizedBox(width: 10),
            Expanded(
              child: _SyncStat(value: '1', label: t('Needs retry'), warning: true),
            ),
            SizedBox(width: 10),
            Expanded(
              child: _SyncStat(value: '24', label: t('Synced')),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SectionTitle(title: t('Upload queue')),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const SizedBox(
                  width: 62,
                  height: 62,
                  child: ShelfArtwork(radius: 14),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('Prince Bazar'),
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 3),
                      Text(
                        t('3 photos • 18.4 MB'),
                        style: TextStyle(
                          fontSize: AppFontSize.sm,
                          color: AppColors.inkMuted,
                        ),
                      ),
                      SizedBox(height: 7),
                      StatusPill(
                        label: t('UPLOAD FAILED'),
                        color: Color(0xFFB45309),
                        background: Color(0xFFFEF3C7),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: () => setState(() => _retrying = !_retrying),
                  icon: _retrying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        PrimaryButton(
          label: _retrying ? 'Retrying upload...' : 'Retry failed uploads',
          onPressed: _retrying ? null : () => setState(() => _retrying = true),
        ),
      ],
    ),
  );
}

class _SyncStat extends StatelessWidget {
  const _SyncStat({
    required this.value,
    required this.label,
    this.warning = false,
  });
  final String value;
  final String label;
  final bool warning;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: AppFontSize.xxl,
              fontWeight: FontWeight.w600,
              color: warning ? const Color(0xFFB45309) : AppColors.navy,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted),
          ),
        ],
      ),
    ),
  );
}

class ReportFiltersScreen extends StatefulWidget {
  const ReportFiltersScreen({super.key});
  @override
  State<ReportFiltersScreen> createState() => _ReportFiltersScreenState();
}

class _ReportFiltersScreenState extends State<ReportFiltersScreen> {
  String _period = 'Last 30 days';
  String _area = 'All areas';
  final Set<String> _categories = {'All categories'};
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('Report filters')),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _period = 'Last 30 days';
            _area = 'All areas';
            _categories
              ..clear()
              ..add('All categories');
          }),
          child: Text(t('Reset')),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                Text(
                  t('DATE RANGE'),
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkMuted,
                    letterSpacing: .8,
                  ),
                ),
                const SizedBox(height: 10),
                ...['Last 7 days', 'Last 30 days', 'This quarter'].map(
                  (item) => ListTile(
                    onTap: () => setState(() => _period = item),
                    leading: Icon(
                      _period == item
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: _period == item
                          ? AppColors.emeraldDark
                          : AppColors.inkMuted,
                    ),
                    title: Text(
                      item,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  initialValue: _area,
                  decoration: InputDecoration(
                    labelText: t('Area'),
                    prefixIcon: Icon(Icons.location_on_outlined),
                  ),
                  items:
                      ['All areas', 'Gulshan & Banani', 'Dhanmondi', 'Mirpur']
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item),
                            ),
                          )
                          .toList(),
                  onChanged: (value) => setState(() => _area = value!),
                ),
                const SizedBox(height: 22),
                Text(
                  t('CATEGORIES'),
                  style: TextStyle(
                    fontSize: AppFontSize.xs,
                    fontWeight: FontWeight.w600,
                    color: AppColors.inkMuted,
                    letterSpacing: .8,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      [
                            'All categories',
                            'Food & Beverage',
                            'Personal Care',
                            'Household',
                          ]
                          .map(
                            (item) => FilterChip(
                              label: Text(item),
                              selected: _categories.contains(item),
                              onSelected: (selected) => setState(() {
                                if (item == 'All categories') {
                                  _categories
                                    ..clear()
                                    ..add(item);
                                } else {
                                  _categories.remove('All categories');
                                  selected
                                      ? _categories.add(item)
                                      : _categories.remove(item);
                                }
                              }),
                            ),
                          )
                          .toList(),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.file_download_outlined),
                  label: Text(t('Export report as PDF')),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: PrimaryButton(
              label: t('Apply filters'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    ),
  );
}

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});
  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final Map<String, bool> _permissions = {
    'Camera': true,
    'Location': true,
    'Photos & media': false,
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t('App permissions'))),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        Text(
          t('ShelfSight uses these permissions only while capturing and saving store audits.'),
          style: TextStyle(color: AppColors.inkMuted, height: 1.45),
        ),
        const SizedBox(height: 20),
        Card(
          child: Column(
            children: _permissions.entries
                .map(
                  (entry) => SwitchListTile.adaptive(
                    value: entry.value,
                    onChanged: (value) =>
                        setState(() => _permissions[entry.key] = value),
                    secondary: Icon(
                      entry.key == 'Camera'
                          ? Icons.camera_alt_outlined
                          : entry.key == 'Location'
                          ? Icons.location_on_outlined
                          : Icons.photo_library_outlined,
                    ),
                    title: Text(
                      entry.key,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(entry.value ? 'Allowed' : 'Not allowed'),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 18),
        StatusPill(
          label:
              t('Changes shown here are UI-only until native permission handling is connected'),
          icon: Icons.info_outline_rounded,
          color: AppColors.inkMuted,
          background: AppColors.surfaceAlt,
        ),
      ],
    ),
  );
}

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(t('Help & support'))),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        TextField(
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: t('Search help topics'),
          ),
        ),
        const SizedBox(height: 20),
        SectionTitle(title: t('Common questions')),
        const SizedBox(height: 10),
        Card(
          child: Column(
            children: [
              ExpansionTile(
                title: Text(
                  t('How should I capture a shelf?'),
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      t('Stand straight in front of the shelf, avoid glare, and capture one section at a time.'),
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  ),
                ],
              ),
              Divider(height: 1),
              ExpansionTile(
                title: Text(
                  t('Why is a product uncertain?'),
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      t('The logo may be hidden, blurred, or too small. Review the item and classify it manually.'),
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  ),
                ],
              ),
              Divider(height: 1),
              ExpansionTile(
                title: Text(
                  t('Can I work without internet?'),
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      t('Drafts can be saved locally and uploaded later from Sync Center.'),
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: t('Contact support'),
          onPressed: () {},
        ),
      ],
    ),
  );
}

class ShelfViewerScreen extends StatelessWidget {
  const ShelfViewerScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF050B14),
    appBar: AppBar(
      backgroundColor: const Color(0xFF050B14),
      foregroundColor: Colors.white,
      title: Text(t('Shelf photo'), style: TextStyle(color: Colors.white)),
      actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.download_outlined)),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              minScale: .8,
              maxScale: 5,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: ShelfArtwork(radius: 20),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            decoration: const BoxDecoration(
              color: Color(0xFF111827),
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _ViewerMetric(value: '126', label: t('Facings')),
                ),
                Expanded(
                  child: _ViewerMetric(value: '54', label: t('Square')),
                ),
                Expanded(
                  child: _ViewerMetric(value: '7', label: t('Uncertain')),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ViewerMetric extends StatelessWidget {
  const _ViewerMetric({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: AppFontSize.xl,
          fontWeight: FontWeight.w600,
        ),
      ),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: AppFontSize.xs)),
    ],
  );
}
