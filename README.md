# frb-tray-spike

> Spike: throwaway exploration, not production code. The Flutter package and
> binary are still named `agent_tray_demo`.

A minimal mock of a tray-first agent client, like a menu bar app: launching
it shows only a tray icon, and the tray opens a **popover that runs in a second
Flutter engine in the same process**. The main window (first engine) is
optional and opened on demand. It demonstrates three things:

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
│  Engine A: main window      Engine B: tray panel │
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
- **macOS:** click the menu-bar icon to toggle the popover under it.
  **Linux:** click the icon, then **Open Another** in its menu.
- Type an instruction in "Ask anything" and send it. The run starts in Rust
  and the popover shows its progress. Click outside or press <kbd>Esc</kbd> to
  dismiss it.
- The popover's open-in-window button (or **Open main window** in the tray
  menu) shows the main window. It shows the same run live, plus the memory
  cost of the second engine. Closing it only hides it; **Quit** is in the tray
  menu.
- **Simulate iPhone session** (tray menu or main window) runs `checkout` from
  0 to 40. Both engines show "Driven from iPhone" and the same revision.
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
| Tray | AppIndicator: menu only, no click events, so the popover opens from the menu | NSStatusItem: left click toggles the popover, right click opens the menu |
| Popover position | Top right through X11; `main.cc` forces XWayland (even over `GDK_BACKEND=wayland`) because Wayland ignores window moves | Centered under the status item |
| Dock / taskbar | Main window hidden at launch; popover skips the taskbar | `LSUIElement`: no Dock icon; main window hidden at launch |
| Popover startup | The runner shapes the hidden window; the main engine shows it. A hidden Flutter view never renders, so the popover engine can't show itself the first time | Same flow |
| RSS source | `/proc/self/status` `VmRSS` | `task_info(MACH_TASK_BASIC_INFO)` |

GNOME only shows tray icons when the AppIndicator extension is enabled. Ubuntu
enables it by default.

## Tests

```bash
cargo test --manifest-path rust/Cargo.toml   # state machine, RSS reader
flutter test                                 # panel and main window views
flutter test integration_test -d linux       # real Rust lib: two subscribers see the same run

# Whole app, both engines: the tray engine types a prompt into the real panel
# and the main engine checks the shared run (flutter drive keeps the
# entrypoint args that tell the two engines apart).
flutter drive -d linux --driver=test_driver/integration_test.dart \
  --target=integration_test/two_engines_drive.dart
```

## Layout

```
rust/src/api/agent.rs        shared state, stream fan-out, mock driver, RSS
lib/main.dart                picks main window or tray panel from engine args
lib/main_window.dart         engine A: tray icon and menu, starts engine B hidden, main window
lib/tray_panel.dart          engine B: the popover from the wireframe
linux/packaging/             install script, desktop entry, icon
lib/panel_window.dart        channel to the runner's native panel helper
linux/runner/panel_window.cc borderless, top-right, always-on-top window (GTK)
macos/Runner/MainFlutterWindow.swift  same for AppKit, plus engine B registration
```
