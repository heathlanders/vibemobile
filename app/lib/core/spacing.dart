import 'package:flutter/widgets.dart';

/// Spacing, radius + motion tokens — see app/DESIGN.md §4–5, §9.
/// Use these instead of raw pixel values in widgets.

/// 8px-based spacing scale.
abstract final class Spacing {
  static const double xs = 4; // intra-component gaps, bubble margins
  static const double sm = 8; // chip padding, tight rows
  static const double md = 12; // default component padding
  static const double lg = 16; // page/section padding
  static const double xl = 24; // modal / centered-content padding

  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: lg);
}

/// Corner radii.
abstract final class Radii {
  static const double sm = 8; // chips, bubbles, thumbnails
  static const double md = 14; // cards
}

/// Motion tokens — see app/DESIGN.md §9. Motion communicates a state change;
/// it never decorates.
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 120); // colour/opacity swaps
  static const Duration base = Duration(milliseconds: 180); // entrances, page routes
  static const Duration slow = Duration(milliseconds: 240); // size changes, stagger cap

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeIn;
}
