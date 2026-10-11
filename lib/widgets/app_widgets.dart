import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.color = const Color(0xC9111827),
    this.borderColor = const Color(0x29FFFFFF),
    this.blur = 18,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color color;
  final Color borderColor;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: borderRadius,
            border: Border.all(color: borderColor),
          ),
          child: child,
        ),
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.backgroundColor = AppColors.navy,
    this.foregroundColor = Colors.white,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      disabledBackgroundColor: AppColors.surfaceAlt,
      disabledForegroundColor: AppColors.inkSubtle,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
      textStyle: AppText.label.copyWith(fontSize: AppFontSize.lg, fontWeight: FontWeight.w500),
    );
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: icon == null
          ? FilledButton(onPressed: onPressed, style: style, child: Text(label))
          : FilledButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon, size: 19),
              label: Text(label),
            ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.icon,
    this.color = AppColors.emeraldDark,
    this.background = AppColors.mint,
  });
  final String label;
  final IconData? icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppFontSize.sm,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class ShelfArtwork extends StatelessWidget {
  const ShelfArtwork({super.key, this.radius = 20, this.overlay});
  final double radius;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: Stack(
      fit: StackFit.expand,
      children: [
        const CustomPaint(painter: _ShelfPainter()),
        if (overlay != null) overlay!,
      ],
    ),
  );
}

class _ShelfPainter extends CustomPainter {
  const _ShelfPainter();
  static const palette = [
    Color(0xFFEF4444),
    Color(0xFFF59E0B),
    Color(0xFF10B981),
    Color(0xFF38BDF8),
    Color(0xFF8B5CF6),
    Color(0xFFF97316),
    Color(0xFFFACC15),
    Color(0xFFFB7185),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF243040),
    );
    final rng = math.Random(7);
    const rows = 5;
    final rowHeight = size.height / rows;
    for (var row = 0; row < rows; row++) {
      final y = row * rowHeight;
      var x = 6.0;
      while (x < size.width - 6) {
        final width = 12 + rng.nextDouble() * 18;
        final top = y + 8 + rng.nextDouble() * 5;
        final safeWidth = math.min(width, size.width - x - 5).toDouble();
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, safeWidth, rowHeight - 15),
          const Radius.circular(2),
        );
        canvas.drawRRect(
          rect,
          Paint()..color = palette[rng.nextInt(palette.length)],
        );
        canvas.drawRect(
          Rect.fromLTWH(
            x + 2,
            top + 3,
            math.max(2, safeWidth - 5).toDouble(),
            2,
          ),
          Paint()..color = Colors.white.withValues(alpha: .65),
        );
        x += width + 3;
      }
      canvas.drawRect(
        Rect.fromLTWH(0, y + rowHeight - 7, size.width, 7),
        Paint()..color = const Color(0xFF0F172A),
      );
      canvas.drawRect(
        Rect.fromLTWH(0, y + rowHeight - 7, size.width, 1),
        Paint()..color = Colors.white.withValues(alpha: .35),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    this.action,
    this.onAction,
  });
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
    ],
  );
}
