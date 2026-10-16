import 'package:flutter/widgets.dart';

import 'main_window.dart';
import 'src/rust/api/agent.dart';
import 'src/rust/frb_generated.dart';
import 'tray_panel.dart';

/// Both engines start here. desktop_multi_window launches the tray engine with
/// `["multi_window", <windowId>, <arguments>]`; the main engine gets no args.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Each engine has its own Dart isolate and must init the bridge; the Rust
  // library itself is loaded once per process, so its state is shared.
  await RustLib.init();

  if (args.firstOrNull == 'multi_window') {
    runApp(await bootTrayPanel());
  } else {
    await attachEngine(name: mainEngineName);
    await recordMemoryMark(label: 'main engine ready');
    runApp(const MainApp());
  }
}
