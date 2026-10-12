import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/onboarding_widgets.dart';
import 'live_scan_screen.dart';
import 'location_permission_screen.dart';

/// Onboarding 2/4 (and 3/4: the same screen in its error state).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  /// Remembered for the app session only; persist with secure storage later.
  static String? rememberedId = 'SO-1001';

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final _idController = TextEditingController(
    text: LoginScreen.rememberedId ?? '',
  );
  final _passController = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  late bool _remember = LoginScreen.rememberedId != null;
  String? _error;

  @override
  void dispose() {
    _idController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_idController.text.trim().isEmpty || _passController.text.isEmpty) {
      setState(() => _error = 'Enter your employee ID and password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final UserSession user;
    try {
      user = UserSession.fromAuth(
        await PlatformApi.instance.login(_idController.text, _passController.text),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
      return;
    }
    if (!mounted) return;
    // Photos captured offline in an earlier session can upload now.
    unawaited(UploadQueue.instance.drain());
    LoginScreen.rememberedId = _remember ? user.employeeId : null;
    currentSession.value = user;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LocationPermissionScreen(session: user)),
    );
  }

  Future<void> _editServer() async {
    final saved = await showDialog<String>(
      context: context,
      builder: (_) => const ServerAddressDialog(),
    );
    if (saved != null && mounted) {
      setState(() => _error = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Recognition: ${PlatformApi.serverLabel}')));
    }
  }

  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('Need help signing in?'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                t('Accounts are created by your company. If you forgot your password or ID, contact your Territory Officer or the IT help desk.'),
                style: TextStyle(height: 1.45),
              ),
              const SizedBox(height: 14),
              StatusPill(
                label: 'Recognition: ${PlatformApi.serverLabel}',
                icon: Icons.dns_outlined,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: AppColors.navy,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 300,
            child: ShelfPattern(opacity: .06, rows: 3),
          ),
          Column(
            children: [
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                  child: Row(
                    children: [
                      BrandMark(size: 52),
                      SizedBox(width: 14),
                      Text(
                        t('ShelfSight'),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: AppFontSize.xxl,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.5,
                        ),
                      ),
                      Spacer(),
                      OnboardingProgress(step: 1, total: 2, onDark: true),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: AppColors.canvas,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      22,
                      28,
                      22,
                      bottomInset + 16,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight:
                            MediaQuery.sizeOf(context).height -
                            MediaQuery.paddingOf(context).top -
                            150 -
                            MediaQuery.paddingOf(context).bottom,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t('Welcome back'),
                            style: TextStyle(
                              fontSize: AppFontSize.xxl,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -.6,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            t('Sign in with your employee credentials'),
                            style: TextStyle(fontSize: AppFontSize.lg),
                          ),
                          const SizedBox(height: 26),
                          _FieldLabel(t('Employee ID')),
                          TextField(
                            controller: _idController,
                            enabled: !_busy,
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.characters,
                            autofillHints: const [AutofillHints.username],
                            onChanged: (_) {
                              if (_error != null) setState(() => _error = null);
                            },
                            decoration: InputDecoration(
                              hintText: t('e.g. SO-1001'),
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                          ),
                          const SizedBox(height: 18),
                          _FieldLabel(t('Password')),
                          TextField(
                            controller: _passController,
                            enabled: !_busy,
                            obscureText: _obscure,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.password],
                            onSubmitted: (_) => _submit(),
                            onChanged: (_) {
                              if (_error != null) setState(() => _error = null);
                            },
                            decoration: InputDecoration(
                              hintText: t('Enter your password'),
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                              ),
                              errorText: _error,
                              errorStyle: const TextStyle(
                                color: AppColors.red,
                                fontSize: AppFontSize.md,
                                fontWeight: FontWeight.w600,
                              ),
                              suffixIcon: IconButton(
                                tooltip: _obscure
                                    ? 'Show password'
                                    : 'Hide password',
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                                icon: Icon(
                                  _obscure
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () =>
                                      setState(() => _remember = !_remember),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        Checkbox(
                                          value: _remember,
                                          activeColor: AppColors.emeraldDark,
                                          onChanged: (v) => setState(
                                            () => _remember = v ?? false,
                                          ),
                                        ),
                                        Flexible(
                                          child: Text(
                                            t('Remember employee ID'),
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.ink,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          PrimaryButton(
                            label: _busy ? 'Signing in…' : 'Sign in',
                            icon: _busy
                                ? Icons.hourglass_top_rounded
                                : Icons.arrow_forward_rounded,
                            onPressed: _busy ? null : _submit,
                          ),
                          const SizedBox(height: 10),
                          // Demo without a server: recognition runs on this phone.
                          OutlinedButton.icon(
                            key: const Key('try-live-scan'),
                            onPressed: _busy
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const LiveScanScreen(storeName: 'Demo', onDevice: true),
                                    ),
                                  ),
                            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                            icon: const Icon(Icons.center_focus_strong_outlined),
                            label: Text(t('Try Live scan on this phone')),
                          ),
                          const SizedBox(height: 6),
                          Center(
                            child: TextButton(
                              onPressed: _showHelp,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                foregroundColor: AppColors.emeraldDark,
                              ),
                              child: Text(
                                t('Need help?'),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: AppFontSize.lg,
                                ),
                              ),
                            ),
                          ),
                          Center(
                            child: TextButton.icon(
                              key: const Key('server-address'),
                              onPressed: _busy ? null : _editServer,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 44),
                                foregroundColor: AppColors.inkMuted,
                              ),
                              icon: const Icon(Icons.dns_outlined, size: 18),
                              label: Text(
                                'Recognition: ${PlatformApi.serverLabel} · Change',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppFontSize.md),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  PlatformApi.offline ? Icons.phone_android_rounded : Icons.lock_rounded,
                                  size: 15,
                                  color: AppColors.inkMuted,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  PlatformApi.offline
                                      ? t('Works without a server or internet')
                                      : t('Secure, encrypted connection'),
                                  style: TextStyle(
                                    fontSize: AppFontSize.md,
                                    color: AppColors.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            height: MediaQuery.paddingOf(context).bottom + 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: AppFontSize.base,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
    ),
  );
}

/// Chooses where the app gets its data and recognises shelves: the models on this phone
/// (no server), or a laptop server on the same Wi-Fi (its GPU models, usually more accurate).
class ServerAddressDialog extends StatefulWidget {
  const ServerAddressDialog({super.key});

  @override
  State<ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<ServerAddressDialog> {
  late bool _phone = PlatformApi.offline;
  late final _controller = TextEditingController(
    text: PlatformApi.offline ? PlatformApi.laptopAddress : PlatformApi.baseUrl,
  );
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _address => _phone ? PlatformApi.offlineBaseUrl : _controller.text;

  void _show(bool ok, String message) => setState(() {
    _ok = ok;
    _result = message;
  });

  Future<void> _test() async {
    if (!_phone && _controller.text.trim().isEmpty) {
      _show(false, "Enter the laptop's IP address.");
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      final message = await PlatformApi.instance.ping(_address);
      if (mounted) _show(true, message);
    } on ApiException catch (error) {
      if (mounted) _show(false, error.message);
    } on FormatException {
      if (mounted) _show(false, 'That is not a valid server address.');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_phone && _controller.text.trim().isEmpty) {
      _show(false, "Enter the laptop's IP address.");
      return;
    }
    final navigator = Navigator.of(context);
    try {
      navigator.pop(await PlatformApi.instance.setServerAddress(_address));
    } on ApiException catch (error) {
      _show(false, error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('Recognition and data')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.phone_android_rounded),
                  label: Text(t('On this phone'), key: const Key('server-on-phone')),
                ),
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.laptop_rounded),
                  label: Text(t('Laptop server'), key: const Key('server-on-laptop')),
                ),
              ],
              selected: {_phone},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() {
                _phone = v.first;
                _result = null;
              }),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _phone
                ? t('No server or internet needed. Recognition runs on the phone with small models: quicker to set up, less accurate.')
                : t("Shelf photos, 360° spheres and Live scan are recognised on the laptop (its GPU models, more accurate). The phone and laptop must be on the same Wi-Fi. Enter the laptop's IP, e.g. 192.168.0.103 (http:// and port 8000 are added)."),
            style: const TextStyle(height: 1.4),
          ),
          if (!_phone) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('server-address-field'),
              controller: _controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() => _result = null),
              onSubmitted: (_) => _test(),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.dns_outlined), hintText: '192.168.0.103'),
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: 10),
            Text(
              _result!,
              style: TextStyle(color: _ok ? AppColors.emeraldDark : AppColors.red, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            t('Changing this signs you out.'),
            style: TextStyle(fontSize: AppFontSize.xs, color: AppColors.inkMuted),
          ),
        ],
      ),
    ),
    actions: [
      if (!_phone)
        TextButton(
          onPressed: _testing ? null : _test,
          child: Text(_testing ? 'Testing…' : 'Test'),
        ),
      TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
      FilledButton(onPressed: _save, child: Text(t('Save'))),
    ],
  );
}
