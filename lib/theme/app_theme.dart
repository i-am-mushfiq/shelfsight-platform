import 'package:flutter/material.dart';

import 'tokens.dart';
import 'typography.dart';

export 'tokens.dart';
export 'typography.dart';

/// Material theme built from the design tokens, so stock widgets (buttons,
/// fields, app bars, dividers, sheets, list rows) match the custom ones without
/// per-screen styling. "Calm field": soft sage canvas, generous spacing, no
/// shadows, one muted primary colour.
abstract final class AppTheme {
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.navy,
      brightness: Brightness.light,
      primary: AppColors.navy,
      secondary: AppColors.emerald,
      surface: AppColors.surface,
      error: AppColors.red,
    );
    const controlBorder = OutlineInputBorder(
      borderRadius: AppRadius.control,
      borderSide: BorderSide(color: AppColors.border),
    );
    const buttonShape = RoundedRectangleBorder(borderRadius: AppRadius.control);
    const buttonSize = Size(64, 50);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      canvasColor: AppColors.canvas,
      fontFamily: AppText.fontFamily,
      fontFamilyFallback: AppText.fontFamilyFallback,
      splashFactory: InkSparkle.splashFactory,
      textTheme: TextTheme(
        displaySmall: AppText.display,
        headlineMedium: AppText.headline,
        titleLarge: AppText.title,
        titleMedium: AppText.subtitle,
        titleSmall: AppText.bodyStrong,
        bodyLarge: AppText.body.copyWith(fontSize: AppFontSize.lg),
        bodyMedium: AppText.body,
        bodySmall: AppText.small,
        labelLarge: AppText.label,
        labelMedium: AppText.small.copyWith(fontWeight: FontWeight.w500),
        labelSmall: AppText.caption,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.headerSurface,
        foregroundColor: AppColors.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        titleSpacing: AppSpace.page,
        titleTextStyle: AppText.subtitle.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.mint,
        indicatorShape: const StadiumBorder(),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected) ? AppColors.navy : AppColors.inkMuted,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return AppText.small.copyWith(
            color: selected ? AppColors.navy : AppColors.inkMuted,
            fontWeight: FontWeight.w500,
          );
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.navy,
          disabledBackgroundColor: AppColors.surfaceAlt,
          elevation: 0,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          shape: buttonShape,
          textStyle: AppText.label.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          side: const BorderSide(color: AppColors.border),
          shape: buttonShape,
          textStyle: AppText.label.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.navy,
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          textStyle: AppText.label.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: AppColors.inkMuted),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: AppSpace.page, vertical: AppSpace.xs),
        minVerticalPadding: AppSpace.md,
        horizontalTitleGap: AppSpace.lg,
        iconColor: AppColors.inkMuted,
        textColor: AppColors.ink,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: AppColors.surface,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: AppColors.border,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.sheet),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.xl))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.ink,
        contentTextStyle: AppText.body.copyWith(color: Colors.white),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        insetPadding: const EdgeInsets.all(AppSpace.page),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.border, space: 1, thickness: 1),
      expansionTileTheme: const ExpansionTileThemeData(
        shape: Border(),
        collapsedShape: Border(),
        iconColor: AppColors.inkMuted,
        collapsedIconColor: AppColors.inkSubtle,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.navy : AppColors.surfaceAlt,
        ),
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6))),
        side: const BorderSide(color: AppColors.inkSubtle, width: 1.5),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? AppColors.navy : Colors.transparent,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.navy),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.card,
          side: BorderSide(color: AppColors.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg + 2, vertical: AppSpace.lg + 2),
        hintStyle: AppText.body.copyWith(color: AppColors.inkSubtle),
        labelStyle: AppText.body.copyWith(color: AppColors.inkMuted),
        prefixIconColor: AppColors.inkSubtle,
        suffixIconColor: AppColors.inkSubtle,
        border: controlBorder,
        enabledBorder: controlBorder,
        errorBorder: controlBorder.copyWith(borderSide: const BorderSide(color: AppColors.red, width: 1.5)),
        focusedErrorBorder: controlBorder.copyWith(borderSide: const BorderSide(color: AppColors.red, width: 1.5)),
        focusedBorder: controlBorder.copyWith(borderSide: const BorderSide(color: AppColors.navy, width: 1.5)),
      ),
    );
  }
}
