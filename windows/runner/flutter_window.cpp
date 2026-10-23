#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

#include <flutter_tray_popover/flutter_tray_popover_windows.h>

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // The popover runs in a second Flutter engine, created by the
  // flutter_tray_popover plugin, and a new engine starts with no plugins.
  // Only the app can register its own, so it does that here for the popover
  // engine; otherwise the popover's calls fail with MissingPluginException.
  // AGENT_DEMO_SKIP_PLUGINS=1 leaves them out to show that failure.
  char skip[2] = {};
  if (GetEnvironmentVariableA("AGENT_DEMO_SKIP_PLUGINS", skip, sizeof(skip)) == 0 ||
      skip[0] != '1') {
    FlutterTrayPopoverPluginSetEngineCreatedCallback(
        [](flutter::PluginRegistry* registry) { RegisterPlugins(registry); });
  }

  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The app lives in the tray: the main window starts hidden (the engine still
  // runs), and the tray popover shows it on demand.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
