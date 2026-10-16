import 'package:agent_tray_demo/main_window.dart';
import 'package:agent_tray_demo/src/rust/api/agent.dart';
import 'package:agent_tray_demo/tray_panel.dart';
import 'package:agent_tray_demo/ui/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AgentSnapshot snapshot({
  String driver = 'iPhone',
  int done = 28,
  List<MemoryMark> marks = const [],
}) =>
    AgentSnapshot(
      task: 'checkout',
      done: done,
      total: 40,
      running: true,
      driver: driver,
      tokensUsed: 35000,
      tokensBudget: 100000,
      engines: const ['main', 'tray'],
      memoryMarks: marks,
      rssKb: 204800,
      popoverVisible: true,
      revision: 7,
    );

Widget host(Widget child) => MaterialApp(theme: buildTheme(), home: child);

void main() {
  group('TrayPanelView', () {
    Future<void> pumpPanel(WidgetTester tester, Widget panel) async {
      tester.view.physicalSize = const Size(440, 330);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(panel));
    }

    testWidgets('renders the wireframe state', (tester) async {
      await pumpPanel(tester, TrayPanelView(snapshot: snapshot(), onSubmit: (_) {}));
      expect(find.text('Another'), findsOneWidget);
      expect(find.text('Driven from iPhone'), findsOneWidget);
      expect(find.text('checkout'), findsOneWidget);
      expect(find.text('28/40'), findsOneWidget);
      expect(find.textContaining('2 engines share this state'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('labels local drivers', (tester) async {
      await pumpPanel(tester, TrayPanelView(snapshot: snapshot(driver: 'tray'), onSubmit: (_) {}));
      expect(find.text('Driven from tray'), findsOneWidget);
      await pumpPanel(tester, TrayPanelView(snapshot: snapshot(driver: 'main'), onSubmit: (_) {}));
      expect(find.text('Driven from main window'), findsOneWidget);
      await pumpPanel(tester, TrayPanelView(snapshot: snapshot(driver: ''), onSubmit: (_) {}));
      expect(find.text('Idle'), findsOneWidget);
    });

    testWidgets('sends trimmed prompt and clears the field', (tester) async {
      final sent = <String>[];
      await pumpPanel(tester, TrayPanelView(snapshot: snapshot(), onSubmit: sent.add));
      await tester.enterText(find.byType(TextField), '  fix checkout  ');
      await tester.tap(find.byKey(const Key('send')));
      await tester.pump();
      expect(sent, ['fix checkout']);
      expect(find.text('fix checkout'), findsNothing);

      await tester.tap(find.byKey(const Key('send')));
      expect(sent, hasLength(1), reason: 'empty prompt is ignored');
    });

    testWidgets('offers to open the main window', (tester) async {
      var opened = false;
      await pumpPanel(
        tester,
        TrayPanelView(snapshot: snapshot(), onSubmit: (_) {}, onOpenMainWindow: () => opened = true),
      );
      await tester.tap(find.byKey(const Key('open-main')));
      expect(opened, isTrue);
    });

    testWidgets('shows missing plugin registration', (tester) async {
      await pumpPanel(
        tester,
        TrayPanelView(
          snapshot: snapshot(),
          onSubmit: (_) {},
          pluginError: 'MissingPluginException(No implementation found)',
        ),
      );
      expect(find.byKey(const Key('plugin-error')), findsOneWidget);
      expect(find.text('Driven from iPhone'), findsNothing);
    });
  });

  group('MainWindowView', () {
    Widget view(AgentSnapshot s, {VoidCallback? onShowPopover}) => host(MainWindowView(
          snapshot: s,
          onShowPopover: onShowPopover ?? () {},
          onRemote: () {},
          onStop: () {},
          onSubmit: (_) {},
        ));

    testWidgets('waits for the popover engine, then can show it', (tester) async {
      var opened = false;
      await tester.pumpWidget(view(snapshot(), onShowPopover: () => opened = true));
      expect(find.text('Waiting for the popover engine to start…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('show-popover')));
      expect(opened, isTrue);
    });

    testWidgets('reports the second engine memory cost', (tester) async {
      await tester.pumpWidget(view(snapshot(marks: const [
        MemoryMark(label: 'before tray engine', rssKb: 200 * 1024),
        MemoryMark(label: 'tray engine ready', rssKb: 245 * 1024),
      ])));
      expect(find.text('Second engine cost ≈ +45.0 MB'), findsOneWidget);
      expect(find.text('engine 2: tray'), findsOneWidget);
    });
  });
}
