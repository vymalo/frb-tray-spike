# frb-tray-spike

> Spike: throwaway exploration, not production code. The Flutter package and
> binary are still named `agent_tray_demo`.

A minimal mock of a tray-first agent client, like a menu bar app: launching
it shows only a tray icon, and the tray opens a **popover that runs in a second
Flutter engine in the same process**. The main window (first engine) is an
optional chat window, opened on demand. Every engine shows the same
conversation. It demonstrates three things:

1. **Shared state through flutter_rust_bridge.** Both engines call
   `RustLib.init()` in their own isolate, but the Rust library is loaded once per
   process. `rust/src/api/agent.rs` keeps one `AgentSnapshot` in a static, and
   every engine that calls `watchState()` gets each change pushed to its own
   `StreamSink`, whichever engine or the mock iPhone thread caused it.
2. **Plugin registration on the tray engine.** A new engine starts with no
   plugins. The runner registers them in desktop_multi_window's
   window-created callback (`linux/runner/my_application.cc`,
   `macos/Runner/MainFlutterWindow.swift`). FRB needs no registration because it
   uses `dart:ffi`, not platform channels.
3. **Extra memory.** The popover engine is started hidden at launch, so the
   first click opens it instantly. Process RSS is recorded right before it
   starts and once it is up; the main window shows the difference.

```
┌──────────────── one OS process ─────────────────┐
│  Engine A: chat window      Engine B: popover    │
│        │                           │             │
│        └──── FRB ──► Rust core ◄───┘             │
│              (static AgentSnapshot)              │
│              mock "iPhone" driver thread         │
└──────────────────────────────────────────────────┘
```

## Run

Linux (Ubuntu 24.04):

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libayatana-appindicator3-dev
flutter run -d linux
```

macOS (needs Xcode and CocoaPods; Flutter cannot build a macOS app from Linux):

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
flutter run -d macos
```

`.github/workflows/build.yml` builds both platforms and uploads the bundles. On
a Mac you can also just clone the repo and run `flutter run -d macos`.

### Try it

- Launch it: only the tray icon appears.
- Click the tray icon (menu bar on macOS, top bar on Linux) to toggle the
  popover under it.
- Type an instruction in "Ask anything" and send it. The run starts in Rust,
  the popover shows its progress, and the chat window gets the prompt and the
  agent's live reply. Click outside or press <kbd>Esc</kbd> to dismiss the
  popover.
- The popover's open-in-window button shows the chat window. It shows the same
  conversation live, plus the memory cost of the second engine. Closing it only
  hides it.
- The popover's `⋯` menu has **Simulate iPhone session**, **Stop run** and
  **Quit**. On macOS the status item's right-click menu has them too.
- **Simulate iPhone session** runs `checkout` from 0 to 40. Both engines show
  "Driven from iPhone", the same step and the same revision.
- Run with `AGENT_DEMO_SKIP_PLUGINS=1` to skip plugin registration on the
  popover engine. It then shows the `MissingPluginException` it gets.
- Run with `AGENT_DEMO_OPEN_PANEL=1` to open the popover at launch.

## Install (Linux)

```bash
linux/packaging/install.sh              # build release and install for this user
linux/packaging/install.sh --autostart  # same, and start it at login
linux/packaging/install.sh --uninstall
```

It installs to `~/.local/share/agent_tray_demo`, adds `agent-tray-demo` to
`~/.local/bin` and an "Another" entry to the app grid.

## Platform notes

| | Linux (GNOME) | macOS |
|---|---|---|
| Tray | X11 tray icon (`GtkStatusIcon`, `linux/runner/linux_tray.cc`): any click toggles the popover, whose `⋯` menu replaces a native menu | NSStatusItem (`tray_manager`): left click toggles the popover, right click opens the menu |
| Popover position | Under the icon through X11; `main.cc` forces XWayland (even over `GDK_BACKEND=wayland`) because Wayland ignores window moves | Centered under the status item |
| Dock / taskbar | Main window hidden at launch; popover skips the taskbar | `LSUIElement`: no Dock icon; main window hidden at launch |
| Popover startup | The runner shapes the hidden window; the main engine shows it. A hidden Flutter view never renders, so the popover engine can't show itself the first time | Same flow |
| RSS source | `/proc/self/status` `VmRSS` | `task_info(MACH_TASK_BASIC_INFO)` |

GNOME only shows tray icons when the AppIndicator extension is enabled. Ubuntu
enables it by default. The Linux tray is a legacy X11 icon rather than an
AppIndicator on purpose: the extension opens an AppIndicator's native menu on
a single left click and only reports a double click to the app, while it
forwards every click on an X11 tray icon. It forwards them as synthetic core X
events, which GTK 3 ignores (it reads pointer input from XInput2), so
`linux_tray.cc` reads them with a GDK event filter.

## Tests

```bash
cargo test --manifest-path rust/Cargo.toml   # state machine, RSS reader
flutter test                                 # popover and chat window views
flutter test integration_test -d linux       # real Rust lib: two subscribers see the same run

# Whole app, both engines: the tray engine types a prompt into the real panel
# and the main engine checks the shared run (flutter drive keeps the
# entrypoint args that tell the two engines apart).
flutter drive -d linux --driver=test_driver/integration_test.dart \
  --target=integration_test/two_engines_drive.dart
```

## Layout

```
rust/src/api/agent.rs        shared state, chat, stream fan-out, mock agent, RSS
lib/main.dart                picks chat window or popover from engine args
lib/main_window.dart         engine A: tray, starts engine B hidden, chat window
lib/tray_panel.dart          engine B: the popover from the wireframe
lib/linux_tray.dart          clicks from the Linux tray icon
lib/panel_window.dart        channel to the runner's native popover helper
linux/runner/linux_tray.cc   Linux tray icon (X11) and its click forwarding
linux/runner/panel_window.cc borderless, always-on-top popover window (GTK)
linux/packaging/             install script, desktop entry, icon
macos/Runner/MainFlutterWindow.swift  popover window for AppKit, plus engine B registration
```
