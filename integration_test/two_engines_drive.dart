import 'package:agent_tray_demo/main_window.dart';
import 'package:agent_tray_demo/src/rust/api/agent.dart';
import 'package:agent_tray_demo/src/rust/frb_generated.dart';
import 'package:agent_tray_demo/tray_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tray_popover/flutter_tray_popover.dart';
import 'package:integration_test/integration_test.dart';

const _prompt = 'refactor payments';

/// Runs the real app with both engines in one process: the test drives the
/// main window, and the popover engine (started by the flutter_tray_popover
/// plugin; on Linux through this same `main`) types a prompt into the real
/// popover and sends it.
Future<void> main(List<String> args) async {
  if (TrayPopover.isPopoverEngine(args)) return _trayEngine();

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tray panel prompt drives the shared agent', (tester) async {
    await RustLib.init();
    await attachEngine(name: mainEngineName);
    final states = watchState().asBroadcastStream();

    // The main window starts hidden (tray-first), and a hidden view never
    // renders, so show it before driving it.
    await tester.runAsync(TrayPopover.showMainWindow);
    final visibility = TrayPopover.visibilityChanges.asBroadcastStream();
    await tester.pumpWidget(const MainApp());
    await tester.pumpAndSettle();

    Future<AgentSnapshot> until(bool Function(AgentSnapshot) test) async =>
        (await tester.runAsync(
            () => states.firstWhere(test).timeout(const Duration(seconds: 60))))!;

    // The popover engine is started hidden at launch, before any click.
    final attached = await until(
        (s) => s.memoryMarks.any((m) => m.label == 'tray engine ready'));
    expect(attached.engines, [mainEngineName, trayEngineName]);
    expect(await tester.runAsync(TrayPopover.isVisible), isFalse);
    expect(attached.memoryMarks.map((m) => m.label),
        containsAll(['before tray engine', 'tray engine ready']));

    final opened = visibility.firstWhere((visible) => visible);
    await tester.tap(find.byKey(const Key('show-popover')));
    await tester.runAsync(() => opened.timeout(const Duration(seconds: 30)));

    final run = await until((s) => s.driver == trayEngineName);
    expect(run.task, 'refactor-payments');
    expect(run.running, isTrue);

    final progressed = await until((s) => s.done >= 2);
    expect(progressed.messages.first.text, _prompt);
    expect(progressed.messages.first.author, trayEngineName);

    // The prompt typed in the popover (engine B) shows up in the chat window
    // (engine A), followed by the agent's live reply.
    await tester.pump();
    expect(find.text(_prompt), findsOneWidget);
    expect(find.text('You · from tray'), findsOneWidget);
    expect(find.textContaining('Working on refactor-payments'), findsOneWidget);
    expect(find.textContaining('second engine ≈ +'), findsOneWidget);

    await stopRun();
  });
}

/// The popover engine's side: boot the real popover, wait until it is opened,
/// then type and send like a user.
Future<void> _trayEngine() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Subscribe before attaching: the test opens the popover once this engine
  // has attached to the shared state.
  final opened = TrayPopover.visibilityChanges.firstWhere((visible) => visible);
  await RustLib.init();
  runApp(await bootTrayPanel());

  await opened;
  final controller = LiveWidgetController(WidgetsBinding.instance);
  final field = find.byType(EditableText);
  // Rendering starts once the window is shown; wait until the panel is laid
  // out at the popover's real size, not the 1x1 view of a hidden window.
  bool laidOut() =>
      WidgetsBinding.instance.rootElement != null &&
      field.evaluate().isNotEmpty &&
      WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.width > 100;
  while (!laidOut()) {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  controller.state<EditableTextState>(field).updateEditingValue(
      const TextEditingValue(text: _prompt));
  await controller.pump();
  await controller.tap(find.byKey(const Key('send')));
}
