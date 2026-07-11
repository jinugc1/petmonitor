import 'package:flutter/material.dart';

/// Material 3 theme shared by both apps. The owner app additionally uses
/// Cupertino widgets where iOS idiom matters (handled per-widget).
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6D4C41), // warm, pet-friendly brown
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}
