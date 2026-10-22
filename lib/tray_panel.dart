import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tray_popover/flutter_tray_popover.dart';

import 'src/rust/api/agent.dart';
import 'ui/palette.dart';
import 'ui/widgets.dart';

const trayEngineName = 'tray';

/// Actions in the popover's overflow menu, in place of a native tray menu.
enum PopoverMenu { remote, stop, quit }

/// Builds the popover engine's app (engine B). The flutter_tray_popover
/// plugin starts this engine hidden at launch and shows, places and hides
/// its window natively, so the first tray click opens it instantly.
Future<Widget> bootTrayPanel() async {
  await attachEngine(name: trayEngineName);
  await recordMemoryMark(label: 'tray engine ready');
  return const TrayPanelApp();
}

class TrayPanelApp extends StatefulWidget {
  const TrayPanelApp({super.key});

  @override
  State<TrayPanelApp> createState() => _TrayPanelAppState();
}

class _TrayPanelAppState extends State<TrayPanelApp> {
  final _state = watchState().asBroadcastStream();
  String? _pluginError;
  var _transparent = false;

  @override
  void initState() {
    super.initState();
    _checkWindow();
  }

  // Also how this engine finds out whether the runner registered its plugins.
  Future<void> _checkWindow() async {
    try {
      final transparent = await TrayPopover.isTransparent();
      if (mounted) setState(() => _transparent = transparent);
    } on MissingPluginException catch (e) {
      if (mounted) setState(() => _pluginError = e.toString());
    }
  }

  void _dismiss() {
    if (_pluginError == null) TrayPopover.hide();
  }

  // Same process as the main window, so Quit here ends both engines.
  void _onMenu(PopoverMenu item) {
    switch (item) {
      case PopoverMenu.remote:
        startRemoteSession();
      case PopoverMenu.stop:
        stopRun();
      case PopoverMenu.quit:
        TrayPopover.quit();
    }
  }

  Future<void> _openMainWindow() async {
    await TrayPopover.showMainWindow();
    await TrayPopover.hide();
  }

  @override
  Widget build(BuildContext context) {
    final pluginError = _pluginError;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: StreamBuilder<AgentSnapshot>(
        stream: _state,
        builder: (context, snap) => TrayPanelView(
          snapshot: snap.data,
          pluginError: pluginError,
          onSubmit: (text) =>
              submitPrompt(text: text, fromEngine: trayEngineName),
          onDismiss: _dismiss,
          onOpenMainWindow: pluginError == null ? _openMainWindow : null,
          onMenu: _onMenu,
          // When the window is see-through, only the card shows.
          transparentBackdrop: _transparent,
        ),
      ),
    );
  }
}

/// The tray card from the wireframe. Pure view so tests can render it without Rust.
class TrayPanelView extends StatefulWidget {
  const TrayPanelView({
    super.key,
    required this.snapshot,
    required this.onSubmit,
    this.onDismiss,
    this.onOpenMainWindow,
    this.onMenu,
    this.pluginError,
    this.transparentBackdrop = false,
  });

  final AgentSnapshot? snapshot;
  final ValueChanged<String> onSubmit;
  final VoidCallback? onDismiss;
  final VoidCallback? onOpenMainWindow;
  final ValueChanged<PopoverMenu>? onMenu;
  final String? pluginError;

  /// Leaves the area around the card see-through, for windows that are
  /// transparent (the macOS panel); otherwise it is filled with the backdrop.
  final bool transparentBackdrop;

  @override
  State<TrayPanelView> createState() => _TrayPanelViewState();
}

/// Transparent room around the card for its shadow, when the window is
/// see-through.
const _shadowMargin = 14.0;

class _TrayPanelViewState extends State<TrayPanelView> {
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
    return CallbackShortcuts(
      bindings: {
        if (widget.onDismiss != null)
          const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss!,
      },
      child: Scaffold(
        backgroundColor: widget.transparentBackdrop
            ? Colors.transparent
            : Palette.card,
        body: Padding(
          // With a see-through window the card floats, rounded and shadowed,
          // inside a transparent margin. Without one, any margin would show
          // as an opaque frame around the card, so the card fills the window.
          padding: EdgeInsets.all(
            widget.transparentBackdrop ? _shadowMargin : 0,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            decoration: BoxDecoration(
              color: Palette.card,
              borderRadius: widget.transparentBackdrop
                  ? BorderRadius.circular(22)
                  : null,
              boxShadow: widget.transparentBackdrop
                  ? const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: s == null
                ? const Center(child: CircularProgressIndicator())
                : _content(s),
          ),
        ),
      ),
    );
  }

  Widget _content(AgentSnapshot s) {
    final progress = s.done / s.total;
    final tokens = s.tokensUsed / s.tokensBudget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const AppLogo(size: 36),
            const SizedBox(width: 12),
            const Text(
              'Another',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Palette.ink,
              ),
            ),
            const Spacer(),
            if (widget.onOpenMainWindow != null)
              IconButton(
                key: const Key('open-main'),
                tooltip: 'Open Another',
                onPressed: widget.onOpenMainWindow,
                icon: const Icon(
                  Icons.open_in_new,
                  size: 18,
                  color: Palette.muted,
                ),
              ),
            if (widget.onMenu case final onMenu?)
              PopupMenuButton<PopoverMenu>(
                key: const Key('popover-menu'),
                tooltip: 'More',
                onSelected: onMenu,
                icon: const Icon(
                  Icons.more_horiz,
                  size: 18,
                  color: Palette.muted,
                ),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: PopoverMenu.remote,
                    child: Text('Simulate iPhone session'),
                  ),
                  PopupMenuItem(
                    value: PopoverMenu.stop,
                    enabled: s.running,
                    child: const Text('Stop run'),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: PopoverMenu.quit,
                    child: Text('Quit'),
                  ),
                ],
              ),
            Tooltip(
              message: '${s.tokensUsed} / ${s.tokensBudget} tokens',
              child: ProgressRing(
                value: tokens,
                size: 38,
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 16,
                  color: Palette.ring,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (widget.pluginError != null)
          Text(
            'Plugins not registered on this engine:\n${widget.pluginError}',
            key: const Key('plugin-error'),
            style: const TextStyle(color: Palette.danger, fontSize: 12),
          )
        else
          _driverChip(s),
        const SizedBox(height: 12),
        Row(
          children: [
            ProgressRing(
              value: progress,
              size: 50,
              stroke: 3,
              fill: Palette.ringFill,
              child: const Icon(Icons.code, size: 20, color: Palette.ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.task,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Palette.ink,
                    ),
                  ),
                  Text(
                    '${s.done}/${s.total}',
                    key: const Key('task-progress'),
                    style: const TextStyle(fontSize: 13, color: Palette.muted),
                  ),
                  if (_latestReply(s) case final reply?)
                    Text(
                      reply,
                      key: const Key('latest-reply'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Palette.chipText,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const Spacer(),
        _composer(progress, tokens),
        const SizedBox(height: 6),
        Center(
          child: Text(
            '${s.engines.length} engines share this state · rev ${s.revision} · RSS ${formatMb(s.rssKb)}',
            key: const Key('engine-footer'),
            style: const TextStyle(fontSize: 11, color: Palette.muted),
          ),
        ),
      ],
    );
  }

  String? _latestReply(AgentSnapshot s) =>
      s.messages.where((m) => !m.fromUser).lastOrNull?.text;

  Widget _driverChip(AgentSnapshot s) {
    if (s.driver.isEmpty) {
      return const StatusChip(icon: Icons.pause_circle_outline, label: 'Idle');
    }
    final (icon, label) = switch (s.driver) {
      'iPhone' => (Icons.devices_outlined, 'Driven from iPhone'),
      trayEngineName => (Icons.space_dashboard_outlined, 'Driven from tray'),
      final other => (
        Icons.desktop_windows_outlined,
        'Driven from $other window',
      ),
    };
    return StatusChip(icon: icon, label: label);
  }

  Widget _composer(double progress, double tokens) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 54,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: Palette.composer,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Row(
              children: [
                const Icon(Icons.add, color: Palette.ink),
                const SizedBox(width: 8),
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
                  value: progress,
                  size: 28,
                  stroke: 2.5,
                  child: const Icon(
                    Icons.memory,
                    size: 13,
                    color: Palette.ring,
                  ),
                ),
                const SizedBox(width: 4),
                ProgressRing(
                  value: tokens,
                  size: 28,
                  stroke: 2.5,
                  child: const Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 13,
                    color: Palette.ring,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.mic_none, color: Palette.ink, size: 20),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox.square(
          dimension: 56,
          child: FilledButton(
            key: const Key('send'),
            onPressed: _send,
            style: FilledButton.styleFrom(
              backgroundColor: Palette.send,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: const Icon(Icons.send_rounded, color: Colors.white),
          ),
        ),
      ],
    );
  }
}
