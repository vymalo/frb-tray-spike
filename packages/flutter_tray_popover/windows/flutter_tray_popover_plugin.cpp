#include "flutter_tray_popover_plugin.h"

#include <windows.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <windowsx.h>

#include <flutter/plugin_registry.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "include/flutter_tray_popover/flutter_tray_popover_windows.h"

namespace flutter_tray_popover {
namespace {

constexpr wchar_t kPopoverWindowClass[] = L"FLUTTER_TRAY_POPOVER_WINDOW";
constexpr UINT kTrayMessage = WM_APP + 0x5e1;
constexpr UINT kTrayIconId = 1;
constexpr int kScreenMargin = 12;  // logical pixels
// A click can arrive as more than one tray event; see OnTrayClick.
constexpr ULONGLONG kDuplicateClickMs = 250;
// Clicking the tray icon while the popover is open first takes activation
// away from the popover, which closes it; that same click must not reopen it.
constexpr ULONGLONG kReopenGuardMs = 400;
// DWMWA_WINDOW_CORNER_PREFERENCE / DWMWCP_ROUND, from Windows 11's SDK.
constexpr DWORD kDwmWindowCornerPreference = 33;
constexpr DWORD kDwmCornerRound = 2;

// Adapts an engine created through the C API to the C++ PluginRegistry the
// app's generated RegisterPlugins() takes.
class EngineRegistry : public flutter::PluginRegistry {
 public:
  explicit EngineRegistry(FlutterDesktopEngineRef engine) : engine_(engine) {}

  FlutterDesktopPluginRegistrarRef GetRegistrarForPlugin(
      const std::string& plugin_name) override {
    return FlutterDesktopEngineGetPluginRegistrar(engine_, plugin_name.c_str());
  }

 private:
  FlutterDesktopEngineRef engine_;
};

// One per process, shared by every engine's registration of the plugin: both
// engines are in this process and see the same tray icon and popover.
struct State {
  std::vector<FlutterTrayPopoverPlugin*> plugins;  // one per engine, for events
  HWND main_window = nullptr;  // top-level window of the engine that called setUp
  HWND popover = nullptr;      // popover host window
  HWND popover_view = nullptr; // engine B's Flutter view, a child of popover
  FlutterDesktopViewControllerRef popover_controller = nullptr;
  FlutterDesktopEngineRef popover_engine = nullptr;
  NOTIFYICONDATAW icon = {};
  bool icon_added = false;
  int width = 440;   // logical pixels
  int height = 330;  // logical pixels
  ULONGLONG last_click_ms = 0;
  ULONGLONG hidden_by_focus_loss_ms = 0;
  FlutterTrayPopoverEngineCreatedCallback engine_created = nullptr;
  WNDPROC main_window_proc = nullptr;  // the runner's, when closing only hides
};

State& state() {
  static State s;
  return s;
}

std::wstring Widen(const std::string& text) {
  if (text.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                   static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                      wide.data(), length);
  return wide;
}

std::wstring ExecutableDirectory() {
  wchar_t path[MAX_PATH];
  DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring directory(path, length);
  return directory.substr(0, directory.find_last_of(L"\\/"));
}

std::wstring AssetPath(const std::string& asset) {
  std::wstring relative = Widen(asset);
  std::replace(relative.begin(), relative.end(), L'/', L'\\');
  return ExecutableDirectory() + L"\\data\\flutter_assets\\" + relative;
}

// Loads the tray icon from a Flutter asset: a .ico file, or a PNG (which
// CreateIconFromResourceEx accepts as icon image data). Falls back to the
// app's own icon (the runner's resource 101), then the system default.
HICON LoadTrayIcon(const std::string& asset) {
  int size = GetSystemMetrics(SM_CXSMICON);
  std::wstring path = AssetPath(asset);
  HICON icon = static_cast<HICON>(
      LoadImageW(nullptr, path.c_str(), IMAGE_ICON, size, size, LR_LOADFROMFILE));
  if (icon == nullptr) {
    std::ifstream file(path, std::ios::binary);
    std::vector<BYTE> bytes((std::istreambuf_iterator<char>(file)),
                            std::istreambuf_iterator<char>());
    if (!bytes.empty()) {
      icon = CreateIconFromResourceEx(bytes.data(),
                                      static_cast<DWORD>(bytes.size()), TRUE,
                                      0x00030000, size, size, LR_DEFAULTCOLOR);
    }
  }
  if (icon == nullptr) icon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101));
  if (icon == nullptr) icon = LoadIconW(nullptr, IDI_APPLICATION);
  return icon;
}

void BroadcastVisibility(bool visible) {
  for (FlutterTrayPopoverPlugin* plugin : state().plugins) {
    plugin->SendVisibility(visible);
  }
}

bool PopoverVisible() {
  return state().popover != nullptr && IsWindowVisible(state().popover);
}

// Puts the popover next to the tray icon, on whichever edge the taskbar is
// on, kept within the monitor's work area. Without the icon's position it
// goes to the bottom-right corner, where the tray usually is.
void PlacePopover(int anchor_x) {
  State& s = state();
  NOTIFYICONIDENTIFIER id = {sizeof(id)};
  id.hWnd = s.popover;
  id.uID = kTrayIconId;
  RECT icon = {};
  bool have_icon = SUCCEEDED(Shell_NotifyIconGetRect(&id, &icon));
  POINT anchor = have_icon ? POINT{(icon.left + icon.right) / 2,
                                   (icon.top + icon.bottom) / 2}
                           : POINT{anchor_x, 0};
  HMONITOR monitor = have_icon || anchor_x >= 0
                         ? MonitorFromPoint(anchor, MONITOR_DEFAULTTOPRIMARY)
                         : MonitorFromWindow(nullptr, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfoW(monitor, &info);
  const RECT& work = info.rcWork;

  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  int width = MulDiv(s.width, dpi, 96);
  int height = MulDiv(s.height, dpi, 96);
  int margin = MulDiv(kScreenMargin, dpi, 96);

  int x = have_icon || anchor_x >= 0 ? anchor.x - width / 2
                                     : work.right - width - margin;
  int y = work.bottom - height - margin;  // taskbar at the bottom (the default)
  if (have_icon) {
    if (icon.bottom <= work.top) {
      y = work.top + margin;  // taskbar at the top
    } else if (icon.right <= work.left) {
      x = work.left + margin;  // taskbar on the left
      y = anchor.y - height / 2;
    } else if (icon.left >= work.right) {
      x = work.right - width - margin;  // taskbar on the right
      y = anchor.y - height / 2;
    }
  }
  x = std::clamp(x, static_cast<int>(work.left) + margin,
                 static_cast<int>(work.right) - width - margin);
  y = std::clamp(y, static_cast<int>(work.top) + margin,
                 static_cast<int>(work.bottom) - height - margin);
  SetWindowPos(s.popover, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
}

void ShowPopover(int anchor_x) {
  State& s = state();
  if (s.popover == nullptr || PopoverVisible()) return;
  PlacePopover(anchor_x);
  ShowWindow(s.popover, SW_SHOW);
  // Allowed: this follows the user's click on the tray icon or in the app.
  SetForegroundWindow(s.popover);
  if (s.popover_view != nullptr) SetFocus(s.popover_view);
  BroadcastVisibility(true);
}

void HidePopover() {
  if (!PopoverVisible()) return;
  ShowWindow(state().popover, SW_HIDE);
  BroadcastVisibility(false);
}

void TogglePopover(int anchor_x) {
  if (PopoverVisible()) {
    HidePopover();
  } else if (GetTickCount64() - state().hidden_by_focus_loss_ms > kReopenGuardMs) {
    ShowPopover(anchor_x);
  }
}

void OnTrayClick(int x) {
  State& s = state();
  ULONGLONG now = GetTickCount64();
  if (now - s.last_click_ms < kDuplicateClickMs) return;
  s.last_click_ms = now;
  TogglePopover(x);
}

LRESULT CALLBACK PopoverWindowProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  State& s = state();
  if (s.popover_controller != nullptr) {
    LRESULT result;
    if (FlutterDesktopViewControllerHandleTopLevelWindowProc(
            s.popover_controller, window, message, wparam, lparam, &result)) {
      return result;
    }
  }
  switch (message) {
    case kTrayMessage:
      // NOTIFYICON_VERSION_4: the event is in LOWORD(lparam), the click's
      // screen position in wparam. Any click toggles the popover; its menu,
      // if any, is drawn by Flutter.
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
        case WM_CONTEXTMENU:
          OnTrayClick(GET_X_LPARAM(wparam));
          return 0;
      }
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        // Clicking anywhere outside the popover closes it.
        if (PopoverVisible()) {
          s.hidden_by_focus_loss_ms = GetTickCount64();
          HidePopover();
        }
      } else if (s.popover_view != nullptr) {
        SetFocus(s.popover_view);
      }
      return 0;
    case WM_SIZE:
      if (s.popover_view != nullptr) {
        RECT client;
        GetClientRect(window, &client);
        MoveWindow(s.popover_view, 0, 0, client.right - client.left,
                   client.bottom - client.top, TRUE);
      }
      return 0;
    case WM_CLOSE:
      HidePopover();
      return 0;
    case WM_FONTCHANGE:
      if (s.popover_engine != nullptr) {
        FlutterDesktopEngineReloadSystemFonts(s.popover_engine);
      }
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void CreateTrayIcon(const std::string& asset) {
  State& s = state();
  s.icon = {};
  s.icon.cbSize = sizeof(s.icon);
  s.icon.hWnd = s.popover;
  s.icon.uID = kTrayIconId;
  s.icon.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  s.icon.uCallbackMessage = kTrayMessage;
  s.icon.hIcon = LoadTrayIcon(asset);
  if (s.main_window != nullptr) {
    GetWindowTextW(s.main_window, s.icon.szTip, ARRAYSIZE(s.icon.szTip));
  }
  s.icon_added = Shell_NotifyIconW(NIM_ADD, &s.icon) == TRUE;
  s.icon.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &s.icon);
}

void RemoveTrayIcon() {
  State& s = state();
  if (!s.icon_added) return;
  Shell_NotifyIconW(NIM_DELETE, &s.icon);
  s.icon_added = false;
}

// The popover's host window and its Flutter engine, started hidden so the
// first click opens an already running popover. The engine starts at the
// named Dart entry point (kept in release builds by
// `@pragma('vm:entry-point')`). A borderless tool window, top-most and out
// of the taskbar; Windows 11 rounds its corners. Windows can't make a child
// Flutter view see-through, so setUp reports it as opaque and the popover
// draws edge to edge.
void CreatePopover(const std::string& entrypoint) {
  State& s = state();
  HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {sizeof(window_class)};
  window_class.lpfnWndProc = PopoverWindowProc;
  window_class.hInstance = instance;
  window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  window_class.lpszClassName = kPopoverWindowClass;
  RegisterClassExW(&window_class);

  s.popover = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
                              kPopoverWindowClass, L"", WS_POPUP, 0, 0,
                              s.width, s.height, nullptr, nullptr, instance,
                              nullptr);
  DwmSetWindowAttribute(s.popover, kDwmWindowCornerPreference, &kDwmCornerRound,
                        sizeof(kDwmCornerRound));

  FlutterDesktopEngineProperties properties = {};
  properties.assets_path = L"data\\flutter_assets";
  properties.icu_data_path = L"data\\icudtl.dat";
  properties.aot_library_path = L"data\\app.so";
  properties.dart_entrypoint = entrypoint.c_str();
  s.popover_engine = FlutterDesktopEngineCreate(&properties);
  if (s.popover_engine == nullptr) return;

  // Plugins first, so they're there before the popover's Dart code runs.
  if (s.engine_created != nullptr) {
    EngineRegistry registry(s.popover_engine);
    s.engine_created(&registry);
  } else {
    OutputDebugStringW(
        L"flutter_tray_popover: no engine-created callback set; the popover "
        L"engine has no plugins. See "
        L"FlutterTrayPopoverPluginSetEngineCreatedCallback().\n");
  }

  UINT dpi = FlutterDesktopGetDpiForHWND(s.popover);
  // Takes ownership of the engine and starts it.
  s.popover_controller = FlutterDesktopViewControllerCreate(
      MulDiv(s.width, dpi, 96), MulDiv(s.height, dpi, 96), s.popover_engine);
  if (s.popover_controller == nullptr) return;
  s.popover_view = FlutterDesktopViewGetHWND(
      FlutterDesktopViewControllerGetView(s.popover_controller));
  SetParent(s.popover_view, s.popover);
  RECT client;
  GetClientRect(s.popover, &client);
  MoveWindow(s.popover_view, 0, 0, client.right - client.left,
             client.bottom - client.top, TRUE);
}

// Closing the main window only hides it; the app lives on in the tray until
// quit. Every other message goes to the runner's own window procedure.
LRESULT CALLBACK MainWindowProc(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  if (message == WM_CLOSE) {
    ShowWindow(window, SW_HIDE);
    return 0;
  }
  return CallWindowProcW(state().main_window_proc, window, message, wparam,
                         lparam);
}

const flutter::EncodableValue* Lookup(const flutter::EncodableMap* args,
                                      const char* key) {
  if (args == nullptr) return nullptr;
  auto it = args->find(flutter::EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

HWND TopLevelWindow(flutter::PluginRegistrarWindows* registrar) {
  flutter::FlutterView* view = registrar->GetView();
  if (view == nullptr) return nullptr;
  return GetAncestor(view->GetNativeWindow(), GA_ROOT);
}

}  // namespace

// static
void FlutterTrayPopoverPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "flutter_tray_popover",
      &flutter::StandardMethodCodec::GetInstance());
  auto plugin =
      std::make_unique<FlutterTrayPopoverPlugin>(registrar, std::move(channel));
  registrar->AddPlugin(std::move(plugin));
}

FlutterTrayPopoverPlugin::FlutterTrayPopoverPlugin(
    flutter::PluginRegistrarWindows* registrar,
    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel)
    : registrar_(registrar), channel_(std::move(channel)) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  state().plugins.push_back(this);
}

FlutterTrayPopoverPlugin::~FlutterTrayPopoverPlugin() {
  auto& plugins = state().plugins;
  plugins.erase(std::remove(plugins.begin(), plugins.end(), this),
                plugins.end());
  // The engine that set up the tray going away means the app is closing.
  if (set_up_tray_) RemoveTrayIcon();
}

void FlutterTrayPopoverPlugin::SendVisibility(bool visible) {
  channel_->InvokeMethod("visibilityChanged",
                         std::make_unique<flutter::EncodableValue>(visible));
}

void FlutterTrayPopoverPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  State& s = state();
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();

  if (method == "setUp") {
    if (s.popover == nullptr) {
      set_up_tray_ = true;
      s.main_window = TopLevelWindow(registrar_);
      if (const auto* width = Lookup(args, "width")) s.width = std::get<int>(*width);
      if (const auto* height = Lookup(args, "height")) s.height = std::get<int>(*height);
      const auto* keep_alive = Lookup(args, "keepAliveOnWindowClose");
      if (s.main_window != nullptr &&
          (keep_alive == nullptr || std::get<bool>(*keep_alive))) {
        s.main_window_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
            s.main_window, GWLP_WNDPROC,
            reinterpret_cast<LONG_PTR>(MainWindowProc)));
      }
      const auto* entrypoint = Lookup(args, "entrypoint");
      CreatePopover(entrypoint != nullptr ? std::get<std::string>(*entrypoint)
                                          : "trayMain");
      const auto* icon = Lookup(args, "icon");
      CreateTrayIcon(icon != nullptr ? std::get<std::string>(*icon) : "");
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("transparent"), flutter::EncodableValue(false)},
    }));
  } else if (method == "show") {
    ShowPopover(-1);
    result->Success();
  } else if (method == "hide") {
    HidePopover();
    result->Success();
  } else if (method == "toggle") {
    TogglePopover(-1);
    result->Success();
  } else if (method == "isVisible") {
    result->Success(flutter::EncodableValue(PopoverVisible()));
  } else if (method == "isTransparent") {
    result->Success(flutter::EncodableValue(false));
  } else if (method == "showMainWindow") {
    HWND window = s.main_window != nullptr ? s.main_window : TopLevelWindow(registrar_);
    if (window != nullptr) {
      ShowWindow(window, SW_SHOW);
      SetForegroundWindow(window);
    }
    result->Success();
  } else if (method == "quit") {
    result->Success();
    RemoveTrayIcon();
    // The runner quits when its main window is destroyed.
    if (s.main_window != nullptr) {
      DestroyWindow(s.main_window);
    } else {
      PostQuitMessage(0);
    }
  } else {
    result->NotImplemented();
  }
}

}  // namespace flutter_tray_popover

void FlutterTrayPopoverPluginSetEngineCreatedCallback(
    FlutterTrayPopoverEngineCreatedCallback callback) {
  flutter_tray_popover::state().engine_created = callback;
}
