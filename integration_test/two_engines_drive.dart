import 'package:agent_tray_demo/main_window.dart';
import 'package:agent_tray_demo/src/rust/api/agent.dart';
import 'package:agent_tray_demo/src/rust/frb_generated.dart';
import 'package:agent_tray_demo/tray_panel.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _prompt = 'refactor payments';

/// Runs the real app with both engines in one process: the test drives the
/// main window, and the tray engine (started by desktop_multi_window with this
/// same entrypoint) types a prompt into the real panel and sends it.
Future<void> main(List<String> args) async {
  if (args.firstOrNull == 'multi_window') return _trayEngine();

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tray panel prompt drives the shared agent', (tester) async {
    await RustLib.init();
    await attachEngine(name: mainEngineName);
    final states = watchState().asBroadcastStream();

    // The main window starts hidden (tray-first), and a hidden view never
    // renders, so show it before driving it.
    await tester.runAsync(() async => (await WindowController.fromCurrentEngine()).show());
    await tester.pumpWidget(const MainApp());
    await tester.pumpAndSettle();

    Future<AgentSnapshot> until(bool Function(AgentSnapshot) test) async =>
        (await tester.runAsync(
            () => states.firstWhere(test).timeout(const Duration(seconds: 60))))!;

    // The popover engine is started hidden at launch, before any click.
    final attached = await until(
        (s) => s.memoryMarks.any((m) => m.label == 'tray engine ready'));
    expect(attached.engines, [mainEngineName, trayEngineName]);
    expect(attached.popoverVisible, isFalse);
    expect(attached.memoryMarks.map((m) => m.label),
        containsAll(['before tray engine', 'tray engine ready']));

    await tester.tap(find.byKey(const Key('show-popover')));
    await until((s) => s.popoverVisible);

    final run = await until((s) => s.driver == trayEngineName);
    expect(run.task, 'refactor-payments');
    expect(run.running, isTrue);

    await until((s) => s.done >= 2);
    await tester.pump();
    expect(find.textContaining('driven by tray'), findsOneWidget);
    expect(find.textContaining('Second engine cost'), findsOneWidget);

    await stopRun();
  });
}

/// The popover engine's side: boot the real popover, wait until it is opened,
/// then type and send like a user.
Future<void> _trayEngine() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(await bootTrayPanel());

  await watchState().firstWhere((s) => s.popoverVisible);
  final controller = LiveWidgetController(WidgetsBinding.instance);
  final field = find.byType(EditableText);
  // Rendering starts once the window is shown; wait for the laid-out panel.
  while (WidgetsBinding.instance.rootElement == null || field.evaluate().isEmpty) {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  controller.state<EditableTextState>(field).updateEditingValue(
      const TextEditingValue(text: _prompt));
  await controller.pump();
  await controller.tap(find.byKey(const Key('send')));
}
