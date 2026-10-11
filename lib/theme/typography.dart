import 'package:flutter/painting.dart';

import 'tokens.dart';

/// Named text styles in Poppins. Prefer these over a new TextStyle; adjust with
/// `copyWith` only for colour or a one-off weight.
abstract final class AppText {
  static const fontFamily = 'Poppins';

  /// Glyphs Poppins lacks fall back to these: Bangla to Hind Siliguri (bundled), the rest
  /// (e.g. ৳) to the platform's own fonts.
  static const fontFamilyFallback = ['HindSiliguri', 'Roboto', 'Segoe UI', 'Arial'];

  static const display = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.display,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -.6,
    color: AppColors.ink,
  );

  static const headline = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.xxl,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -.4,
    color: AppColors.ink,
  );

  static const title = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.xl,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -.2,
    color: AppColors.ink,
  );

  static const subtitle = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.lg,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: AppColors.ink,
  );

  static const body = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.base,
    height: 1.55,
    fontWeight: FontWeight.w400,
    color: AppColors.ink,
  );

  static const bodyStrong = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.base,
    height: 1.55,
    fontWeight: FontWeight.w500,
    color: AppColors.ink,
  );

  static const secondary = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.md,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: AppColors.inkMuted,
  );

  static const label = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.base,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );

  static const small = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.sm,
    height: 1.35,
    fontWeight: FontWeight.w400,
    color: AppColors.inkMuted,
  );

  static const caption = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: AppFontSize.xs,
    height: 1.3,
    fontWeight: FontWeight.w400,
    color: AppColors.inkMuted,
  );
}
