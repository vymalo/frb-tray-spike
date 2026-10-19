import 'package:flutter/services.dart';

/// ⌥Space from the macOS runner (MainFlutterWindow.swift), registered
/// system-wide so the popover opens from any app.
abstract final class GlobalHotkey {
  static const _channel = MethodChannel('agent_tray_demo/hotkey');

  static void listen(VoidCallback onToggle) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'toggle') onToggle();
    });
  }
}
