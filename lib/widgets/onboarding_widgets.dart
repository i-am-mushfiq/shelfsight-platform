import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../theme/app_theme.dart';

/// Rounded logo tile used on every onboarding screen.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 64, this.glow = false});
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.navySoft,
        borderRadius: BorderRadius.circular(size * .28),
        border: Border.all(color: AppColors.emerald.withValues(alpha: .25)),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: AppColors.emerald.withValues(alpha: .28),
                  blurRadius: 44,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .28),
        child: Image.asset(
          'assets/branding/shelfsight-logo.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// Abstract, role-neutral shelf: rows of rounded product blocks on rails.
class ShelfPattern extends StatelessWidget {
  const ShelfPattern({
    super.key,
    this.color = Colors.white,
    this.opacity = .07,
    this.rows = 4,
  });
  final Color color;
  final double opacity;
  final int rows;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: CustomPaint(
        painter: _ShelfPatternPainter(color.withValues(alpha: opacity), rows),
        size: Size.infinite,
      ),
    ),
  );
}

class _ShelfPatternPainter extends CustomPainter {
  _ShelfPatternPainter(this.color, this.rows);
  final Color color;
  final int rows;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final rng = math.Random(5);
    final rowH = size.height / rows;
    for (var r = 0; r < rows; r++) {
      final base = (r + 1) * rowH - 6;
      var x = 14.0;
      while (x < size.width - 14) {
        final w = 16 + rng.nextDouble() * 22;
        final h = rowH * (.38 + rng.nextDouble() * .38);
        final rw = math.min(w, size.width - 14 - x);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, base - h, rw, h),
            const Radius.circular(6),
          ),
          paint,
        );
        x += w + 8;
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, base + 2, size.width, 4),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ShelfPatternPainter old) =>
      old.color != color || old.rows != rows;
}

/// "Step 1 of 2" dots shared by login and permission screens.
class OnboardingProgress extends StatelessWidget {
  const OnboardingProgress({
    super.key,
    required this.step,
    required this.total,
    this.onDark = false,
  });
  final int step; // 1-based
  final int total;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Step $step of $total',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= total; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.only(right: 6),
              width: i == step ? 26 : 8,
              height: 8,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: i == step
                    ? AppColors.emerald
                    : (onDark ? Colors.white24 : AppColors.border),
              ),
            ),
          const SizedBox(width: 6),
          Text(
            'Step $step of $total',
            style: TextStyle(
              fontSize: AppFontSize.sm,
              fontWeight: FontWeight.w600,
              color: onDark ? const Color(0xFFB6C2D4) : AppColors.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small emerald three-bar loading animation.
class EmeraldLoader extends StatefulWidget {
  const EmeraldLoader({super.key});
  @override
  State<EmeraldLoader> createState() => _EmeraldLoaderState();
}

class _EmeraldLoaderState extends State<EmeraldLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: t('Loading'),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 6,
                height:
                    10 +
                    14 *
                        math
                            .pow(math.sin((_c.value - i * .15) * math.pi), 2)
                            .toDouble(),
                decoration: BoxDecoration(
                  color: AppColors.emerald,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Friendly map + location illustration for the permission screen.
class LocationIllustration extends StatefulWidget {
  const LocationIllustration({super.key});
  @override
  State<LocationIllustration> createState() => _LocationIllustrationState();
}

class _LocationIllustrationState extends State<LocationIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: t('Map with a pin on a nearby shop'),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          height: 190,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const CustomPaint(painter: _MiniMapPainter()),
              Center(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    final t = _c.value;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 40 + 100 * t,
                          height: 40 + 100 * t,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.emerald.withValues(
                              alpha: .35 * (1 - t),
                            ),
                          ),
                        ),
                        Transform.translate(
                          offset: const Offset(0, -22),
                          child: Transform.rotate(
                            angle: -math.pi / 4,
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: AppColors.emerald,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(23),
                                  topRight: Radius.circular(23),
                                  bottomRight: Radius.circular(23),
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x550B1426),
                                    blurRadius: 10,
                                  ),
                                ],
                              ),
                              child: Transform.rotate(
                                angle: math.pi / 4,
                                child: const Icon(
                                  Icons.storefront_rounded,
                                  color: AppColors.navy,
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.navy,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniMapPainter extends CustomPainter {
  const _MiniMapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.mint);
    final block = Paint()..color = Colors.white.withValues(alpha: .55);
    final rng = math.Random(3);
    for (var i = 0; i < 14; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rng.nextDouble() * size.width,
            rng.nextDouble() * size.height,
            40 + rng.nextDouble() * 50,
            26 + rng.nextDouble() * 30,
          ),
          const Radius.circular(6),
        ),
        block,
      );
    }
    final road = Paint()
      ..color = Colors.white
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, size.height * .62),
      Offset(size.width, size.height * .5),
      road,
    );
    canvas.drawLine(
      Offset(size.width * .3, 0),
      Offset(size.width * .38, size.height),
      road,
    );
    canvas.drawLine(
      Offset(size.width * .75, 0),
      Offset(size.width * .68, size.height),
      road,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
