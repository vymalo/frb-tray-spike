# flutter_tray_popover

A tray icon that opens a **Flutter popover**, like a menu-bar app, instead of a
native context menu. The popover is rendered by a **second Flutter engine in
the same process**, started hidden at launch so the first click opens it
instantly.

| | Linux (GNOME, X11 through XWayland) | macOS | Windows |
|---|---|---|---|
| Tray icon | Legacy X11 tray icon | `NSStatusItem` | Not implemented |
| Popover window | Borderless utility window, always on top, transparent with a compositor | Non-activating `NSPanel`, transparent | — |
| Popover engine starts at | `main(['tray_popover'])` | `trayMain` by name | — |
| Global shortcut | — | <kbd>⌥ Space</kbd> | — |
| Status | Tested | Compiles in CI, not yet run on a Mac | — |

## Usage

**1. Two entry points.** The popover engine runs its own entry point. Keep it
in release builds with `@pragma('vm:entry-point')`, and route `main` with
`TrayPopover.run`, which Linux needs:

```dart
void main(List<String> args) =>
    TrayPopover.run(args: args, app: appMain, popover: trayMain);

void appMain() => runApp(const MainApp());

@pragma('vm:entry-point')
void trayMain() => runApp(const PopoverApp());
```

**2. Set it up once, from the main engine:**

```dart
final transparent = await TrayPopover.setUp(
  icon: 'assets/tray_icon.png',   // an asset declared in pubspec.yaml
  size: const Size(440, 330),
  optionSpaceShortcut: true,      // macOS
);
```

**3. Register the app's plugins on the popover engine.** A new engine starts
with no plugins, and only the app can call its own generated registrant:

```c
// linux/runner/my_application.cc
#include "flutter_tray_popover/flutter_tray_popover_plugin.h"
...
flutter_tray_popover_plugin_set_engine_created_callback(
    [](FlPluginRegistry* registry) { fl_register_plugins(registry); });
```
```swift
// macos/Runner/MainFlutterWindow.swift
import flutter_tray_popover
...
FlutterTrayPopoverPlugin.onEngineCreated = { RegisterGeneratedPlugins(registry: $0) }
```

**4. Use it from either engine:**

```dart
await TrayPopover.show();           // under the tray icon, with keyboard focus
await TrayPopover.hide();
await TrayPopover.toggle();
await TrayPopover.isVisible();
await TrayPopover.isTransparent();  // if false, draw the popover edge to edge
await TrayPopover.showMainWindow();
await TrayPopover.quit();           // both engines, the tray icon, the process
TrayPopover.visibilityChanges.listen((visible) { ... });
```

Clicking the tray icon toggles the popover, and clicking anywhere else closes
it. Both happen natively, without a round trip through Dart.

## Sharing state between the engines

The two engines are separate Dart isolates and can't share Dart objects, or
use Provider, Riverpod or Bloc across them. Keep shared state in native
memory, which every engine in the process reaches. For example, use a Rust
library through [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/),
with one `StreamSink` per engine, as the app in this repo does.

## Platform requirements

- **Linux:** X11, or XWayland. Force it in the runner's `main.cc` before GTK
  starts (`g_setenv("GDK_BACKEND", "x11", TRUE)`), because Wayland doesn't let
  apps place their windows. GNOME shows the icon through its AppIndicator
  extension's legacy tray support; Ubuntu enables it by default.
  - **Why not an AppIndicator:** GNOME's tray extension opens an
    AppIndicator's native menu on a single click and never tells the app
    ([tray_manager#101](https://github.com/leanflutter/tray_manager/issues/101)).
    The plugin uses a legacy X11 tray icon instead, and reads the clicks GNOME
    forwards with a GDK event filter, because GTK 3 ignores them.
  - **Click-outside closing:** when the popover opens, the plugin focuses it
    using the X timestamp of the tray click that opened it, so GNOME's
    focus-stealing prevention allows the focus.
  - **Main window:** with `keepAliveOnWindowClose`, closing the main engine's
    window only hides it.
- **macOS:** to keep the app running when its last window closes, return
  `false` from `applicationShouldTerminateAfterLastWindowClosed` in the
  `AppDelegate`. For a menu-bar-only app, set `LSUIElement` in `Info.plist`.
  The ⌥ Space shortcut uses Carbon's `RegisterEventHotKey`, which needs no
  Accessibility permission.
