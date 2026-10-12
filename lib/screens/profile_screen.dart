import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/session.dart';
import '../offline/offline_backend.dart';
import '../recognition/debug_log.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import 'support_screens.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _saveOriginals = true;
  bool _useMobileData = false;
  bool _captureHints = true;

  @override
  Widget build(BuildContext context) {
    return FixedHeaderScrollView(
      title: t('Profile'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.list(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 68,
                            height: 68,
                            decoration: BoxDecoration(
                              color: AppColors.navy,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              currentSession.value?.initials ?? 'RA',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: AppFontSize.xxl,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 15),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentSession.value?.name ?? 'Rahim Ahmed',
                                  style: TextStyle(
                                    fontSize: AppFontSize.xl,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  currentSession.value?.roleLabel ?? 'Sales Officer',
                                  style: TextStyle(color: AppColors.inkMuted),
                                ),
                                SizedBox(height: 8),
                                StatusPill(
                                  label: currentSession.value?.territory ?? 'Dhaka North',
                                  icon: Icons.location_on_outlined,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      const Divider(),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _ProfileMetric(
                              value: '142',
                              label: t('Audits'),
                            ),
                          ),
                          SizedBox(height: 38, child: VerticalDivider()),
                          Expanded(
                            child: _ProfileMetric(value: '38', label: t('Stores')),
                          ),
                          SizedBox(height: 38, child: VerticalDivider()),
                          Expanded(
                            child: _ProfileMetric(
                              value: '96%',
                              label: t('On time'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SyncCenterScreen()),
                ),
                borderRadius: BorderRadius.circular(22),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: const Color(0xFFA7F3D0)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_done_outlined,
                        color: AppColors.emeraldDark,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t('All data synced'),
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppColors.emeraldDark,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              t('Last sync • just now'),
                              style: TextStyle(
                                fontSize: AppFontSize.sm,
                                color: AppColors.emeraldDark,
                              ),
                            ),
                          ],
                        ),
                      ),
                      StatusPill(label: t('ONLINE')),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _SettingHeader(title: t('Capture & storage')),
              const SizedBox(height: 10),
              Card(
                child: Column(
                  children: [
                    SwitchListTile.adaptive(
                      value: _captureHints,
                      onChanged: (value) =>
                          setState(() => _captureHints = value),
                      secondary: const Icon(Icons.tips_and_updates_outlined),
                      title: Text(
                        t('Capture guidance'),
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(t('Show alignment and quality tips')),
                    ),
                    const Divider(height: 1, indent: 56),
                    SwitchListTile.adaptive(
                      value: _saveOriginals,
                      onChanged: (value) =>
                          setState(() => _saveOriginals = value),
                      secondary: const Icon(Icons.photo_library_outlined),
                      title: Text(
                        t('Keep original photos'),
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(t('Save a local copy after upload')),
                    ),
                    const Divider(height: 1, indent: 56),
                    SwitchListTile.adaptive(
                      value: _useMobileData,
                      onChanged: (value) =>
                          setState(() => _useMobileData = value),
                      secondary: const Icon(Icons.network_cell_outlined),
                      title: Text(
                        t('Upload on mobile data'),
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(t('Otherwise wait for Wi-Fi')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _SettingHeader(title: t('App settings')),
              const SizedBox(height: 10),
              Card(
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.language_rounded,
                      title: t('Language'),
                      trailing: t('English'),
                      onTap: _showLanguagePicker,
                    ),
                    const Divider(height: 1, indent: 56),
                    _SettingsRow(
                      icon: Icons.notifications_none_rounded,
                      title: t('Notifications'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const NotificationsScreen(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _SettingsRow(
                      icon: Icons.admin_panel_settings_outlined,
                      title: t('App permissions'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PermissionsScreen(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _SettingsRow(
                      icon: PlatformApi.offline ? Icons.phone_android_rounded : Icons.laptop_rounded,
                      title: 'Recognition',
                      trailing: PlatformApi.serverLabel,
                      onTap: _chooseRecognition,
                    ),
                    const Divider(height: 1, indent: 56),
                    _SettingsRow(
                      icon: Icons.bug_report_outlined,
                      title: 'Recognition log',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const RecognitionLogScreen()),
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    _SettingsRow(
                      icon: Icons.help_outline_rounded,
                      title: t('Help & support'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const HelpSupportScreen(),
                        ),
                      ),
                    ),
                    if (PlatformApi.offline) ...[
                      const Divider(height: 1, indent: 56),
                      _SettingsRow(
                        key: const Key('reset-demo'),
                        icon: Icons.restart_alt_rounded,
                        title: t('Reset demo data'),
                        trailing: t('On this phone'),
                        onTap: _resetDemo,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: () {
                    PlatformApi.instance.signOut();
                    currentSession.value = null;
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (_) => false,
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.red,
                    side: const BorderSide(color: AppColors.red),
                    shape: const StadiumBorder(),
                  ),
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(
                    t('Sign out'),
                    style: TextStyle(fontSize: AppFontSize.lg, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  t('ShelfSight 1.0.0 • Field build'),
                  style: TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }


  /// Phone models or the laptop server. A token only works on its own server, so a change
  /// signs out and goes back to the sign-in screen.
  Future<void> _chooseRecognition() async {
    final before = PlatformApi.baseUrl;
    final saved = await showDialog<String>(context: context, builder: (_) => const ServerAddressDialog());
    if (saved == null || saved == before || !mounted) return;
    PlatformApi.instance.signOut();
    currentSession.value = null;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Recognition: ${PlatformApi.serverLabel}. Sign in again.')),
    );
  }

  /// Without a server the demo's visits, photos, orders and new shops live on this phone;
  /// this clears them so the next demo starts from the shipped data.
  Future<void> _resetDemo() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Reset demo data?')),
        content: Text(t('Visits, photos, orders, decisions and shops added on this phone are deleted. Shops and their history come back as shipped.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t('Reset'))),
        ],
      ),
    );
    if (confirmed != true) return;
    await OfflineBackend.instance.reset();
    messenger.showSnackBar(SnackBar(content: Text(t('Demo data reset'))));
  }
  void _showLanguagePicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('App language'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              ListTile(
                onTap: () => Navigator.pop(context),
                title: Text(t('English')),
                trailing: const Icon(
                  Icons.radio_button_checked_rounded,
                  color: AppColors.emeraldDark,
                ),
              ),
              ListTile(
                onTap: () => Navigator.pop(context),
                title: const Text('বাংলা'),
                trailing: const Icon(
                  Icons.radio_button_off_rounded,
                  color: AppColors.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileMetric extends StatelessWidget {
  const _ProfileMetric({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: AppFontSize.xl, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 2),
      Text(
        label,
        style: const TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted),
      ),
    ],
  );
}

class _SettingHeader extends StatelessWidget {
  const _SettingHeader({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) => Text(
    title.toUpperCase(),
    style: const TextStyle(
      fontSize: AppFontSize.xs,
      color: AppColors.inkMuted,
      fontWeight: FontWeight.w600,
      letterSpacing: .8,
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String? trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: Icon(icon, color: AppColors.inkMuted),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(color: AppColors.inkMuted, fontSize: AppFontSize.sm),
          ),
        const SizedBox(width: 5),
        const Icon(Icons.chevron_right_rounded, color: AppColors.inkMuted),
      ],
    ),
  );
}
