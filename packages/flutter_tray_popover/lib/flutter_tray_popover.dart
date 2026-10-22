/// A tray icon that opens a Flutter popover, rendered by a second Flutter
/// engine in the same process.
///
/// The app's normal engine calls [TrayPopover.setUp]. The plugin then creates
/// the tray icon and a second engine for the popover, started hidden so the
/// first click opens it instantly. Clicking the icon toggles the popover
/// under it, and clicking anywhere else closes it.
///
/// Both engines run the same app, but they're separate Dart isolates and
/// don't share Dart objects. Share state through native memory, for example
/// a Rust library reached over FFI.
///
/// The popover engine starts at a named entry point, `trayMain` by default.
/// Keep it in release builds with `@pragma('vm:entry-point')`:
///
/// ```dart
/// void main(List<String> args) => TrayPopover.run(
///       args: args,
///       app: () => runApp(const MainApp()),
///       popover: trayMain,
///     );
///
/// @pragma('vm:entry-point')
/// void trayMain() => runApp(const PopoverApp());
/// ```
///
/// macOS starts `trayMain` by name. The Linux embedder can only run `main`,
/// so there the popover engine runs `main` with [TrayPopover.popoverArgument],
/// and [TrayPopover.run] routes it to `popover`.
///
/// Each new engine starts without plugins, so the app's runner must register
/// its plugins on the popover engine (see the README).
library;

import 'dart:async';

import 'package:flutter/services.dart';

abstract final class TrayPopover {
  /// The argument the popover engine's `main` receives on Linux.
  static const popoverArgument = 'tray_popover';

  static const _channel = MethodChannel('flutter_tray_popover');
  static final _visibility = StreamController<bool>.broadcast();
  static var _listening = false;

  /// Whether this engine is the popover's, judged from `main`'s arguments.
  static bool isPopoverEngine(List<String> args) =>
      args.isNotEmpty && args.first == popoverArgument;

  /// Calls [popover] in the popover engine and [app] everywhere else.
  static void run({
    required List<String> args,
    required void Function() app,
    required void Function() popover,
  }) =>
      isPopoverEngine(args) ? popover() : app();

  /// Creates the tray icon and the popover engine. Call it once, from the
  /// app's main engine. Returns whether the popover window is transparent
  /// around what Flutter draws: always on macOS, and on Linux whenever a
  /// compositor is running.
  ///
  /// - [icon]: an asset path, for example `'assets/tray_icon.png'`.
  /// - [size]: the popover window's size, in logical pixels.
  /// - [entrypoint]: the popover's Dart entry point (macOS).
  /// - [keepAliveOnWindowClose]: closing the main window only hides it, so the
  ///   app keeps running in the tray until [quit] (Linux; on macOS return
  ///   `false` from `applicationShouldTerminateAfterLastWindowClosed`).
  /// - [optionSpaceShortcut]: <kbd>⌥ Space</kbd> toggles the popover from
  ///   any app (macOS).
  static Future<bool> setUp({
    required String icon,
    Size size = const Size(440, 330),
    String entrypoint = 'trayMain',
    bool keepAliveOnWindowClose = true,
    bool optionSpaceShortcut = false,
  }) async {
    _listen();
    final result = await _channel.invokeMapMethod<String, Object?>('setUp', {
      'icon': icon,
      'width': size.width.round(),
      'height': size.height.round(),
      'entrypoint': entrypoint,
      'keepAliveOnWindowClose': keepAliveOnWindowClose,
      'optionSpaceShortcut': optionSpaceShortcut,
    });
    return result?['transparent'] == true;
  }

  /// Shows the popover under the tray icon, with keyboard focus.
  static Future<void> show() => _channel.invokeMethod('show');

  static Future<void> hide() => _channel.invokeMethod('hide');

  static Future<void> toggle() => _channel.invokeMethod('toggle');

  static Future<bool> isVisible() async =>
      await _channel.invokeMethod<bool>('isVisible') ?? false;

  /// Whether the popover window is transparent around what Flutter draws.
  /// When it isn't, draw the popover edge to edge, or the empty margin shows
  /// as a frame.
  static Future<bool> isTransparent() async =>
      await _channel.invokeMethod<bool>('isTransparent') ?? false;

  /// Shows and focuses the main engine's window (the engine that called
  /// [setUp]; before [setUp], the calling engine's own window).
  static Future<void> showMainWindow() => _channel.invokeMethod('showMainWindow');

  /// Quits the app: both engines, the tray icon and the process.
  static Future<void> quit() => _channel.invokeMethod('quit');

  /// The popover was shown (`true`) or hidden (`false`), for whatever reason:
  /// a tray click, a click elsewhere, [show], [hide] or [toggle]. Available
  /// in every engine.
  static Stream<bool> get visibilityChanges {
    _listen();
    return _visibility.stream;
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'visibilityChanged') _visibility.add(call.arguments == true);
    });
  }
}
