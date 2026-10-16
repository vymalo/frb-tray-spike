import 'package:agent_tray_demo/src/rust/api/agent.dart';
import 'package:agent_tray_demo/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Runs against the real Rust library inside a Linux/macOS build.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  test('remote session progress reaches every subscriber', () async {
    expect(await attachEngine(name: 'test'), 1);

    final a = watchState().asBroadcastStream();
    final b = watchState().asBroadcastStream();
    final seenByB = b.firstWhere((s) => s.driver == 'iPhone' && s.done >= 2);

    await startRemoteSession();
    final seenByA = await a
        .firstWhere((s) => s.driver == 'iPhone' && s.done >= 2)
        .timeout(const Duration(seconds: 10));
    final fromB = await seenByB.timeout(const Duration(seconds: 10));

    expect(seenByA.task, 'checkout');
    expect(fromB.total, 40);
    expect(seenByA.rssKb, greaterThan(0));

    await stopRun();
    final stopped = await a.firstWhere((s) => !s.running);
    expect(stopped.done, lessThan(40));
  });

  test('memory marks record process RSS', () async {
    await recordMemoryMark(label: 'probe');
    final s = await watchState().firstWhere((s) => s.memoryMarks.isNotEmpty);
    expect(s.memoryMarks.last.label, 'probe');
    expect(s.memoryMarks.last.rssKb, greaterThan(0));
  });
}
