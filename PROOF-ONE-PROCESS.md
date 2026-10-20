# Proof: two Flutter engines in one process

The tray popover (engine B) and the chat window (engine A) are **two Flutter
engines inside one OS process**, not two processes. Each engine runs its own
Dart isolate, and both share **one copy of the Rust library**, whose state
they reach through flutter_rust_bridge (FRB).

```
one OS process (agent_tray_demo)
├─ Flutter engine A → Dart isolate 1 → tray icon + chat window
├─ Flutter engine B → Dart isolate 2 → tray popover
└─ librust_lib_agent_tray_demo.so (loaded once) → shared AgentSnapshot
```

- [1. What the running system shows](#1-what-the-running-system-shows)
  - [1.1 One process, no children](#11-one-process-no-children)
  - [1.2 Every window belongs to that process](#12-every-window-belongs-to-that-process)
  - [1.3 Two engines: two sets of engine threads](#13-two-engines-two-sets-of-engine-threads)
  - [1.4 Two Dart isolates in one Dart VM](#14-two-dart-isolates-in-one-dart-vm)
  - [1.5 One copy of the Flutter engine and of the Rust library](#15-one-copy-of-the-flutter-engine-and-of-the-rust-library)
  - [1.6 Both engines see the same state](#16-both-engines-see-the-same-state)
- [2. The code that makes it possible](#2-the-code-that-makes-it-possible)
- [3. Reproduce it](#3-reproduce-it)

## 1. What the running system shows

Sections 1.1, 1.2, 1.3 and 1.5 were captured on 2026-10-20 from the installed
release build (`linux/packaging/install.sh`) on Ubuntu 24.04 (GNOME, X11
through XWayland). It was started from the app grid, with no window opened:
engine B is created hidden at launch, so both engines were already running.
Section 1.4 needs the Dart VM service, which only debug builds have, so it
comes from a debug run on 2026-10-19.

### 1.1 One process, no children

```
$ ps -o pid,ppid,nlwp,rss,cmd -C agent_tray_demo
    PID    PPID NLWP   RSS CMD
 113357    4033   60 189216 /home/christian/.local/share/agent_tray_demo/agent_tray_demo

$ ps --ppid 113357 -o pid= | wc -l
0
```

There's exactly one `agent_tray_demo` process, and it hasn't started any
child process. If engine B were a separate process, there would be a second
line here, or a child.

### 1.2 Every window belongs to that process

```
$ xprop -id <window> _NET_WM_PID      # for each of the app's X11 windows
0x1a00030 "Another"                  pid=113357   ← tray icon
0x1a00035 (has no name)              pid=113357   ← popover, engine B
0x1a00007 "Another — agent client"   pid=113357   ← chat window, engine A
```

The tray icon, the popover and the chat window are all owned by PID 113357.

### 1.3 Two engines: two sets of engine threads

```
$ cat /proc/113357/task/*/comm | grep '^io\.flutter' | sort | uniq -c
      2 io.flutter.io
      2 io.flutter.rast
```

Every Flutter engine starts its own I/O thread and raster thread. Two of each
in one process's thread list means two engines in that process. On Linux each
engine's UI work runs on the shared GTK main thread, so there's no separate UI
thread to count.

### 1.4 Two Dart isolates in one Dart VM

From a debug build (PID 24321), asking its Dart VM service:

```
$ curl -s $VM_SERVICE/getVM
vm pid: 24321
isolate isolates/8125096608763831 main
isolate isolates/2111368719695815 main
```

One Dart VM, in the app's own PID, runs two root isolates: one per engine,
each started from `main`. Isolates don't share memory, which is why the
engines share state through Rust (section 2.3).

### 1.5 One copy of the Flutter engine and of the Rust library

```
$ for lib in librust_lib_agent_tray_demo libflutter_linux_gtk; do
    echo "$lib: $(grep $lib /proc/113357/maps | awk '{print $5}' | sort -u | wc -l) inode(s)," \
         "segments: $(grep $lib /proc/113357/maps | awk '{print $2}' | tr '\n' ' ')"
  done
librust_lib_agent_tray_demo: 1 inode(s), segments: r--p r-xp r--p rw-p
libflutter_linux_gtk: 1 inode(s), segments: r--p r-xp r--p rw-p
```

Each library is **one file mapped once**. The four segments are the usual parts
of a single mapping: read-only, code, read-only data and **writable
data**. That one writable data segment holds the Rust `static`s both engines
use.

### 1.6 Both engines see the same state

The chat window (engine A) and the popover (engine B), captured back to back
during a simulated iPhone run started from the chat window:

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

`desktop_multi_window` (`linux/multi_window_manager.cc`, version 0.3.1) makes a
new window by creating a new Flutter view, and with it a new engine, in the
current process. It doesn't launch a program:

```c
g_autoptr(FlDartProject) project = fl_dart_project_new();            // line 95
const char* entrypoint_args[] = {"multi_window", window_id.c_str(),  // line 96
                                 config.arguments.c_str(), nullptr};
...
auto fl_view = fl_view_new(project);                                 // line 102: new engine
```

Its Linux code contains no `fork`, `exec`, `g_spawn` or `posix_spawn`. On
macOS it does the same with `FlutterViewController(project:)`.

### 2.2 One entrypoint, two roles

Both engines run the same Dart `main`, and engine B gets the arguments above
(`lib/main.dart`):

```dart
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Each engine has its own Dart isolate and must init the bridge; the Rust
  // library itself is loaded once per process, so its state is shared.
  await RustLib.init();

  if (args.firstOrNull == 'multi_window') {
    runApp(await bootTrayPanel());          // engine B: the popover
  } else {
    await attachEngine(name: mainEngineName);
    await recordMemoryMark(label: 'main engine ready');
    runApp(const MainApp());                // engine A: tray + chat window
  }
}
```

Engine A creates engine B, hidden, at launch (`lib/main_window.dart`):

```dart
Future<WindowController> _startPopoverEngine() async {
  await recordMemoryMark(label: _beforeTrayMark);
  return WindowController.create(
    const WindowConfiguration(arguments: trayPanelArgument, hiddenAtLaunch: true),
  );
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

A new engine starts with no platform-channel plugins, so the runner registers
them for every engine `desktop_multi_window` creates
(`linux/runner/my_application.cc`):

```c
desktop_multi_window_plugin_set_window_created_callback(
    [](FlPluginRegistry* registry) {   // runs for each new engine, in-process
      fl_register_plugins(registry);
      panel_window_register(registry);
    });
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
for lib in librust_lib_agent_tray_demo libflutter_linux_gtk; do
  echo "$lib: $(grep "$lib" /proc/"$P"/maps | awk '{print $5}' | sort -u | wc -l) inode(s)"
done
```

For 1.4, run a debug build (`flutter run -d linux`) and query the VM service
URL it prints:

```bash
curl -s "$VM_SERVICE/getVM" | python3 -c \
  "import json,sys; v=json.load(sys.stdin)['result']; print('vm pid', v['pid']); [print(i['id']) for i in v['isolates']]"
```
