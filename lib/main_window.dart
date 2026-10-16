import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';

import 'src/rust/api/agent.dart';
import 'ui/palette.dart';
import 'ui/widgets.dart';

const mainEngineName = 'main';
const trayPanelArgument = 'tray_panel';

const _beforeTrayMark = 'before tray engine';
const _trayReadyMark = 'tray engine ready';

/// Engine A: owns the tray icon and the (initially hidden) main window, and
/// starts the popover engine hidden at launch so the first tray click is instant.
class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with TrayListener {
  final _state = watchState().asBroadcastStream();
  late final StreamSubscription<AgentSnapshot> _tracking;
  late final Future<WindowController> _popover = _startPopoverEngine();
  AgentSnapshot? _last;
  DateTime? _popoverHiddenAt;

  @override
  void initState() {
    super.initState();
    _tracking = _state.listen((s) {
      if (_last?.popoverVisible == true && !s.popoverVisible) {
        _popoverHiddenAt = DateTime.now();
      }
      _last = s;
    });
    trayManager.addListener(this);
    _setUpTray();
    _popover.then((_) {
      if (Platform.environment['AGENT_DEMO_OPEN_PANEL'] == '1') _setPopover(true);
    });
  }

  @override
  void dispose() {
    _tracking.cancel();
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _setUpTray() async {
    await trayManager.setIcon('assets/tray_icon.png');
    if (!Platform.isLinux) await trayManager.setToolTip('Another');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'popover', label: 'Open Another'),
      MenuItem(key: 'main', label: 'Open main window'),
      MenuItem.separator(),
      MenuItem(key: 'remote', label: 'Simulate iPhone session'),
      MenuItem(key: 'stop', label: 'Stop run'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  }

  Future<WindowController> _startPopoverEngine() async {
    await recordMemoryMark(label: _beforeTrayMark);
    return WindowController.create(
      const WindowConfiguration(arguments: trayPanelArgument, hiddenAtLaunch: true),
    );
  }

  Future<void> _setPopover(bool visible) async {
    final popover = await _popover;
    visible ? await popover.show() : await popover.hide();
    await setPopoverVisible(visible: visible);
  }

  void _togglePopover() {
    // Clicking the tray icon while the popover is open first takes focus away
    // from it, which already dismissed it; that click must not reopen it.
    final hiddenAt = _popoverHiddenAt;
    final justDismissed = hiddenAt != null &&
        DateTime.now().difference(hiddenAt) < const Duration(milliseconds: 400);
    _setPopover(!(_last?.popoverVisible ?? false) && !justDismissed);
  }

  Future<void> _showMainWindow() async =>
      (await WindowController.fromCurrentEngine()).show();

  // macOS: a left click on the status item toggles the popover.
  // Linux AppIndicator never reports clicks; it only opens the menu below.
  @override
  void onTrayIconMouseDown() => _togglePopover();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'popover':
        _setPopover(true);
      case 'main':
        _showMainWindow();
      case 'remote':
        startRemoteSession();
      case 'stop':
        stopRun();
      case 'quit':
        exit(0);
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
          onShowPopover: () => _setPopover(true),
          onRemote: startRemoteSession,
          onStop: stopRun,
          onSubmit: (text) => submitPrompt(text: text, fromEngine: mainEngineName),
        ),
      ),
    );
  }
}

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
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      _header(),
                      const SizedBox(height: 20),
                      _stateCard(s),
                      const SizedBox(height: 14),
                      _memoryCard(s),
                      const SizedBox(height: 14),
                      _actions(s),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _header() => const Row(children: [
        AppLogo(size: 44),
        SizedBox(width: 14),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Another',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Palette.ink)),
          Text('Main engine · agent client',
              style: TextStyle(fontSize: 13, color: Palette.muted)),
        ]),
      ]);

  Widget _card({required String title, required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Palette.card,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w700,
                  color: Palette.muted)),
          const SizedBox(height: 12),
          ...children,
        ]),
      );

  Widget _stateCard(AgentSnapshot s) => _card(
        title: 'SHARED AGENT STATE · RUST',
        children: [
          Row(children: [
            ProgressRing(
              value: s.done / s.total,
              size: 52,
              fill: Palette.ringFill,
              child: const Icon(Icons.code, size: 20, color: Palette.ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.task,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Text(
                  '${s.done}/${s.total} · ${s.running ? 'running' : 'idle'}'
                  '${s.driver.isEmpty ? '' : ' · driven by ${s.driver}'}',
                  key: const Key('main-progress'),
                  style: const TextStyle(color: Palette.muted),
                ),
              ]),
            ),
            Text('rev ${s.revision}', style: const TextStyle(color: Palette.muted)),
          ]),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (i, e) in s.engines.indexed)
              StatusChip(icon: Icons.memory, label: 'engine ${i + 1}: $e'),
          ]),
        ],
      );

  Widget _memoryCard(AgentSnapshot s) {
    int? markKb(String label) =>
        s.memoryMarks.where((m) => m.label == label).firstOrNull?.rssKb;
    final before = markKb(_beforeTrayMark);
    final after = markKb(_trayReadyMark);
    return _card(title: 'PROCESS MEMORY', children: [
      Text('RSS now: ${formatMb(s.rssKb)}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      for (final m in s.memoryMarks)
        Text('${m.label}: ${formatMb(m.rssKb)}',
            style: const TextStyle(color: Palette.muted)),
      if (before != null && after != null) ...[
        const SizedBox(height: 8),
        Text('Second engine cost ≈ +${formatMb(after - before)}',
            key: const Key('engine-cost'),
            style: const TextStyle(fontWeight: FontWeight.w700, color: Palette.send)),
      ] else
        const Text('Waiting for the popover engine to start…',
            style: TextStyle(color: Palette.muted)),
    ]);
  }

  Widget _actions(AgentSnapshot s) => _card(title: 'DRIVE THE AGENT', children: [
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.icon(
            key: const Key('show-popover'),
            onPressed: widget.onShowPopover,
            style: FilledButton.styleFrom(backgroundColor: Palette.send),
            icon: const Icon(Icons.space_dashboard_outlined),
            label: const Text('Show tray popover'),
          ),
          OutlinedButton.icon(
            key: const Key('remote'),
            onPressed: widget.onRemote,
            icon: const Icon(Icons.devices_outlined),
            label: const Text('Simulate iPhone session'),
          ),
          TextButton(onPressed: s.running ? widget.onStop : null, child: const Text('Stop')),
        ]),
        const SizedBox(height: 14),
        TextField(
          controller: _prompt,
          onSubmitted: (_) => _send(),
          decoration: InputDecoration(
            hintText: 'Ask anything (runs locally, mirrored in the tray)',
            filled: true,
            fillColor: Palette.composer,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              onPressed: _send,
              icon: const Icon(Icons.send_rounded, color: Palette.send),
            ),
          ),
        ),
      ]);
}
