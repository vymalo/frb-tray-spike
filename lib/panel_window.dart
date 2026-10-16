import 'package:flutter/services.dart';

/// Native helper registered by the runner on the popover engine; see
/// linux/runner/panel_window.cc and macos/Runner/MainFlutterWindow.swift.
abstract final class PanelWindow {
  static const _channel = MethodChannel('agent_tray_demo/panel_window');

  static const width = 440;
  static const height = 330;

  /// Shapes and places the window as a popover without showing it.
  static Future<void> configure() =>
      _channel.invokeMethod('configure', {'width': width, 'height': height});

  /// Brings the (already shown) popover to the front with keyboard focus.
  static Future<void> focus() => _channel.invokeMethod('focus');

  static Future<void> hide() => _channel.invokeMethod('hide');

  /// Called when the popover loses focus, i.e. the user clicked elsewhere.
  static void onFocusLost(VoidCallback callback) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'focusLost') callback();
    });
  }
}
