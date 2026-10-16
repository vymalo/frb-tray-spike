import 'package:flutter/material.dart';

/// Colours sampled from the "Mac tray · driven remotely" wireframe.
abstract final class Palette {
  static const sageDeep = Color(0xFFA8C3A6);
  static const sageMist = Color(0xFFE8EFE6);
  static const card = Color(0xFFFFFFFF);
  static const composer = Color(0xFFF1F3F0);
  static const send = Color(0xFF5A7247);
  static const ring = Color(0xFF5F7A52);
  static const ringFill = Color(0xFFCDE8C0);
  static const ringTrack = Color(0xFFE2E6E0);
  static const chip = Color(0xFFD3ECF1);
  static const chipText = Color(0xFF2F5661);
  static const ink = Color(0xFF1C1C1C);
  static const muted = Color(0xFF6B6B6B);
  static const logoPill = Color(0xFFC8E6B9);
  static const danger = Color(0xFFB3261E);

  static const backdrop = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [sageMist, sageDeep],
  );
}

ThemeData buildTheme() => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Palette.send,
        primary: Palette.send,
        surface: Palette.card,
      ),
      scaffoldBackgroundColor: Palette.sageMist,
    );
