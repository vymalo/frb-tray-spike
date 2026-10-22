import 'package:flutter/widgets.dart';
import 'package:flutter_tray_popover/flutter_tray_popover.dart';

import 'main_window.dart';
import 'src/rust/api/agent.dart';
import 'src/rust/frb_generated.dart';
import 'tray_panel.dart';

/// Engine A (the main engine) starts here. On Linux the popover engine does
/// too, with [TrayPopover.popoverArgument], and is routed to [trayMain].
void main(List<String> args) =>
    TrayPopover.run(args: args, app: appMain, popover: trayMain);

/// Engine A: the chat window, which also sets up the tray and the popover.
Future<void> appMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Each engine has its own Dart isolate and must init the bridge; the Rust
  // library itself is loaded once per process, so its state is shared.
  await RustLib.init();
  await attachEngine(name: mainEngineName);
  await recordMemoryMark(label: 'main engine ready');
  runApp(const MainApp());
}

/// Engine B: the popover. The plugin starts this engine at `trayMain` by
/// name on macOS, so it must survive tree-shaking in release builds.
@pragma('vm:entry-point')
Future<void> trayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(await bootTrayPanel());
}
