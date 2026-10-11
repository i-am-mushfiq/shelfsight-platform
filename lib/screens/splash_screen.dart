import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../theme/app_theme.dart';
import '../widgets/onboarding_widgets.dart';
import 'login_screen.dart';

/// Onboarding 1/4. Auto-advances to login; no user navigation.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 2200), _next);
  }

  void _next() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 420),
        pageBuilder: (_, a, b) => const LoginScreen(),
        transitionsBuilder: (_, a, b, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.navy,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 260,
            child: ShelfPattern(opacity: .05, rows: 3),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const Spacer(flex: 5),
                  TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeOutCubic,
                    tween: Tween(begin: 0, end: 1),
                    builder: (context, v, child) => Opacity(
                      opacity: v,
                      child: Transform.translate(
                        offset: Offset(0, 14 * (1 - v)),
                        child: child,
                      ),
                    ),
                    child: Column(
                      children: [
                        BrandMark(size: 120, glow: true),
                        SizedBox(height: 28),
                        Text(
                          t('ShelfSight'),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: AppFontSize.display,
                            height: 1,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -1,
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          t('Retail visibility, measured'),
                          style: TextStyle(
                            color: Color(0xFFB6C2D4),
                            fontSize: AppFontSize.lg,
                            letterSpacing: .2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(flex: 6),
                  const EmeraldLoader(),
                  const SizedBox(height: 36),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
