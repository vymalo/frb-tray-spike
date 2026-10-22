# Proof: two Flutter engines in one process

The tray popover (engine B) and the chat window (engine A) are **two Flutter
engines inside one OS process**, not two processes. Each engine runs its own
Dart isolate, and both share **one copy of the Rust library**, whose state
they reach through flutter_rust_bridge (FRB).

```
one OS process (agent_tray_demo)
├─ Flutter engine A → Dart isolate 1 → chat window; sets up the tray
├─ Flutter engine B → Dart isolate 2 → tray popover, created by the plugin
├─ libflutter_tray_popover_plugin.so (loaded once) → tray icon, popover window
└─ librust_lib_agent_tray_demo.so (loaded once) → shared AgentSnapshot
```

- [1. What the running system shows](#1-what-the-running-system-shows)
  - [1.1 One process, no children](#11-one-process-no-children)
  - [1.2 Every window belongs to that process](#12-every-window-belongs-to-that-process)
  - [1.3 Two engines: two sets of engine threads](#13-two-engines-two-sets-of-engine-threads)
  - [1.4 Two Dart isolates in one Dart VM](#14-two-dart-isolates-in-one-dart-vm)
  - [1.5 One copy of each library](#15-one-copy-of-each-library)
  - [1.6 Both engines see the same state](#16-both-engines-see-the-same-state)
- [2. The code that makes it possible](#2-the-code-that-makes-it-possible)
- [3. Reproduce it](#3-reproduce-it)

## 1. What the running system shows

Sections 1.1 to 1.5 were captured on 2026-10-22 from the build that uses the
[`flutter_tray_popover`](packages/flutter_tray_popover) plugin, on Ubuntu 24.04
(GNOME, X11 through XWayland). 1.1, 1.2, 1.3 and 1.5 come from the installed
release build (`linux/packaging/install.sh`), started from the app grid with no
window opened: the plugin creates engine B hidden at launch, so both engines
were already running. 1.4 needs the Dart VM service, which only debug builds
have, so it comes from a debug run of the same code.

### 1.1 One process, no children

```
$ ps -o pid,ppid,nlwp,rss,cmd -C agent_tray_demo
    PID    PPID NLWP   RSS CMD
 165725    1168   61 192656 /home/christian/.local/share/agent_tray_demo/agent_tray_demo

$ ps --ppid 165725 -o pid= | wc -l
0
```

There's exactly one `agent_tray_demo` process, and it hasn't started any
child process. If engine B were a separate process, there would be a second
line here, or a child.

### 1.2 Every window belongs to that process

```
$ xprop -id <window> _NET_WM_PID      # for each of the app's X11 windows
0xe00030 "dev.demo.agent_tray_demo"   pid=165725   ← tray icon (plugin)
0xe00035 _NET_WM_WINDOW_TYPE_UTILITY  pid=165725   ← popover, engine B (plugin)
0xe00007 "Another — agent client"     pid=165725   ← chat window, engine A
```

The tray icon, the popover and the chat window are all owned by PID 165725.

### 1.3 Two engines: two sets of engine threads

```
$ cat /proc/165725/task/*/comm | grep '^io\.flutter' | sort | uniq -c
      2 io.flutter.io
      2 io.flutter.rast
```

Every Flutter engine starts its own I/O thread and raster thread. Two of each
in one process's thread list means two engines in that process. On Linux each
engine's UI work runs on the shared GTK main thread, so there's no separate UI
thread to count.

### 1.4 Two Dart isolates in one Dart VM

From a debug build (PID 166200), asking its Dart VM service:

```
$ curl -s $VM_SERVICE/getVM
vm pid: 166200
isolate isolates/1364051846502787 main
isolate isolates/8042944666079187 main
```

One Dart VM, in the app's own PID, runs two root isolates: one per engine.
Both are named `main` because on Linux engine B also starts in `main` (with a
`tray_popover` argument that routes it to `trayMain`; section 2.2). Isolates
don't share memory, which is why the engines share state through Rust
(section 2.3).

### 1.5 One copy of each library

```
$ for lib in librust_lib_agent_tray_demo libflutter_linux_gtk libflutter_tray_popover_plugin; do
    echo "$lib: $(grep $lib /proc/165725/maps | awk '{print $5}' | sort -u | wc -l) inode(s)," \
         "segments: $(grep $lib /proc/165725/maps | awk '{print $2}' | tr '\n' ' ')"
  done
librust_lib_agent_tray_demo: 1 inode(s), segments: r--p r-xp r--p rw-p
libflutter_linux_gtk: 1 inode(s), segments: r--p r-xp r--p rw-p
libflutter_tray_popover_plugin: 1 inode(s), segments: r--p r-xp r--p r--p rw-p
```

Each library is **one file mapped once**. The segments are the usual parts of
a single mapping: read-only, code, read-only data and **writable data**. The
Rust library's one writable data segment holds the `static`s both engines use,
and the plugin's holds its one tray icon and popover, shared by both engines'
registrations of the plugin.

### 1.6 Both engines see the same state

The chat window (engine A) and the popover (engine B), captured back to back
during a simulated iPhone run started from the chat window. This capture is
from 2026-10-19, before the tray moved into the plugin; the shared Rust state
it shows hasn't changed since, and the end-to-end test below passes with the
plugin build:

| | Engine A: chat window | Engine B: popover |
|---|---|---|
| Revision | `rev 44` | `rev 44` |
| Progress | `checkout 14/40`, "Working on checkout… step 14 of 40" | `14/40`, "Working on checkout… step 14 of 40" |
| Engines | "2 engines share this state (main + tray)" | "2 engines share this state" |

`revision` is a counter in Rust that every state change increments, so both
engines showing the same value means they read the same Rust state. The
end-to-end test asserts the same thing automatically:
`flutter drive … --target=integration_test/two_engines_drive.dart` types a
prompt into engine B's popover and checks that engine A's chat window shows it,
with `engines == ['main', 'tray']`.

## 2. The code that makes it possible

### 2.1 Engine B is created inside the running process

The [`flutter_tray_popover`](packages/flutter_tray_popover) plugin creates
engine B by creating a new Flutter view, and with it a new engine, in the
current process. It doesn't launch a program
(`packages/flutter_tray_popover/linux/flutter_tray_popover_plugin.cc`):

```c
void create_popover() {
  ...
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  const char* args[] = {kPopoverArgument, nullptr};          // "tray_popover"
  fl_dart_project_set_dart_entrypoint_arguments(project,
                                                const_cast<char**>(args));
  FlView* view = fl_view_new(project);                       // new engine, same process
  ...
  // Plugins first, so they're there before the popover's Dart code runs.
  if (s.engine_created != nullptr) {
    s.engine_created(FL_PLUGIN_REGISTRY(view));
  }
  ...
  // Realizing the view (which realizes its still hidden window too) starts
  // the engine, so the first click opens an already running popover.
  gtk_widget_realize(GTK_WIDGET(view));
```

The plugin contains no `fork`, `exec`, `g_spawn` or `posix_spawn`. On macOS
it does the same with `FlutterEngine(name:project:)`, `run(withEntrypoint:
"trayMain")` and `FlutterViewController(engine:)`
(`macos/Classes/FlutterTrayPopoverPlugin.swift`).

### 2.2 One codebase, two entry points

Both engines run the same app (`lib/main.dart`). Engine A runs `appMain`;
engine B runs `trayMain`, which macOS starts by name. The Linux embedder can
only start an engine at `main`, so there engine B runs `main` with the
`tray_popover` argument from 2.1, and `TrayPopover.run` routes it:

```dart
void main(List<String> args) =>
    TrayPopover.run(args: args, app: appMain, popover: trayMain);

/// Engine A: the chat window, which also sets up the tray and the popover.
Future<void> appMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Each engine has its own Dart isolate and must init the bridge; the Rust
  // library itself is loaded once per process, so its state is shared.
  await RustLib.init();
  await attachEngine(name: mainEngineName);
  await recordMemoryMark(label: 'main engine ready');
  runApp(const MainApp());
}

/// Engine B: the popover. The plugin starts this engine at `trayMain` by
/// name on macOS, so it must survive tree-shaking in release builds.
@pragma('vm:entry-point')
Future<void> trayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(await bootTrayPanel());
}
```

Engine A asks the plugin for the tray and engine B, at launch
(`lib/main_window.dart`):

```dart
Future<void> _setUpTray() async {
  await recordMemoryMark(label: _beforeTrayMark);
  await TrayPopover.setUp(
    icon: 'assets/tray_icon.png',
    optionSpaceShortcut: true, // macOS
  );
  ...
}
```

### 2.3 Shared state lives in the one Rust library

Because there's one process, there's one copy of the Rust library, and these
`static`s exist once for both engines (`rust/src/api/agent.rs`):

```rust
fn core() -> MutexGuard<'static, Core> {
    static CORE: OnceLock<Mutex<Core>> = OnceLock::new();
    CORE.get_or_init(|| Mutex::new(Core::new()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

fn sinks() -> MutexGuard<'static, Vec<StreamSink<AgentSnapshot>>> {
    static SINKS: Mutex<Vec<StreamSink<AgentSnapshot>>> = Mutex::new(Vec::new());
    SINKS.lock().unwrap_or_else(|e| e.into_inner())
}
```

Each engine registers itself and subscribes with its own stream. Every change
is sent to both:

```rust
pub fn attach_engine(name: String) -> u32 {   // "main" from A, "tray" from B
    let count = {
        let mut core = core();
        core.snap.engines.push(name);
        core.snap.engines.len() as u32
    };
    broadcast();
    count
}

fn broadcast() {
    let snap = {
        let mut core = core();
        core.snap.revision += 1;
        core.snap.rss_kb = process_rss_kb();
        core.snap.clone()
    };
    // One sink per engine; both receive the same snapshot.
    sinks().retain(|sink| sink.add(snap.clone()).is_ok());
}
```

If engine B were a separate process, it would load its own copy of the
library with its own `CORE`. `engines` would then never contain both `main`
and `tray`, and the two windows couldn't show the same `revision`.

### 2.4 Why a second engine needs plugin registration but not FRB setup

A new engine starts with no platform-channel plugins, and only the app can call
its own generated registrant. So the app's runner hands the plugin a callback,
which the plugin calls for engine B right after creating it (2.1)
(`linux/runner/my_application.cc`):

```c
flutter_tray_popover_plugin_set_engine_created_callback(
    [](FlPluginRegistry* registry) { fl_register_plugins(registry); });
```

FRB needs no such step. It reaches the already-loaded Rust library directly
through `dart:ffi`, so `RustLib.init()` in each isolate is enough.

## 3. Reproduce it

Start the app, then run (Linux, X11 through XWayland):

```bash
P=$(pgrep -x agent_tray_demo | head -1)

# 1.1 one process, no children
ps -o pid,ppid,nlwp,rss,cmd -C agent_tray_demo
ps --ppid "$P" -o pid= | wc -l

# 1.2 owner of every app window
for w in $(xwininfo -root -tree | grep '"dev.demo.agent_tray_demo"' | awk '{print $1}'); do
  echo "$w $(xprop -id "$w" _NET_WM_PID)"
done

# 1.3 engine threads
for t in /proc/"$P"/task/*; do cat "$t"/comm; done | grep '^io\.flutter' | sort | uniq -c

# 1.5 each library is one file (one inode), mapped once
for lib in librust_lib_agent_tray_demo libflutter_linux_gtk libflutter_tray_popover_plugin; do
  echo "$lib: $(grep "$lib" /proc/"$P"/maps | awk '{print $5}' | sort -u | wc -l) inode(s)"
done
```

For 1.4, run a debug build (`flutter run -d linux`) and query the VM service
URL it prints:

```bash
curl -s "$VM_SERVICE/getVM" | python3 -c \
  "import json,sys; v=json.load(sys.stdin)['result']; print('vm pid', v['pid']); [print(i['id']) for i in v['isolates']]"
```
