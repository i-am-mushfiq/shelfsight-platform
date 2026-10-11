import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/session.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/onboarding_widgets.dart';
import 'app_shell.dart';

/// Onboarding 4/4: in-app explanation shown before any system dialog.
/// Both actions continue into the app; wire "Allow location" to the real
/// permission request (e.g. geolocator) when GPS is integrated.
class LocationPermissionScreen extends StatelessWidget {
  const LocationPermissionScreen({super.key, required this.session});
  final UserSession session;

  void _continue(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => AppShell(session: session)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        BrandMark(size: 44),
                        Spacer(),
                        OnboardingProgress(step: 2, total: 2),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const LocationIllustration(),
                    const SizedBox(height: 24),
                    Text(
                      t('Find your current shop'),
                      style: TextStyle(
                        fontSize: AppFontSize.xxl,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.6,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      t('ShelfSight uses your location while the app is open to identify the retail shop you are visiting.'),
                      style: TextStyle(fontSize: AppFontSize.lg, height: 1.45),
                    ),
                    const SizedBox(height: 20),
                    _Benefit(
                      icon: Icons.near_me_rounded,
                      text: t('Detect the nearest assigned shop'),
                    ),
                    _Benefit(
                      icon: Icons.verified_rounded,
                      text: t('Verify store visits'),
                    ),
                    _Benefit(
                      icon: Icons.photo_camera_rounded,
                      text: t('Enable shop-specific shelf audits'),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 12),
              child: Column(
                children: [
                  PrimaryButton(
                    label: t('Allow location'),
                    onPressed: () => _continue(context),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () => _continue(context),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      foregroundColor: AppColors.inkMuted,
                    ),
                    child: Text(
                      t('Not now'),
                      style: TextStyle(
                        fontSize: AppFontSize.lg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 15,
                        color: AppColors.inkMuted,
                      ),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          t('Background tracking is not used in this demo'),
                          style: TextStyle(
                            fontSize: AppFontSize.md,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.mint,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: AppColors.emeraldDark, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: AppFontSize.lg,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            ),
          ),
        ),
      ],
    ),
  );
}
