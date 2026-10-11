import 'package:flutter/painting.dart';

/// ShelfSight design tokens. Screens use these instead of literal values, so a
/// change here applies everywhere. See docs/design-system.md.
///
/// Colour roles:
///   ink / inkMuted / inkSubtle   text, from primary to least important
///   canvas / surface / surfaceAlt  page background, cards, quiet fills
///   border                       hairlines and card outlines
///   navy                         primary actions and selected state
///   emerald*, amber*, red*       success, warning and error, each with a soft fill
abstract final class AppColors {
  // "Calm field": low-glare sage neutrals, softened ink, desaturated status colours.
  // Brand (primary actions, selected state): a muted slate-teal instead of near-black.
  static const navy = Color(0xFF2C4A52);
  static const navySoft = Color(0xFF3F616A);

  // Text: green-charcoal, so dark text on the sage canvas is gentle but still well above AA.
  static const ink = Color(0xFF22302D);
  static const inkMuted = Color(0xFF66736F);
  static const inkSubtle = Color(0xFF9AA4A0);

  // Surfaces
  static const canvas = Color(0xFFF2F4F1);
  static const headerSurface = canvas;
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFEBEFEA);
  static const border = Color(0xFFE1E6E0);

  // Status: success (jade)
  static const emerald = Color(0xFF52B48E);
  static const emeraldDark = Color(0xFF2E7C61);
  static const mint = Color(0xFFE2F2E9);

  // Status: warning (ochre)
  static const amber = Color(0xFFD9A441);
  static const amberInk = Color(0xFF7D5714);
  static const amberSoft = Color(0xFFF8EFDB);

  // Status: error (clay)
  static const red = Color(0xFFD0645C);
  static const redSoft = Color(0xFFF8E7E4);
}

/// Spacing scale on a 4 pt grid.
abstract final class AppSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;

  /// Horizontal page gutter.
  static const double page = 20;

  /// Inside a card.
  static const double card = 20;

  /// Between sections of a page.
  static const double section = 28;
}

/// Corner radii.
abstract final class AppRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double pill = 999;

  static const card = BorderRadius.all(Radius.circular(lg));
  static const control = BorderRadius.all(Radius.circular(md));
  static const sheet = BorderRadius.vertical(top: Radius.circular(xl));
}

/// Type scale. Every font size in the app is one of these.
abstract final class AppFontSize {
  static const double xs = 11; // captions, attributions, chart axes
  static const double sm = 12; // metadata, pills
  static const double md = 13.5; // secondary text
  static const double base = 15; // body
  static const double lg = 16.5; // emphasised body, section titles
  static const double xl = 20; // screen and card titles
  static const double xxl = 24; // headlines
  static const double display = 32; // large figures
  static const double hero = 40; // single hero number
}
