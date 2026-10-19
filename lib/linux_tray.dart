import 'package:flutter/services.dart';

/// Clicks on the runner's Linux tray icon (linux/runner/linux_tray.cc).
/// macOS uses tray_manager's status item instead.
abstract final class LinuxTray {
  static const _channel = MethodChannel('agent_tray_demo/linux_tray');

  /// [onActivate] gets the icon's screen x, or null when the desktop hides it.
  static void listen({required void Function(int? iconX) onActivate}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'activate') return;
      final x = (call.arguments as Map?)?['x'] as int?;
      onActivate(x == null || x < 0 ? null : x);
    });
  }
}
