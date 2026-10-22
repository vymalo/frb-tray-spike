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
  List<ChatMessage> messages = const [],
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
      messages: messages,
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

    testWidgets('menu replaces the native tray menu', (tester) async {
      final chosen = <PopoverMenu>[];
      await pumpPanel(
        tester,
        TrayPanelView(snapshot: snapshot(), onSubmit: (_) {}, onMenu: chosen.add),
      );
      await tester.tap(find.byKey(const Key('popover-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Simulate iPhone session'), findsOneWidget);
      expect(find.text('Quit'), findsOneWidget);
      await tester.tap(find.text('Simulate iPhone session'));
      await tester.pumpAndSettle();
      expect(chosen, [PopoverMenu.remote]);
    });

    testWidgets('can leave the area around the card transparent', (tester) async {
      BoxDecoration card() => tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.color == Palette.card);

      // Opaque window: the card fills it, so there is no frame around it.
      await pumpPanel(tester, TrayPanelView(snapshot: snapshot(), onSubmit: (_) {}));
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, Palette.card);
      expect(card().borderRadius, isNull);
      expect(card().boxShadow, isNull);

      await pumpPanel(
        tester,
        TrayPanelView(snapshot: snapshot(), onSubmit: (_) {}, transparentBackdrop: true),
      );
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor, Colors.transparent);
      expect(card().borderRadius, BorderRadius.circular(22));
      expect(card().boxShadow, isNotEmpty);
      expect(find.text('Driven from iPhone'), findsOneWidget);
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
    Widget view(AgentSnapshot s,
            {VoidCallback? onShowPopover, ValueChanged<String>? onSubmit}) =>
        host(MainWindowView(
          snapshot: s,
          onShowPopover: onShowPopover ?? () {},
          onRemote: () {},
          onStop: () {},
          onSubmit: onSubmit ?? (_) {},
        ));

    const conversation = [
      ChatMessage(id: 1, fromUser: true, author: 'tray', text: 'refactor payments'),
      ChatMessage(id: 2, fromUser: false, author: 'agent', text: 'Working on refactor-payments… step 3 of 27'),
    ];

    testWidgets('shows the shared conversation with where prompts came from', (tester) async {
      await tester.pumpWidget(view(snapshot(messages: conversation)));
      expect(find.text('refactor payments'), findsOneWidget);
      expect(find.text('You · from tray'), findsOneWidget);
      expect(find.text('Working on refactor-payments… step 3 of 27'), findsOneWidget);
    });

    testWidgets('sends from the chat composer', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(view(snapshot(), onSubmit: sent.add));
      expect(find.textContaining('Ask anything here'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'write tests');
      await tester.tap(find.byKey(const Key('main-send')));
      expect(sent, ['write tests']);
    });

    testWidgets('can show the popover', (tester) async {
      var opened = false;
      await tester.pumpWidget(view(snapshot(), onShowPopover: () => opened = true));
      await tester.tap(find.byKey(const Key('show-popover')));
      expect(opened, isTrue);
    });

    testWidgets('reports both engines and the second engine memory cost', (tester) async {
      await tester.pumpWidget(view(snapshot()));
      expect(find.textContaining('starting popover engine'), findsOneWidget);
      await tester.pumpWidget(view(snapshot(marks: const [
        MemoryMark(label: 'before tray engine', rssKb: 200 * 1024),
        MemoryMark(label: 'tray engine ready', rssKb: 245 * 1024),
      ])));
      final status = tester.widget<Text>(find.byKey(const Key('engine-status'))).data!;
      expect(status, contains('2 engines share this state (main + tray)'));
      expect(status, contains('second engine ≈ +45.0 MB'));
    });
  });

  testWidgets('popover shows the latest agent reply', (tester) async {
    tester.view.physicalSize = const Size(440, 330);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(TrayPanelView(
      snapshot: snapshot(messages: const [
        ChatMessage(id: 1, fromUser: true, author: 'main', text: 'hi'),
        ChatMessage(id: 2, fromUser: false, author: 'agent', text: 'Done with hi'),
      ]),
      onSubmit: (_) {},
    )));
    expect(find.text('Done with hi'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
