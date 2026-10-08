import 'dart:async';

import 'package:flutter/material.dart';

import '../models/session.dart';
import '../services/platform_api.dart';
import '../services/upload_queue.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/onboarding_widgets.dart';
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
                'Need help signing in?',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              const Text(
                'Accounts are created by your company. If you forgot your '
                'password or ID, contact your Territory Officer or the IT '
                'help desk.',
                style: TextStyle(height: 1.45),
              ),
              const SizedBox(height: 14),
              const StatusPill(
                label: 'Server: ${PlatformApi.baseUrl}',
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
                    children: const [
                      BrandMark(size: 52),
                      SizedBox(width: 14),
                      Text(
                        'ShelfSight',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
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
                          const Text(
                            'Welcome back',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.6,
                              color: AppColors.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Sign in with your employee credentials',
                            style: TextStyle(fontSize: 15.5),
                          ),
                          const SizedBox(height: 26),
                          const _FieldLabel('Employee ID'),
                          TextField(
                            controller: _idController,
                            enabled: !_busy,
                            textInputAction: TextInputAction.next,
                            textCapitalization: TextCapitalization.characters,
                            autofillHints: const [AutofillHints.username],
                            onChanged: (_) {
                              if (_error != null) setState(() => _error = null);
                            },
                            decoration: const InputDecoration(
                              hintText: 'e.g. SO-1001',
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                          ),
                          const SizedBox(height: 18),
                          const _FieldLabel('Password'),
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
                              hintText: 'Enter your password',
                              prefixIcon: const Icon(
                                Icons.lock_outline_rounded,
                              ),
                              errorText: _error,
                              errorStyle: const TextStyle(
                                color: AppColors.red,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
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
                                        const Flexible(
                                          child: Text(
                                            'Remember employee ID',
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
                          const SizedBox(height: 6),
                          Center(
                            child: TextButton(
                              onPressed: _showHelp,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                foregroundColor: AppColors.emeraldDark,
                              ),
                              child: const Text(
                                'Need help?',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.lock_rounded,
                                  size: 15,
                                  color: AppColors.inkMuted,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Secure, encrypted connection',
                                  style: TextStyle(
                                    fontSize: 13,
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
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
    ),
  );
}
