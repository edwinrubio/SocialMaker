import 'package:flutter/material.dart';

/// SocialMaker brand colors (also used by the app icon in
/// tool/brand_icon.swift and the splash screen in pubspec.yaml).
abstract final class Brand {
  /// Primary accent: record button, selections, primary actions.
  static const pink = Color(0xFFFE2C55);

  /// Second gradient stop of the mark.
  static const orange = Color(0xFFFF8A3D);

  /// Splash and dark surfaces.
  static const night = Color(0xFF0C0912);

  /// Adaptive icon background.
  static const plum = Color(0xFF1A0B17);

  static const gradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [pink, orange],
  );
}
