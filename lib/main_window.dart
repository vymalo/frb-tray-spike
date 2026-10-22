import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tray_popover/flutter_tray_popover.dart';

import 'src/rust/api/agent.dart';
import 'ui/palette.dart';
import 'ui/widgets.dart';

const mainEngineName = 'main';

const _beforeTrayMark = 'before tray engine';
const _trayReadyMark = 'tray engine ready';

/// Engine A: the (initially hidden) chat window. It asks the
/// flutter_tray_popover plugin for the tray icon and the popover engine,
/// which the plugin starts hidden so the first tray click is instant.
class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  final _state = watchState().asBroadcastStream();

  @override
  void initState() {
    super.initState();
    _setUpTray();
  }

  Future<void> _setUpTray() async {
    await recordMemoryMark(label: _beforeTrayMark);
    await TrayPopover.setUp(
      icon: 'assets/tray_icon.png',
      optionSpaceShortcut: true, // macOS
    );
    if (Platform.environment['AGENT_DEMO_OPEN_PANEL'] == '1') {
      await TrayPopover.show();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Another',
      theme: buildTheme(),
      home: StreamBuilder<AgentSnapshot>(
        stream: _state,
        builder: (context, snap) => MainWindowView(
          snapshot: snap.data,
          onShowPopover: TrayPopover.show,
          onRemote: startRemoteSession,
          onStop: stopRun,
          onSubmit: (text) => submitPrompt(text: text, fromEngine: mainEngineName),
        ),
      ),
    );
  }
}

/// The chat window: the shared conversation, a status line about the two
/// engines, and a composer. Pure view so tests can render it without Rust.
class MainWindowView extends StatefulWidget {
  const MainWindowView({
    super.key,
    required this.snapshot,
    required this.onShowPopover,
    required this.onRemote,
    required this.onStop,
    required this.onSubmit,
  });

  final AgentSnapshot? snapshot;
  final VoidCallback onShowPopover;
  final VoidCallback onRemote;
  final VoidCallback onStop;
  final ValueChanged<String> onSubmit;

  @override
  State<MainWindowView> createState() => _MainWindowViewState();
}

class _MainWindowViewState extends State<MainWindowView> {
  final _prompt = TextEditingController();

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _send() {
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
    _prompt.clear();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: Palette.backdrop),
        child: s == null
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Column(children: [
                      _header(s),
                      const SizedBox(height: 8),
                      _engineStatus(s),
                      const SizedBox(height: 12),
                      Expanded(child: _conversation(s)),
                      const SizedBox(height: 12),
                      _composer(s),
                    ]),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _header(AgentSnapshot s) => Row(children: [
        const AppLogo(size: 40),
        const SizedBox(width: 12),
        const Text('Another',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Palette.ink)),
        const SizedBox(width: 12),
        if (s.driver.isNotEmpty)
          StatusChip(
            icon: s.driver == 'iPhone' ? Icons.devices_outlined : Icons.bolt_outlined,
            label: s.running ? '${s.task} ${s.done}/${s.total}' : s.task,
          ),
        const Spacer(),
        IconButton(
          key: const Key('show-popover'),
          tooltip: 'Show tray popover',
          onPressed: widget.onShowPopover,
          icon: const Icon(Icons.space_dashboard_outlined, color: Palette.ink),
        ),
        IconButton(
          key: const Key('remote'),
          tooltip: 'Simulate iPhone session',
          onPressed: widget.onRemote,
          icon: const Icon(Icons.devices_outlined, color: Palette.ink),
        ),
        IconButton(
          tooltip: 'Stop run',
          onPressed: s.running ? widget.onStop : null,
          icon: const Icon(Icons.stop_circle_outlined),
        ),
      ]);

  /// One line proving the point of the spike: two engines, one state, and
  /// what the second engine costs.
  Widget _engineStatus(AgentSnapshot s) {
    int? markKb(String label) =>
        s.memoryMarks.where((m) => m.label == label).firstOrNull?.rssKb;
    final before = markKb(_beforeTrayMark);
    final after = markKb(_trayReadyMark);
    final cost = before != null && after != null
        ? 'second engine ≈ +${formatMb(after - before)}'
        : 'starting popover engine…';
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '${s.engines.length} engines share this state (${s.engines.join(' + ')}) · '
        'rev ${s.revision} · RSS ${formatMb(s.rssKb)} · $cost',
        key: const Key('engine-status'),
        style: const TextStyle(fontSize: 12, color: Palette.muted),
      ),
    );
  }

  Widget _conversation(AgentSnapshot s) {
    if (s.messages.isEmpty) {
      return const Center(
        child: Text(
          'Ask anything here, from the tray popover, or from your iPhone.\n'
          'Every engine sees the same conversation.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Palette.muted, height: 1.5),
        ),
      );
    }
    final messages = s.messages.reversed.toList();
    return ListView.builder(
      reverse: true,
      itemCount: messages.length,
      itemBuilder: (context, i) => ChatBubble(
        message: messages[i],
        working: i == 0 && s.running,
        progress: s.done / s.total,
      ),
    );
  }

  Widget _composer(AgentSnapshot s) => Row(children: [
        Expanded(
          child: Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Palette.card,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(children: [
              const Icon(Icons.add, color: Palette.ink),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _prompt,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Ask anything',
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ),
              ProgressRing(
                value: s.tokensUsed / s.tokensBudget,
                size: 28,
                stroke: 2.5,
                child: const Icon(Icons.account_balance_wallet_outlined,
                    size: 13, color: Palette.ring),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.mic_none, color: Palette.ink, size: 20),
            ]),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox.square(
          dimension: 54,
          child: FilledButton(
            key: const Key('main-send'),
            onPressed: _send,
            style: FilledButton.styleFrom(
              backgroundColor: Palette.send,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            child: const Icon(Icons.send_rounded, color: Colors.white),
          ),
        ),
      ]);
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
    this.working = false,
    this.progress = 0,
  });

  final ChatMessage message;
  final bool working;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final mine = message.fromUser;
    final label = mine ? 'You · from ${message.author}' : 'Agent';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: Palette.muted)),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: mine ? Palette.ringFill : Palette.card,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (working) ...[
                    ProgressRing(value: progress, size: 18, stroke: 2.5),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(message.text,
                        style: const TextStyle(color: Palette.ink, height: 1.4)),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
