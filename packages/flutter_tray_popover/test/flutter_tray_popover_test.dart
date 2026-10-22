import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tray_popover/flutter_tray_popover.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tray_popover');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'setUp' => {'transparent': true},
        'isVisible' => true,
        'isTransparent' => false,
        _ => null,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('routes the popover engine to popover and every other to app', () {
    final ran = <String>[];
    void app() => ran.add('app');
    void popover() => ran.add('popover');

    TrayPopover.run(args: const [], app: app, popover: popover);
    TrayPopover.run(args: const ['--verbose'], app: app, popover: popover);
    TrayPopover.run(args: const [TrayPopover.popoverArgument], app: app, popover: popover);

    expect(ran, ['app', 'app', 'popover']);
  });

  test('setUp sends its options and reports transparency', () async {
    final transparent = await TrayPopover.setUp(
      icon: 'assets/icon.png',
      size: const Size(300, 200),
      optionSpaceShortcut: true,
    );

    expect(transparent, isTrue);
    expect(calls.single.method, 'setUp');
    expect(calls.single.arguments, {
      'icon': 'assets/icon.png',
      'width': 300,
      'height': 200,
      'entrypoint': 'trayMain',
      'keepAliveOnWindowClose': true,
      'optionSpaceShortcut': true,
    });
  });

  test('forwards commands and queries to the native side', () async {
    await TrayPopover.show();
    await TrayPopover.hide();
    await TrayPopover.toggle();
    await TrayPopover.showMainWindow();
    expect(await TrayPopover.isVisible(), isTrue);
    expect(await TrayPopover.isTransparent(), isFalse);

    expect(calls.map((c) => c.method), [
      'show', 'hide', 'toggle', 'showMainWindow', 'isVisible', 'isTransparent',
    ]);
  });

  test('turns native visibility events into a stream', () async {
    final events = <bool>[];
    final subscription = TrayPopover.visibilityChanges.listen(events.add);

    Future<void> nativeSends(bool visible) =>
        messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall('visibilityChanged', visible)),
          (_) {},
        );
    await nativeSends(true);
    await nativeSends(false);
    await Future<void>.delayed(Duration.zero);

    expect(events, [true, false]);
    await subscription.cancel();
  });
}
